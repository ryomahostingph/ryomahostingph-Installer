#!/usr/bin/env bash
set -euo pipefail

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

# ================== LOAD / GENERATE DB CREDENTIALS ==================
if [ -f "$CRED_FILE" ]; then
    log "Loading existing DB credentials from $CRED_FILE"
    source "$CRED_FILE"
else
    log "No existing DB credentials found. Generating new password..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
fi

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

    # Create server scripts (start/stop/restart)
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

    if systemctl list-unit-files | grep -q '^vncserver@'; then
        systemctl enable --now vncserver@1.service 2>/dev/null || true
    fi
    log "User ${RATHENA_USER} prepared."
}

phase_configure_phpmyadmin(){
    log "Configuring phpMyAdmin..."
    # Enable correct PHP module for Debian 12
    if [ -f /etc/apache2/mods-available/php8.2.load ]; then
        a2enmod php8.2
    fi
    systemctl enable --now apache2

    if [ ! -d /usr/share/phpmyadmin ]; then
        log "phpMyAdmin not found, skipping configuration."
        return 1
    fi

    rm -f /etc/apache2/conf-available/phpmyadmin.conf
    cat > /etc/apache2/conf-available/phpmyadmin.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
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
    sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || log "Failed to clone rAthena"

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
EOF
    chmod 600 "$CRED_FILE"
    log "MariaDB setup complete and credentials saved to $CRED_FILE"
}

phase_compile_rathena() {
    log "Compiling rAthena (as ${RATHENA_USER})..."
    if [ ! -d "$RATHENA_INSTALL_DIR" ]; then
        log "rAthena directory not found at ${RATHENA_INSTALL_DIR}."
        return 1
    fi
    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$RATHENA_INSTALL_DIR"

    sudo -u "$RATHENA_USER" bash -c "
cd '$RATHENA_INSTALL_DIR' &&
if [ -f Makefile ]; then
    make clean && make -j\$(nproc)
elif [ -f CMakeLists.txt ]; then
    rm -rf build && mkdir -p build &&
    cmake -S . -B build &&
    cmake --build build -j\$(nproc)
else
    echo 'No Makefile or CMakeLists.txt found' && exit 2
fi
" >>"$LOGFILE" 2>&1 || { log "Compilation failed. See $LOGFILE"; return 1; }

    log "rAthena compiled successfully."
}

phase_import_sqls(){
    log "Importing SQL files..."
    SQL_DIRS=("$RATHENA_INSTALL_DIR/sql" "$RATHENA_HOME/sql_imports")
    for dir in "${SQL_DIRS[@]}"; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.sql; do
            [ -e "$f" ] || continue
            case "$(basename "$f")" in
                main.sql) mariadb "$DB_RAGNAROK" < "$f" && log "Imported main.sql";;
                logs.sql) mariadb "$DB_LOGS" < "$f" && log "Imported logs.sql";;
                *) mariadb "$DB_RAGNAROK" < "$f" && log "Imported $(basename "$f")";;
            esac
        done
    done
    log "SQL import completed."
}

phase_generate_rathena_config(){
    log "Generating rAthena import config files..."
    mkdir -p "$RATHENA_INSTALL_DIR/conf/import"

    # Automatic server account generation
    USERID="$(tr -dc 'A-Za-z' </dev/urandom | head -c6)"
    USERPASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c8)"
    SERVER_IP="$(hostname -I | awk '{print $1}')"

    cat > "$RATHENA_INSTALL_DIR/conf/import/char_conf.txt" <<EOF
userid: ${USERID}
passwd: ${USERPASS}
char_ip: ${SERVER_IP}
EOF

    cat > "$RATHENA_INSTALL_DIR/conf/import/map_conf.txt" <<EOF
userid: ${USERID}
passwd: ${USERPASS}
map_ip: ${SERVER_IP}
EOF

    cat > "$RATHENA_INSTALL_DIR/conf/import/inter_conf.txt" <<EOF
login_server_pw: ${DB_PASS}
ipban_db_pw: ${DB_PASS}
char_server_pw: ${DB_PASS}
map_server_pw: ${DB_PASS}
log_db_pw: ${DB_PASS}
EOF

    cat > "$RATHENA_INSTALL_DIR/conf/import/rathena_db.conf" <<EOF
db_ip="127.0.0.1"
db_user="${DB_USER}"
db_pass="${DB_PASS}"
db_database="${DB_RAGNAROK}"
db_logs="${DB_LOGS}"
db_fluxcp="${DB_FLUXCP}"
EOF

    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$RATHENA_INSTALL_DIR/conf/import"
    log "rAthena import config generated."
}

