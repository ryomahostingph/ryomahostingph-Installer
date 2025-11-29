#!/usr/bin/env bash
# rAthena + FluxCP + TightVNC Installer for Debian 12 (Final)
# - Clean (wipe) mode and Resume (phase) mode
# - Separate systemd units for master/login/map/char
# - TightVNC with whitelist and default password Ch4ng3me
# - Desktop shortcuts, ServerDetails.txt, conf/import auto-generation
# - Backups of existing /opt/rathena to /opt/rathena.backup/<ts>
#
# Run as root (sudo). Test on a staging VPS first.
set -o pipefail
set -e

### CONFIG - edit ONLY if you know what you do ###
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
FLUXCP_REPO="https://github.com/FluxCP/fluxcp.git"
WEBROOT="/var/www/fluxcp"
RATHENA_INSTALL_DIR="/opt/rathena"
DEFAULT_VNC_PASSWORD="Ch4ng3me"
DB_NAME="rathena"
DB_USER="rathena"
STATE_DIR="/opt/rathena_installer_state"
LOGFILE="/var/log/rathena_installer.log"
WHITELIST_ALWAYS=("120.28.137.77" "127.0.0.1")
BACKGROUND_IMAGE_PATH="${RATHENA_HOME}/background.png"
###############################################

# helpers
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
die(){ echo "FATAL: $*" | tee -a "$LOGFILE"; exit 1; }
if [ "$EUID" -ne 0 ]; then die "Please run as root (sudo)"; fi
mkdir -p "$(dirname "$LOGFILE")" "$STATE_DIR"
touch "$LOGFILE"; chmod 600 "$LOGFILE"

random_pass() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c8 || openssl rand -base64 6 | tr -dc 'A-Za-z0-9' | head -c8
}

detect_public_ip(){
  ip=""
  ip=$(curl -s ifconfig.me || true)
  [ -z "$ip" ] && ip=$(curl -s icanhazip.com || true)
  [ -z "$ip" ] && ip=$(curl -s ifconfig.co || true)
  echo "$ip"
}

# checkpoint utilities
phase_ok(){ [ -f "${STATE_DIR}/$1.ok" ]; }
phase_mark(){ touch "${STATE_DIR}/$1.ok"; log "PHASE OK: $1"; }

