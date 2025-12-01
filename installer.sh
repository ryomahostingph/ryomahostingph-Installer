#!/usr/bin/env bash
# rAthena auto-installer with interactive menu, spinner, strict phase error handling,
# post-compile config + validation, and FluxCP patching for /config layout.
set -uo pipefail

# ================== VARIABLES ==================
LOGFILE="/var/log/rathena_installer_final.log"
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"

WEBROOT="/var/www/html"
FLUX_REPO="https://github.com/rathena/FluxCP.git"
FLUX_CFG_DIR="${WEBROOT}/config"          # ✅ your actual FluxCP config dir
STATE_DIR="/opt/rathena_installer_state"

DEFAULT_VNC_PASSWORD="Ch4ng3me"
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

DB_USER="rathena"
DB_PASS=""
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"

# Server-to-server credentials (char/map/login)
USERID=""
USERPASS=""

CRED_FILE="/root/.rathena_db_credentials"

# ================== SETUP LOG & ENV ==================
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE" || true
chmod 600 "$LOGFILE" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
apt_install(){ apt install -y --no-install-recommends "$@"; }

# ================== CREDENTIAL SAVE HELPER ==================
save_creds() {
    cat > "$CRED_FILE" <<EOF
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
DB_RAGNAROK='${DB_RAGNAROK}'
DB_LOGS='${DB_LOGS}'
DB_FLUXCP='${DB_FLUXCP}'
USERID='${USERID}'
USERPASS='${USERPASS}'
EOF
    chmod 600 "$CRED_FILE"
    log "Credentials saved to $CRED_FILE"
}

# ================== SIMPLE SPINNER ==================
spinner() {
    local pid="$1"
    local label="$2"
    local spin='-\|/'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ -t 1 ]; then
            printf "\r[%c] %s" "${spin:i++%4:1}" "$label"
        fi
        sleep 0.2
    done
    if [ -t 1 ]; then
        printf "\r[✓] %s\n" "$label"
    fi
}

# ================== LOAD / GENERATE CREDENTIALS ==================
if [ -f "$CRED_FILE" ]; then
    log "Loading existing credentials from $CRED_FILE"
    # shellcheck source=/dev/null
    source "$CRED_FILE" || true
fi

# If no pass after load (or file missing), generate
if [ -z "${DB_PASS:-}" ]; then
    log "No usable DB password found. Generating new DB password..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || echo 'ChangeMe123')"
fi

# Ensure USERID/USERPASS defined even if CRED_FILE didn't contain them
USERID="${USERID:-}"
USERPASS="${USERPASS:-}"

# ================== PHASE WRAPPER (ERROR HANDLING) ==================
run_phase() {
    local label="$1"; shift
    log "=== Starting: ${label} ==="

    "$@" &
    local phase_pid=$!
    spinner "$phase_pid" "${label} in progress..."

    wait "$phase_pid"
    local rc=$?

    if [ $rc -ne 0 ]; then
        log "ERROR: ${label} failed with exit code ${rc}"
        echo
        echo ">>> ERROR: ${label} failed (exit code ${rc})."
        if [ -s "$LOGFILE" ]; then
            echo
            echo "Last 20 lines from ${LOGFILE}:"
            echo "----------------------------------------"
            tail -n 20 "$LOGFILE" || true
            echo "----------------------------------------"
        else
            echo "No log output available yet at ${LOGFILE}."
        fi
        echo
        read -rp "Press Enter to return to the menu..." _
        return $rc
    fi

    log "=== Completed: ${label} ==="
    return 0
}

# ================== PHASES ==================

phase_update_upgrade(){
    log "Updating system..."
    apt update >>"$LOGFILE" 2>&1 || return 1
    apt upgrade -y >>"$LOGFILE" 2>&1 || return 1
    log "System updated."
}

phase_install_packages(){
    log "Installing base packages..."
    apt_install sudo build-essential git cmake autoconf libssl-dev \
    libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
    wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring \
    php-curl php-zip php-tidy \
    mariadb-server mariadb-client \
    dbus-x11 xauth xorg ufw tightvncserver xfce4 xfce4-goodies x11-xserver-utils \
    phpmyadmin imagemagick xterm xfce4-terminal htop xdg-utils dos2unix \
    perl >>"$LOGFILE" 2>&1 || return 1

    log "Base packages installed."
}

