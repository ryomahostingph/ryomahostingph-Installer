#!/usr/bin/env bash
# Fully Updated rAthena + FluxCP + TightVNC Installer for Debian 12 (Final)
# Features:
# - rAthena cloned to /home/rathena/Desktop/rathena
# - Separate build folder /home/rathena/Desktop/build for compilation
# - Default PacketVer 20250604
# - Adds 8GB swap if needed
# - FluxCP installed directly to /var/www/html
# - VNC locked to rathena user
# - Three separate databases: Ragnarok, Logs, FluxCP
# - Imports rAthena SQL appropriately
# - Prints all credentials in ServerDetails.txt

set -o pipefail
set -e

### CONFIG ###
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
FLUXCP_REPO="https://github.com/rathena/FluxCP.git"
WEBROOT="/var/www/html"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
BUILD_DIR="${RATHENA_HOME}/Desktop/build"
DEFAULT_VNC_PASSWORD="Ch4ng3me"
STATE_DIR="/opt/rathena_installer_state"
LOGFILE="/var/log/rathena_installer.log"
PACKETVER="20250604"

DB_USER="rathena"
DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12 || openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c12)"
DB_RAGNAROK="ragnarok"
DB_LOGS="ragnarok_logs"
DB_FLUXCP="fluxcp"

WHITELIST_ALWAYS=("120.28.137.77" "127.0.0.1")
BACKGROUND_IMAGE_PATH="${RATHENA_HOME}/background.png"

# Helpers
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

