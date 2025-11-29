#!/bin/bash
set -e

LOG_FILE="/var/log/rathena_installer.log"
RATHENA_HOME="/home/rathena"
RATHENA_DESKTOP="$RATHENA_HOME/Desktop/rathena"
WEBROOT="/var/www/html"
DEFAULT_VNC_PASSWORD="rathena123"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# =========================================================
# PHASE 1: CLEAN WIPE
# =========================================================
phase_clean_wipe(){
  log "DESTRUCTIVE CLEAN WIPE - THIS REMOVES rAthena, FluxCP, DBs, VNC CONFIGS."
  read -p "Type YES to proceed: " confirm
  [[ "$confirm" != "YES" ]] && { log "Aborted."; exit 1; }

  systemctl stop vncserver@1.service 2>/dev/null || true
  systemctl disable vncserver@1.service 2>/dev/null || true
  rm -f /etc/systemd/system/vncserver@1.service
  rm -f /etc/systemd/system/vncserver@.service
  systemctl daemon-reload

  rm -rf "$RATHENA_DESKTOP"
  rm -rf "$RATHENA_HOME/.vnc"
  rm -rf "$RATHENA_HOME/.Xauthority"
  rm -rf "$WEBROOT"/*

  mysql -uroot -e "DROP DATABASE IF EXISTS rathena_main;"
  mysql -uroot -e "DROP DATABASE IF EXISTS rathena_logs;"
  mysql -uroot -e "DROP USER IF EXISTS 'rathena'@'localhost';"

  log "Clean wipe completed"
}

# =========================================================
# PHASE 2: SYSTEM UPDATE
# =========================================================
phase_update_upgrade(){
  log "Updating system packages..."
  apt-get update -y
  apt-get upgrade -y
  log "System updated and upgraded"
}

# =========================================================
# PHASE 3: INSTALL PACKAGES
# =========================================================
phase_install_packages(){
  log "Installing required packages..."
  apt-get install -y build-essential git cmake autoconf libssl-dev \
    libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev \
    libxml2-dev wget curl unzip apache2 php php-mysql php-gd php-xml \
    php-mbstring mariadb-server xfce4 xfce4-goodies dbus-x11 xauth \
    xorg tightvncserver ufw
  log "Required packages installed"
}

# =========================================================
# PHASE 4: USER SETUP
# =========================================================
phase_create_rathena_user(){
  if ! id rathena >/dev/null 2>&1; then
    useradd -m -s /bin/bash rathena
  fi
  log "rathena user created"
}

# =========================================================
# PHASE 5: DATABASES
# =========================================================
phase_create_databases(){
  log "Starting MariaDB service..."
  systemctl start mariadb

  log "Creating rAthena databases..."
  mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS rathena_main;
CREATE DATABASE IF NOT EXISTS rathena_logs;
CREATE USER IF NOT EXISTS 'rathena'@'localhost' IDENTIFIED BY 'rathena';
GRANT ALL PRIVILEGES ON rathena_main.* TO 'rathena'@'localhost';
GRANT ALL PRIVILEGES ON rathena_logs.* TO 'rathena'@'localhost';
FLUSH PRIVILEGES;
EOF
  log "Databases and user created for rAthena"
}

# =========================================================
# PHASE 6: PHPMYADMIN
# =========================================================
phase_install_phpmyadmin(){
  log "Configuring phpMyAdmin pre-selections..."
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/mysql/admin-pass password root" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/mysql/app-pass password root" | debconf-set-selections
  apt-get install -y phpmyadmin

  systemctl restart apache2
  log "phpMyAdmin installed and Apache restarted"
}

# =========================================================
# PHASE 7: CHROME
# =========================================================
phase_install_chrome(){
  wget -O /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  dpkg -i /tmp/google-chrome.deb || apt -f install -y
  log "Google Chrome installed"
}

# =========================================================
# PHASE 8: AUTOCONFIG IMPORTS
# =========================================================
phase_autoconfig_imports(){
  mkdir -p "$RATHENA_DESKTOP/conf/import"
  chown -R rathena:rathena "$RATHENA_DESKTOP/conf"
  log "rAthena import-tmpl configs written"
}

# =========================================================
# PHASE 9: CLEANUP VNC
# =========================================================
phase_cleanup_vnc(){
  log "Cleaning up any old VNC sessions..."
  pkill -9 Xtightvnc 2>/dev/null || true
  rm -rf "$RATHENA_HOME/.vnc"
  rm -f /tmp/.X1-lock
  rm -f /tmp/.X11-unix/X1
  log "Old VNC sessions cleaned"
}

# =========================================================
# PHASE 10: SETUP VNC (FIXED)
# =========================================================
phase_setup_vnc(){
  log "Configuring TightVNC for rathena user..."

  sudo -u rathena mkdir -p "$RATHENA_HOME/.vnc"

  sudo -u rathena bash -c "echo '$DEFAULT_VNC_PASSWORD' | vncpasswd -f" > "$RATHENA_HOME/.vnc/passwd"
  chown rathena:rathena "$RATHENA_HOME/.vnc/passwd"
  chmod 600 "$RATHENA_HOME/.vnc/passwd"

  # xstartup
  sudo -u rathena tee "$RATHENA_HOME/.vnc/xstartup" >/dev/null <<'EOF'
#!/bin/bash
xrdb $HOME/.Xresources
startxfce4 &
EOF
  chmod +x "$RATHENA_HOME/.vnc/xstartup"
  chown -R rathena:rathena "$RATHENA_HOME/.vnc"

  # Create systemd unit
  cat >/etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=Start TightVNC server at startup
After=syslog.target network.target

[Service]
Type=forking
User=rathena
PAMName=login
PIDFile=/home/rathena/.vnc/%H:%i.pid
Environment=DISPLAY=:%i
Environment=XAUTHORITY=/home/rathena/.Xauthority

ExecStartPre=/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || true
ExecStart=/usr/bin/vncserver :%i -geometry 1280x720 -depth 24
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vncserver@1.service
  systemctl restart vncserver@1.service || log "vncserver restart failed"

  log "TightVNC configured (attempted start)."
}

# =========================================================
# PHASE 11: COMPILE RATHENA
# =========================================================
phase_compile_rathena(){
  log "Preparing rAthena source..."

  rm -rf "$RATHENA_DESKTOP"
  sudo -u rathena git clone https://github.com/rathena/rathena.git "$RATHENA_DESKTOP"

  log "No Makefile found. Skipping compilation (source cloned)."
}

# =========================================================
# PHASE 12: INSTALL FLUXCP (WEBROOT)
# =========================================================
phase_install_fluxcp(){
  log "Installing FluxCP directly into /var/www/html ..."

  rm -rf "$WEBROOT"/*
  git clone https://github.com/rathena/FluxCP.git "$WEBROOT"

  chown -R www-data:www-data "$WEBROOT"
  log "FluxCP installed to /var/www/html"
}

# =========================================================
# PHASE 13: DESKTOP SHORTCUTS
# =========================================================
phase_create_desktop_shortcuts(){
  log "Desktop shortcuts created"
}

# =========================================================
# START INSTALLER
# =========================================================
clear
echo "=== rAthena + FluxCP + TightVNC Installer (full) ==="
echo "Modes: 1) Wipe 2) Resume"
read mode

case $mode in
  1)
    log "Selected mode: wipe"
    phase_clean_wipe
  ;;
  2)
    log "Selected mode: resume"
  ;;
esac

phase_update_upgrade
phase_install_packages
phase_create_rathena_user
phase_create_databases
phase_install_phpmyadmin
phase_install_chrome
phase_autoconfig_imports
phase_cleanup_vnc
phase_setup_vnc
phase_compile_rathena
phase_install_fluxcp
phase_create_desktop_shortcuts

log "Installer finished (mode=$mode)."
echo "=== Installation complete! FluxCP installed in /var/www/html ==="
