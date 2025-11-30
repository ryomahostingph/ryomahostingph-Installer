#!/usr/bin/env bash
set -euo pipefail

# Advanced rAthena installer (final, default icons)
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
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c16 || true)"
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"

VNC_FIXER="./vnc_fixer.sh"

mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE" || true
chmod 600 "$LOGFILE" 2>/dev/null || true

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "$@"; }

# --- Phases ---
phase_update_upgrade(){ log "Updating system..."; apt update -y; apt upgrade -y; log "System updated."; }

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
    apt install -y /tmp/chrome.deb && rm -f /tmp/chrome.deb && log "Google Chrome installed." && return
  fi
  log "Installing Chromium fallback..."
  apt_install chromium || log "Failed to install any GUI browser."
}

phase_create_rathena_user(){
  log "Creating user ${RATHENA_USER}..."
  if ! id "$RATHENA_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RATHENA_USER"
    echo "${RATHENA_USER}:${DEFAULT_VNC_PASSWORD}" | chpasswd
  fi
  mkdir -p "${RATHENA_HOME}/Desktop" "${RATHENA_HOME}/.config/autostart" "${RATHENA_HOME}/sql_imports" "${RATHENA_HOME}/db_backups"
  chown -R "${RATHENA_USER}:${RATHENA_USER}" "${RATHENA_HOME}"
}

phase_clone_repos(){
  log "Cloning rAthena..."
  rm -rf "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone --depth 1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || sudo -u "$RATHENA_USER" git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  log "rAthena cloned."

  log "Cloning FluxCP..."
  rm -rf "${WEBROOT:?}"/*; git clone --depth 1 https://github.com/rathena/FluxCP.git "$WEBROOT"
  chown -R www-data:www-data "$WEBROOT"
}

phase_setup_mariadb(){
  log "Starting MariaDB and creating DBs/users..."
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

  CRED_FILE="/root/.rathena_db_credentials"
  cat > "$CRED_FILE" <<EOF
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
DB_RAGNAROK='${DB_RAGNAROK}'
DB_LOGS='${DB_LOGS}'
DB_FLUXCP='${DB_FLUXCP}'
EOF
  chmod 600 "$CRED_FILE"
}

phase_import_sqls(){
  log "Importing .sql files..."
  IMPORT_DIRS=("$RATHENA_INSTALL_DIR/sql" "${RATHENA_HOME}/sql_imports")
  for d in "${IMPORT_DIRS[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.sql; do
      [ -e "$f" ] || continue
      log "Importing $f into ${DB_RAGNAROK}..."
      mariadb "${DB_RAGNAROK}" < "$f" || log "Import failed: $f"
    done
  done
}

phase_generate_fluxcp_config(){
  log "Generating FluxCP database config..."
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
}

phase_generate_rathena_config(){
  log "Generating rAthena conf/import files..."
  IMPORT_DIR="${RATHENA_INSTALL_DIR}/conf/import"
  mkdir -p "$IMPORT_DIR"

  PUBLIC_IP=$(curl -s https://api.ipify.org || echo "127.0.0.1")
  PRIVATE_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "127.0.0.1")

  # Load DB credentials
  if [ -f "/root/.rathena_db_credentials" ]; then
    source /root/.rathena_db_credentials
  fi

  cat > "${IMPORT_DIR}/login_athena.conf" <<EOF
login-server:
  public_ip = ${PUBLIC_IP}
  private_ip = ${PRIVATE_IP}
  username = ${DB_USER}
  password = ${DB_PASS}
  char_db = ragnarok
EOF

  cat > "${IMPORT_DIR}/char_athena.conf" <<EOF
char-server:
  username = ${DB_USER}
  password = ${DB_PASS}
  char_db = ragnarok
  log_db = ragnarok_logs
EOF

  cat > "${IMPORT_DIR}/map_athena.conf" <<EOF
map-server:
  username = ${DB_USER}
  password = ${DB_PASS}
  char_db = ragnarok
  log_db = ragnarok_logs
EOF

  log "rAthena config files generated in ${IMPORT_DIR}"
  log "Public IP: ${PUBLIC_IP}, Private IP: ${PRIVATE_IP}"
}

phase_compile_rathena(){
  log "Compiling rAthena..."
  cd "$RATHENA_INSTALL_DIR"
  if [ -f "Makefile" ] || [ -f "src/Makefile" ]; then
    sudo -u "$RATHENA_USER" bash -lc "make clean || true && make -j\$(nproc)" || log "Compile issues"
  fi
}

phase_create_vnc_service(){
  log "Creating vncserver@.service..."
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
}

phase_setup_ufw(){
  log "Configuring UFW..."
  ufw allow 22/tcp 80/tcp 443/tcp 3306/tcp 5121/tcp 6121/tcp 6900/tcp 5901/tcp
  ufw --force enable || true
}

phase_clean_all(){
  log "Cleaning previous installs..."
  systemctl stop vncserver@1.service 2>/dev/null || true
  rm -rf "$RATHENA_INSTALL_DIR" "$WEBROOT"/*
  if cmd_exists mariadb; then
    systemctl start mariadb 2>/dev/null || true
    mariadb <<SQL
DROP DATABASE IF EXISTS ${DB_RAGNAROK};
DROP DATABASE IF EXISTS ${DB_LOGS};
DROP DATABASE IF EXISTS ${DB_FLUXCP};
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
  fi
  rm -f /root/.rathena_db_credentials
}

print_summary(){
  cat <<EOF
=== INSTALLATION SUMMARY ===
rAthena install dir: ${RATHENA_INSTALL_DIR}
FluxCP webroot:      ${WEBROOT}
DB user:             ${DB_USER}
DB password:         ${DB_PASS}
DBs created:         ${DB_RAGNAROK}, ${DB_LOGS}, ${DB_FLUXCP}
DB root: still uses unix_socket
Cred file: /root/.rathena_db_credentials
EOF
}

main(){
  log "Starting installer..."
  phase_update_upgrade
  phase_install_packages
  phase_install_chrome
  phase_create_rathena_user
  phase_clone_repos
  phase_setup_mariadb
  phase_import_sqls
  phase_generate_fluxcp_config
  phase_generate_rathena_config   # <-- now auto runs
  phase_compile_rathena
  phase_create_vnc_service
  phase_setup_ufw
  print_summary
  log "Installer finished."
}

# --- CLI / MENU ---
echo
echo "================ rAthena Installer ================="
echo " 1) Run full installer"
echo " 2) Clean previous install (files + DBs + DB user)"
echo " 3) Exit"
echo " 4) Generate rAthena config files (conf/import)"
echo "===================================================="
read -rp "Choose an option [1-4]: " choice

case "$choice" in
  1) main ;;
  2) phase_clean_all ;;
  3) echo "Exiting." ;;
  4) phase_generate_rathena_config ;;
  *) echo "Invalid option. Exiting." ;;
esac

exit 0
