#!/usr/bin/env bash
# rAthena + FluxCP + TightVNC Installer for Debian 12 (Final)
# Updated version: rAthena on /home/rathena/Desktop/rathena

set -o pipefail
set -e

### CONFIG ###
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
FLUXCP_REPO="https://github.com/rathena/FluxCP.git"
WEBROOT="/var/www/fluxcp"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
DEFAULT_VNC_PASSWORD="Ch4ng3me"
DB_NAME="rathena"
DB_USER="rathena"
STATE_DIR="/opt/rathena_installer_state"
LOGFILE="/var/log/rathena_installer.log"
WHITELIST_ALWAYS=("120.28.137.77" "127.0.0.1")
BACKGROUND_IMAGE_PATH="${RATHENA_HOME}/background.png"
PACKETVER="20250604"

# Helpers
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
die(){ echo "FATAL: $*" | tee -a "$LOGFILE"; exit 1; }
[ "$EUID" -ne 0 ] && die "Please run as root (sudo)"
mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE"; chmod 600 "$LOGFILE"

random_pass(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c8 || openssl rand -base64 6 | tr -dc 'A-Za-z0-9' | head -c8; }
detect_public_ip(){ ip="$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ifconfig.co || true)"; echo "$ip"; }
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
  rm -rf "$RATHENA_INSTALL_DIR" "${RATHENA_INSTALL_DIR}.backup" "$WEBROOT" "$RATHENA_HOME/.vnc" "$RATHENA_HOME/Desktop/rathena" /root/rathena_db_creds /root/rathena_db_backups /var/log/rathena || true
  mysql -e "DROP DATABASE IF EXISTS \\`${DB_NAME}\\`;" 2>/dev/null || true
  mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  log "Clean wipe completed"
}

phase_update_upgrade(){ apt update -y && apt upgrade -y; }
phase_install_packages(){ DEBIAN_FRONTEND=noninteractive apt install -y build-essential git cmake autoconf libssl-dev libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring mariadb-server xfce4 xfce4-goodies dbus-x11 xauth xorg tightvncserver ufw; }
phase_create_user(){ id -u "$RATHENA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RATHENA_USER"; mkdir -p "$RATHENA_HOME/Desktop"; chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"; }
phase_configure_mariadb(){ systemctl enable --now mariadb; DB_PASS="$(random_pass)"; mysql -e "CREATE DATABASE IF NOT EXISTS \\`${DB_NAME}\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"; mysql -e "GRANT ALL PRIVILEGES ON \\`${DB_NAME}\\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"; cat >/root/rathena_db_creds <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
  chmod 600 /root/rathena_db_creds; log "DB created"; echo "DB credentials: ${DB_USER} / ${DB_PASS}"; }
phase_add_swap(){
  if ! swapon --show | grep -q "."; then
    log "No swap detected. Adding 8GB swap..."
    fallocate -l 8G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "8GB swap enabled"
  else
    log "Swap already exists. Skipping swap creation."
  fi
}
phase_autoconfig_imports(){
  mkdir -p "$RATHENA_INSTALL_DIR/conf/import"
  source /root/rathena_db_creds || die "DB creds missing"
  VPS_IP="$(detect_public_ip)"
  cat >"$RATHENA_INSTALL_DIR/conf/import/sql_connection.conf" <<EOF
 db_hostname: localhost
 db_port: 3306
 db_username: ${DB_USER}
 db_password: ${DB_PASS}
 db_database: ${DB_NAME}
EOF
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR/conf/import"
  log "Wrote conf/import templates"
}
phase_clone_build_rathena(){
  mkdir -p "$RATHENA_INSTALL_DIR"; chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone --depth=1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || die "git clone failed"
  cd "$RATHENA_INSTALL_DIR"
  mkdir -p build; cd build
  export PACKETVER="${PACKETVER}"
  log "Using PacketVer $PACKETVER"
  sudo -u "$RATHENA_USER" cmake -G"Unix Makefiles" -DINSTALL_TO_SOURCE=ON -DCMAKE_BUILD_TYPE=Release ..
  sudo -u "$RATHENA_USER" make -j$(nproc)
  log "rAthena compiled at $RATHENA_INSTALL_DIR"
}
phase_install_fluxcp(){
  [ -d "$WEBROOT" ] && rm -rf "$WEBROOT"
  mkdir -p "$WEBROOT"
  git clone --depth=1 "$FLUXCP_REPO" "$WEBROOT" || die "fluxcp clone failed"
  chown -R www-data:www-data "$WEBROOT"
  log "FluxCP installed to $WEBROOT"
}
phase_setup_vnc_and_firewall(){
  sudo -u "$RATHENA_USER" bash -c "mkdir -p ${RATHENA_HOME}/.vnc && echo -e \"${DEFAULT_VNC_PASSWORD}\n${DEFAULT_VNC_PASSWORD}\n\" | vncpasswd >/dev/null 2>&1"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/.vnc"
  chmod 700 "$RATHENA_HOME/.vnc"
  cat >/etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=TightVNC remote desktop service (display %i)
After=syslog.target network.target
[Service]
Type=forking
User=%i
PAMName=login
PIDFile=/home/%i/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/tightvncserver :%i -geometry 1280x720
ExecStop=/usr/bin/vncserver -kill :%i
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now vncserver@1.service || true
  DEPLOYER_IP=$(detect_public_ip)
  WHITELIST=("${WHITELIST_ALWAYS[@]}")
  [ -n "$DEPLOYER_IP" ] && WHITELIST+=("$DEPLOYER_IP")
  ufw default deny incoming || true
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw delete allow proto tcp from any to any port 5901 >/dev/null 2>&1 || true
  for ip in "${WHITELIST[@]}"; do [ -n "$ip" ] && ufw allow proto tcp from "$ip" to any port 5901 comment 'VNC whitelist'; done
  ufw --force enable || true
  log "VNC and firewall configured. Initial VNC password: ${DEFAULT_VNC_PASSWORD}"
}

# ==================== MAIN ====================

echo "=== rAthena + FluxCP + TightVNC Installer (Final) ==="
echo "Modes:"
echo " 1) Full Clean Install (Wipe)"
echo " 2) Resume / Fix (Continue)"
read -r choice
MODE=$([ "$choice" = "1" ] && echo wipe || echo resume)
log "Selected mode: $MODE"

if [ "$MODE" = "wipe" ]; then
  run_phase "Clean_Wipe" "phase_clean_wipe"
  rm -rf "$STATE_DIR" && mkdir -p "$STATE_DIR"
fi

PHASE_LIST=(
  "Update_and_Upgrade:phase_update_upgrade"
  "Install_Packages:phase_install_packages"
  "Create_Rathena_User:phase_create_user"
  "Configure_MariaDB:phase_configure_mariadb"
  "Add_Swap:phase_add_swap"
  "AutoConfig_ConfImport:phase_autoconfig_imports"
  "Clone_and_Build_rAthena:phase_clone_build_rathena"
  "Install_FluxCP:phase_install_fluxcp"
  "Setup_VNC_and_Firewall:phase_setup_vnc_and_firewall"
)

for p in "${PHASE_LIST[@]}"; do name="${p%%:*}"; func="${p#*:}"; run_phase "$name" "$func"; done

log "Installer finished (mode=$MODE)."
