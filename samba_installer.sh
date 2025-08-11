#!/bin/bash

# =========================================================================
# ===           Samba Share Configuration for Raspberry Pi            ===
# =========================================================================
# This script installs Samba and configures two public, password-free shares:
# 1. A USB drive, mounted at a specific location.
# 2. The Android backup folder on the user's desktop.
# =========================================================================

# --- Sudo Check: Ensure script is run as root ---
if [[ $EUID -ne 0 ]]; then
    echo "This script needs admin rights to work. Trying again with sudo..."
    exec sudo -- "$0" "$@"
    exit 1
fi

# --- Configuration Variables ---
USB_MOUNT_FOLDER_NAME="Android_Backup_USB"
BACKUP_FOLDER_NAME="Android_Backups"
SAMBA_CONFIG="/etc/samba/smb.conf"

if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    ORIGINAL_USER="$SUDO_USER"
else
    USER_HOME=$HOME
    ORIGINAL_USER=$(whoami)
fi

USB_SHARE_PATH="$USER_HOME/Desktop/$USB_MOUNT_FOLDER_NAME"
BACKUP_SHARE_PATH="$USER_HOME/Desktop/$BACKUP_FOLDER_NAME"

# =========================================================================
# ---                         MAIN SCRIPT LOGIC                         ---
# =========================================================================

echo "Starting Samba installation and configuration..."

# 1. Install Samba
echo "1. Installing Samba..."
apt-get update -qq >/dev/null && apt-get install -y samba samba-common-bin >/dev/null
if [ $? -eq 0 ]; then
    echo "   Samba installed successfully."
else
    echo "   Error: Failed to install Samba. Exiting."
    exit 1
fi

# 2. Create Shared Folders if they don't exist
echo "2. Creating shared folders and setting permissions..."
mkdir -p "$USB_SHARE_PATH"
mkdir -p "$BACKUP_SHARE_PATH"
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$USB_SHARE_PATH"
chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$BACKUP_SHARE_PATH"
chmod 777 "$USB_SHARE_PATH"
chmod 777 "$BACKUP_SHARE_PATH"
echo "   Folders created and permissions set."

# 3. Configure Samba
echo "3. Configuring Samba shares..."

# Remove previous shares to prevent duplicates
sed -i '/^\[USB_Backup\]/,/^\[/d' "$SAMBA_CONFIG"
sed -i '/^\[Desktop_Backups\]/,/^\[/d' "$SAMBA_CONFIG"

# Add new share configurations
cat <<EOF >> "$SAMBA_CONFIG"

[USB_Backup]
   path = $USB_SHARE_PATH
   browseable = yes
   writeable = yes
   guest ok = yes
   create mask = 0777
   directory mask = 0777
   force user = $ORIGINAL_USER

[Desktop_Backups]
   path = $BACKUP_SHARE_PATH
   browseable = yes
   writeable = yes
   guest ok = yes
   create mask = 0777
   directory mask = 0777
   force user = $ORIGINAL_USER

EOF
echo "   Samba configuration file updated." 

# 4. Restart Samba Service
echo "4. Restarting the Samba service..."
systemctl restart smbd.service
if [ $? -eq 0 ]; then
    echo "   Samba service restarted successfully."
else
    echo "   Error: Failed to restart Samba service. Exiting."
    exit 1
fi

echo ""
echo "================================================================="
echo " Samba is now configured!"
echo " You can access your shares from your local network at:"
echo " smb://$(hostname)/USB_Backup"
echo " smb://$(hostname)/Desktop_Backups"
echo "================================================================="

exit 0