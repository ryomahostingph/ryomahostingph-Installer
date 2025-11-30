#!/usr/bin/env bash
set -euo pipefail

# Advanced rAthena installer (final, default icons)
# - Uses ./athena-start start/stop and XFCE autostart for visible VNC terminals
# - Uses MariaDB unix_socket auth (no root password touch)
# - Uses system/default icons for desktop shortcuts
# Run as root

LOGFILE="/var/log/rathena_installer_final.log"
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
WEBROOT="/var/www/html"
STATE_DIR="/opt/rathena_installer_state"
DEFAULT_VNC_PASSWORD="Ch4ng3me"
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

# DB settings (root uses unix_socket, no password)
DB_USER="rathena"
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"

VNC_FIXER="./vnc_fixer.sh"

mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE" || true
chmod 600 "$LOGFILE" 2>/dev/null || true

log(){
  echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

apt_install(){
  DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "$@"
}

phase_update_upgrade(){
  log "Updating system..."
  apt update -y
  apt upgrade -y
  log "System updated."
}

phase_install_packages(){
  log "Installing base packages..."
  apt_install build-essential git cmake autoconf libssl-dev \
    libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
    wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring \
    mariadb-server mariadb-client \
    dbus-x11 xauth xorg ufw tightvncserver xfce4 xfce4-goodies x11-xserver-utils \
    phpmyadmin imagemagick xterm xfce4-terminal htop xdg-utils
  log "Base packages installed."
}

phase_install_chrome(){
  log "Installing Google Chrome (or Chromium fallback)..."
  if wget -O /tmp/chrome.deb "$CHROME_URL"; then
    if apt install -y /tmp/chrome.deb; then
      log "Google Chrome installed successfully."
      rm -f /tmp/chrome.deb
      return
    else
      log "Chrome .deb install failed, will try Chromium..."
    fi
  else
    log "Failed to download Chrome .deb, will try Chromium..."
  fi

  if apt_install chromium; then
    log "Chromium installed as fallback browser."
  else
    log "Failed to install any GUI browser. You may need to install one manually."
  fi
}

phase_create_rathena_user(){
  log "Creating user ${RATHENA_USER}..."
  if ! id "$RATHENA_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RATHENA_USER"
    echo "${RATHENA_USER}:${DEFAULT_VNC_PASSWORD}" | chpasswd
    log "User ${RATHENA_USER} created with VNC password ${DEFAULT_VNC_PASSWORD}."
  else
    log "User ${RATHENA_USER} exists."
  fi

  mkdir -p "${RATHENA_HOME}/Desktop" "${RATHENA_HOME}/.config/autostart" "${RATHENA_HOME}/sql_imports" "${RATHENA_HOME}/db_backups"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}"
}

phase_clone_repos(){
  log "Cloning rAthena..."
  rm -rf "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" \
    || sudo -u "$RATHENA_USER" git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  log "rAthena cloned."

  log "Cloning FluxCP into ${WEBROOT}..."
  rm -rf "${WEBROOT:?}"/{*,.*} 2>/dev/null || true
  git clone --depth 1 https://github.com/rathena/FluxCP.git "$WEBROOT" || log "FluxCP clone failed"
  chown -R www-data:www-data "$WEBROOT"
  log "FluxCP prepared."
}

phase_setup_mariadb(){
  log "Starting MariaDB and creating DBs/users..."
  systemctl enable --now mariadb

  if ! cmd_exists mariadb; then
    log "ERROR: mariadb client not found."
    exit 1
  fi

  # Use unix_socket root auth, no password
  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_RAGNAROK}
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ${DB_LOGS}
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS ${DB_FLUXCP}
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_RAGNAROK}.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_LOGS}.*     TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_FLUXCP}.*   TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  CRED_FILE="/root/.rathena_db_credentials"
  cat > "$CRED_FILE" <<EOF
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
DB_RAGNAROK='${DB_RAGNAROK}'
DB_LOGS='${DB_LOGS}'
DB_FLUXCP='${DB_FLUXCP}'
# Root still uses unix_socket (login with: sudo mariadb)
EOF
  chmod 600 "$CRED_FILE"
  log "MariaDB DBs/users created. Creds saved to $CRED_FILE"
}