# interactive phase runner that respects resume mode
run_phase(){
  local name="$1"; shift; local func="$1"
  if [ "$MODE" = "resume" ] && phase_ok "$name"; then
    log "Skipping phase (already OK) $name"
    return 0
  fi
  log "PHASE START: $name"
  echo "==> Running: $name"
  set +e
  bash -c "$func"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    log "PHASE ERROR: $name (rc=$rc)"
    echo
    echo "Phase '$name' failed (exit $rc). Options:"
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

# =================================================
# PHASES
# =================================================

phase_clean_wipe(){
  echo "DESTRUCTIVE CLEAN WIPE - THIS REMOVES rAthena, FluxCP, DBs, VNC CONFIGS."
  echo "Type YES to proceed with a full clean wipe (or anything else to cancel):"
  read -r ans
  [ "$ans" = "YES" ] || { log "Clean wipe cancelled by user"; return 0; }
  systemctl stop rathena-*.service vncserver@:1.service apache2 mariadb 2>/dev/null || true
  systemctl disable rathena-*.service vncserver@:1.service 2>/dev/null || true
  # remove systemd units created by this installer (best-effort)
  rm -f /etc/systemd/system/rathena-*.service /etc/systemd/system/vncserver@.service /usr/local/bin/rathena_helpers/* /usr/local/bin/rathena_start_*.sh || true
  rm -rf "$RATHENA_INSTALL_DIR" "${RATHENA_INSTALL_DIR}.backup" "$WEBROOT" "$RATHENA_HOME/.vnc" "$RATHENA_HOME/Desktop" /root/rathena_db_creds /root/rathena_db_backups /var/log/rathena || true
  mysql -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
  mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
  # clear state so fresh run
  rm -rf "$STATE_DIR" || true
  mkdir -p "$STATE_DIR"
  log "Clean wipe completed (best-effort)."
}

phase_update_upgrade(){
  apt update -y && apt upgrade -y
}

phase_install_packages(){
  DEBIAN_FRONTEND=noninteractive apt install -y \
    build-essential git cmake autoconf libssl-dev libmysqlclient-dev libpcre3-dev \
    zlib1g-dev libxml2-dev wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring \
    mariadb-server xfce4 xfce4-goodies dbus-x11 xauth xorg tightvncserver ufw
}

phase_create_user(){
  if id -u "$RATHENA_USER" >/dev/null 2>&1; then
    log "User $RATHENA_USER exists"
  else
    useradd -m -s /bin/bash "$RATHENA_USER"
    log "Created user $RATHENA_USER"
  fi
  mkdir -p "$RATHENA_HOME/Desktop"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"
}

phase_configure_mariadb(){
  systemctl enable --now mariadb
  # create DB and user with random password
  DB_PASS="$(random_pass)"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
  cat >/root/rathena_db_creds <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
  chmod 600 /root/rathena_db_creds
  log "DB created and credentials stored in /root/rathena_db_creds"
  echo "DB credentials: ${DB_USER} / ${DB_PASS}"
}

phase_clone_build_rathena(){
  # backup existing
  if [ -d "$RATHENA_INSTALL_DIR" ]; then
    ts=$(date +%F_%H%M%S)
    mkdir -p "${RATHENA_INSTALL_DIR}.backup/${ts}"
    cp -a "$RATHENA_INSTALL_DIR" "${RATHENA_INSTALL_DIR}.backup/${ts}/" || log "Backup copy warning"
    log "Existing rathena backed up to ${RATHENA_INSTALL_DIR}.backup/${ts}/"
  fi

  # remove and reclone
  rm -rf "$RATHENA_INSTALL_DIR"
  mkdir -p "$RATHENA_INSTALL_DIR"
  chown "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR"
  sudo -u "$RATHENA_USER" git clone --depth=1 "$RATHENA_REPO" "$RATHENA_INSTALL_DIR" || die "git clone rathena failed"

  # typical build
  pushd "$RATHENA_INSTALL_DIR" >/dev/null
  sudo -u "$RATHENA_USER" cmake -DCMAKE_BUILD_TYPE=Release . || log "cmake may have warnings"
  sudo -u "$RATHENA_USER" make -j"$(nproc)" || log "make may have warnings"
  popd >/dev/null

  # create a safe start script if none exists
  if [ ! -f "${RATHENA_INSTALL_DIR}/start-server.sh" ]; then
    cat >"${RATHENA_INSTALL_DIR}/start-server.sh" <<'SS'
#!/bin/bash
BASEDIR="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="/var/log/rathena"
mkdir -p "$LOGDIR" "/var/run/rathena"
cd "$BASEDIR"
for bin in master-server login-server char-server map-server; do
  if [ -x "./$bin" ]; then
    nohup "./$bin" >>"${LOGDIR}/${bin}.log" 2>&1 &
    echo $! > /var/run/rathena/${bin}.pid
    sleep 1
  fi
done
SS
    chmod +x "${RATHENA_INSTALL_DIR}/start-server.sh"
  fi
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_INSTALL_DIR"
  log "rAthena cloned & built at $RATHENA_INSTALL_DIR"
}

phase_install_fluxcp(){
  # backup and reinstall fluxcp
  if [ -d "$WEBROOT" ]; then
    ts=$(date +%F_%H%M%S)
    mkdir -p "${WEBROOT}.backup/${ts}"
    cp -a "$WEBROOT" "${WEBROOT}.backup/${ts}/" || true
    log "FluxCP backed up to ${WEBROOT}.backup/${ts}"
  fi
  rm -rf "$WEBROOT"
  mkdir -p "$WEBROOT"
  git clone --depth=1 "$FLUXCP_REPO" "$WEBROOT" || die "fluxcp clone failed"
  chown -R www-data:www-data "$WEBROOT"
  cat >/etc/apache2/sites-available/fluxcp.conf <<EOF
<VirtualHost *:80>
    ServerAdmin admin@localhost
    DocumentRoot ${WEBROOT}/public
    <Directory ${WEBROOT}/public>
        Require all granted
        AllowOverride All
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/fluxcp_error.log
    CustomLog \${APACHE_LOG_DIR}/fluxcp_access.log combined
</VirtualHost>
EOF
  a2ensite fluxcp.conf || true
  a2enmod rewrite || true
  systemctl reload apache2 || true
  log "FluxCP installed to $WEBROOT"
}

phase_setup_vnc_and_firewall(){
  # set VNC password for rathena user
  sudo -u "$RATHENA_USER" bash -c "mkdir -p ${RATHENA_HOME}/.vnc && echo -e \"${DEFAULT_VNC_PASSWORD}\n${DEFAULT_VNC_PASSWORD}\n\" | vncpasswd >/dev/null 2>&1"
  cat >"${RATHENA_HOME}/.vnc/xstartup" <<'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4 &
XSTARTUP
  chown -R "$RATHENA_USER":"$RATHENA_USER" "${RATHENA_HOME}/.vnc"
  chmod +x "${RATHENA_HOME}/.vnc/xstartup"

  # vncserver systemd template
  cat >/etc/systemd/system/vncserver@.service <<'UNIT'
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
UNIT

  systemctl daemon-reload
  systemctl enable --now vncserver@1.service || log "vnc enable warning"

  # UFW whitelist: deployer IP + fixed IPs
  DEPLOYER_IP=$(detect_public_ip)
  WHITELIST=("${WHITELIST_ALWAYS[@]}")
  [ -n "$DEPLOYER_IP" ] && WHITELIST+=("$DEPLOYER_IP")
  log "VNC whitelist: ${WHITELIST[*]}"

  ufw default deny incoming || true
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  # remove broad 5901 rule if exists
  ufw delete allow proto tcp from any to any port 5901 >/dev/null 2>&1 || true
  for ip in "${WHITELIST[@]}"; do
    [ -n "$ip" ] && ufw allow proto tcp from "$ip" to any port 5901 comment 'VNC whitelist'
  done
  ufw --force enable || true

  log "VNC and firewall configured. Initial VNC password: ${DEFAULT_VNC_PASSWORD}"
}

phase_create_systemd_units(){
  mkdir -p /var/log/rathena /var/run/rathena
  chown "$RATHENA_USER":"$RATHENA_USER" /var/log/rathena /var/run/rathena

  # create units for master/login/map/char; if binary missing, create wrapper that will fail gracefully
  create_unit(){
    local role="$1"; local bin="$2"
    local unit="/etc/systemd/system/rathena-${role}.service"
    cat >"$unit" <<EOF
[Unit]
Description=rAthena ${role^} Server
After=network.target mariadb.service

[Service]
Type=simple
User=${RATHENA_USER}
WorkingDirectory=${RATHENA_INSTALL_DIR}
ExecStart=${RATHENA_INSTALL_DIR}/${bin}
Restart=on-failure
RestartSec=5s
StandardOutput=append:/var/log/rathena/${bin}.log
StandardError=append:/var/log/rathena/${bin}.err

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unit"
    systemctl daemon-reload
    systemctl enable "rathena-${role}.service" || true
    log "Created and enabled rathena-${role}.service -> ${bin}"
  }

  for pair in "master:master-server" "login:login-server" "map:map-server" "char:char-server"; do
    role="${pair%%:*}"; bin="${pair#*:}"
    if [ -x "${RATHENA_INSTALL_DIR}/${bin}" ]; then
      create_unit "$role" "$bin"
    else
      # create simple wrapper script that tries to exec the binary (will fail if missing)
      wrapper="/usr/local/bin/rathena_start_${role}.sh"
      cat >"$wrapper" <<WRAP
#!/bin/bash
cd ${RATHENA_INSTALL_DIR} || exit 1
LOGDIR="/var/log/rathena"
mkdir -p "\$LOGDIR"
if [ -x "./${bin}" ]; then
  exec "./${bin}" >>"\$LOGDIR/${bin}.log" 2>&1
else
  echo "${bin} not found in ${RATHENA_INSTALL_DIR}" >&2
  exit 1
fi
WRAP
      chmod +x "$wrapper"
      chown "$RATHENA_USER":"$RATHENA_USER" "$wrapper"
      cat >/etc/systemd/system/rathena-${role}.service <<EOF
[Unit]
Description=rAthena ${role^} Server (wrapper)
After=network.target mariadb.service

[Service]
Type=simple
User=${RATHENA_USER}
WorkingDirectory=${RATHENA_INSTALL_DIR}
ExecStart=${wrapper}
Restart=on-failure
RestartSec=5s
StandardOutput=append:/var/log/rathena/${role}.log
StandardError=append:/var/log/rathena/${role}.err

[Install]
WantedBy=multi-user.target
EOF
      chmod 644 /etc/systemd/system/rathena-${role}.service
      systemctl daemon-reload
      systemctl enable "rathena-${role}.service" || true
      log "Created wrapper unit rathena-${role}.service (executes ${bin} if present)"
    fi
  done
}

phase_create_helpers_and_desktop(){
  mkdir -p /usr/local/bin/rathena_helpers
  chown root:root /usr/local/bin/rathena_helpers
  chmod 755 /usr/local/bin/rathena_helpers

  # start/stop/restart
  cat >/usr/local/bin/rathena_helpers/start_all.sh <<'STARTALL'
#!/bin/bash
systemctl start rathena-master.service || true
systemctl start rathena-login.service || true
systemctl start rathena-map.service || true
systemctl start rathena-char.service || true
systemctl start vncserver@1.service || true
echo "Started rAthena services and VNC"
STARTALL
  chmod +x /usr/local/bin/rathena_helpers/start_all.sh

  cat >/usr/local/bin/rathena_helpers/stop_all.sh <<'STOPALL'
#!/bin/bash
systemctl stop vncserver@1.service || true
systemctl stop rathena-char.service || true
systemctl stop rathena-map.service || true
systemctl stop rathena-login.service || true
systemctl stop rathena-master.service || true
echo "Stopped rAthena services and VNC"
STOPALL
  chmod +x /usr/local/bin/rathena_helpers/stop_all.sh

  cat >/usr/local/bin/rathena_helpers/restart_all.sh <<'RESTARTALL'
#!/bin/bash
systemctl restart rathena-master.service rathena-login.service rathena-map.service rathena-char.service || true
systemctl restart vncserver@1.service || true
echo "Restarted rAthena services and VNC"
RESTARTALL
  chmod +x /usr/local/bin/rathena_helpers/restart_all.sh

  # recompile
  cat >/usr/local/bin/rathena_helpers/recompile.sh <<'RECOMPILE'
#!/bin/bash
cd /opt/rathena || exit 1
sudo -u rathena cmake -DCMAKE_BUILD_TYPE=Release . || exit 1
sudo -u rathena make -j$(nproc) || exit 1
echo "Recompile finished."
RECOMPILE
  chmod +x /usr/local/bin/rathena_helpers/recompile.sh

  # change vnc password
  cat >/usr/local/bin/rathena_helpers/change_vnc_pass.sh <<'VNCCHG'
#!/bin/bash
sudo -u rathena bash -c 'mkdir -p ~/.vnc && vncpasswd'
echo "VNC password changed for user rathena"
VNCCHG
  chmod +x /usr/local/bin/rathena_helpers/change_vnc_pass.sh

  # backup DB
  cat >/usr/local/bin/rathena_helpers/backup_db.sh <<'BACKDB'
#!/bin/bash
DEST="/root/rathena_db_backups"
mkdir -p "$DEST"
TS=$(date +%F_%H%M%S)
source /root/rathena_db_creds
mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "${DEST}/${DB_NAME}_${TS}.sql"
echo "Backup saved to ${DEST}/${DB_NAME}_${TS}.sql"
BACKDB
  chmod +x /usr/local/bin/rathena_helpers/backup_db.sh

  # open folders
  cat >/usr/local/bin/rathena_helpers/open_rathena_folder.sh <<'OPENR'
#!/bin/bash
xdg-open /opt/rathena || xdg-open /opt/rathena .
OPENR
  chmod +x /usr/local/bin/rathena_helpers/open_rathena_folder.sh

  cat >/usr/local/bin/rathena_helpers/open_fluxcp_folder.sh <<'OPENF'
#!/bin/bash
xdg-open /var/www/fluxcp || xdg-open /var/www/fluxcp .
OPENF
  chmod +x /usr/local/bin/rathena_helpers/open_fluxcp_folder.sh

  # re-download rathena: backup then clone
  cat >/usr/local/bin/rathena_helpers/redownload_rathena.sh <<'REDOWN'
#!/bin/bash
TS=$(date +%F_%H%M%S)
BACK="/opt/rathena.backup/${TS}"
mkdir -p "$BACK"
if [ -d /opt/rathena ]; then
  cp -a /opt/rathena "$BACK" || true
  echo "Backup copied to $BACK"
fi
rm -rf /opt/rathena
sudo -u rathena git clone --depth=1 "${RATHENA_REPO:-https://github.com/rathena/rathena.git}" /opt/rathena || { echo "git clone failed"; exit 1; }
cd /opt/rathena || exit 1
sudo -u rathena cmake -DCMAKE_BUILD_TYPE=Release . || echo "cmake nonfatal"
sudo -u rathena make -j$(nproc) || echo "make nonfatal"
echo "rAthena re-downloaded to /opt/rathena; previous backup at $BACK"
REDOWN
  chmod +x /usr/local/bin/rathena_helpers/redownload_rathena.sh

  # create .desktop files in user's Desktop
  desktop_create(){
    local script="$1"; local label="$2"; local icon="$3"; local terminal="$4"
    local ds="${RATHENA_HOME}/Desktop/$(echo "$label" | tr ' ' '_').desktop"
    cat >"$ds" <<DESK
[Desktop Entry]
Type=Application
Name=$label
Exec=bash -lc "$script"
Icon=$icon
Terminal=$terminal
StartupNotify=true
DESK
    chmod +x "$ds"
    chown "$RATHENA_USER":"$RATHENA_USER" "$ds"
    log "Created desktop shortcut: $ds"
  }

  desktop_create "/usr/local/bin/rathena_helpers/start_all.sh" "Start rAthena" "system-run" "true"
  desktop_create "/usr/local/bin/rathena_helpers/stop_all.sh" "Stop rAthena" "process-stop" "true"
  desktop_create "/usr/local/bin/rathena_helpers/restart_all.sh" "Restart rAthena" "view-refresh" "true"
  desktop_create "/usr/local/bin/rathena_helpers/recompile.sh" "Recompile rAthena" "tools" "true"
  desktop_create "/usr/local/bin/rathena_helpers/change_vnc_pass.sh" "Change VNC Password" "security-high" "true"
  desktop_create "/usr/local/bin/rathena_helpers/backup_db.sh" "Backup rAthena DB" "document-save" "true"
  desktop_create "/usr/local/bin/rathena_helpers/open_rathena_folder.sh" "Open rAthena Folder" "folder" "false"
  desktop_create "/usr/local/bin/rathena_helpers/open_fluxcp_folder.sh" "Open FluxCP Folder" "folder" "false"
  desktop_create "/usr/local/bin/rathena_helpers/redownload_rathena.sh" "Re-download rAthena (backup first)" "system-software-update" "true"

  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop"
  log "Helpers and desktop entries created"
}

phase_set_wallpaper(){
  # create placeholder if missing
  if [ ! -f "$BACKGROUND_IMAGE_PATH" ]; then
    # create a tiny placeholder file
    printf '\x89PNG\r\n\x1a\n' > "$BACKGROUND_IMAGE_PATH"
    chown "$RATHENA_USER":"$RATHENA_USER" "$BACKGROUND_IMAGE_PATH"
  fi

  if command -v xfconf-query >/dev/null 2>&1; then
    # set for each output
    sudo -u "$RATHENA_USER" xfconf-query -c xfce4-desktop -l 2>/dev/null | while read -r prop; do
      sudo -u "$RATHENA_USER" xfconf-query -c xfce4-desktop -p "$prop" -s "$BACKGROUND_IMAGE_PATH" >/dev/null 2>&1 || true
    done
    log "Attempted to set XFCE wallpaper to $BACKGROUND_IMAGE_PATH"
  else
    log "xfconf-query not present; wallpaper not set automatically"
  fi
}

phase_autoconfig_imports(){
  # write safe conf/import files to avoid editing default conf/
  mkdir -p "${RATHENA_INSTALL_DIR}/conf/import"
  source /root/rathena_db_creds || die "DB creds missing at /root/rathena_db_creds (run DB phase first)"
  VPS_IP="$(detect_public_ip)"
  # inter_server.conf (sample)
  cat >"${RATHENA_INSTALL_DIR}/conf/import/inter_server.conf" <<EOF
inter_server_password: "$(random_pass)"
login_ip: "${VPS_IP:-127.0.0.1}"
char_ip: "${VPS_IP:-127.0.0.1}"
map_ip: "${VPS_IP:-127.0.0.1}"
EOF

  # sql_connection.conf
  cat >"${RATHENA_INSTALL_DIR}/conf/import/sql_connection.conf" <<EOF
db_hostname: "localhost"
db_port: 3306
db_username: "${DB_USER}"
db_password: "${DB_PASS}"
db_database: "${DB_NAME}"
EOF

  # login / char / map (examples) - adjust keys as needed for your rAthena build
  cat >"${RATHENA_INSTALL_DIR}/conf/import/login_athena.conf" <<EOF
login_ip: "${VPS_IP:-127.0.0.1}"
userid: "${DB_USER}"
passwd: "${DB_PASS}"
EOF

  cat >"${RATHENA_INSTALL_DIR}/conf/import/char_athena.conf" <<EOF
userid: "${DB_USER}"
passwd: "${DB_PASS}"
char_ip: "${VPS_IP:-127.0.0.1}"
EOF

  cat >"${RATHENA_INSTALL_DIR}/conf/import/map_athena.conf" <<EOF
userid: "${DB_USER}"
passwd: "${DB_PASS}"
map_ip: "${VPS_IP:-127.0.0.1}"
EOF

  # subnet_athena.conf - conservative
  cat >"${RATHENA_INSTALL_DIR}/conf/import/subnet_athena.conf" <<EOF
subnet: 255.0.0.0:127.0.0.1:127.0.0.1
subnet: 255.255.255.0:${VPS_IP:-127.0.0.1}:${VPS_IP:-127.0.0.1}
EOF

  # optional log db
  cat >"${RATHENA_INSTALL_DIR}/conf/import/log_db.conf" <<EOF
log_db_hostname: "localhost"
log_db_port: 3306
log_db_username: "${DB_USER}"
log_db_password: "${DB_PASS}"
log_db_database: "${DB_NAME}_logs"
EOF

  chown -R "$RATHENA_USER":"$RATHENA_USER" "${RATHENA_INSTALL_DIR}/conf/import"
  log "Wrote conf/import templates under ${RATHENA_INSTALL_DIR}/conf/import"
}

phase_write_server_details(){
  source /root/rathena_db_creds || die "Missing DB creds"
  VPS_IP="$(detect_public_ip)"

  cat >"${RATHENA_HOME}/Desktop/ServerDetails.txt" <<EOF
rAthena Installer - Server Details
=================================
Date: $(date)
rAthena Path: ${RATHENA_INSTALL_DIR}
FluxCP Path: ${WEBROOT}
Services:
  rathena-master.service
  rathena-login.service
  rathena-map.service
  rathena-char.service
  vncserver@1.service

Database:
  DB_NAME: ${DB_NAME}
  DB_USER: ${DB_USER}
  DB_PASS: ${DB_PASS}
  Credentials file: /root/rathena_db_creds

VNC:
  Initial VNC password (user ${RATHENA_USER}): ${DEFAULT_VNC_PASSWORD}
  VNC service: vncserver@1.service

Network:
  VPS public IP (detected): ${VPS_IP:-<not-detected>}
  VNC whitelist includes deployer IP (if detected) and: ${WHITELIST_ALWAYS[*]}

Notes:
  - rAthena conf import files: ${RATHENA_INSTALL_DIR}/conf/import
  - rAthena backups: ${RATHENA_INSTALL_DIR}.backup
  - Desktop shortcuts: /home/${RATHENA_USER}/Desktop
EOF
  chown "$RATHENA_USER":"$RATHENA_USER" "${RATHENA_HOME}/Desktop/ServerDetails.txt"
  chmod 600 "${RATHENA_HOME}/Desktop/ServerDetails.txt"
  log "Wrote ServerDetails.txt to ${RATHENA_HOME}/Desktop/ServerDetails.txt"
}

# =================================================
# Installer menu & execution flow
# =================================================

echo "=== rAthena + FluxCP + TightVNC Installer (Final) ==="
echo "Modes:"
echo " 1) Full Clean Install (Wipe) - recommended for production"
echo " 2) Resume / Fix (Continue) - picks up where it left off using checkpoints"
echo "Choose mode (1 or 2) and press Enter:"
read -r choice
if [ "$choice" = "1" ]; then MODE="wipe"; else MODE="resume"; fi
log "Selected mode: $MODE"

if [ "$MODE" = "wipe" ]; then
  run_phase "Clean_Wipe" "phase_clean_wipe"
  # ensure fresh state dir
  rm -rf "$STATE_DIR" || true; mkdir -p "$STATE_DIR"
fi

# list of phases in desired order
PHASE_LIST=(
  "Update_and_Upgrade:phase_update_upgrade"
  "Install_Packages:phase_install_packages"
  "Create_Rathena_User:phase_create_user"
  "Configure_MariaDB:phase_configure_mariadb"
  "Clone_and_Build_rAthena:phase_clone_build_rathena"
  "Install_FluxCP:phase_install_fluxcp"
  "Setup_VNC_and_Firewall:phase_setup_vnc_and_firewall"
  "Create_Systemd_Units:phase_create_systemd_units"
  "Create_Helpers_and_Desktop:phase_create_helpers_and_desktop"
  "Set_Wallpaper:phase_set_wallpaper"
  "AutoConfig_ConfImport:phase_autoconfig_imports"
  "Write_ServerDetails:phase_write_server_details"
)

for p in "${PHASE_LIST[@]}"; do
  name="${p%%:*}"; func="${p#*:}"
  run_phase "$name" "$func"
done

echo "Installation complete. Summary:"
echo " - rAthena path: $RATHENA_INSTALL_DIR"
echo " - FluxCP path: $WEBROOT"
echo " - Desktop shortcuts: ${RATHENA_HOME}/Desktop"
echo " - Server details: ${RATHENA_HOME}/Desktop/ServerDetails.txt"
echo " - Logs: $LOGFILE"
echo
echo "Use systemctl to manage services, for example:"
echo "  systemctl status rathena-master.service"
echo "  systemctl start rathena-master.service"
echo "  systemctl restart rathena-master.service"
echo
echo "If installer stopped on an error, fix the issue and re-run the script in Resume mode (choose option 2)."
log "Installer finished (mode=$MODE)."