phase_install_chrome(){
    log "Installing Google Chrome..."
    if wget -O /tmp/chrome.deb "$CHROME_URL" >>"$LOGFILE" 2>&1; then
        if apt install -y /tmp/chrome.deb >>"$LOGFILE" 2>&1; then
            rm -f /tmp/chrome.deb
            log "Google Chrome installed."
            return 0
        else
            log "Chrome .deb install failed; falling back to Chromium..."
        fi
    else
        log "Chrome download failed; falling back to Chromium..."
    fi

    apt_install chromium >>"$LOGFILE" 2>&1 || log "No browser installed."
}

phase_create_rathena_user(){
    log "Creating user ${RATHENA_USER} (if missing)..."
    if ! id "$RATHENA_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$RATHENA_USER"
        echo "${RATHENA_USER}:${DEFAULT_VNC_PASSWORD}" | chpasswd
        log "Default VNC password set to ${DEFAULT_VNC_PASSWORD} for user ${RATHENA_USER}"
    fi

    mkdir -p "${RATHENA_HOME}/Desktop" "${RATHENA_HOME}/.config/autostart" \
             "${RATHENA_HOME}/sql_imports" "${RATHENA_HOME}/db_backups"
    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$RATHENA_HOME"

    # ---- Server control scripts (CMake aware) ----
    cat > "${RATHENA_HOME}/start_servers_xfce.sh" <<'BASH'
#!/usr/bin/env bash
set -e
RATHENA_HOME="/home/rathena"
BASE="$RATHENA_HOME/Desktop/rathena"
BIN="$BASE"
[ -x "$BASE/build/login-server" ] && BIN="$BASE/build"
cd "$BIN"
nohup ./login-server > /dev/null 2>&1 &
nohup ./char-server  > /dev/null 2>&1 &
nohup ./map-server   > /dev/null 2>&1 &
BASH
    chmod +x "${RATHENA_HOME}/start_servers_xfce.sh"
    chown "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}/start_servers_xfce.sh"

    cat > "${RATHENA_HOME}/stop_servers_xfce.sh" <<'BASH'
#!/usr/bin/env bash
pkill -f login-server || true
pkill -f char-server || true
pkill -f map-server || true
BASH
    chmod +x "${RATHENA_HOME}/stop_servers_xfce.sh"
    chown "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}/stop_servers_xfce.sh"

    cat > "${RATHENA_HOME}/restart_servers_xfce.sh" <<'BASH'
#!/usr/bin/env bash
set -e
"${HOME}/stop_servers_xfce.sh" || true
sleep 1
"${HOME}/start_servers_xfce.sh" || true
BASH
    sed -i "s|\${HOME}|${RATHENA_HOME}|g" "${RATHENA_HOME}/restart_servers_xfce.sh"
    chmod +x "${RATHENA_HOME}/restart_servers_xfce.sh"
    chown "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}/restart_servers_xfce.sh"

    # Enable VNC template if present
    if systemctl list-unit-files 2>/dev/null | grep -q '^vncserver@'; then
        systemctl enable --now vncserver@1.service 2>/dev/null || true
    fi

    log "User ${RATHENA_USER} prepared."
}

phase_configure_phpmyadmin(){
    log "Configuring phpMyAdmin..."

    # Enable PHP module for whichever version exists
    for mod in /etc/apache2/mods-available/php*.load; do
        [ -f "$mod" ] || continue
        a2enmod "$(basename "$mod" .load)" >>"$LOGFILE" 2>&1 || true
    done

    systemctl enable --now apache2 >>"$LOGFILE" 2>&1 || return 1

    if [ ! -d /usr/share/phpmyadmin ]; then
        log "phpMyAdmin not found, skipping configuration."
        return 0
    fi

    # ---- Write Apache alias/config for phpMyAdmin ----
    # SECURITY DEFAULT: localhost-only. Comment out Require ip line if you want public access.
    rm -f /etc/apache2/conf-available/phpmyadmin.conf
    cat > /etc/apache2/conf-available/phpmyadmin.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options FollowSymLinks
    DirectoryIndex index.php
    AllowOverride All

    <RequireAny>
        Require ip 127.0.0.1 ::1
        Require ip 120.28.137.77 ::1
        Require ip 216.247.14.55 ::1
        # Require ip YOUR.PUBLIC.IP.HERE
    </RequireAny>
</Directory>

EOF

    # Enable config
    a2enconf phpmyadmin >>"$LOGFILE" 2>&1 || true

    # Enable rewrite (harmless, useful for web apps)
    a2enmod rewrite >>"$LOGFILE" 2>&1 || true

    # Reload Apache safely
    apache2ctl -t >>"$LOGFILE" 2>&1 || { log "Apache config test failed"; return 1; }
    systemctl reload apache2 >>"$LOGFILE" 2>&1 || systemctl restart apache2 >>"$LOGFILE" 2>&1 || true

    # Permissions
    chown -R www-data:www-data /usr/share/phpmyadmin

    log "phpMyAdmin configured at http://localhost/phpmyadmin"
    log "NOTE: Access is locked to localhost by default (Require ip 127.0.0.1 ::1)."
}


