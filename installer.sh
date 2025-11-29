#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/rathena_installer.log"
RATHENA_USER="rathena"
RATHENA_HOME="/home/${RATHENA_USER}"
RATHENA_REPO="https://github.com/rathena/rathena.git"
RATHENA_INSTALL_DIR="${RATHENA_HOME}/Desktop/rathena"
WEBROOT="/var/www/html"
STATE_DIR="/opt/rathena_installer_state"
DEFAULT_VNC_PASSWORD="Ch4ng3me"   # default VNC password
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
# Phase 1: System Update and Cleanup
# -------------------------
phase_update_upgrade(){
  log "Updating system..."
  apt update -y && apt upgrade -y
  log "System updated."
}

# -------------------------
# Install Essential Packages (Minimal)
# -------------------------
phase_install_packages_minimal(){
  log "Installing essential packages..."
  apt install -y \
    build-essential \
    git \
    cmake \
    autoconf \
    libssl-dev \
    libmariadb-dev-compat \
    libmariadb-dev \
    libpcre3-dev \
    zlib1g-dev \
    libxml2-dev \
    wget \
    curl \
    unzip \
    apache2 \
    php \
    php-mysql \
    php-gd \
    php-xml \
    php-mbstring \
    mariadb-server \
    dbus-x11 \
    xauth \
    xorg \
    ufw \
    tightvncserver \
    xfce4 \
    xfce4-goodies \
    x11-xserver-utils
  log "Essential packages installed."
}

# -------------------------
# Create rAthena User
# -------------------------
phase_create_rathena_user(){
  log "Creating user: $RATHENA_USER..."
  if ! id "$RATHENA_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RATHENA_USER"
    echo "$RATHENA_USER:$DB_PASS" | chpasswd
    log "User '$RATHENA_USER' created."
  else
    log "User '$RATHENA_USER' already exists."
  fi
}

# -------------------------
# Clone rAthena and FluxCP Repositories
# -------------------------
phase_clone_rathena(){
  log "Cloning rAthena into $RATHENA_INSTALL_DIR..."
  git clone "$RATHENA_REPO" "$RATHENA_INSTALL_DIR"
  log "rAthena cloned."
}

phase_clone_fluxcp(){
  log "Cloning FluxCP into $WEBROOT..."
  git clone https://github.com/rathena/FluxCP.git "$WEBROOT"
  log "FluxCP installed."
}

# -------------------------
# Compile rAthena (Optional)
# -------------------------
phase_compile_rathena(){
  log "Compiling rAthena..."
  cd "$RATHENA_INSTALL_DIR"
  if [ ! -f "Makefile" ]; then
    log "Makefile not found, skipping compile."
  else
    make clean
    make -j"$(nproc)"
    log "rAthena compiled."
  fi
}

# -------------------------
# Install phpMyAdmin
# -------------------------
phase_install_phpmyadmin(){
  log "Installing phpMyAdmin..."
  apt install -y phpmyadmin
  log "phpMyAdmin installed."
}

# -------------------------
# Install Google Chrome
# -------------------------
phase_install_chrome(){
  log "Installing Google Chrome..."
  wget -q "$CHROME_URL" -O /tmp/google-chrome.deb
  dpkg -i /tmp/google-chrome.deb
  apt --fix-broken install -y
  log "Google Chrome installed."
}

# -------------------------
# Install TightVNC and XFCE
# -------------------------
install_tightvnc(){
  log "Installing TightVNC and XFCE..."
  apt install -y tightvncserver xfce4 xfce4-goodies dbus-x11
  log "TightVNC and XFCE installed."
}

# -------------------------
# Create Desktop Shortcuts
# -------------------------
phase_create_shortcuts(){
  log "Creating desktop shortcuts..."
  mkdir -p "$RATHENA_HOME/Desktop"
  chown "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop"

  # Create shortcuts for rAthena actions
  cat > "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Recompile rAthena
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && make -j\$(nproc) || true"
Terminal=true
Type=Application
EOF

  cat > "$RATHENA_HOME/Desktop/Start_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Start rAthena Servers
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && ./start_rathena.sh"
Terminal=true
Type=Application
EOF

  cat > "$RATHENA_HOME/Desktop/Change_VNC_Password.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Change VNC Password
Exec=sudo -u ${RATHENA_USER} bash -lc "vncpasswd <<< '${DEFAULT_VNC_PASSWORD}'"
Terminal=true
Type=Application
EOF

  cat > "$RATHENA_HOME/Desktop/Backup_rAthena_DB.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Backup rAthena Database
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && ./backup_db.sh"
Terminal=true
Type=Application
EOF

  chmod +x "$RATHENA_HOME/Desktop"/*.desktop
  log "Desktop shortcuts created."
}

# -------------------------
# VNC Fixer (Set Password, etc.)
# -------------------------
run_vnc_fixer(){
  log "Running VNC Fixer..."
  if [ ! -f "$VNC_FIXER" ]; then
    log "VNC Fixer script ($VNC_FIXER) not found. Skipping."
    return
  fi
  bash "$VNC_FIXER"
  log "VNC Fixer executed."
}

# -------------------------
# Phase 4: Setup Services (Optional)
# -------------------------
phase_setup_rathena_services(){
  log "Setting up rAthena as a service..."
  # Optional: Create systemd service files here, if desired.
}

# -------------------------
# Clean All
# -------------------------
phase_clean_all(){
  log "Cleaning previous installations..."
  rm -rf "$RATHENA_HOME/Desktop/rathena"
  rm -rf "$WEBROOT"
  rm -f /etc/systemd/system/vncserver@1.service
  userdel -r "$RATHENA_USER" || true
  log "Cleanup completed."
}

# -------------------------
# Main Menu
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
        phase_clone_rathena
        phase_clone_fluxcp
        phase_compile_rathena
        phase_compile_rathena
        phase_install_phpmyadmin
        phase_install_chrome
        install_tightvnc
        phase_create_shortcuts
        run_vnc_fixer
        phase_setup_rathena_services
        log "rAthena + FluxCP installation complete."
        ;;
      3)
        log "Selected: Install TightVNC + XFCE"
        install_tightvnc
        phase_create_shortcuts
        run_vnc_fixer
        log "TightVNC and XFCE installation complete."
        ;;
      4)
        log "Selected: Run VNC Fixer"
        run_vnc_fixer
        log "VNC Fixer completed."
        ;;
      5)
        log "Selected: Setup rAthena Services for Auto Start"
        phase_setup_rathena_services
        log "rAthena services setup completed."
        ;;
      6)
        log "Exiting..."
        exit 0
        ;;
      *)
        log "Invalid option. Please choose a valid option."
        ;;
    esac
  done
}

# Start the menu
main_menu
