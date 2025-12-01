#!/usr/bin/env bash
# rAthena auto-installer with interactive menu, spinner, strict phase error handling,
# and post-compile config + validation.
set -uo pipefail

# ================== VARIABLES ==================
LOGFILE="/var/log/rathena_installer_final.log"
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
WEBROOT="/var/www/html"
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
else
    log "No existing DB credentials found. Generating new DB password..."
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
        return $rc   # ⬅️ prevents next phase from running
    fi

    log "=== Completed: ${label} ==="
    return 0
}

# ================== PHASES ==================

phase_update_upgrade(){
    log "Updating system..."
    apt update
    apt upgrade -y
    log "System updated."
}

phase_install_packages(){
    log "Installing base packages..."
    apt_install sudo build-essential git cmake autoconf libssl-dev \
      libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
      wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring \
      mariadb-server mariadb-client \
      dbus-x11 xauth xorg ufw tightvncserver xfce4 xfce4-goodies x11-xserver-utils \
      phpmyadmin imagemagick xterm xfce4-terminal htop xdg-utils dos2unix
    log "Base packages installed."
}

phase_install_chrome(){
    log "Installing Google Chrome..."
    if wget -O /tmp/chrome.deb "$CHROME_URL"; then
        apt install -y /tmp/chrome.deb && rm -f /tmp/chrome.deb
        log "Google Chrome installed."
    else
        log "Falling back to Chromium..."
        apt_install chromium || log "No browser installed."
    fi
}

phase_create_rathena_user(){
    log "Creating user ${RATHENA_USER} (if missing)..."
    if ! id "$RATHENA_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$RATHENA_USER"
        echo "${RATHENA_USER}:${DEFAULT_VNC_PASSWORD}" | chpasswd
    fi

    mkdir -p "${RATHENA_HOME}/Desktop" "${RATHENA_HOME}/.config/autostart" \
             "${RATHENA_HOME}/sql_imports" "${RATHENA_HOME}/db_backups"
    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$RATHENA_HOME"

    # Server control scripts
    cat > "${RATHENA_HOME}/start_servers_xfce.sh" <<'BASH'
#!/usr/bin/env bash
set -e
RATHENA_HOME="/home/rathena"
cd "$RATHENA_HOME/Desktop/rathena"
nohup ./login-server > /dev/null 2>&1 &
nohup ./char-server > /dev/null 2>&1 &
nohup ./map-server > /dev/null 2>&1 &
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
    # Enable PHP module (Debian 12 default)
    if [ -f /etc/apache2/mods-available/php8.2.load ]; then
        a2enmod php8.2
    fi
    systemctl enable --now apache2

    if [ ! -d /usr/share/phpmyadmin ]; then
        log "phpMyAdmin not found, skipping configuration."
        return 0
    fi

    rm -f /etc/apache2/conf-available/phpmyadmin.conf
    cat > /etc/apache2/conf-available/phpmyadmin.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    Require all granted
</Directory>
EOF

    a2enconf phpmyadmin
    systemctl reload apache2 || systemctl restart apache2
    chown -R www-data:www-data /usr/share/phpmyadmin
    log "phpMyAdmin configured at http://localhost/phpmyadmin"
}

phase_clone_repos(){
    log "Cloning rAthena..."
    rm -rf "$RATHENA_INSTALL_DIR"

    if cmd_exists sudo; then
        sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || log "Failed to clone rAthena"
    else
        su - "$RATHENA_USER" -s /bin/bash -c "git clone --depth 1 '$RATHENA_REPO' '$RATHENA_INSTALL_DIR'" || log "Failed to clone rAthena"
    fi

    log "Cloning FluxCP into ${WEBROOT}..."
    if [ -d "$WEBROOT" ]; then
        find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi
    git clone --depth 1 https://github.com/rathena/FluxCP.git "$WEBROOT" || log "Failed to clone FluxCP"
    chown -R www-data:www-data "$WEBROOT"
}

