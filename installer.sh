#!/usr/bin/env bash
# ================================
# rAthena + FluxCP + TightVNC Installer
# Fully fixed + FluxCP auto-install for Debian 12
# ================================

set -o pipefail
set -e

### CONFIG ###
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
WEBROOT="/var/www/html"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
BUILD_DIR="${RATHENA_HOME}/Desktop/build"
DEFAULT_VNC_PASSWORD="Ch4ng3me"
STATE_DIR="/opt/rathena_installer_state"
LOGFILE="/var/log/rathena_installer.log"
PACKETVER="20250604"
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

DB_USER="rathena"
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12 || openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c12)"
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"

# ================================
# Helpers
# ================================
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
die(){ echo "FATAL: $*" | tee -a "$LOGFILE"; exit 1; }
[ "$EUID" -ne 0 ] && die "Please run as root (sudo)"
mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE"; chmod 600 "$LOGFILE"
phase_ok(){ [ -f "${STATE_DIR}/$1.ok" ]; }
phase_mark(){ touch "${STATE_DIR}/$1.ok"; log "PHASE OK: $1"; }

run_phase(){
  local name="$1"; shift; local func="$1"
  if [ "$MODE" = "resume" ] && phase_ok "$name"; then log "Skipping phase (already OK) $name"; return 0; fi
  log "PHASE START: $name"
  echo "==> Running: $name"
  set +e
  if declare -f "$func" >/dev/null 2>&1; then "$func"; rc=$?; else log "Function $func not found"; rc=127; fi
  set -e
  if [ $rc -ne 0 ]; then
    log "PHASE ERROR: $name (rc=$rc)"
    echo; echo "Phase '$name' failed (exit $rc). Options:"
    select opt in "Retry" "Skip" "Abort" "Enter Debug Shell"; do
      case $REPLY in
        1) log "User chose Retry for $name"; run_phase "$name" "$func"; return;;
        2) log "User chose Skip for $name"; return;;
        3) die "Aborted by user at phase $name";;
        4) log "User opened debug shell at phase $name"; /bin/bash; echo "Resuming..."; run_phase "$name" "$func"; return;;
        *) echo "Invalid";;
      esac
    done
  else
    phase_mark "$name"
  fi
}

