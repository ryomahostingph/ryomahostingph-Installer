#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/rathena_installer.log"
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
WEBROOT="/var/www/html"
STATE_DIR="/opt/rathena_installer_state"
DEFAULT_VNC_PASSWORD="Ch4ng3me"   # used only by vnc_fixer if invoked
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
DB_USER="rathena"
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12 || true)"
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"
VNC_FIXER="./vnc_fixer.sh"

mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE" || true
chmod 600 "$LOGFILE" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

# -------------------------
# Basic checks
# -------------------------
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

# -------------------------
# Helper Functions for Phases
# -------------------------
phase_clean_all(){
  log "Cleaning previous installations..."
  systemctl stop vncserver@1.service 2>/dev/null || true
  systemctl disable vncserver@1.service 2>/dev/null || true
  rm -f /etc/systemd/system/vncserver@.service /etc/systemd/system/vncserver@1.service 2>/dev/null || true
  rm -rf "$RATHENA_HOME/.vnc" "$RATHENA_HOME/.Xauthority" /tmp/.X*-lock /tmp/.X11-unix/* 2>/dev/null || true
  rm -rf "$RATHENA_INSTALL_DIR" "$WEBROOT" || true
  systemctl daemon-reload || true
  userdel -r "$RATHENA_USER" || true
  log "Cleanup completed."
}

# -------------------------
# Phase 1: System Update and Cleanup
# -------------------------
phase_update_upgrade(){
  log "Updating system..."
  apt update -y && apt upgrade -y
  log "System updated."
}

# -------------------------
# Phase 2: Install Base Packages (excluding VNC/GUI)
# -------------------------
phase_install_packages_minimal(){
  log "Installing essential packages..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    build-essential git cmake autoconf libssl-dev \
    libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
    wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring mariadb-server \
    dbus-x11 xauth xorg ufw
  log "Essential packages installed."
}

# -------------------------
# Install TightVNC + XFCE
# -------------------------
install_tightvnc_packages(){
  log "Installing TightVNC and XFCE..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    tightvncserver xfce4 xfce4-goodies \
    x11-xserver-utils dbus-x11 xauth
  log "TightVNC and XFCE installed."
}

# -------------------------
# Phase 3: Create rAthena User and Directories
# -------------------------
phase_create_rathena_user(){
  if ! id -u "$RATHENA_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$RATHENA_USER"
    log "Created user $RATHENA_USER."
  else
    log "User $RATHENA_USER exists."
  fi
  mkdir -p "$RATHENA_HOME/Desktop"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"
}

# -------------------------
# Phase 4: Create Databases
# -------------------------
phase_create_databases(){
  log "Starting MariaDB and creating DBs..."
  systemctl start mariadb
  for i in {1..10}; do
    mysqladmin ping >/dev/null 2>&1 && break
    sleep 1
  done

  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_RAGNAROK}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_LOGS}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_FLUXCP}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_RAGNAROK}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_LOGS}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_FLUXCP}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
  log "Databases and user created (user: ${DB_USER})."
}

# -------------------------
# Phase 5: Install phpMyAdmin
# -------------------------
phase_install_phpmyadmin(){
  log "Installing phpMyAdmin..."
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin || true
  systemctl restart apache2 || true
  log "phpMyAdmin installed (if package available)."
}

# -------------------------
# Phase 6: Install Google Chrome (Optional)
# -------------------------
phase_install_chrome(){
  log "Installing Google Chrome..."
  wget -q "$CHROME_URL" -O /tmp/google-chrome.deb || true
  dpkg -i /tmp/google-chrome.deb || apt --fix-broken install -y || true
  log "Google Chrome installed."
}

# -------------------------
# Phase 7: Clone rAthena from GitHub
# -------------------------
phase_clone_rathena(){
  log "Cloning rAthena into $RATHENA_INSTALL_DIR..."
  rm -rf "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR"
  log "rAthena cloned."
}

# -------------------------
# Phase 8: Compile rAthena
# -------------------------
phase_compile_rathena(){
  log "Compiling rAthena..."
  cd "$RATHENA_INSTALL_DIR" || return 0
  if [ -f Makefile ]; then
    sudo -u "$RATHENA_USER" make clean || true
    sudo -u "$RATHENA_USER" make -j"$(nproc)" || log "rAthena compile failed."
    log "rAthena compiled."
  else
    log "Makefile not found, skipping compile."
  fi
}

# -------------------------
# Phase 9: Install FluxCP
# -------------------------
phase_install_fluxcp(){
  log "Installing FluxCP..."
  if [ -n "$(ls -A "$WEBROOT" 2>/dev/null || true)" ]; then
    ts="$(date +%s)"
    mv "$WEBROOT" "${WEBROOT}.backup.${ts}"
    mkdir -p "$WEBROOT"
    log "Existing webroot backed up to ${WEBROOT}.backup.${ts}."
  fi
  git clone https://github.com/rathena/FluxCP.git "$WEBROOT"
  chown -R www-data:www-data "$WEBROOT"
  log "FluxCP installed."
}

# -------------------------
# Phase 10: Create Desktop Shortcuts
# -------------------------
phase_create_shortcuts(){
  log "Creating desktop shortcuts..."
  
  # Ensure the Desktop directory exists
  mkdir -p "$RATHENA_HOME/Desktop"
  
  # Recompile rAthena shortcut
  cat > "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Recompile rAthena
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && make -j\$(nproc) || true"
Terminal=true
Type=Application
EOF

  # Start rAthena Servers shortcut
  cat > "$RATHENA_HOME/Desktop/Start_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Start rAthena Servers
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && ./start_rathena.sh"
Terminal=true
Type=Application
EOF

  # VNC Password Changer shortcut
  cat > "$RATHENA_HOME/Desktop/VNC_Password_Changer.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Change VNC Password
Exec=sudo -u ${RATHENA_USER} bash -lc "vncpasswd"
Terminal=true
Type=Application
EOF

  # Backup rAthena Database shortcut
  cat > "$RATHENA_HOME/Desktop/Backup_rAthena_DB.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Backup rAthena Database
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && ./backup_db.sh"
Terminal=true
Type=Application
EOF

  # Ensure correct permissions for .desktop files
  chmod +x "$RATHENA_HOME/Desktop"/*.desktop
  chown "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop"/*.desktop

  log "Desktop shortcuts created."
}

# -------------------------
# Phase 11: Setup Systemd Services for rAthena Servers
# -------------------------
phase_setup_rathena_services(){
  log "Setting up rAthena services for auto start..."
  # Example systemd service creation for rAthena (Map, Char, Login)
  cat > /etc/systemd/system/rathena_map_server.service <<EOF
[Unit]
Description=rAthena Map Server
After=network.target

[Service]
Type=simple
User=rathena
ExecStart=/home/rathena/Desktop/rathena/map-server
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable rathena_map_server.service
  systemctl start rathena_map_server.service
  log "rAthena Map server service created and enabled."
}

# -------------------------
# Main Menu for Interactive Installer
# -------------------------
main_menu(){
  while true; do
    cat <<EOF
=== rAthena + FluxCP Installer ===
1) Clean All (Remove old settings and installations)
2) Install rAthena + FluxCP
3) Install TightVNC + XFCE
4) Run VNC Fixer
5) Setup rAthena Services for Auto Start
6) Exit
EOF
    read -rp "Choice: " opt
    case "$opt" in
      1)
        log "Selected: Clean All"
        phase_clean_all
        ;;
      2)
        log "Selected: Install rAthena + FluxCP"
        phase_update_upgrade
        phase_install_packages_minimal
        phase_create_rathena_user
        phase_create_databases
        phase_install_phpmyadmin
        phase_install_chrome
        phase_clone_rathena
        phase_compile_rathena
        phase_install_fluxcp
        phase_create_shortcuts
        log "Install finished"
        ;;
      3)
        log "Selected: Install TightVNC + XFCE"
        install_tightvnc_packages
        ;;
      4)
        log "Selected: Run VNC fixer"
        run_vnc_fixer
        ;;
      5)
        log "Selected: Setup rAthena Services"
        phase_setup_rathena_services
        ;;
      6)
        log "Exiting"
        exit 0
        ;;
      *)
        echo "Invalid option"
        ;;
    esac
  done
}

# Run main menu
main_menu
