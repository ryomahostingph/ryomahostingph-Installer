# ryomahostingph-Installer
# ⚡ rAthena VPS Installer for Debian 12

Automated **rAthena server + FluxCP panel installer** for a clean **Debian 12 VPS**.  
Includes **MariaDB**, **Apache2 + PHP**, **XFCE desktop environment**, **TightVNC**, and **desktop utilities** for easy server management.

---

## 🚀 Features

✅ Complete rAthena server installation  
✅ FluxCP web panel with preconfigured database  
✅ MariaDB server setup with **secure auto-generated passwords**  
✅ XFCE desktop environment + TightVNC for remote management  
✅ Desktop shortcuts for:
- Start / Stop rAthena servers  
- Compile Pre-renewal / Renewal modes  
- Recompile rAthena  
- Change VNC password  
- Backup / Restore rAthena databases  
- Manage VNC whitelist  
✅ Automatic `background.png` wallpaper and `logo.png` panel logo  
✅ Optional gameplay patches and pre-renewal mode  
✅ Systemd services for rAthena (login, char, map)  
✅ Firewall and VNC whitelist management

---

## 🖥 Requirements

- **Clean Debian 12 VPS** (root access required)  
- **Internet connection**  
- Minimum **2GB RAM**, **2 CPU cores** recommended  

---

## ⚙️ Installation Steps

### 1️⃣ Clone repository
```bash
apt-get update -y && \
apt-get install -y dos2unix curl git && \
git clone https://github.com/ryomahostingph/ryomahostingph-Installer.git && \
cd ryomahostingph-Installer && \
dos2unix *.sh && \
chmod +x installer.sh && \
./installer.sh


```
2️⃣ Edit environment variables (optional)

Before running the installer, edit:

```bash
nano rathena-installer.env
```

✅ rAthena username: RUSER
✅ Database credentials: automatically generated if left as CHANGE_ME_DB_PASSWORD
✅ FluxCP settings: Base URI, installer password, site title
✅ Pre-renewal mode and gameplay patches

3️⃣ Run the installer
```bash
chmod +x run_installer.sh
./run_installer.sh
```
| Phase | Description                                             |
| ----- | ------------------------------------------------------- |
| 1     | System preparation: user, folders, permissions          |
| 2     | Install dependencies: Apache2, PHP, MariaDB, XFCE4, VNC |
| 3     | MariaDB setup & database creation                       |
| 4     | Clone & compile rAthena                                 |
| 5     | FluxCP installation & Apache configuration              |
| 6     | Create systemd services for rAthena                     |
| 7     | Desktop utilities, scripts, launchers                   |
| 8     | TightVNC setup & auto-check service                     |
| 9     | Finalization: generate install report & desktop details |


🛠 Desktop Utilities

After installation, switch to the rAthena user:
| Shortcut                 | Description                          |
| ------------------------ | ------------------------------------ |
| **Start rAthena**        | Start all servers (login, char, map) |
| **Recompile rAthena**    | Pull latest updates & compile        |
| **Compile Pre-renewal**  | Compile in pre-renewal mode          |
| **Compile Renewal**      | Compile in renewal mode              |
| **Change VNC Password**  | Update TightVNC password             |
| **Backup Database**      | Backup all rAthena databases         |
| **Restore Database**     | Restore from SQL backup              |
| **Whitelist Management** | Add IPs allowed for VNC access       |

🌐 VNC Access

✅Default password: Ch4ngeMe
✅Display: :1
✅Change password:
```bash
runuser -l rathena -c vncpasswd
```

Auto-restart enabled via systemd service

🔒 Security Notes

Database credentials stored in /root/.rathena_db_creds (chmod 600)

TightVNC firewall + whitelist ensures secure access

rAthena servers run as non-root user

📂 FluxCP Web Panel

Open browser: http://<VPS-IP>/

Use installer password set in rathena-installer.env

Panel paths, DB config, and system info available in desktop report

💡 Post-installation Tips

Change default VNC password immediately

Check ServerDetails.txt on Desktop for paths & credentials

Use desktop shortcuts for routine operations instead of manual commands

Keep your rathena-installer.env for future reconfiguration

📝 Optional Customization

Copy background.png and logo.png into the installer folder for automatic desktop customization

Enable optional gameplay patches via PATCH_FOLDER_ENABLED="yes"

Configure pre-renewal mode or renewal mode compilation

📌 Notes

Tested on Debian 12 minimal clean VPS

Compatible with rAthena latest stable branch

Designed for quick deployment & easy server management

⚡ Pro Tip: Keep a backup of your .rathena_db_creds and desktop scripts. They will save hours during server migration or recovery.