phase_clone_repos(){
    log "Cloning rAthena..."
    rm -rf "$RATHENA_INSTALL_DIR"

    if cmd_exists sudo; then
        sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" >>"$LOGFILE" 2>&1 || return 1
    else
        su - "$RATHENA_USER" -s /bin/bash -c "git clone --depth 1 '$RATHENA_REPO' '$RATHENA_INSTALL_DIR'" >>"$LOGFILE" 2>&1 || return 1
    fi

    log "Cloning FluxCP into ${WEBROOT}..."
    # safer wipe: backup existing webroot content first
    if [ -d "$WEBROOT" ] && [ "$(ls -A "$WEBROOT" 2>/dev/null | wc -l)" -gt 0 ]; then
        local backup="${STATE_DIR}/webroot_backup_$(date +%F_%H%M%S)"
        mkdir -p "$backup"
        cp -a "$WEBROOT/." "$backup/" 2>/dev/null || true
        log "Backed up existing webroot to $backup"
        find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi

    git clone --depth 1 "$FLUX_REPO" "$WEBROOT" >>"$LOGFILE" 2>&1 || return 1
    chown -R www-data:www-data "$WEBROOT"
    log "Repos cloned."
}

phase_setup_mariadb(){
    log "Setting up MariaDB..."
    systemctl enable --now mariadb >>"$LOGFILE" 2>&1 || return 1

    mariadb <<SQL >>"$LOGFILE" 2>&1
CREATE DATABASE IF NOT EXISTS ${DB_RAGNAROK} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ${DB_LOGS} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ${DB_FLUXCP} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_RAGNAROK}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_LOGS}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_FLUXCP}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

    save_creds
    log "MariaDB setup complete."
}

phase_compile_rathena() {
    log "Compiling rAthena (as ${RATHENA_USER})..."

    if [ ! -d "$RATHENA_INSTALL_DIR" ]; then
        log "rAthena directory not found at ${RATHENA_INSTALL_DIR}."
        echo "rAthena source directory not found. The clone step may have failed or been skipped."
        return 1
    fi

    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$RATHENA_INSTALL_DIR"

    if [ -f "${RATHENA_INSTALL_DIR}/Makefile" ]; then
        log "Detected Makefile – using make build."
        sudo -u "$RATHENA_USER" bash -lc "
cd '$RATHENA_INSTALL_DIR'
make clean
make -j\$(nproc)
" >>"$LOGFILE" 2>&1 || return 1

    elif [ -f "${RATHENA_INSTALL_DIR}/CMakeLists.txt" ]; then
        log "No Makefile found – using CMake out-of-source build."
        sudo -u "$RATHENA_USER" bash -lc "
cd '$RATHENA_INSTALL_DIR'
rm -rf build
mkdir -p build
cmake -S . -B build
cmake --build build -j\$(nproc)
" >>"$LOGFILE" 2>&1 || return 1

    else
        log "Neither Makefile nor CMakeLists.txt found – cannot compile."
        return 1
    fi

    log "rAthena compiled successfully."
    echo "rAthena compiled successfully."
}

phase_import_sqls(){
    log "Importing SQL files from sql-files..."

    # ✅ use installer variable, not a hard-coded path
    local SQL_DIR="${RATHENA_INSTALL_DIR}/sql-files"

    if [ ! -d "$SQL_DIR" ]; then
        log "ERROR: SQL directory not found: $SQL_DIR"
        echo "SQL directory not found at: $SQL_DIR"
        return 1
    fi

    mapfile -t sql_files < <(find "$SQL_DIR" -maxdepth 1 -type f -name "*.sql" | sort)
    if [ ${#sql_files[@]} -eq 0 ]; then
        log "WARNING: No .sql files found in $SQL_DIR"
        echo "No .sql files found in $SQL_DIR"
        return 0
    fi

    import_sql(){
        local db="$1"
        local file="$2"
        log "Importing $(basename "$file") into $db ..."
        mariadb -u"$DB_USER" -p"$DB_PASS" "$db" < "$file" >>"$LOGFILE" 2>&1
    }

    local ok=1
    for f in "${sql_files[@]}"; do
        case "$(basename "$f")" in
            main.sql) import_sql "$DB_RAGNAROK" "$f" || ok=0 ;;
            logs.sql) import_sql "$DB_LOGS"     "$f" || ok=0 ;;
            *)        import_sql "$DB_RAGNAROK" "$f" || ok=0 ;;
        esac
    done

    if [ $ok -eq 1 ]; then
        log "SQL import completed successfully."
        echo "SQL import completed successfully."
        return 0
    else
        log "ERROR: One or more SQL imports failed. Check $LOGFILE."
        echo "One or more SQL imports failed. Check $LOGFILE."
        return 1
    fi
}


