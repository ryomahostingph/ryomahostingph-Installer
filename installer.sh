#!/usr/bin/env bash
# rAthena + FluxCP + TightVNC Installer for Debian 12 (Final)
# ... [same header as before] ...

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

# =================================================
# Fixed run_phase
# =================================================
run_phase(){
  local name="$1"; shift; local func="$1"
  if [ "$MODE" = "resume" ] && phase_ok "$name"; then
    log "Skipping phase (already OK) $name"
    return 0
  fi
  log "PHASE START: $name"
  echo "==> Running: $name"
  set +e
  if declare -f "$func" >/dev/null 2>&1; then
      "$func"
      rc=$?
  else
      log "Function $func not found"
      rc=127
  fi
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
phase_clean_wipe(){ ... }         # same as your script
phase_update_upgrade(){ ... }      # same as your script
phase_install_packages(){ ... }    # same as your script
phase_create_user(){ ... }         # same as your script
phase_configure_mariadb(){ ... }   # same as your script
phase_clone_build_rathena(){ ... } # same as your script
phase_install_fluxcp(){ ... }      # same as your script
phase_setup_vnc_and_firewall(){ ... } # same as your script
phase_create_systemd_units(){ ... }   # same as your script
phase_create_helpers_and_desktop(){ ... } # same as your script
phase_set_wallpaper(){ ... }       # same as your script
phase_autoconfig_imports(){ ... }  # same as your script
phase_write_server_details(){ ... }# same as your script

# =================================================
# Installer menu & execution flow
# =================================================
echo "=== rAthena + FluxCP + TightVNC Installer (Final) ==="
echo "Modes:"
echo " 1) Full Clean Install (Wipe) - recommended for production"
echo " 2) Resume / Fix (Continue) - picks up where it left off using checkpoints"
read -r choice
if [ "$choice" = "1" ]; then MODE="wipe"; else MODE="resume"; fi
log "Selected mode: $MODE"

if [ "$MODE" = "wipe" ]; then
  run_phase "Clean_Wipe" "phase_clean_wipe"
  rm -rf "$STATE_DIR" || true; mkdir -p "$STATE_DIR"
fi

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
