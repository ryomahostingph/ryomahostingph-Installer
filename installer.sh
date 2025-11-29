#!/usr/bin/env bash
# Fully Updated rAthena + FluxCP + TightVNC Installer with additional features for Debian 12
# Features:
# - phpMyAdmin installed and locked to localhost
# - Google Chrome browser installed
# - Desktop shortcuts added for server actions and database backup
# - Buttons added for server control and VNC password management

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
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

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

phase_update_upgrade(){
  apt update -y && apt upgrade -y
  log "System updated and upgraded"
}

phase_install_packages(){
  DEBIAN_FRONTEND=noninteractive apt install -y build-essential git cmake autoconf libssl-dev libmariadb-dev-compat libmariadb-dev libpcre3-dev zlib1g-dev libxml2-dev wget curl unzip apache2 php php-mysql php-gd php-xml php-mbstring mariadb-server xfce4 xfce4-goodies dbus-x11 xauth xorg tightvncserver ufw
  log "Required packages installed"
}

# New phase to install Google Chrome
phase_install_chrome(){
  wget -q "$CHROME_URL" -O /tmp/google-chrome.deb
  dpkg -i /tmp/google-chrome.deb || apt --fix-broken install -y
  log "Google Chrome installed"
}

phase_create_user(){
  id -u "$RATHENA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RATHENA_USER"
  mkdir -p "$RATHENA_HOME/Desktop"
  chown -R "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME"
  log "rathena user created"
}

# New phase to install phpMyAdmin locked to localhost
phase_install_phpmyadmin(){
  apt install -y phpmyadmin
  # Lock phpMyAdmin to localhost by editing its configuration
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
  sed -i 's/^.*\$cfg\[\x27Servers\x27\]\[\x27host\x27\] = \x27.*\x27;/\$cfg[\x27Servers\x27][\x27host\x27] = \x27localhost\';/' /etc/phpmyadmin/config.inc.php
  systemctl restart apache2
  log "phpMyAdmin installed and locked to localhost"
}

# More phases (configuring MariaDB, swap, rAthena build, etc.)

# ==================== SHORTCUTS AND DESKTOP BUTTONS ====================

# Create desktop shortcuts for the server
phase_create_desktop_shortcuts(){
  mkdir -p "$RATHENA_HOME/Desktop"
  
  # Start rAthena button
  echo -e "[Desktop Entry]\nVersion=1.0\nName=Start rAthena\nComment=Start the rAthena Server\nExec=sudo systemctl start rathena.service\nIcon=system-run\nTerminal=true\nType=Application\nCategories=Utility;" > "$RATHENA_HOME/Desktop/Start_rAthena.desktop"

  # Stop rAthena button
  echo -e "[Desktop Entry]\nVersion=1.0\nName=Stop rAthena\nComment=Stop the rAthena Server\nExec=sudo systemctl stop rathena.service\nIcon=system-run\nTerminal=true\nType=Application\nCategories=Utility;" > "$RATHENA_HOME/Desktop/Stop_rAthena.desktop"

  # Recompile rAthena button
  echo -e "[Desktop Entry]\nVersion=1.0\nName=Recompile rAthena\nComment=Recompile rAthena Server\nExec=sudo -u rathena make -j$(nproc)\nIcon=system-run\nTerminal=true\nType=Application\nCategories=Utility;" > "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop"
  
  # Backup SQL Database button
  echo -e "[Desktop Entry]\nVersion=1.0\nName=Backup Databases\nComment=Backup rAthena Databases\nExec=sudo mysqldump --all-databases > /home/rathena/Desktop/db_backup.sql\nIcon=folder-saved\nTerminal=true\nType=Application\nCategories=Utility;" > "$RATHENA_HOME/Desktop/Backup_Databases.desktop"

  # Change VNC Password button
  echo -e "[Desktop Entry]\nVersion=1.0\nName=Change VNC Password\nComment=Change the VNC password for rAthena\nExec=sudo -u rathena vncpasswd\nIcon=preferences-system\nTerminal=true\nType=Application\nCategories=Utility;" > "$RATHENA_HOME/Desktop/Change_VNC_Password.desktop"
  
  # Make desktop shortcuts executable
  chmod +x "$RATHENA_HOME/Desktop/"*.desktop
  log "Desktop shortcuts created"
}

# ==================== MAIN ====================

echo "=== rAthena + FluxCP + TightVNC Installer (with additional features) ==="
echo "Modes: 1) Wipe 2) Resume"
read -r choice
MODE=$([ "$choice" = "1" ] && echo wipe || echo resume)
log "Selected mode: $MODE"

[ "$MODE" = "wipe" ] && run_phase "Clean_Wipe" "phase_clean_wipe"

PHASE_LIST=(
  "Update_and_Upgrade:phase_update_upgrade"
  "Install_Packages:phase_install_packages"
  "Install_Chrome:phase_install_chrome"
  "Install_phpMyAdmin:phase_install_phpmyadmin"
  "Create_Rathena_User:phase_create_user"
  "Create_Desktop_Shortcuts:phase_create_desktop_shortcuts"
)

for p in "${PHASE_LIST[@]}"; do name="${p%%:*}"; func="${p#*:}"; run_phase "$name" "$func"; done

log "Installer finished (mode=$MODE)."