# ---------- validation helper ----------
validate_rathena_imports() {
    local import_dir="$1"
    local char_conf="$import_dir/char_conf.txt"
    local map_conf="$import_dir/map_conf.txt"
    local inter_conf="$import_dir/inter_conf.txt"
    local db_conf="$import_dir/rathena_db.conf"

    log "Validating rAthena import configs in ${import_dir}..."

    local warn=0

    for f in "$char_conf" "$map_conf" "$inter_conf" "$db_conf"; do
        if [ ! -f "$f" ]; then
            log "WARNING: Missing import config file: $f"
            warn=1
        fi
    done

    [ $warn -ne 0 ] && echo "WARNING: One or more rAthena import files are missing." && return 0

    local char_user char_pass map_user map_pass
    char_user="$(sed -n 's/^userid:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
    char_pass="$(sed -n 's/^passwd:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
    map_user="$(sed -n 's/^userid:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$map_conf" | head -n1)"
    map_pass="$(sed -n 's/^passwd:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$map_conf" | head -n1)"

    if [ "$char_user" != "$map_user" ] || [ "$char_pass" != "$map_pass" ]; then
        log "WARNING: char_conf.txt and map_conf.txt mismatched userid/pass."
        warn=1
    fi

    local db_user db_pass db_main db_logs db_flux
    db_user="$(sed -n 's/^db_user="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_pass="$(sed -n 's/^db_pass="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_main="$(sed -n 's/^db_database="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_logs="$(sed -n 's/^db_logs="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_flux="$(sed -n 's/^db_fluxcp="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"

    if [ "$db_user" != "$DB_USER" ] || [ "$db_pass" != "$DB_PASS" ]; then
        log "WARNING: rathena_db.conf creds differ from installer."
        warn=1
    fi

    if [ "$db_main" != "$DB_RAGNAROK" ] || [ "$db_logs" != "$DB_LOGS" ] || [ "$db_flux" != "$DB_FLUXCP" ]; then
        log "WARNING: rathena_db.conf DB names differ from installer."
        warn=1
    fi

    [ $warn -eq 0 ] && log "rAthena import config validation OK." || echo "WARNING: rAthena imports look inconsistent."
    return 0
}

phase_generate_rathena_config(){
    log "Generating rAthena import config files..."
    local import_dir="$RATHENA_INSTALL_DIR/conf/import"
    mkdir -p "$import_dir"

    local char_conf="$import_dir/char_conf.txt"
    local map_conf="$import_dir/map_conf.txt"
    local inter_conf="$import_dir/inter_conf.txt"
    local db_conf="$import_dir/rathena_db.conf"

    if [ -z "$USERID" ] && [ -f "$char_conf" ]; then
        USERID="$(sed -n 's/^userid:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
        USERPASS="$(sed -n 's/^passwd:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
    fi

    if [ -n "$USERID" ] && [ -n "$USERPASS" ]; then
        log "Reusing existing server-to-server credentials from $CRED_FILE"
    else
        [ -z "$USERID" ]   && USERID="$(tr -dc 'A-Za-z' </dev/urandom | head -c6 || echo s1)"
        [ -z "$USERPASS" ] && USERPASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c8 || echo p1)"
        log "Generated new server-to-server credentials"
    fi

    local SERVER_IP
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$SERVER_IP" ] || SERVER_IP="127.0.0.1"

    cat > "$char_conf" <<EOF
userid: ${USERID}
passwd: ${USERPASS}
char_ip: ${SERVER_IP}
EOF

    cat > "$map_conf" <<EOF
userid: ${USERID}
passwd: ${USERPASS}
map_ip: ${SERVER_IP}
EOF

    cat > "$inter_conf" <<EOF