phase_setup_mariadb(){
    log "Setting up MariaDB..."
    systemctl enable --now mariadb
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_RAGNAROK} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ${DB_LOGS} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ${DB_FLUXCP} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_RAGNAROK}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_LOGS}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_FLUXCP}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
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
    log "MariaDB setup complete and credentials saved to $CRED_FILE"
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
        log "Detected Makefile – using make-based build."
        echo "Using legacy make build system..."

        sudo -u "$RATHENA_USER" bash -lc "
cd '$RATHENA_INSTALL_DIR'
make clean
make -j\$(nproc)
" >>"$LOGFILE" 2>&1 || {
            log "Compilation failed using make. See $LOGFILE for details."
            echo
            echo "rAthena compilation failed while running 'make'."
            echo "Open ${LOGFILE} and search for 'error:' lines to see the exact compiler error."
            return 1
        }

    elif [ -f "${RATHENA_INSTALL_DIR}/CMakeLists.txt" ]; then
        log "No Makefile found – using CMake out-of-source build (build/ directory)."
        echo "Using CMake build system (this can take a bit)."

        sudo -u "$RATHENA_USER" bash -lc "
cd '$RATHENA_INSTALL_DIR'
rm -rf build
mkdir -p build
echo '>>> [cmake configure]'
cmake -S . -B build
echo '>>> [cmake build]'
cmake --build build -j\$(nproc)
" >>"$LOGFILE" 2>&1 || {
            log "Compilation failed using CMake. See $LOGFILE for details."
            echo
            echo "rAthena compilation failed during the CMake build."
            echo "Most common causes:"
            echo "  - Missing dev libraries (zlib, OpenSSL, MariaDB headers, etc.)"
            echo "  - Source code errors or incompatible options"
            echo
            echo "Check ${LOGFILE} and look right after the '[cmake build]' section for the exact error."
            return 1
        }

    else
        log "Neither Makefile nor CMakeLists.txt found – cannot determine build system."
        echo "Could not compile rAthena: no Makefile or CMakeLists.txt found in ${RATHENA_INSTALL_DIR}."
        echo "Check that the rAthena repository cloned correctly and contains the expected files."
        return 1
    fi

    log "rAthena compiled successfully."
    echo "rAthena compiled successfully."
}

