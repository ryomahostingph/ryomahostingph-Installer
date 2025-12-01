#!/usr/bin/env bash
# swap_installer.sh — Create and enable an 8GB swap file on Debian 12
# Safe defaults, idempotent behavior, and persistence via /etc/fstab.
set -euo pipefail

SWAPFILE="/swapfile"
SWAPSIZE_GB=8
LOGFILE="/var/log/swap_installer.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root (sudo)." >&2
    exit 1
  fi
}

have_swap_enabled() {
  swapon --show=NAME | grep -qx "$SWAPFILE"
}

swapfile_exists() {
  [ -f "$SWAPFILE" ]
}

fstab_has_swapfile() {
  grep -qE "^[^#]*\s+$SWAPFILE\s+none\s+swap" /etc/fstab
}

create_swapfile() {
  log "Creating ${SWAPSIZE_GB}G swap file at $SWAPFILE..."

  # Prefer fallocate; fallback to dd if needed.
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${SWAPSIZE_GB}G" "$SWAPFILE"
  else
    log "fallocate not found, using dd (this may take a while)."
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAPSIZE_GB * 1024)) status=progress
  fi

  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  log "Swap file created and formatted."
}

enable_swapfile() {
  log "Enabling swap on $SWAPFILE..."
  swapon "$SWAPFILE"
  log "Swap enabled."
}

persist_swapfile() {
  if fstab_has_swapfile; then
    log "/etc/fstab already has swapfile entry. Skipping."
  else
    log "Adding swapfile entry to /etc/fstab..."
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    log "Swapfile entry added."
  fi
}

tune_swappiness_optional() {
  # Optional: set swappiness to a sane desktop/server default (10).
  # Comment this out if you don't want it changed.
  local target=10
  log "Setting vm.swappiness to $target (optional tuning)..."
  sysctl -w vm.swappiness="$target" >/dev/null

  if grep -qE "^\s*vm\.swappiness=" /etc/sysctl.conf; then
    sed -i -E "s/^\s*vm\.swappiness=.*/vm.swappiness=$target/" /etc/sysctl.conf
  else
    echo "vm.swappiness=$target" >> /etc/sysctl.conf
  fi
  log "Swappiness tuned and persisted."
}

show_status() {
  log "Final swap status:"
  swapon --show | tee -a "$LOGFILE"
  free -h | tee -a "$LOGFILE"
}

main() {
  require_root
  touch "$LOGFILE" && chmod 600 "$LOGFILE" || true

  log "=== Swap Installer Started ==="

  if have_swap_enabled; then
    log "Swapfile $SWAPFILE is already active. Nothing to do."
    show_status
    exit 0
  fi

  if swapfile_exists; then
    log "Swapfile $SWAPFILE already exists."
    # If it exists but isn't enabled, try to enable/persist it.
  else
    create_swapfile
  fi

  enable_swapfile
  persist_swapfile
  tune_swappiness_optional
  show_status

  log "=== Swap Installer Finished Successfully ==="
}

main "$@"