# ==================== PHASES ====================
phase_clean_wipe(){
  echo "DESTRUCTIVE CLEAN WIPE - THIS REMOVES rAthena, FluxCP, DBs, VNC CONFIGS."
  read -rp "Type YES to proceed: " ans
  [ "$ans" != "YES" ] && { log "Clean wipe cancelled"; return 0; }
  systemctl stop rathena-*.service vncserver@:1.service apache2 mariadb 2>/dev/null || true
  systemctl disable rathena-*.service vncserver@:1.service 2>/dev/null || true
  rm -f /etc/systemd/system/rathena-*.service /etc/systemd/system/vncserver@.service /usr/local/bin/rathena_helpers/* /usr/local/bin/rathena_start_*.sh || true
  rm -rf "$RATHENA_INSTALL_DIR" "${RATHENA_INSTALL_DIR}.backup" "$BUILD_DIR" "$WEBROOT" "$RATHENA_HOME/.vnc" /root/rathena_db_creds /root/rathena_db_backups /var/log/rathena || true
  mysql -e "DROP DATABASE IF EXISTS \\`${DB_RAGNAROK}\\`;" 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS \\`${DB_LOGS}\\`;" 2>/dev/null || true
  mysql -e "DROP DATABASE IF EXISTS \\`${DB_FLUXCP}\\`;" 2>/dev/null || true
  mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
  rm -rf "$STATE_DIR" || true
  mkdir -p "$STATE_DIR"
  log "Clean wipe completed"
}

phase_update_upgrade(){ apt update -y && apt upgrade -y; }
phase_install_packages(){ DEBIAN_FRONTEND=noninteractive apt install -y build-essential git cmake autoconf libssl-dev libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring mariadb-server xfce4 xfce4-goodies dbus-x11 xauth xorg tightvncserver ufw; }
phase_create_user(){ id -u "$RATHENA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RATHENA_USER"; mkdir -p "$RATHENA_HOME/Desktop"; chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"; }

phase_configure_mariadb(){
  systemctl enable --now mariadb
  mysql -e "CREATE DATABASE IF NOT EXISTS \\`${DB_RAGNAROK}\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE DATABASE IF NOT EXISTS \\`${DB_LOGS}\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE DATABASE IF NOT EXISTS \\`${DB_FLUXCP}\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON \\`${DB_RAGNAROK}\\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \\`${DB_LOGS}\\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "GRANT ALL PRIVILEGES ON \\`${DB_FLUXCP}\\`.* TO '${DB_USER}'@'localhost';"
  mysql -e "FLUSH PRIVILEGES;"
  cat >/root/rathena_db_creds <<EOF
DB_RAGNAROK=${DB_RAGNAROK}
DB_LOGS=${DB_LOGS}
DB_FLUXCP=${DB_FLUXCP}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
  chmod 600 /root/rathena_db_creds
  log "Databases created and credentials saved"
}

phase_add_swap(){ if ! swapon --show | grep -q "."; then log "Adding 8GB swap..."; fallocate -l 8G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile; echo '/swapfile none swap sw 0 0' >> /etc/fstab; log "8GB swap enabled"; else log "Swap already exists"; fi; }

phase_autoconfig_imports(){
  mkdir -p "$RATHENA_INSTALL_DIR/conf/import"
  VPS_IP="$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ifconfig.co || true)"
  cat >"$RATHENA_INSTALL_DIR/conf/import/sql_connection.conf" <<EOF
 db_hostname: localhost
 db_port: 3306
 db_username: ${DB_USER}
 db_password: ${DB_PASS}
 db_database: ${DB_RAGNAROK}
EOF
  cat >"$RATHENA_INSTALL_DIR/conf/import/log_db.conf" <<EOF
 log_db_hostname: localhost
 log_db_port: 3306
 log_db_username: ${DB_USER}
 log_db_password: ${DB_PASS}
 log_db_database: ${DB_LOGS}
EOF
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR/conf/import"
  log "rAthena import configs written"
}

phase_clone_build_rathena(){
  rm -rf "$RATHENA_INSTALL_DIR" "$BUILD_DIR"
  mkdir -p "$RATHENA_INSTALL_DIR" "$BUILD_DIR"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR" "$BUILD_DIR"
  sudo -u "$RATHENA_USER" git clone --depth=1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || die "git clone failed"
  cd "$BUILD_DIR"
  export PACKETVER="${PACKETVER}"
  sudo -u "$RATHENA_USER" cmake -G"Unix Makefiles" -DINSTALL_TO_SOURCE=ON -DCMAKE_BUILD_TYPE=Release "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" make -j$(nproc)
  log "rAthena compiled at $RATHENA_INSTALL_DIR"
}

phase_install_fluxcp(){
  rm -rf "$WEBROOT"/*
  git clone --depth=1 "$FLUXCP_REPO" "$WEBROOT" || die "fluxcp clone failed"
  chown -R www-data:www-data "$WEBROOT"
  log "FluxCP installed to $WEBROOT"
}

phase_write_server_details(){
  cat >"${RATHENA_HOME}/Desktop/ServerDetails.txt" <<EOF
rAthena Installer - Server Details
=================================
Date: $(date)
rAthena Path: ${RATHENA_INSTALL_DIR}
FluxCP Path: ${WEBROOT}
Database Credentials:
  Ragnarok DB: ${DB_RAGNAROK}
  Logs DB:     ${DB_LOGS}
  FluxCP DB:   ${DB_FLUXCP}
  DB User:     ${DB_USER}
  DB Pass:     ${DB_PASS}
  Credentials file: /root/rathena_db_creds
EOF
  chown "$RATHENA_USER":"$RATHENA_USER" "${RATHENA_HOME}/Desktop/ServerDetails.txt"
  chmod 600 "${RATHENA_HOME}/Desktop/ServerDetails.txt"
  log "ServerDetails.txt written"
}

# ==================== MAIN ====================

echo "=== rAthena + FluxCP + TightVNC Installer (Final) ==="
echo "Modes: 1) Wipe 2) Resume"
read -r choice
MODE=$([ "$choice" = "1" ] && echo wipe || echo resume)
log "Selected mode: $MODE"

[ "$MODE" = "wipe" ] && run_phase "Clean_Wipe" "phase_clean_wipe"

PHASE_LIST=(
  "Update_and_Upgrade:phase_update_upgrade"
  "Install_Packages:phase_install_packages"
  "Create_Rathena_User:phase_create_user"
  "Configure_MariaDB:phase_configure_mariadb"
  "Add_Swap:phase_add_swap"
  "AutoConfig_ConfImport:phase_autoconfig_imports"
  "Clone_and_Build_rathena:phase_clone_build_rathena"
  "Install_FluxCP:phase_install_fluxcp"
  "Write_ServerDetails:phase_write_server_details"
)

for p in "${PHASE_LIST[@]}"; do name="${p%%:*}"; func="${p#*:}"; run_phase "$name" "$func"; done

log "Installer finished (mode=$MODE)."