phase_import_sqls(){
    log "Importing SQL files..."
    SQL_DIRS=("$RATHENA_INSTALL_DIR/sql" "$RATHENA_HOME/sql_imports")
    for dir in "${SQL_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.sql; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
                main.sql)
                    mariadb "$DB_RAGNAROK" < "$f" && log "Imported main.sql"
                    ;;
                logs.sql)
                    mariadb "$DB_LOGS" < "$f" && log "Imported logs.sql"
                    ;;
                *)
                    mariadb "$DB_RAGNAROK" < "$f" && log "Imported $(basename "$f")"
                    ;;
            esac
        done
    done
    log "SQL import completed."
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

    # Required files
    for f in "$char_conf" "$map_conf" "$inter_conf" "$db_conf"; do
        if [ ! -f "$f" ]; then
            log "WARNING: Missing import config file: $f"
            warn=1
        fi
    done

    if [ $warn -ne 0 ]; then
        echo "WARNING: One or more rAthena import files are missing. Server may fail to start."
        return 0
    fi

    # Server credentials from char/map
    local char_user char_pass map_user map_pass

    char_user="$(sed -n 's/^userid:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
    char_pass="$(sed -n 's/^passwd:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"

    map_user="$(sed -n 's/^userid:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$map_conf" | head -n1)"
    map_pass="$(sed -n 's/^passwd:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$map_conf" | head -n1)"

    if [ "$char_user" != "$map_user" ] || [ "$char_pass" != "$map_pass" ]; then
        log "WARNING: char_conf.txt and map_conf.txt have mismatched userid/pass."
        log "         char: ${char_user}/${char_pass}, map: ${map_user}/${map_pass}"
        echo "WARNING: Server connection credentials differ between char/map configs."
        warn=1
    else
        log "Server credentials match between char_conf.txt and map_conf.txt (${char_user}/****)."
    fi

    # DB config vs installer vars
    local db_user db_pass db_main db_logs db_flux

    db_user="$(sed -n 's/^db_user="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_pass="$(sed -n 's/^db_pass="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_main="$(sed -n 's/^db_database="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_logs="$(sed -n 's/^db_logs="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"
    db_flux="$(sed -n 's/^db_fluxcp="\([^"]*\)".*$/\1/p' "$db_conf" | head -n1)"

    if [ "$db_user" != "$DB_USER" ] || [ "$db_pass" != "$DB_PASS" ]; then
        log "WARNING: rathena_db.conf DB credentials differ from installer values."
        log "         In file: ${db_user}/****, expected: ${DB_USER}/****"
        warn=1
    fi

    if [ "$db_main" != "$DB_RAGNAROK" ] || [ "$db_logs" != "$DB_LOGS" ] || [ "$db_flux" != "$DB_FLUXCP" ]; then
        log "WARNING: rathena_db.conf database names differ from installer variables."
        log "         In file: main=${db_main}, logs=${db_logs}, flux=${db_flux}"
        log "         Expected: main=${DB_RAGNAROK}, logs=${DB_LOGS}, flux=${DB_FLUXCP}"
        warn=1
    fi

    if [ $warn -eq 0 ]; then
        log "rAthena import config validation OK (server credentials + DB settings consistent)."
    else
        echo "WARNING: Some rAthena import settings look inconsistent. Check the log at:"
        echo "         ${LOGFILE}"
    fi

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

    # Reuse existing USERID/USERPASS from char_conf if present and not already set
    if [ -z "$USERID" ] && [ -f "$char_conf" ]; then
        USERID="$(sed -n 's/^userid:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
        USERPASS="$(sed -n 's/^passwd:[[:space:]]*\([^[:space:]]\+\).*$/\1/p' "$char_conf" | head -n1)"
    fi

    if [ -z "$USERID" ]; then
        USERID="$(tr -dc 'A-Za-z' </dev/urandom | head -c6 || echo s1)"
        log "Generated new server userid: ${USERID}"
    else
        log "Reusing server userid: ${USERID}"
    fi

    if [ -z "$USERPASS" ]; then
        USERPASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c8 || echo p1)"
        log "Generated new server password for userid ${USERID}"
    else
        log "Reusing server password for userid ${USERID}"
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
login_server_pw: ${DB_PASS}
ipban_db_pw: ${DB_PASS}
char_server_pw: ${DB_PASS}
map_server_pw: ${DB_PASS}
log_db_pw: ${DB_PASS}
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

    # Persist USERID/USERPASS to CRED_FILE for reuse
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

    validate_rathena_imports "$import_dir"
}

phase_validate_rathena_setup(){
    log "Running post-compile rAthena setup validation..."

    local import_dir="$RATHENA_INSTALL_DIR/conf/import"
    if [ ! -d "$import_dir" ]; then
        log "WARNING: rAthena import directory missing at ${import_dir}"
        echo "WARNING: rAthena import directory is missing. Server may not start correctly."
    else
        validate_rathena_imports "$import_dir"
    fi

    # Check server binaries (login/char/map)
    local bin_dir="$RATHENA_INSTALL_DIR"
    [ -d "$RATHENA_INSTALL_DIR/build" ] && bin_dir="$RATHENA_INSTALL_DIR/build"

    local missing=0
    for s in login-server char-server map-server; do
        if ! find "$bin_dir" -maxdepth 2 -type f -name "$s" -perm -u+x 2>/dev/null | head -n1 | grep -q .; then
            log "WARNING: rAthena server binary '$s' not found or not executable under ${bin_dir}"
            missing=1
        fi
    done

    if [ $missing -ne 0 ]; then
        echo "WARNING: One or more rAthena server binaries are missing or not executable."
        echo "         Check build output in: ${LOGFILE}"
    else
        log "rAthena server binaries appear to exist (login/char/map)."
    fi

    return 0
}