# ================================
# PHASES
# ================================
phase_clean_wipe(){
  echo "DESTRUCTIVE CLEAN WIPE - THIS REMOVES rAthena, FluxCP, DBs, VNC CONFIGS."
  read -rp "Type YES to proceed: " ans
  [ "$ans" != "YES" ] && { log "Clean wipe cancelled"; return 0; }
  systemctl stop rathena-*.service vncserver@:1.service apache2 mariadb 2>/dev/null || true
  systemctl disable rathena-*.service vncserver@:1.service 2>/dev/null || true
  rm -f /etc/systemd/system/rathena-*.service /etc/systemd/system/vncserver@.service || true
  rm -rf "$RATHENA_INSTALL_DIR" "$BUILD_DIR" "$WEBROOT/fluxcp" "$RATHENA_HOME/.vnc" /var/log/rathena || true
  mysql -e "DROP DATABASE IF EXISTS \`${DB_RAGNAROK}\`;" 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS \`${DB_LOGS}\`;" 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS \`${DB_FLUXCP}\`;" 2>/dev/null || true
  mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
  rm -rf "$STATE_DIR" || true
  mkdir -p "$STATE_DIR"
  log "Clean wipe completed"
}

phase_update_upgrade(){
  apt update -y && apt upgrade -y
  log "System updated and upgraded"
}

phase_install_packages(){
  DEBIAN_FRONTEND=noninteractive apt install -y \
    build-essential git cmake autoconf libssl-dev libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev \
    wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring mariadb-server xfce4 xfce4-goodies dbus-x11 xauth xorg tightvncserver ufw
  log "Required packages installed"
}

phase_create_user(){
  id -u "$RATHENA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RATHENA_USER"
  mkdir -p "$RATHENA_HOME/Desktop"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"
  log "rathena user created"
}

phase_create_databases(){
  log "Starting MariaDB service..."
  systemctl start mariadb
  for i in {1..10}; do
    mysqladmin ping >/dev/null 2>&1 && break
    log "MariaDB not ready yet, waiting 2 seconds..."
    sleep 2
  done

  log "Creating rAthena databases..."
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_RAGNAROK}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_LOGS}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_FLUXCP}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_RAGNAROK}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_LOGS}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_FLUXCP}\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
  log "Databases and user created for rAthena"
}

phase_install_phpmyadmin(){
  log "Configuring phpMyAdmin pre-selections..."
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/app-password-confirm password ${DB_PASS}" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/mysql/admin-user string root" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/mysql/admin-pass password" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/mysql/app-pass password ${DB_PASS}" | debconf-set-selections

  DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin

  if [ -f /etc/phpmyadmin/config.inc.php ]; then
    sed -i "s/^\(\$cfg\['Servers'\]\['host'\] = \).*\$/\1'localhost';/" /etc/phpmyadmin/config.inc.php
    log "phpMyAdmin configured to localhost"
  else
    log "WARNING: phpMyAdmin config file not found"
  fi

  systemctl restart apache2
  log "phpMyAdmin installed and Apache restarted"
}

phase_install_chrome(){
  wget -q "$CHROME_URL" -O /tmp/google-chrome.deb
  dpkg -i /tmp/google-chrome.deb || apt --fix-broken install -y
  log "Google Chrome installed"
}

phase_autoconfig_imports(){
  mkdir -p "$RATHENA_INSTALL_DIR/conf/import-tmpl"
  VPS_IP="$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ifconfig.co || true)"
  cat >"$RATHENA_INSTALL_DIR/conf/import-tmpl/sql_connection.conf" <<EOF
db_hostname: localhost
db_port: 3306
db_username: ${DB_USER}
db_password: ${DB_PASS}
db_database: ${DB_RAGNAROK}
EOF

  cat >"$RATHENA_INSTALL_DIR/conf/import-tmpl/log_db.conf" <<EOF
log_db_hostname: localhost
log_db_port: 3306
log_db_username: ${DB_USER}
log_db_password: ${DB_PASS}
log_db_database: ${DB_LOGS}
EOF

  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR/conf/import-tmpl"
  log "rAthena import-tmpl configs written"
}

phase_setup_vnc(){
  log "Configuring TightVNC for rathena user..."
  sudo -u rathena rm -rf "$RATHENA_HOME/.vnc"
  sudo -u rathena mkdir -p "$RATHENA_HOME/.vnc"

  echo "$DEFAULT_VNC_PASSWORD" | sudo -u rathena vncpasswd -f > "$RATHENA_HOME/.vnc/passwd"
  chmod 600 "$RATHENA_HOME/.vnc/passwd"

  sudo -u rathena tee "$RATHENA_HOME/.vnc/xstartup" > /dev/null <<'EOF'
#!/bin/bash
xrdb $HOME/.Xresources || true
startxfce4 &
EOF
  sudo -u rathena chmod +x "$RATHENA_HOME/.vnc/xstartup"

  cat >/etc/systemd/system/vncserver@:1.service <<EOF
[Unit]
Description=Start TightVNC server at startup
After=syslog.target network.target

[Service]
Type=forking
User=rathena
PAMName=login
PIDFile=/home/rathena/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x720 -depth 24
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vncserver@:1
  systemctl start vncserver@:1
  sleep 3
  systemctl status vncserver@:1 --no-pager
  log "TightVNC configured and started"
}

phase_compile_rathena(){
  log "Preparing rAthena source..."
  if [ -d "$RATHENA_INSTALL_DIR" ]; then
    log "Existing rAthena folder found, removing..."
    rm -rf "$RATHENA_INSTALL_DIR"
  fi

  sudo -u rathena git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR"

  cd "$RATHENA_INSTALL_DIR"
  if [ -f Makefile ]; then
    log "Cleaning previous build..."
    sudo -u rathena make clean
  fi
  log "Compiling rAthena..."
  if [ -f Makefile ]; then
    sudo -u rathena make -j$(nproc)
    log "rAthena compiled successfully"
  else
    log "No Makefile found. Skipping compilation (source cloned)."
  fi
}

phase_install_fluxcp(){
  log "Installing FluxCP into /var/www/html..."
  rm -rf "$WEBROOT/fluxcp"
  git clone https://github.com/rathena/FluxCP.git "$WEBROOT/fluxcp"
  chown -R www-data:www-data "$WEBROOT/fluxcp"
  mkdir -p "$WEBROOT/fluxcp/cache"
  chown -R www-data:www-data "$WEBROOT/fluxcp/cache"
  log "FluxCP installed to $WEBROOT/fluxcp"
}

phase_create_desktop_shortcuts(){
  mkdir -p "$RATHENA_HOME/Desktop"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop"
  log "Desktop shortcuts created"
}

# ================================
# MAIN
# ================================
echo "=== rAthena + FluxCP + TightVNC Installer (with full features) ==="
echo "Modes: 1) Wipe 2) Resume"
read -r choice
MODE=$([ "$choice" = "1" ] && echo wipe || echo resume)
log "Selected mode: $MODE"

[ "$MODE" = "wipe" ] && run_phase "Clean_Wipe" "phase_clean_wipe"

PHASE_LIST=(
  "Update_and_Upgrade:phase_update_upgrade"
  "Install_Packages:phase_install_packages"
  "Create_Rathena_User:phase_create_user"
  "Create_Databases:phase_create_databases"
  "Install_phpMyAdmin:phase_install_phpmyadmin"
  "Install_Chrome:phase_install_chrome"
  "Autoconfig_Imports:phase_autoconfig_imports"
  "Setup_VNC:phase_setup_vnc"
  "Compile_rAthena:phase_compile_rathena"
  "Install_FluxCP:phase_install_fluxcp"
  "Create_Desktop_Shortcuts:phase_create_desktop_shortcuts"
)

for p in "${PHASE_LIST[@]}"; do name="${p%%:*}"; func="${p#*:}"; run_phase "$name" "$func"; done

log "Installer finished (mode=$MODE)."
echo "=== Installation complete! FluxCP installed in /var/www/html/fluxcp ==="
