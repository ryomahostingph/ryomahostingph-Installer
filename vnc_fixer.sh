#!/usr/bin/env bash
set -euo pipefail

RUSER="rathena"
RHOME="/home/${RUSER}"
DEFAULT_VNC_PASSWORD="Ch4ng3me"   # change here or pass env

log(){ echo "[$(date '+%F %T')] $*" | tee -a /var/log/vnc_fixer.log; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }

print_usage(){
  cat <<EOF
vnc_fixer.sh - install | remove | status
  install  - configure .vnc, write passwd as user, create xstartup, systemd unit and start vncserver@1
  remove   - stop service, remove systemd unit and delete .vnc
  status   - show vncserver@1.service status and tail log
EOF
}

# cleanup helper (safe)
cleanup_old(){
  log "Cleaning old VNC processes and PID files..."
  pkill -u "${RUSER}" Xtightvnc 2>/dev/null || true
  pkill -f "/usr/bin/vncserver" 2>/dev/null || true
  for i in {1..9}; do sudo -u "${RUSER}" /usr/bin/vncserver -kill ":$i" 2>/dev/null || true; done
  rm -f "${RHOME}/.vnc/"*.pid 2>/dev/null || true
  rm -f /tmp/.X*-lock /tmp/.X11-unix/* 2>/dev/null || true
}

install_vnc(){
  log "Running VNC fixer install..."

  cleanup_old

  rm -rf "${RHOME}/.vnc"
  sudo -u "${RUSER}" mkdir -p "${RHOME}/.vnc"
  chown "${RUSER}":"${RUSER}" "${RHOME}/.vnc"
  chmod 700 "${RHOME}/.vnc"

  # create passwd as rathena to ensure correct owner & format
  sudo -u "${RUSER}" bash -c "echo '${DEFAULT_VNC_PASSWORD}' | vncpasswd -f > \$HOME/.vnc/passwd"
  chown "${RUSER}":"${RUSER}" "${RHOME}/.vnc/passwd"
  chmod 600 "${RHOME}/.vnc/passwd"

  # xstartup — ensure dbus session for XFCE
  sudo -u "${RUSER}" tee "${RHOME}/.vnc/xstartup" > /dev/null <<'EOF'
#!/bin/bash
xrdb $HOME/.Xresources || true
# start dbus session for XFCE
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  eval $(dbus-launch --sh-syntax) || true
fi
startxfce4 &
EOF

  chown "${RUSER}":"${RUSER}" "${RHOME}/.vnc/xstartup"
  chmod +x "${RHOME}/.vnc/xstartup"

  # write a reliable systemd template for vncserver@.service
  cat >/etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=Start TightVNC server at startup
After=syslog.target network.target

[Service]
Type=forking
User=RUSER
PAMName=login
PIDFile=/home/RUSER/.vnc/%H:%i.pid
Environment=DISPLAY=:%i
Environment=XAUTHORITY=/home/RUSER/.Xauthority

ExecStartPre=/usr/bin/vncserver -kill :%i > /dev/null 2>&1 || true
ExecStart=/usr/bin/vncserver :%i -geometry 1280x720 -depth 24
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

  sed -i "s/RUSER/${RUSER}/g" /etc/systemd/system/vncserver@.service

  systemctl daemon-reload
  systemctl enable vncserver@1.service
  # start and show status
  if systemctl restart vncserver@1.service; then
    log "vncserver@1.service started"
    systemctl status vncserver@1.service --no-pager || true
  else
    log "vncserver failed to start; check journalctl -xeu vncserver@1.service"
    systemctl status vncserver@1.service --no-pager || true
  fi

  log "VNC fixer install completed"
}

remove_vnc(){
  log "Removing VNC service and files..."
  systemctl stop vncserver@1.service 2>/dev/null || true
  systemctl disable vncserver@1.service 2>/dev/null || true
  rm -f /etc/systemd/system/vncserver@.service /etc/systemd/system/vncserver@1.service 2>/dev/null || true
  systemctl daemon-reload || true
  rm -rf "${RHOME}/.vnc" "${RHOME}/.Xauthority" 2>/dev/null || true
  log "VNC removed"
}

status_vnc(){
  systemctl status vncserver@1.service --no-pager || true
  echo "---- VNC log tail ----"
  tail -n 80 "${RHOME}/.vnc/$(hostname):1.log" 2>/dev/null || true
}

# -------------------------
# entrypoint
# -------------------------
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
  *)
    print_usage
    ;;
esac
