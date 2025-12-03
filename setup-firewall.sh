#!/bin/bash
# Rathena + FluxCP + VNC UFW firewall setup

# Reset UFW to start fresh
sudo ufw --force reset

# Default policy: deny all incoming, allow all outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH from specific IPs only
sudo ufw allow from 120.29.109.131 to any port 22 proto tcp
sudo ufw allow from 120.28.137.77 to any port 22 proto tcp

# Allow VNC (port 5901) from specific IPs only
sudo ufw allow from 120.29.109.131 to any port 5901 proto tcp
sudo ufw allow from 120.28.137.77 to any port 5901 proto tcp

# Allow FluxCP web ports globally
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Allow rAthena server ports globally
sudo ufw allow 6900/tcp          # login-server
sudo ufw allow 5121:5122/tcp     # char-server & map-server

# Enable UFW
sudo ufw --force enable

# Show status
sudo ufw status verbose
