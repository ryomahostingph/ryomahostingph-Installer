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
# Phase 1: System Update and Cleanup
# -------------------------
phase_update_upgrade(){
  log "Updating system..."
  apt update -y && apt upgrade -y
  log "System updated."
}

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
# Phase 10: Create Desktop Shortcuts
# -------------------------
phase_create_shortcuts(){
  log "Creating desktop shortcuts..."

  # Ensure the desktop directory exists
  mkdir -p "$RATHENA_HOME/Desktop"
  chown "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop"

  # Recompile rAthena shortcut
  cat > "$RATHENA_HOME/Desktop/Recompile_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Recompile rAthena
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && make -j\$(nproc) || true"
Terminal=true
Type=Application
EOF

  # Start rAthena Servers
  cat > "$RATHENA_HOME/Desktop/Start_rAthena.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Start rAthena Servers
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && ./start_rathena.sh"
Terminal=true
Type=Application
EOF

  # VNC Password Changer
  cat > "$RATHENA_HOME/Desktop/VNC_Password_Changer.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Change VNC Password
Exec=sudo -u ${RATHENA_USER} bash -lc "vncpasswd <<< '${DEFAULT_VNC_PASSWORD}'"
Terminal=true
Type=Application
EOF

  # Backup rAthena Database
  cat > "$RATHENA_HOME/Desktop/Backup_rAthena_DB.desktop" <<EOF
[Desktop Entry]
Version=1.0
Name=Backup rAthena Database
Exec=sudo -u ${RATHENA_USER} bash -lc "cd ${RATHENA_INSTALL_DIR} && ./backup_db.sh"
Terminal=true
Type=Application
EOF

  # Ensure the desktop files are created properly
  log "Desktop shortcuts created at $RATHENA_HOME/Desktop."
  ls -l "$RATHENA_HOME/Desktop/"

  # Apply execute permissions
  chmod +x "$RATHENA_HOME/Desktop"/*.desktop
  chown "$RATHENA_USER":"$RATHENA_USER" "$RATHENA_HOME/Desktop"/*.desktop
  log "Execute permissions set for desktop shortcuts."
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
