#!/usr/bin/env bash
set -euo pipefail

RUSER="rathena"
RHOME="/home/${RUSER}"
DEFAULT_VNC_PASSWORD="Ch4ng3me"   # change here or pass env

log() {
    echo "[$(date '+%F %T')] $*" | tee -a /var/log/vnc_fixer.log
}

[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

print_usage() {
    cat <<EOF
vnc_fixer.sh - install | remove | status
  install  - configure .vnc, write passwd as user, create xstartup, systemd unit and start vncserver@1
  remove   - stop service, remove systemd unit and delete .vnc
  status   - show vncserver@1.service status and tail log
  clean    - remove stale lock files and pid files
EOF
}

# Cleanup function to remove stale lock files and pid files
cleanup_old() {
    log "Cleaning old VNC processes and PID files..."
    pkill -u "${RUSER}" Xtightvnc 2>/dev/null || true
    pkill -f "/usr/bin/vncserver" 2>/dev/null || true

    # Remove stale lock and pid files
    rm -f /tmp/.X*-lock /tmp/.X11-unix/* 2>/dev/null || true
    rm -f "${RHOME}/.vnc/*.pid" 2>/dev/null || true

    log "Cleanup complete"
}

# Function to interactively ask for the VNC password
ask_for_password() {
    if [ -z "${VNC_PASSWORD:-}" ]; then
        read -rp "Enter VNC password: " VNC_PASSWORD
        read -rp "Verify VNC password: " VERIFY_PASSWORD
        if [ "$VNC_PASSWORD" != "$VERIFY_PASSWORD" ]; then
            log "Passwords do not match. Exiting..."
            exit 1
        fi
    fi
}

# Install VNC with systemd service
install_vnc() {
    log "Running VNC fixer install..."

    cleanup_old

    # Ensure .vnc directory exists with proper ownership
    rm -rf "${RHOME}/.vnc"
    sudo -u "${RUSER}" mkdir -p "${RHOME}/.vnc"
    chown "${RUSER}":"${RUSER}" "${RHOME}/.vnc"
    chmod 700 "${RHOME}/.vnc"

    # Ask for password (either from env or interactive)
    ask_for_password

    # Set VNC password
    sudo -u "${RUSER}" bash -c "echo '${VNC_PASSWORD}' | vncpasswd -f > \$HOME/.vnc/passwd"
    chown "${RUSER}":"${RUSER}" "${RHOME}/.vnc/passwd"
    chmod 600 "${RHOME}/.vnc/passwd"

    # Create the xstartup file for XFCE and DBus support
    sudo -u "${RUSER}" tee "${RHOME}/.vnc/xstartup" > /dev/null <<'EOF'
#!/bin/bash
xrdb $HOME/.Xresources || true
# Start DBus session for XFCE
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  eval $(dbus-launch --sh-syntax) || true
fi
startxfce4 &
EOF

    chown "${RUSER}":"${RUSER}" "${RHOME}/.vnc/xstartup"
    chmod +x "${RHOME}/.vnc/xstartup"

    # Write a reliable systemd template for vncserver@.service
    cat >/etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=TightVNC server for user %i
After=network.target

[Service]
Type=forking
User=rathena
Environment=HOME=/home/rathena
ExecStartPre=-/usr/bin/vncserver -kill :%i
ExecStart=/usr/bin/vncserver :%i -geometry 1280x720 -depth 24
ExecStop=/usr/bin/vncserver -kill :%i
Restart=on-failure
GuessMainPID=no

[Install]
WantedBy=multi-user.target
EOF

    sed -i "s/RUSER/${RUSER}/g" /etc/systemd/system/vncserver@.service

    # Reload systemd and enable the service
    systemctl daemon-reload
    systemctl enable vncserver@1.service

    # Start the service and log its status
    if systemctl start vncserver@1.service; then
        log "vncserver@1.service started successfully"
        systemctl status vncserver@1.service --no-pager || true
    else
        log "vncserver failed to start; check journalctl -xeu vncserver@1.service"
        systemctl status vncserver@1.service --no-pager || true
    fi

    log "VNC fixer install completed"
}

# Remove VNC and associated files
remove_vnc() {
    log "Removing VNC service and files..."

    systemctl stop vncserver@1.service 2>/dev/null || true
    systemctl disable vncserver@1.service 2>/dev/null || true
    rm -f /etc/systemd/system/vncserver@.service /etc/systemd/system/vncserver@1.service 2>/dev/null || true
    systemctl daemon-reload || true

    rm -rf "${RHOME}/.vnc" "${RHOME}/.Xauthority" 2>/dev/null || true

    log "VNC removed"
}

# Show status of VNC service
status_vnc() {
    systemctl status vncserver@1.service --no-pager || true
    echo "---- VNC log tail ----"
    tail -n 80 "${RHOME}/.vnc/$(hostname):1.log" 2>/dev/null || true
}

# Entry point
if [ $# -lt 1 ]; then
    print_usage
    exit 0
fi

case "$1" in
    install)
        install_vnc
        ;;
    remove)
        remove_vnc
        ;;
    status)
        status_vnc
        ;;
    clean)
        cleanup_old
        ;;
    *)
        print_usage
        ;;
esac
