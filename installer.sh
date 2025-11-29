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
# Helpers / phases
# -------------------------
phase_update_upgrade(){
  log "Updating system..."
  apt update -y && apt upgrade -y
  log "System updated"
}

phase_install_packages_minimal(){
  log "Installing minimal packages (no VNC/GUI)..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    build-essential git cmake autoconf libssl-dev \
    libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
    wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring mariadb-server \
    dbus-x11 xauth xorg ufw
  log "Minimal packages installed"
}

phase_create_rathena_user(){
  if ! id -u "$RATHENA_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$RATHENA_USER"
    log "Created user $RATHENA_USER"
  else
    log "User $RATHENA_USER exists"
  fi
  mkdir -p "$RATHENA_HOME/Desktop"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"
}

phase_create_databases(){
  log "Starting MariaDB and creating DBs"
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
  log "Databases and user created (user: ${DB_USER})"
}

phase_install_phpmyadmin(){
  log "Installing phpMyAdmin (noninteractive)..."
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
  DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin || true
  systemctl restart apache2 || true
  log "phpMyAdmin installed (if package available)"
}

phase_install_chrome(){
  log "Installing Google Chrome (optional)..."
  wget -q "$CHROME_URL" -O /tmp/google-chrome.deb || true
  dpkg -i /tmp/google-chrome.deb || apt --fix-broken install -y || true
  log "Chrome done"
}

phase_clone_rathena(){
  log "Cloning rAthena into $RATHENA_INSTALL_DIR"
  rm -rf "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR"
  log "rAthena cloned"
}

phase_compile_rathena(){
  log "Attempting to compile rAthena if Makefile exists"
  cd "$RATHENA_INSTALL_DIR" || return 0
  # only run make if Makefile present (some branches use cmake/etc)
  if [ -f Makefile ]; then
    sudo -u "$RATHENA_USER" make clean || true
    sudo -u "$RATHENA_USER" make -j"$(nproc)" || log "make failed"
    log "rAthena compiled"
  else
    log "Makefile not found, skipping compile"
  fi
}

phase_install_fluxcp(){
  log "Installing FluxCP directly into $WEBROOT (will backup existing webroot)"
  if [ -n "$(ls -A "$WEBROOT" 2>/dev/null || true)" ]; then
    ts="$(date +%s)"
    mv "$WEBROOT" "${WEBROOT}.backup.${ts}"
    mkdir -p "$WEBROOT"
    log "Existing webroot backed up to ${WEBROOT}.backup.${ts}"
  fi

  git clone https://github.com/rathena/FluxCP.git "$WEBROOT"
  chown -R www-data:www-data "$WEBROOT"
  mkdir -p "$WEBROOT/cache" "$WEBROOT/templates_c" "$WEBROOT/logs" 2>/dev/null || true
  chown -R www-data:www-data "$WEBROOT"
  log "FluxCP cloned to $WEBROOT"
}

phase_create_shortcuts(){
  mkdir -p "$RATHENA_HOME/Desktop"
  cat > "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Recompile rAthena
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && make -j\$(nproc) || true"
Terminal=true
Type=Application
EOF
  chown "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop"
  chmod +x "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop"
  log "Desktop shortcuts created"
}

phase_cleanup_vnc_artifacts(){
  log "Removing any VNC artifacts (.vnc, systemd units, pid files) to ensure clean non-VNC install"
  systemctl stop vncserver@1.service 2>/dev/null || true
  systemctl disable vncserver@1.service 2>/dev/null || true
  rm -f /etc/systemd/system/vncserver@.service /etc/systemd/system/vncserver@1.service 2>/dev/null || true
  rm -rf "$RATHENA_HOME/.vnc" "$RATHENA_HOME/.Xauthority" /tmp/.X*-lock /tmp/.X11-unix/* 2>/dev/null || true
  systemctl daemon-reload || true
  log "VNC artifacts removed"
}

# -------------------------
# VNC module management (menu will call vnc_fixer for full setup)
# -------------------------
install_tightvnc_packages(){
  log "Installing TightVNC + XFCE (optional module)"
  DEBIAN_FRONTEND=noninteractive apt install -y xfce4 xfce4-goodies dbus-x11 xauth xorg tightvncserver
  log "TightVNC + XFCE packages installed"
  # call fixer script if available
  if [ -x "$VNC_FIXER" ]; then
    log "Running vnc_fixer for final configuration"
    bash "$VNC_FIXER" install
  else
    log "vnc_fixer not found or not executable: $VNC_FIXER"
  fi
}

run_vnc_fixer(){
  if [ -x "$VNC_FIXER" ]; then
    bash "$VNC_FIXER" install
  else
    echo "vnc_fixer.sh missing or not executable. Create/save vnc_fixer.sh in the same folder and chmod +x it."
  fi
}

uninstall_tightvnc(){
  log "Uninstalling TightVNC module (removes packages, systemd unit & .vnc)"
  systemctl stop vncserver@1.service 2>/dev/null || true
  systemctl disable vncserver@1.service 2>/dev/null || true
  rm -f /etc/systemd/system/vncserver@.service /etc/systemd/system/vncserver@1.service 2>/dev/null || true
  rm -rf "$RATHENA_HOME/.vnc" "$RATHENA_HOME/.Xauthority" 2>/dev/null || true
  apt remove --purge -y tightvncserver xfce4 xfce4-goodies dbus-x11 xauth xorg || true
  apt autoremove -y || true
  systemctl daemon-reload || true
  log "TightVNC module removed"
}

# -------------------------
# Menu / main flows
# -------------------------
main_menu(){
  while true; do
    cat <<EOF

=== rAthena + FluxCP Installer (modular) ===
1) Install rAthena + FluxCP (NO VNC)   <-- recommended first run
2) Install TightVNC + XFCE (optional)
3) Run TightVNC fixer only (vnc_fixer.sh)
4) Uninstall TightVNC module completely
5) Exit
EOF
    read -rp "Choice: " opt
    case "$opt" in
      1)
        log "Selected: Install rAthena + FluxCP (no VNC)"
        phase_update_upgrade
        phase_install_packages_minimal
        phase_create_rathena_user
        phase_create_databases
        phase_install_phpmyadmin
        phase_install_chrome
        phase_cleanup_vnc_artifacts
        phase_clone_rathena
        phase_compile_rathena
        phase_install_fluxcp
        phase_create_shortcuts
        log "Install (no VNC) finished"
        ;;
      2)
        log "Selected: Install TightVNC + XFCE"
        install_tightvnc_packages
        ;;
      3)
        log "Selected: Run TightVNC fixer only"
        run_vnc_fixer
        ;;
      4)
        log "Selected: Uninstall TightVNC module"
        uninstall_tightvnc
        ;;
      5)
        log "Exiting"
        exit 0
        ;;
      *)
        echo "Invalid"
        ;;
    esac
  done
}

# run menu
main_menu