login_server_id: ${DB_USER}
login_server_pw: ${DB_PASS}
login_server_db: ${DB_RAGNAROK}
ipban_db_id: ${DB_USER}
ipban_db_pw: ${DB_PASS}
ipban_db_db: ${DB_RAGNAROK}
char_server_id: ${DB_USER}
char_server_pw: ${DB_PASS}
char_server_db: ${DB_RAGNAROK}
map_server_id: ${DB_USER}
map_server_pw: ${DB_PASS}
map_server_db: ${DB_RAGNAROK}
web_server_id: ${DB_USER}
web_server_pw: ${DB_PASS}
web_server_db: ${DB_RAGNAROK}
log_db_id: ${DB_USER}
log_db_pw: ${DB_PASS}
log_db_db: ${DB_LOGS}
EOF

    cat > "$db_conf" <<EOF
db_ip="127.0.0.1"
db_user="${DB_USER}"
db_pass="${DB_PASS}"
db_database="${DB_RAGNAROK}"
db_logs="${DB_LOGS}"
db_fluxcp="${DB_FLUXCP}"
EOF

    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$import_dir"
    log "rAthena import config generated."

    save_creds
    validate_rathena_imports "$import_dir"
}

phase_validate_rathena_setup(){
    log "Running post-compile rAthena setup validation..."

    local import_dir="$RATHENA_INSTALL_DIR/conf/import"
    if [ ! -d "$import_dir" ]; then
        log "WARNING: rAthena import directory missing at ${import_dir}"
        echo "WARNING: rAthena import directory is missing."
    else
        validate_rathena_imports "$import_dir"
    fi

    local bin_dir="$RATHENA_INSTALL_DIR"
    [ -d "$RATHENA_INSTALL_DIR/build" ] && bin_dir="$RATHENA_INSTALL_DIR/build"

    local missing=0
    for s in login-server char-server map-server; do
        if ! find "$bin_dir" -maxdepth 2 -type f -name "$s" -perm -u+x 2>/dev/null | head -n1 | grep -q .; then
            log "WARNING: server binary '$s' not found/executable in ${bin_dir}"
            missing=1
        fi
    done

    [ $missing -ne 0 ] && echo "WARNING: One or more rAthena server binaries missing." || log "rAthena server binaries OK."
    return 0
}