phase_import_sqls(){
  log "Attempting to import any .sql files found..."
  IMPORT_DIRS=("$RATHENA_INSTALL_DIR/sql" "${RATHENA_HOME}/sql_imports")

  for d in "${IMPORT_DIRS[@]}"; do
    if [ -d "$d" ]; then
      for f in "$d"/*.sql; do
        [ -e "$f" ] || continue
        log "Importing $f into ${DB_RAGNAROK}..."
        if ! mariadb "${DB_RAGNAROK}" < "$f"; then
          log "Import failed for $f"
        fi
      done
    fi
  done

  log "SQL import step done."
}

phase_generate_fluxcp_config(){
  log "Seeding FluxCP database config placeholder..."
  CONF_DIR="$WEBROOT/application/config"
  mkdir -p "$CONF_DIR"

  cat > "$CONF_DIR/database.php" <<EOF
<?php return [
  'default' => [
    'host'     => 'localhost',
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
  log "FluxCP config placeholder created."
}

phase_compile_rathena(){
  log "Compiling rAthena (if Makefile present)..."
  if [ -d "$RATHENA_INSTALL_DIR" ]; then
    cd "$RATHENA_INSTALL_DIR"
    if [ -f "Makefile" ] || [ -f "src/Makefile" ]; then
      sudo -u "$RATHENA_USER" bash -lc "cd '$RATHENA_INSTALL_DIR' && make clean || true && make -j\$(nproc)" \
        || log "Compile had issues."
    else
      log "No Makefile; skipping compile."
    fi
  fi
}

phase_create_vnc_service(){
  log "Creating vncserver@.service template for TightVNC..."
  cat > /etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=TightVNC remote desktop server for %i
After=syslog.target network.target

[Service]
Type=forking
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || true
ExecStart=/usr/bin/su - %i -c "/usr/bin/vncserver :%i -geometry 1280x720 -depth 24"
ExecStop=/usr/bin/su - %i -c "/usr/bin/vncserver -kill :%i"

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now vncserver@1.service || true
  log "VNC template created and vncserver@1 enabled (attempted)."
}

phase_setup_ufw(){
  log "Setting firewall rules..."
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 3306/tcp
  ufw allow 5121/tcp
  ufw allow 6121/tcp
  ufw allow 6900/tcp
  ufw allow 5901/tcp
  ufw --force enable || true
  log "UFW configured."
}

phase_create_start_stop_scripts_and_autostart(){
  log "Creating start/stop helper scripts and XFCE autostart entry..."

  # start_servers_xfce.sh - runs only when the rathena user logs into XFCE (VNC)
  START_SCRIPT="${RATHENA_HOME}/start_servers_xfce.sh"
  cat > "$START_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RATHENA_HOME="$HOME"
RATHENA_DIR="${RATHENA_HOME}/Desktop/rathena"

# If already started (detect process), skip starting
if pgrep -f "athena-start" >/dev/null 2>&1; then
  echo "rAthena appears to be already started (athena-start found). Opening log terminals..."
else
  cd "$RATHENA_DIR" || exit 0
  if [ -x "./athena-start" ]; then
    ./athena-start start || echo "athena-start start returned non-zero (check ${RATHENA_DIR})"
    sleep 1
  else
    echo "athena-start not found or not executable in ${RATHENA_DIR}"
  fi
fi

LOG_DIR="${RATHENA_DIR}/log"
mkdir -p "$LOG_DIR"

open_tail(){
  title="$1"; pattern="$2"
  file=""
  if [ -f "${LOG_DIR}/${pattern}.log" ]; then
    file="${LOG_DIR}/${pattern}.log"
  else
    filefound=( "${LOG_DIR}"/*"${pattern}"* )
    if [ -e "${filefound[0]:-}" ]; then
      file="${filefound[0]}"
    fi
  fi

  if [ -n "$file" ]; then
    xfce4-terminal --title="$title" -e "bash -lc 'tail -n +1 -F \"$file\"; exec bash'" &
  else
    xfce4-terminal --title="$title" -e "bash -lc 'cd \"$RATHENA_DIR\"; echo No log file found for $pattern; exec bash'" &
  fi
}

open_tail "login-server" "login"
open_tail "char-server" "char"
open_tail "map-server" "map"

sleep 1
exit 0
SH
  chmod +x "$START_SCRIPT"
  chown "${RATHENA_USER}:${RATHENA_USER}" "$START_SCRIPT"

  # stop script
  STOP_SCRIPT="${RATHENA_HOME}/stop_servers_xfce.sh"
  cat > "$STOP_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
RATHENA_DIR="$HOME/Desktop/rathena"
cd "$RATHENA_DIR" || exit 0
if [ -x "./athena-start" ]; then
  ./athena-start stop || echo "athena-start stop returned non-zero"
else
  echo "athena-start not found"
fi
exit 0
SH
  chmod +x "$STOP_SCRIPT"
  chown "${RATHENA_USER}:${RATHENA_USER}" "$STOP_SCRIPT"

  # restart (stop then start)
  RESTART_SCRIPT="${RATHENA_HOME}/restart_servers_xfce.sh"
  cat > "$RESTART_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
"$HOME/stop_servers_xfce.sh" || true
sleep 1
"$HOME/start_servers_xfce.sh" || true
exit 0
SH
  chmod +x "$RESTART_SCRIPT"
  chown "${RATHENA_USER}:${RATHENA_USER}" "$RESTART_SCRIPT"

  AUTOSTART_DIR="${RATHENA_HOME}/.config/autostart"
  mkdir -p "$AUTOSTART_DIR"
  cat > "${AUTOSTART_DIR}/rathena-autostart.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=rAthena Start (on VNC login)
Exec=${START_SCRIPT}
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "${AUTOSTART_DIR}"

  log "Start/Stop scripts and XFCE autostart created."
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

  # Terminal / configs / monitor
  write_desktop "Terminal.desktop" "Terminal" \
    "xfce4-terminal" \
    "utilities-terminal" false

  write_desktop "Edit_rAthena_Configs.desktop" "Edit rAthena Configs" \
    "bash -lc 'xdg-open ${RATHENA_INSTALL_DIR}/conf || xterm -e \"ls -la ${RATHENA_INSTALL_DIR}/conf\"'" \
    "text-editor" false

  write_desktop "System_Monitor.desktop" "System Monitor" \
    "xterm -e 'htop || top'" \
    "utilities-system-monitor" true

  # Start/stop servers
  write_desktop "Start_All_Servers.desktop" "Start All Servers" \
    "bash -lc 'su - ${RATHENA_USER} -c \"${RATHENA_HOME}/start_servers_xfce.sh\"'" \
    "media-playback-start" false

  write_desktop "Stop_All_Servers.desktop" "Stop All Servers" \
    "bash -lc 'su - ${RATHENA_USER} -c \"${RATHENA_HOME}/stop_servers_xfce.sh\"'" \
    "media-playback-stop" false

  write_desktop "Restart_All_Servers.desktop" "Restart All Servers" \
    "bash -lc 'su - ${RATHENA_USER} -c \"${RATHENA_HOME}/restart_servers_xfce.sh\"'" \
    "view-refresh" false

  write_desktop "Recompile_rAthena.desktop" "Recompile rAthena" \
    "bash -lc 'cd ${RATHENA_INSTALL_DIR} && make -j\$(nproc) || true'" \
    "applications-development" true

  # VNC helpers
  write_desktop "Change_VNC_Password.desktop" "Change VNC Password" \
    "bash -lc 'su - ${RATHENA_USER} -c \"vncpasswd\"'" \
    "dialog-password" false

  write_desktop "Start_VNC_Server.desktop" "Start VNC Server" \
    "systemctl start vncserver@1.service" \
    "video-display" false

  write_desktop "Stop_VNC_Server.desktop" "Stop VNC Server" \
    "systemctl stop vncserver@1.service" \
    "process-stop" false

  # Web tools
  write_desktop "Open_FluxCP.desktop" "Open FluxCP" \
    "xdg-open http://localhost/" \
    "internet-web-browser" false

  write_desktop "Open_phpMyAdmin.desktop" "Open phpMyAdmin" \
    "xdg-open http://localhost/phpmyadmin" \
    "applications-internet" false

  # DB backup
  write_desktop "Backup_rAthena_DB.desktop" "Backup rAthena DB" \
    "bash -lc 'su - ${RATHENA_USER} -c \"mysqldump -u ${DB_USER} -p\\\"${DB_PASS}\\\" ${DB_RAGNAROK} > ${RATHENA_HOME}/db_backups/ragnarok_\$(date +%F).sql && echo Backup done\"'" \
    "document-save" false

  log "Desktop shortcuts created."
}

phase_run_vnc_fixer(){
  log "Running VNC fixer if present..."
  if [ -f "$VNC_FIXER" ]; then
    bash "$VNC_FIXER" || true
    log "VNC fixer executed."
  else
    log "No VNC fixer found; skip."
  fi
}

phase_clean_all(){
  log "Cleaning previous installs (files + DBs + DB user)..."

  systemctl stop vncserver@1.service 2>/dev/null || true

  # Remove files
  rm -rf "$RATHENA_INSTALL_DIR"
  rm -rf "${WEBROOT:?}"/*

  # Drop DBs and user
  if cmd_exists mariadb; then
    systemctl start mariadb 2>/dev/null || true
    log "Dropping MariaDB databases and user..."
    mariadb <<SQL || log "Warning: DB drop failed (check manually)"
DROP DATABASE IF EXISTS ${DB_RAGNAROK};
DROP DATABASE IF EXISTS ${DB_LOGS};
DROP DATABASE IF EXISTS ${DB_FLUXCP};
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  else
    log "mariadb client not found; skipping DB drop."
  fi

  rm -f /root/.rathena_db_credentials

  log "Clean complete."
}

print_summary(){
  cat <<EOF
=== INSTALLATION SUMMARY ===
rAthena install dir: ${RATHENA_INSTALL_DIR}
FluxCP webroot:      ${WEBROOT}

DB user:             ${DB_USER}
DB password:         ${DB_PASS}
DBs created:         ${DB_RAGNAROK}, ${DB_LOGS}, ${DB_FLUXCP}

 DB root: still uses unix_socket (login with: sudo mariadb)
 Cred file: /root/.rathena_db_credentials

Desktop shortcuts:   ${RATHENA_HOME}/Desktop
XFCE autostart:      ${RATHENA_HOME}/.config/autostart/rathena-autostart.desktop
Start script:        ${RATHENA_HOME}/start_servers_xfce.sh
Stop script:         ${RATHENA_HOME}/stop_servers_xfce.sh

Notes:
- Servers start ONLY when user "${RATHENA_USER}" logs into XFCE (VNC).
- Start script uses ./athena-start start then opens log terminals.
- Do NOT create duplicate systemd services for the same rAthena servers.
EOF
}

main(){
  log "Starting final advanced installer..."
  phase_update_upgrade
  phase_install_packages
  phase_install_chrome
  phase_create_rathena_user
  phase_clone_repos
  phase_setup_mariadb
  phase_import_sqls
  phase_generate_fluxcp_config
  phase_compile_rathena
  phase_create_vnc_service
  phase_setup_ufw
  phase_create_start_stop_scripts_and_autostart
  phase_create_desktop_shortcuts
  phase_run_vnc_fixer
  print_summary
  log "Installer finished."
}

# --- CLI / MENU ---

# Direct args still supported
if [ "${1:-}" = "run" ]; then
  main
  exit 0
fi

if [ "${1:-}" = "clean" ]; then
  phase_clean_all
  exit 0
fi

# Interactive menu (default)
echo
echo "================ rAthena Installer ================="
echo " 1) Run full installer"
echo " 2) Clean previous install (files + DBs + DB user)"
echo " 3) Exit"
echo "===================================================="
read -rp "Choose an option [1-3]: " choice

case "$choice" in
  1) main ;;
  2) phase_clean_all ;;
  *) echo "Exiting." ;;
esac

exit 0
