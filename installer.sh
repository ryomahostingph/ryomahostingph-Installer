#!/usr/bin/env bash
set -euo pipefail

# Advanced rAthena installer (final) - uses ./athena-start start/stop and XFCE autostart for visible VNC terminals
# Run as root

LOGFILE="/var/log/rathena_installer_final.log"
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
WEBROOT="/var/www/html"
ICON_DIR="${RATHENA_HOME}/.icons"
STATE_DIR="/opt/rathena_installer_state"
DEFAULT_VNC_PASSWORD="Ch4ng3me"
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
DB_ROOT_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
DB_USER="rathena"
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"
VNC_FIXER="./vnc_fixer.sh"

mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR" "$ICON_DIR"
touch "$LOGFILE" || true
chmod 600 "$LOGFILE" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

cmd_exists(){ command -v "$1" >/dev/null 2>&1 || return 1; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "$@"; }

phase_update_upgrade(){
  log "Updating system..."
  apt update -y
  apt upgrade -y
  log "System updated."
}

phase_install_packages(){
  log "Installing packages..."
  apt_install build-essential git cmake autoconf libssl-dev \
    libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
    wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring \
    mariadb-server mariadb-client \
    dbus-x11 xauth xorg ufw tightvncserver xfce4 xfce4-goodies x11-xserver-utils \
    phpmyadmin imagemagick xterm xfce4-terminal htop
  log "Packages installed."
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
  mkdir -p "${RATHENA_HOME}/Desktop" "${RATHENA_HOME}/.config/autostart" "${RATHENA_HOME}/sql_imports"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}"
}

