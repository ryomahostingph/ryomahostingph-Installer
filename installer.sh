#!/usr/bin/env bash
set -euo pipefail

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

mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE" || true
chmod 600 "$LOGFILE" 2>/dev/null || true
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "$@"; }

# ------------------ LOAD / GENERATE DB CREDENTIALS ------------------
if [ -f "$CRED_FILE" ]; then
    log "Loading existing DB credentials from $CRED_FILE"
    # shellcheck disable=SC1090
    source "$CRED_FILE"
else
    log "No existing DB credentials found. Generating new password..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
fi

# ------------------ PHASES ------------------

phase_update_upgrade(){
    log "Updating system..."
    apt update -y && apt upgrade -y
    log "System updated."
}

phase_install_packages(){
    log "Installing base packages..."
    apt_install build-essential git cmake autoconf libssl-dev \
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
        return
    fi
    log "Falling back to Chromium..."
    apt_install chromium || log "No browser installed."
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
    log "User ${RATHENA_USER} prepared."
}

phase_clone_repos(){
    log "Cloning rAthena..."
    rm -rf "$RATHENA_INSTALL_DIR"
    sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || log "Failed to clone rAthena"
    log "Cloning FluxCP into ${WEBROOT}..."
    rm -rf "${WEBROOT:?}/"{*,.*} 2>/dev/null || true
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

phase_compile_rathena(){
    log "Compiling rAthena (as ${RATHENA_USER})..."
    if [ ! -d "$RATHENA_INSTALL_DIR" ]; then
        log "rAthena directory not found: $RATHENA_INSTALL_DIR"
        return 0
    fi
    sudo -u "$RATHENA_USER" bash -lc "cd '${RATHENA_INSTALL_DIR}' && ./configure --enable-packetver=20250604 --enable-utf8 && make clean && make -j\$(nproc)" || log "Compilation failed (check logs)"
    log "Compile step completed (or failed with non-fatal error logged)."
}

phase_import_sqls(){
    log "Importing SQL files..."

    SQL_DIR1="${RATHENA_INSTALL_DIR}/sql"
    SQL_DIR2="${RATHENA_HOME}/sql_imports"

    # ---------- IMPORT main.sql FIRST ----------
    for dir in "$SQL_DIR1" "$SQL_DIR2"; do
        if [ -f "$dir/main.sql" ]; then
            log "Importing main.sql into ${DB_RAGNAROK}..."
            mariadb "${DB_RAGNAROK}" < "$dir/main.sql" \
                && log "Imported main.sql" \
                || log "Failed to import main.sql"
        fi
    done

    # ---------- IMPORT logs.sql FIRST TO LOG DB ----------
    for dir in "$SQL_DIR1" "$SQL_DIR2"; do
        if [ -f "$dir/logs.sql" ]; then
            log "Importing logs.sql into ${DB_LOGS}..."
            mariadb "${DB_LOGS}" < "$dir/logs.sql" \
                && log "Imported logs.sql" \
                || log "Failed to import logs.sql"
        fi
    done

    # ---------- IMPORT ALL OTHER SQLS ----------
    for dir in "$SQL_DIR1" "$SQL_DIR2"; do
        [ -d "$dir" ] || continue

        for f in "$dir"/*.sql; do
            [ -e "$f" ] || continue

            base="$(basename "$f")"

            # skip because already imported
            [[ "$base" == "main.sql" ]] && continue
            [[ "$base" == "logs.sql" ]] && continue

            log "Importing $base into ${DB_RAGNAROK}..."
            mariadb "${DB_RAGNAROK}" < "$f" \
                && log "Imported $base" \
                || log "Failed import $base"
        done
    done

    log "SQL import completed."
}


phase_generate_fluxcp_config(){
    log "Generating FluxCP database config..."
    CONF_DIR="$WEBROOT/application/config"
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/database.php" <<EOF
<?php return [
  'default' => [
    'host' => 'localhost',
    'username' => '${DB_USER}',
    'password' => '${DB_PASS}',
    'database' => '${DB_FLUXCP}',
    'dbdriver' => 'mysqli',
    'char_set' => 'utf8',
    'dbcollat' => 'utf8_general_ci',
  ],
];
EOF
    chown -R www-data:www-data "$WEBROOT"
    log "FluxCP config generated."
}

phase_generate_rathena_config(){
    log "Generating rAthena import config files..."

    IMPORT_CONF_DIR="$RATHENA_INSTALL_DIR/conf/import"
    mkdir -p "$IMPORT_CONF_DIR"

    # Auto-generate USERID (6 letters), USERPASS (8 letters)
    USERID="$(tr -dc 'A-Za-z' </dev/urandom | head -c6)"
    USERPASS="$(tr -dc 'A-Za-z' </dev/urandom | head -c8)"

    # Auto-detect server IP
    SERVER_IP="$(hostname -I | awk '{print $1}')"

    log "Generated rAthena login: USERID=${USERID}, USERPASS=${USERPASS}, SERVER_IP=${SERVER_IP}"

    # ------------------------------
    # Write char_conf.txt
    # ------------------------------
    cat > "$IMPORT_CONF_DIR/char_conf.txt" <<EOF
// Auto-generated by installer
userid: ${USERID}
passwd: ${USERPASS}
char_ip: ${SERVER_IP}
EOF

    # ------------------------------
    # Write map_conf.txt
    # ------------------------------
    cat > "$IMPORT_CONF_DIR/map_conf.txt" <<EOF
// Auto-generated by installer
userid: ${USERID}
passwd: ${USERPASS}
map_ip: ${SERVER_IP}
EOF

    # ------------------------------
    # Write inter_conf.txt
    # ------------------------------
    cat > "$IMPORT_CONF_DIR/inter_conf.txt" <<EOF
// Auto-generated by installer
//use_sql_db: yes
login_server_pw: ${DB_PASS}
ipban_db_pw: ${DB_PASS}
char_server_pw: ${DB_PASS}
map_server_pw: ${DB_PASS}
log_db_pw: ${DB_PASS}
EOF

    # ------------------------------
    # Write rathena_db.conf (database settings)
    # ------------------------------
    cat > "$IMPORT_CONF_DIR/rathena_db.conf" <<EOF
db_ip="127.0.0.1"
db_user="${DB_USER}"
db_pass="${DB_PASS}"
db_database="${DB_RAGNAROK}"
db_logs="${DB_LOGS}"
db_fluxcp="${DB_FLUXCP}"
EOF

    # Set proper ownership
    chown -R "${RATHENA_USER}:${RATHENA_USER}" "$IMPORT_CONF_DIR"

    log "rAthena import config generated successfully."
}


phase_setup_phpmyadmin(){
    log "Setting up phpMyAdmin front-end..."
    ln -sf /usr/share/phpmyadmin /var/www/html/phpmyadmin
    a2enconf phpmyadmin || true
    systemctl reload apache2 || systemctl restart apache2
    log "phpMyAdmin available at /phpmyadmin"
}

phase_create_serverdetails(){
    log "Writing ServerDetails.txt to desktop..."
    DETAILS_FILE="$RATHENA_HOME/Desktop/ServerDetails.txt"
    cat > "$DETAILS_FILE" <<EOF
=== rAthena Server Details ===

rAthena dir: ${RATHENA_INSTALL_DIR}
FluxCP webroot: ${WEBROOT}

DB user: ${DB_USER}
DB password: ${DB_PASS}
Databases: ${DB_RAGNAROK}, ${DB_LOGS}, ${DB_FLUXCP}

phpMyAdmin: http://localhost/phpmyadmin
FluxCP: http://localhost/

VNC user: ${RATHENA_USER}
VNC password: ${DEFAULT_VNC_PASSWORD}

Notes:
- Servers start only on XFCE login via VNC processes you control in the session.
- Use ./configure --packetver=20240403 --enable-utf8 to compile correct RAGExe.
EOF
    chown "${RATHENA_USER}:${RATHENA_USER}" "$DETAILS_FILE"
    log "ServerDetails written."
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
    "bash -lc 'cd ${RATHENA_INSTALL_DIR} && ./configure --enable-utf8 --packetver=20240403 && make clean && make -j\$(nproc)'" \
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

phase_clean_all(){
    log "Cleaning previous install..."
    systemctl stop vncserver@1.service 2>/dev/null || true
    rm -rf "$RATHENA_INSTALL_DIR" "${WEBROOT:?}/"{*,.*} "${RATHENA_HOME}/Desktop/ServerDetails.txt" 2>/dev/null || true
    mariadb <<SQL
DROP DATABASE IF EXISTS ${DB_RAGNAROK};
DROP DATABASE IF EXISTS ${DB_LOGS};
DROP DATABASE IF EXISTS ${DB_FLUXCP};
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    rm -f "$CRED_FILE"
    log "Clean complete."
}

phase_regenerate_db_password(){
    log "Regenerating rAthena DB password..."
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
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
EOF
    chmod 600 "$CRED_FILE"
    phase_generate_fluxcp_config
    phase_generate_rathena_config
    phase_create_serverdetails
    echo "New DB password for ${DB_USER}: ${DB_PASS}"
}

# ------------------ MAIN ------------------

main(){
    log "Starting full installer..."
    phase_update_upgrade
    phase_install_packages
    phase_install_chrome
    phase_create_rathena_user
    phase_clone_repos
    phase_setup_mariadb
    phase_import_sqls
    phase_generate_fluxcp_config
    phase_generate_rathena_config
    phase_setup_phpmyadmin
    phase_compile_rathena
    phase_create_serverdetails
    phase_create_desktop_shortcuts
    log "Installer finished. ServerDetails.txt on Desktop and shortcuts created."
}

# ------------------ CLI MENU ------------------

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
  1) main ;;
  2) phase_clean_all ;;
  3) phase_regenerate_db_password ;;
  4) phase_compile_rathena ;;
  5) phase_generate_rathena_config ;;
  6) phase_generate_fluxcp_config ;;
  7) echo "Exiting." ;;
  *) echo "Invalid choice. Exiting." ;;
esac

exit 0