phase_generate_fluxcp_config() {
    log "Patching FluxCP application.php and server.php..."

    mkdir -p "$WEBROOT/application/config"
    APPFILE="$WEBROOT/application/config/application.php"
    SRVFILE="$WEBROOT/application/config/server.php"

    # ---- 1) Ensure real config files exist (copy .dist if present) ----
    if [ ! -f "$APPFILE" ]; then
        if [ -f "${APPFILE}.dist" ]; then
            cp "${APPFILE}.dist" "$APPFILE"
        else
            echo "<?php return [];" > "$APPFILE"
        fi
    fi

    if [ ! -f "$SRVFILE" ]; then
        if [ -f "${SRVFILE}.dist" ]; then
            cp "${SRVFILE}.dist" "$SRVFILE"
        else
            echo "<?php return [];" > "$SRVFILE"
        fi
    fi

    # helper: set or insert a TOP-LEVEL key in a return array
    set_top_key () {
        local file="$1" key="$2" val="$3"
        perl -0777 -i -pe '
            my ($k,$v)=@ARGV; 
            s/([\"\x27]\Q$k\E[\"\x27]\s*=>\s*)([\"\x27]).*?\2/$1$2$v$2/g
            or
            s/return\s*(array\s*\(|\[)(.*?)(\)\s*;|\]\s*;)/"return $1$2\n  \x27$k\x27 => \x27$v\x27,\n$3"/se
        ' "$key" "$val" "$file"
    }

    # helper: patch a nested config block (array() or [])
    patch_db_block () {
        local file="$1" block="$2" host="$3" user="$4" pass="$5" db="$6" convert="$7"

        perl -0777 -i -pe '
            my ($block,$host,$user,$pass,$db,$convert)=@ARGV;

            # find block: "BlockName" => array(...) OR [...]
            if (s/
                ([\"\x27]\Q$block\E[\"\x27]\s*=>\s*)(array\s*\(|\[)
                (.*?)
                (\)\s*,|\]\s*,)
            /
                my $pre=$1; my $open=$2; my $body=$3; my $close=$4;

                sub setk {
                    my ($b,$k,$v)=@_;
                    if ($b =~ s/([\"\x27]\Q$k\E[\"\x27]\s*=>\s*)([\"\x27]).*?\2/$1$2$v$2/s) {
                        return $b;
                    } else {
                        return $b . \"\\n    \x27$k\x27 => \x27$v\x27,\";
                    }
                }

                $body = setk($body, \"Hostname\", $host) if length $host;
                $body = setk($body, \"Convert\",  $convert) if length $convert;
                $body = setk($body, \"Username\", $user) if length $user;
                $body = setk($body, \"Password\", $pass) if length $pass;
                $body = setk($body, \"Database\", $db) if length $db;

                \"$pre$open$body\\n  $close\"
            /sexg) { }
        ' "$block" "$host" "$user" "$pass" "$db" "$convert" "$file"
    }

    # ---- 2) application.php patches (replace OR insert) ----
    set_top_key "$APPFILE" "BaseURI" "/"
    set_top_key "$APPFILE" "InstallerPassword" "RyomaHostingPH"
    set_top_key "$APPFILE" "SiteTitle" "Ragnarok Control Panel"
    set_top_key "$APPFILE" "DonationCurrency" "PHP"

    # ---- 3) server.php patches ----
    set_top_key "$SRVFILE" "ServerName" "RagnaROK"

    patch_db_block "$SRVFILE" "DbConfig"     "127.0.0.1" "$DB_USER" "$DB_PASS" "$DB_RAGNAROK" "utf8"
    patch_db_block "$SRVFILE" "LogsDbConfig" ""          "$DB_USER" "$DB_PASS" "$DB_LOGS"     "utf8"
    patch_db_block "$SRVFILE" "WebDbConfig"  "127.0.0.1" "$DB_USER" "$DB_PASS" "$DB_FLUXCP"   ""

    chown -R www-data:www-data "$WEBROOT"
    usermod -a -G www-data "$RATHENA_USER" 2>/dev/null || true
    chmod -R 0774 "$WEBROOT"

    log "FluxCP application.php and server.php patched."
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
  log "Creating desktop shortcuts (using system icons)..."
  DESKTOP_DIR="${RATHENA_HOME}/Desktop"
  mkdir -p "$DESKTOP_DIR"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "$DESKTOP_DIR" "${RATHENA_HOME}/db_backups"

  write_desktop(){
    file="$1"; name="$2"; cmd="$3"; icon="$4"; terminal="${5:-false}"
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
    log "Cleaning previous rAthena installation completely..."

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

    rm -f "$CRED_FILE"

    if cmd_exists mariadb; then
        mariadb <<SQL
DROP DATABASE IF EXISTS ${DB_RAGNAROK};
DROP DATABASE IF EXISTS ${DB_LOGS};
DROP DATABASE IF EXISTS ${DB_FLUXCP};
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    else
        log "MariaDB not installed or not found; skipping DB drop."
    fi

    log "Clean complete. All rAthena files, databases, and user credentials removed."
}

phase_regenerate_db_password(){
    if ! cmd_exists mariadb; then
        log "MariaDB client not found; cannot regenerate DB password."
        echo "MariaDB client not found; install MariaDB first."
        return 1
    fi

    log "Regenerating DB password..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || echo 'ChangeMe123')"
    mariadb <<SQL
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
FLUSH PRIVILEGES;
SQL
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
    log "DB password regenerated: ${DB_PASS}"
}

# ================== FULL INSTALLER ==================
full_install(){
    log "Starting full installer..."

    run_phase "System update & upgrade"        phase_update_upgrade         || { log "Full installer aborted."; return 1; }
    run_phase "Install base packages"         phase_install_packages       || { log "Full installer aborted."; return 1; }
    run_phase "Install Chrome/Chromium"       phase_install_chrome         || { log "Full installer aborted."; return 1; }
    run_phase "Create rAthena user"           phase_create_rathena_user    || { log "Full installer aborted."; return 1; }
    run_phase "Configure phpMyAdmin"          phase_configure_phpmyadmin   || { log "Full installer aborted."; return 1; }
    run_phase "Clone rAthena and FluxCP"      phase_clone_repos            || { log "Full installer aborted."; return 1; }
    run_phase "Setup MariaDB & credentials"   phase_setup_mariadb          || { log "Full installer aborted."; return 1; }
    run_phase "Import SQL files"              phase_import_sqls            || { log "Full installer aborted."; return 1; }
    run_phase "Generate FluxCP config"        phase_generate_fluxcp_config || { log "Full installer aborted."; return 1; }

    # ⬇️ Your requirement: compile first, then configs
    run_phase "Compile rAthena"               phase_compile_rathena        || { log "Full installer aborted."; return 1; }
    run_phase "Generate rAthena config"       phase_generate_rathena_config || { log "Full installer aborted."; return 1; }
    run_phase "Validate rAthena setup"        phase_validate_rathena_setup || { log "Full installer aborted."; return 1; }

    run_phase "Create ServerDetails.txt"      phase_create_serverdetails   || { log "Full installer aborted."; return 1; }
    run_phase "Create desktop shortcuts"      phase_create_desktop_shortcuts || { log "Full installer aborted."; return 1; }

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
  echo " 2) Clean previous install (files + DBs + DB user)"
  echo " 3) Regenerate rAthena DB password"
  echo " 4) Recompile rAthena server"
  echo " 5) Generate rAthena config (conf/import)"
  echo " 6) Generate FluxCP config (application/config)"
  echo " 7) Exit"
  echo "===================================================="
  read -rp "Choose an option [1-7]: " choice

  case "$choice" in
    1) full_install ;;
    2) run_phase "Clean previous install" phase_clean_all ;;
    3) run_phase "Regenerate DB password" phase_regenerate_db_password ;;
    4) run_phase "Recompile rAthena"      phase_compile_rathena ;;
    5) run_phase "Generate rAthena config" phase_generate_rathena_config ;;
    6) run_phase "Generate FluxCP config"  phase_generate_fluxcp_config ;;
    7) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice."; read -rp "Press Enter to continue..." _ ;;
  esac
done