phase_clone_repos(){
  log "Cloning rAthena..."
  rm -rf "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || {
    sudo -u "$RATHENA_USER" git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  }
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
  mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS \`${DB_RAGNAROK}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS \`${DB_LOGS}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS \`${DB_FLUXCP}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_RAGNAROK}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_LOGS}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_FLUXCP}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  CRED_FILE="/root/.rathena_db_credentials"
  cat > "$CRED_FILE" <<EOF
DB_ROOT_PASS='${DB_ROOT_PASS}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
DB_RAGNAROK='${DB_RAGNAROK}'
DB_LOGS='${DB_LOGS}'
DB_FLUXCP='${DB_FLUXCP}'
EOF
  chmod 600 "$CRED_FILE"
  log "MariaDB secured and DBs/users created. Creds saved to $CRED_FILE"
}

phase_import_sqls(){
  log "Attempting to import any .sql files found..."
  IMPORT_DIRS=("$RATHENA_INSTALL_DIR/sql" "${RATHENA_HOME}/sql_imports")
  for d in "${IMPORT_DIRS[@]}"; do
    if [ -d "$d" ]; then
      for f in "$d"/*.sql; do
        [ -e "$f" ] || continue
        log "Importing $f into ${DB_RAGNAROK}..."
        mysql -u root -p"${DB_ROOT_PASS}" "${DB_RAGNAROK}" < "$f" || log "Import failed for $f"
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
<?php
return [
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
  log "FluxCP config placeholder created."
}

phase_compile_rathena(){
  log "Compiling rAthena (if Makefile present)..."
  if [ -d "$RATHENA_INSTALL_DIR" ]; then
    cd "$RATHENA_INSTALL_DIR"
    if [ -f "Makefile" ] || [ -f "src/Makefile" ]; then
      sudo -u "$RATHENA_USER" bash -lc "cd '$RATHENA_INSTALL_DIR' && make clean || true && make -j\$(nproc)" || log "Compile had issues."
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

phase_generate_icons(){
  log "Generating icons into ${ICON_DIR}..."
  mkdir -p "$ICON_DIR"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "$ICON_DIR"

  create_icon(){
    name="$1"; label="$2"; bgcolor="$3"
    svg="$(mktemp --suffix=.svg)"
    png="${ICON_DIR}/${name}.png"
    cat > "$svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256">
  <rect width="100%" height="100%" rx="32" ry="32" fill="${bgcolor}" />
  <text x="50%" y="54%" font-family="DejaVu Sans, Arial" font-size="72" fill="#FFFFFF" text-anchor="middle" dominant-baseline="middle">${label}</text>
</svg>
SVG
    if cmd_exists convert; then
      convert -background none -resize 64x64 "$svg" "$png" || cp "$svg" "${ICON_DIR}/${name}.svg"
    else
      cp "$svg" "${ICON_DIR}/${name}.svg"
    fi
    rm -f "$svg"
    chown "${RATHENA_USER}:${RATHENA_USER}" "$png" || true
    log "Icon created: $png"
  }

  create_icon "recompile" "RC" "#3b82f6"
  create_icon "start" "▶" "#10b981"
  create_icon "stop" "■" "#ef4444"
  create_icon "restart" "⟳" "#f59e0b"
  create_icon "edit_configs" "✎" "#8b5cf6"
  create_icon "fluxcp" "🌐" "#06b6d4"
  create_icon "phpmyadmin" "DB" "#6366f1"
  create_icon "backup_db" "⇪" "#f97316"
  create_icon "restore_db" "♻" "#06b6d4"
  create_icon "change_vnc" "🔒" "#0ea5a4"
  create_icon "vnc_start" "🖥" "#60a5fa"
  create_icon "vnc_stop" "✖" "#ef4444"
  create_icon "sysmon" "📊" "#8b5cf6"
  create_icon "terminal" "⌨" "#64748b"
  create_icon "start_all" "All" "#06b6d4"
  create_icon "stop_all" "Off" "#ef4444"
  create_icon "restart_all" "R" "#f59e0b"

  log "Icons generated."
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

# Open terminals tailing logs. Adjust filenames as necessary.
LOG_DIR="${RATHENA_DIR}/log"
mkdir -p "$LOG_DIR"

# helper to open terminal and tail the right file (fallbacks included)
open_tail(){
  title="$1"; pattern="$2"
  # choose file if exists, otherwise fallback to any file matching pattern
  file=""
  if [ -f "${LOG_DIR}/${pattern}.log" ]; then
    file="${LOG_DIR}/${pattern}.log"
  else
    # pick first matching pattern
    filefound=( "${LOG_DIR}"/*"${pattern}"*  )
    if [ -e "${filefound[0]}" ]; then
      file="${filefound[0]}"
    fi
  fi

  if [ -n "$file" ]; then
    xfce4-terminal --title="$title" -e "bash -lc 'tail -n +1 -F \"$file\"; exec bash'" &
  else
    # open an interactive terminal if no log found
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

  # XFCE autostart .desktop — runs only for rathena user at XFCE session start (VNC)
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
  log "Creating desktop shortcuts..."
  DESKTOP_DIR="${RATHENA_HOME}/Desktop"
  mkdir -p "$DESKTOP_DIR"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "$DESKTOP_DIR"

  write_desktop(){
    file="$1"; name="$2"; cmd="$3"; icon="$4"; terminal="${5:-false}"
    cat > "${DESKTOP_DIR}/${file}" <<EOF
[Desktop Entry]
Version=1.0
Name=${name}
Exec=${cmd}
Terminal=${terminal}
Type=Application
Icon=${ICON_DIR}/${icon}.png
EOF
    chmod +x "${DESKTOP_DIR}/${file}"
    chown "${RATHENA_USER}:${RATHENA_USER}" "${DESKTOP_DIR}/${file}"
    log "Created ${DESKTOP_DIR}/${file}"
  }

  write_desktop "Recompile_rAthena.desktop" "Recompile rAthena" "bash -lc 'cd ${RATHENA_INSTALL_DIR} && make -j\$(nproc) || true'" "recompile" true
  write_desktop "Start_All.desktop" "Start All Servers" "bash -lc 'su - ${RATHENA_USER} -c \"${RATHENA_HOME}/start_servers_xfce.sh\"'" "start_all" false
  write_desktop "Stop_All.desktop" "Stop All Servers" "bash -lc 'su - ${RATHENA_USER} -c \"${RATHENA_HOME}/stop_servers_xfce.sh\"'" "stop_all" false
  write_desktop "Restart_All.desktop" "Restart All Servers" "bash -lc 'su - ${RATHENA_USER} -c \"${RATHENA_HOME}/restart_servers_xfce.sh\"'" "restart_all" false
  write_desktop "Edit_Configs.desktop" "Edit rAthena Configs" "bash -lc 'xdg-open ${RATHENA_INSTALL_DIR}/conf || xterm -e \"ls -la ${RATHENA_INSTALL_DIR}/conf\"'" "edit_configs" false
  write_desktop "Open_FluxCP.desktop" "Open FluxCP" "xdg-open http://localhost/" "fluxcp" false
  write_desktop "Open_phpMyAdmin.desktop" "Open phpMyAdmin" "xdg-open http://localhost/phpmyadmin" "phpmyadmin" false
  write_desktop "Backup_DB.desktop" "Backup rAthena DB" "bash -lc 'su - ${RATHENA_USER} -c \"mysqldump -u ${DB_USER} -p\\\"${DB_PASS}\\\" ${DB_RAGNAROK} > ${RATHENA_HOME}/db_backups/ragnarok_$(date +%F).sql && echo Backup done\"'" "backup_db" false
  write_desktop "Change_VNC_Password.desktop" "Change VNC Password" "bash -lc 'su - ${RATHENA_USER} -c \"vncpasswd\"'" "change_vnc" false
  write_desktop "VNC_Start.desktop" "Start VNC Server" "systemctl start vncserver@1.service" "vnc_start" false
  write_desktop "VNC_Stop.desktop" "Stop VNC Server" "systemctl stop vncserver@1.service" "vnc_stop" false
  write_desktop "System_Monitor.desktop" "System Monitor" "xterm -e 'htop || top'" "sysmon" true
  write_desktop "Terminal.desktop" "Terminal" "xfce4-terminal" "terminal" false
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
  log "Cleaning previous installs (safe)..."
  systemctl stop vncserver@1.service 2>/dev/null || true
  rm -rf "$RATHENA_INSTALL_DIR"
  rm -rf "${WEBROOT:?}"/*
  log "Clean complete."
}

print_summary(){
  cat <<EOF

=== INSTALLATION SUMMARY ===

rAthena install dir: ${RATHENA_INSTALL_DIR}
FluxCP webroot: ${WEBROOT}
DB user: ${DB_USER}
DB password: ${DB_PASS}
DBs created: ${DB_RAGNAROK}, ${DB_LOGS}, ${DB_FLUXCP}
Root DB password saved to: /root/.rathena_db_credentials

Desktop icons: ${ICON_DIR}
Desktop shortcuts: ${RATHENA_HOME}/Desktop
XFCE autostart script: ${RATHENA_HOME}/.config/autostart/rathena-autostart.desktop
Visible servers start script: ${RATHENA_HOME}/start_servers_xfce.sh
Stop script: ${RATHENA_HOME}/stop_servers_xfce.sh

Notes:
 - Servers will start ONLY when rathena user logs into XFCE (VNC) — as requested (Option A).
 - The start script uses ./athena-start start and then opens terminals that tail log files.
 - If log files are not present, the terminals will open in the repo folder and show a message.
 - Do NOT enable any systemd rathena services that start the same servers, or you'll get duplicate processes.

EOF
}

main(){
  log "Starting final advanced installer..."
  phase_update_upgrade
  phase_install_packages
  phase_create_rathena_user
  phase_clone_repos
  phase_setup_mariadb
  phase_import_sqls
  phase_generate_fluxcp_config
  phase_compile_rathena
  phase_create_vnc_service
  phase_setup_ufw
  phase_generate_icons
  phase_create_start_stop_scripts_and_autostart
  phase_create_desktop_shortcuts
  phase_run_vnc_fixer
  print_summary
  log "Installer finished."
}

# CLI
if [ "${1:-}" = "clean" ]; then
  phase_clean_all; exit 0
fi
if [ "${1:-}" = "run" ]; then
  main; exit 0
fi

cat <<EOF
Usage:
  run   - perform the full advanced install now
  clean - remove previous installation artifacts (safe)
Example:
  sudo ./installer_final_with_xfce_autostart.sh run

EOF

read -rp "Type 'run' to execute the full installer or 'clean' to remove old installs: " choice
case "$choice" in
  run) main ;;
  clean) phase_clean_all ;;
  *) echo "Exiting." ;;
esac

exit 0