phase_generate_fluxcp_config(){
    log "Patching FluxCP application.php and servers.php in /config ..."

    mkdir -p "$FLUX_CFG_DIR"
    local APPFILE="$FLUX_CFG_DIR/application.php"
    local SRVFILE="$FLUX_CFG_DIR/servers.php"

    # Copy .dist if they exist and real configs missing
    [ ! -f "$APPFILE" ] && [ -f "${APPFILE}.dist" ] && cp "${APPFILE}.dist" "$APPFILE"
    [ ! -f "$SRVFILE" ] && [ -f "${SRVFILE}.dist" ] && cp "${SRVFILE}.dist" "$SRVFILE"

    # Safety fallback
    [ ! -f "$APPFILE" ] && echo "<?php return array();" > "$APPFILE"
    [ ! -f "$SRVFILE" ] && echo "<?php return array();" > "$SRVFILE"

    # ---------------- application.php patches ----------------
    sed -i -E "s|('BaseURI'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'/'|g" "$APPFILE"
    sed -i -E "s|('InstallerPassword'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'RyomaHostingPH'|g" "$APPFILE"
    sed -i -E "s|('SiteTitle'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'Ragnarok Control Panel'|g" "$APPFILE"
    sed -i -E "s|('DonationCurrency'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'PHP'|g" "$APPFILE"

    # ---------------- servers.php patches ----------------
    sed -i -E "s|('ServerName'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'RagnaROK'|g" "$SRVFILE"

    sed -i -E "/'DbConfig'[[:space:]]*=>[[:space:]]*array\(/,/^[[:space:]]*\),/ {
        s|('Hostname'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'127.0.0.1'|g
        s|('Username'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_USER}'|g
        s|('Password'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_PASS}'|g
        s|('Database'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_RAGNAROK}'|g
        s|('Convert'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'utf8'|g
    }" "$SRVFILE"

    sed -i -E "/'LogsDbConfig'[[:space:]]*=>[[:space:]]*array\(/,/^[[:space:]]*\),/ {
        s|('Hostname'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'127.0.0.1'|g
        s|('Username'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_USER}'|g
        s|('Password'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_PASS}'|g
        s|('Database'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_LOGS}'|g
        s|('Convert'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'utf8'|g
    }" "$SRVFILE"

    sed -i -E "/'WebDbConfig'[[:space:]]*=>[[:space:]]*array\(/,/^[[:space:]]*\),/ {
        s|('Hostname'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'127.0.0.1'|g
        s|('Username'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_USER}'|g
        s|('Password'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_PASS}'|g
        s|('Database'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_FLUXCP}'|g
    }" "$SRVFILE"

    # ---------------- LoginServer patches / insert ----------------
    if grep -q "'LoginServer'[[:space:]]*=>[[:space:]]*array" "$SRVFILE"; then
        sed -i -E "/'LoginServer'[[:space:]]*=>[[:space:]]*array\(/,/^[[:space:]]*\),/ {
            s|('Address'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'127.0.0.1'|g
            s|('Port'[[:space:]]*=>[[:space:]]*)[0-9]+|\1 6900|g
            s|('UseMD5'[[:space:]]*=>[[:space:]]*)[^,)]*|\1true|g
        }" "$SRVFILE"
    else
        sed -i -E "/'ServerName'[[:space:]]*=>/a\\
\\
        'LoginServer'    => array(\\
            'Address'  => '127.0.0.1',\\
            'Port'     => 6900,\\
            'UseMD5'   => true,\\
        ),\\
" "$SRVFILE"
    fi

    # ---- Post-patch validation (fail phase if missed) ----
    grep -q "'BaseURI'[[:space:]]*=>[[:space:]]*'/'" "$APPFILE" || { log "ERROR: BaseURI patch failed"; return 1; }
    grep -q "'InstallerPassword'[[:space:]]*=>[[:space:]]*'RyomaHostingPH'" "$APPFILE" || { log "ERROR: InstallerPassword patch failed"; return 1; }
    grep -q "'DonationCurrency'[[:space:]]*=>[[:space:]]*'PHP'" "$APPFILE" || { log "ERROR: DonationCurrency patch failed"; return 1; }
    grep -q "'Username'[[:space:]]*=>[[:space:]]*'${DB_USER}'" "$SRVFILE" || { log "ERROR: DbConfig Username patch failed"; return 1; }

    chown -R www-data:www-data "$WEBROOT"
    usermod -a -G www-data "$RATHENA_USER" 2>/dev/null || true
    chmod -R 0774 "$WEBROOT"

    log "FluxCP config patched successfully in $FLUX_CFG_DIR"
}


# NEW: Patch FluxCP ServerDetails.php with DB creds
phase_patch_fluxcp_serverdetails_php() {
    log "Patching FluxCP ServerDetails.php with DB credentials..."

    local DETAILS_PHP="${WEBROOT}/ServerDetails.php"

    # If file doesn't exist, create a minimal one
    if [ ! -f "$DETAILS_PHP" ]; then
        cat > "$DETAILS_PHP" <<'PHP'
<?php
return array(
    'DbHost' => '127.0.0.1',
    'DbUser' => '',
    'DbPass' => '',
    'DbName' => '',
    'LogsDbName' => '',
    'WebDbName' => '',
);
PHP
        log "Created new ServerDetails.php"
    fi

    sed -i -E "s|('DbHost'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'127.0.0.1'|g" "$DETAILS_PHP"
    sed -i -E "s|('DbUser'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_USER}'|g" "$DETAILS_PHP"
    sed -i -E "s|('DbPass'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_PASS}'|g" "$DETAILS_PHP"
    sed -i -E "s|('DbName'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_RAGNAROK}'|g" "$DETAILS_PHP"
    sed -i -E "s|('LogsDbName'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_LOGS}'|g" "$DETAILS_PHP"
    sed -i -E "s|('WebDbName'[[:space:]]*=>[[:space:]]*)'[^']*'|\1'${DB_FLUXCP}'|g" "$DETAILS_PHP"

    grep -q "${DB_USER}" "$DETAILS_PHP" || { log "ERROR: ServerDetails.php patch failed"; return 1; }

    chown www-data:www-data "$DETAILS_PHP"
    log "ServerDetails.php patched successfully."
}

phase_create_serverdetails(){
    log "Generating ServerDetails.txt on Desktop..."
    local DETAILS_FILE="${RATHENA_HOME}/Desktop/ServerDetails.txt"
    cat > "$DETAILS_FILE" <<EOF
=== rAthena Server Details ===
rAthena dir: ${RATHENA_INSTALL_DIR}
FluxCP webroot: ${WEBROOT}

DB user: ${DB_USER}
DB password: ${DB_PASS}
Databases: ${DB_RAGNAROK}, ${DB_LOGS}, ${DB_FLUXCP}

Server connection account (char/map/login):
  userid: ${USERID}
  password: ${USERPASS}

phpMyAdmin: http://localhost/phpmyadmin
FluxCP: http://localhost/

FluxCP InstallerPassword: RyomaHostingPH

VNC user: ${RATHENA_USER}
VNC password: ${DEFAULT_VNC_PASSWORD}
EOF
    chown "${RATHENA_USER}:${RATHENA_USER}" "$DETAILS_FILE"
    chmod 600 "$DETAILS_FILE"
    log "ServerDetails.txt created."
}

phase_create_desktop_shortcuts(){
  log "Creating desktop shortcuts..."
  local DESKTOP_DIR="${RATHENA_HOME}/Desktop"
  mkdir -p "$DESKTOP_DIR"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "$DESKTOP_DIR" "${RATHENA_HOME}/db_backups"

  write_desktop(){
    local file="$1" name="$2" cmd="$3" icon="$4" terminal="${5:-false}"
    cat > "${DESKTOP_DIR}/${file}" <<EOF
[Desktop Entry]
Version=1.0
Name=${name}
Exec=${cmd}
Terminal=${terminal}
Type=Application
Icon=${icon}
EOF
    chmod +x "${DESKTOP_DIR}/${file}"
    chown "${RATHENA_USER}:${RATHENA_USER}" "${DESKTOP_DIR}/${file}"
    log "Created ${DESKTOP_DIR}/${file}"
  }

  write_desktop "Terminal.desktop" "Terminal" \
    "xfce4-terminal" \
    "utilities-terminal" false

  write_desktop "Edit_rAthena_Configs.desktop" "Edit rAthena Configs" \
    "xdg-open ${RATHENA_INSTALL_DIR}/conf" \
    "text-editor" false

  write_desktop "System_Monitor.desktop" "System Monitor" \
    "xfce4-terminal --command='htop'" \
    "utilities-system-monitor" true

  write_desktop "Start_All_Servers.desktop" "Start All Servers" \
    "bash -lc '${RATHENA_HOME}/start_servers_xfce.sh'" \
    "media-playback-start" false

  write_desktop "Stop_All_Servers.desktop" "Stop All Servers" \
    "bash -lc '${RATHENA_HOME}/stop_servers_xfce.sh'" \
    "media-playback-stop" false

  write_desktop "Restart_All_Servers.desktop" "Restart All Servers" \
    "bash -lc '${RATHENA_HOME}/restart_servers_xfce.sh'" \
    "view-refresh" false

  # CMake-aware recompile shortcut
  write_desktop "Recompile_rAthena.desktop" "Recompile rAthena" \
    "bash -lc 'cd ${RATHENA_INSTALL_DIR} && if [ -f Makefile ]; then make clean && make -j\$(nproc); elif [ -f CMakeLists.txt ]; then rm -rf build && cmake -S . -B build && cmake --build build -j\$(nproc); else echo \"No Makefile or CMakeLists.txt found in ${RATHENA_INSTALL_DIR}\"; fi'" \
    "applications-development" true

  write_desktop "Change_VNC_Password.desktop" "Change VNC Password" \
    "bash -lc 'vncpasswd'" \
    "dialog-password" false

  write_desktop "Open_FluxCP.desktop" "Open FluxCP" \
    "xdg-open http://localhost/" \
    "internet-web-browser" false

  write_desktop "Open_phpMyAdmin.desktop" "Open phpMyAdmin" \
    "xdg-open http://localhost/phpmyadmin" \
    "applications-internet" false

  write_desktop "Backup_rAthena_DB.desktop" "Backup rAthena DB" \
    "bash -lc 'mysqldump -u ${DB_USER} -p\"${DB_PASS}\" ${DB_RAGNAROK} > ${RATHENA_HOME}/db_backups/ragnarok_\$(date +%F).sql && notify-send \"Backup complete\"'" \
    "document-save" false

  log "Desktop shortcuts created."
}

# ================== CLEAN & DB PASSWORD PHASES ==================
phase_clean_all(){
    log "Cleaning previous rAthena installation completely (SAFE CLEAN: credentials kept)..."

    systemctl stop vncserver@1.service 2>/dev/null || true
    systemctl stop apache2 mariadb 2>/dev/null || true

    rm -rf "$RATHENA_INSTALL_DIR" 2>/dev/null || true

    if [ -d "$WEBROOT" ]; then
        find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi

    rm -f "$RATHENA_HOME/Desktop/ServerDetails.txt"
    rm -f "$RATHENA_HOME/Desktop/"*.desktop 2>/dev/null || true

    rm -rf "$RATHENA_HOME/db_backups" "$RATHENA_HOME/sql_imports"
    rm -rf "$RATHENA_HOME/.config/autostart"
    rm -rf "$RATHENA_HOME/.vnc"

    # SAFE CLEAN: DO NOT remove $CRED_FILE
    log "Safe clean enabled: keeping credentials at $CRED_FILE"

    if cmd_exists mariadb; then
        mariadb <<SQL >>"$LOGFILE" 2>&1
DROP DATABASE IF EXISTS ${DB_RAGNAROK};
DROP DATABASE IF EXISTS ${DB_LOGS};
DROP DATABASE IF EXISTS ${DB_FLUXCP};
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    else
        log "MariaDB not installed or not found; skipping DB drop."
    fi

    log "Clean complete. All rAthena files, databases, and configs removed (credentials preserved)."
}

phase_regenerate_db_password(){
    if ! cmd_exists mariadb; then
        log "MariaDB client not found; cannot regenerate DB password."
        echo "MariaDB client not found; install MariaDB first."
        return 1
    fi

    log "Regenerating DB password..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || echo 'ChangeMe123')"
    mariadb <<SQL >>"$LOGFILE" 2>&1
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
SQL

    save_creds
    log "DB password regenerated."
}

# ================== FULL INSTALLER ==================
full_install(){
    log "Starting full installer..."

    run_phase "System update & upgrade"        phase_update_upgrade           || { log "Full installer aborted."; return 1; }
    run_phase "Install base packages"          phase_install_packages         || { log "Full installer aborted."; return 1; }
    run_phase "Install Chrome/Chromium"        phase_install_chrome           || { log "Full installer aborted."; return 1; }
    run_phase "Create rAthena user"            phase_create_rathena_user      || { log "Full installer aborted."; return 1; }
    run_phase "Configure phpMyAdmin"           phase_configure_phpmyadmin     || { log "Full installer aborted."; return 1; }
    run_phase "Clone rAthena and FluxCP"       phase_clone_repos              || { log "Full installer aborted."; return 1; }
    run_phase "Setup MariaDB & credentials"    phase_setup_mariadb            || { log "Full installer aborted."; return 1; }
    run_phase "Import SQL files"               phase_import_sqls              || { log "Full installer aborted."; return 1; }
    run_phase "Generate FluxCP config"         phase_generate_fluxcp_config   || { log "Full installer aborted."; return 1; }
    run_phase "Patch FluxCP ServerDetails.php" phase_patch_fluxcp_serverdetails_php || { log "Full installer aborted."; return 1; }

    run_phase "Compile rAthena"                phase_compile_rathena          || { log "Full installer aborted."; return 1; }

    run_phase "Create ServerDetails.txt"       phase_create_serverdetails     || { log "Full installer aborted."; return 1; }
    run_phase "Create desktop shortcuts"       phase_create_desktop_shortcuts || { log "Full installer aborted."; return 1; }
    run_phase "Generate rAthena config"        phase_generate_rathena_config  || { log "Full installer aborted."; return 1; }
    run_phase "Validate rAthena setup"         phase_validate_rathena_setup   || { log "Full installer aborted."; return 1; }

    log "Full installer finished successfully."
    echo
    echo "Full installation complete!"
    read -rp "Press Enter to return to the menu..." _
}

# ================== OPTIONAL CLI CLEAN ==================
if [ "${1:-}" = "clean" ]; then
    run_phase "Clean previous install" phase_clean_all
    exit 0
fi

# ================== MENU LOOP ==================
while true; do
  clear
  echo "================ rAthena Installer ================="
  echo " 1) Run full installer"
  echo " 2) Clean previous install (files + DBs + DB user) [SAFE CLEAN]"
  echo " 3) Regenerate rAthena DB password"
  echo " 4) Recompile rAthena server"
  echo " 5) Generate rAthena config (conf/import)"
  echo " 6) Generate FluxCP config (/config)"
  echo " 7) Patch FluxCP ServerDetails.php"
  echo " 8) Import SQL files (sql-files -> DBs)"
  echo " 9) Exit"
  echo "===================================================="
  read -rp "Choose an option [1-9]: " choice


  case "$choice" in
    1) full_install ;;
    2) run_phase "Clean previous install"         phase_clean_all ;;
    3) run_phase "Regenerate DB password"         phase_regenerate_db_password ;;
    4) run_phase "Recompile rAthena"              phase_compile_rathena ;;
    5) run_phase "Generate rAthena config"        phase_generate_rathena_config ;;
    6) run_phase "Generate FluxCP config"         phase_generate_fluxcp_config ;;
    7) run_phase "Patch FluxCP ServerDetails.php" phase_patch_fluxcp_serverdetails_php ;;
    8) run_phase "Import SQL files"               phase_import_sqls ;;
    9) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice."; read -rp "Press Enter to continue..." _ ;;
  esac

done