phase_generate_fluxcp_config(){
    log "Patching FluxCP application.php and server.php..."
    APPFILE="$WEBROOT/application/config/application.php"
    SRVFILE="$WEBROOT/application/config/server.php"

    if [ -f "$APPFILE" ]; then
        sed -i "s/'BaseURI'[[:space:]]*=>[[:space:]]*'[^']*'/'BaseURI' => '\/'/g" "$APPFILE" || true
        sed -i "s/'InstallerPassword'[[:space:]]*=>[[:space:]]*'[^']*'/'InstallerPassword' => 'RyomaHostingPH'/g" "$APPFILE" || true
        sed -i "s/'SiteTitle'[[:space:]]*=>[[:space:]]*'[^']*'/'SiteTitle' => 'Ragnarok Control Panel'/g" "$APPFILE" || true
        sed -i "s/'DonationCurrency'[[:space:]]*=>[[:space:]]*'[^']*'/'DonationCurrency' => 'PHP'/g" "$APPFILE" || true
    else
        log "Warning: $APPFILE not found — skipping application.php patches."
    fi

    if [ -f "$SRVFILE" ]; then
        sed -i "s/'ServerName'[[:space:]]*=>[[:space:]]*'[^']*'/'ServerName' => 'RagnaROK'/g" "$SRVFILE" || true
        sed -i "/'DbConfig'[[:space:]]*=>[[:space:]]*array(/,/^[[:space:]]*),/ {
            s/'Hostname'[[:space:]]*=>[[:space:]]*'[^']*'/'Hostname' => '127.0.0.1'/;
            s/'Convert'[[:space:]]*=>[[:space:]]*'[^']*'/'Convert' => 'utf8'/;
            s/'Username'[[:space:]]*=>[[:space:]]*'[^']*'/'Username' => '${DB_USER}'/;
            s/'Password'[[:space:]]*=>[[:space:]]*'[^']*'/'Password' => '${DB_PASS}'/;
            s/'Database'[[:space:]]*=>[[:space:]]*'[^']*'/'Database' => '${DB_RAGNAROK}'/;
        }" "$SRVFILE" || true

        sed -i "/'LogsDbConfig'[[:space:]]*=>[[:space:]]*array(/,/^[[:space:]]*),/ {
            s/'Convert'[[:space:]]*=>[[:space:]]*'[^']*'/'Convert' => 'utf8'/;
            s/'Username'[[:space:]]*=>[[:space:]]*'[^']*'/'Username' => '${DB_USER}'/;
            s/'Password'[[:space:]]*=>[[:space:]]*'[^']*'/'Password' => '${DB_PASS}'/;
            s/'Database'[[:space:]]*=>[[:space:]]*'[^']*'/'Database' => '${DB_LOGS}'/;
        }" "$SRVFILE" || true

        sed -i "/'WebDbConfig'[[:space:]]*=>[[:space:]]*array(/,/^[[:space:]]*),/ {
            s/'Hostname'[[:space:]]*=>[[:space:]]*'[^']*'/'Hostname' => '127.0.0.1'/;
            s/'Username'[[:space:]]*=>[[:space:]]*'[^']*'/'Username' => '${DB_USER}'/;
            s/'Password'[[:space:]]*=>[[:space:]]*'[^']*'/'Password' => '${DB_PASS}'/;
            s/'Database'[[:space:]]*=>[[:space:]]*'[^']*'/'Database' => '${DB_FLUXCP}'/;
        }" "$SRVFILE" || true
    else
        log "Warning: $SRVFILE not found — skipping server.php patches."
    fi
}

phase_generate_serverdetails(){
    log "Generating ServerDetails.txt on Desktop..."
    cat > "${RATHENA_HOME}/Desktop/ServerDetails.txt" <<EOF
Rathena Credentials:
  DB_USER: ${DB_USER}
  DB_PASS: ${DB_PASS}
  DB_NAME: ${DB_RAGNAROK}
  DB_LOGS: ${DB_LOGS}
  DB_FLUXCP: ${DB_FLUXCP}

FluxCP InstallerPassword: RyomaHostingPH
EOF
    chown "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}/Desktop/ServerDetails.txt"
    chmod 600 "${RATHENA_HOME}/Desktop/ServerDetails.txt"
    log "ServerDetails.txt created."
}

# ================== CLEAN PHASE ==================
phase_clean(){
    log "Cleaning all installation artifacts..."
    systemctl stop apache2 mariadb vncserver@1.service 2>/dev/null || true
    rm -rf "$RATHENA_INSTALL_DIR" "$WEBROOT" "$CRED_FILE"
    log "All artifacts cleaned."
}

# ================== RUN MENU ==================
if [ "${1:-}" = "clean" ]; then
    run_phase "Clean Installer Artifacts" phase_clean
    exit 0
fi

# Full run
run_phase "System Update/Upgrade" phase_update_upgrade
run_phase "Install Packages" phase_install_packages
run_phase "Install Google Chrome" phase_install_chrome
run_phase "Create rAthena User & Setup XFCE" phase_create_rathena_user
run_phase "Configure phpMyAdmin" phase_configure_phpmyadmin
run_phase "Clone Repositories" phase_clone_repos
run_phase "Setup MariaDB & Credentials" phase_setup_mariadb
run_phase "Compile rAthena" phase_compile_rathena
run_phase "Import SQL Files" phase_import_sqls
run_phase "Generate rAthena Configs" phase_generate_rathena_config
run_phase "Patch FluxCP Configs" phase_generate_fluxcp_config
run_phase "Generate ServerDetails.txt" phase_generate_serverdetails

log "=== Installer completed successfully ==="
echo "Installation completed! ServerDetails.txt is on rathena Desktop."
