#!/bin/bash
set -e

# rpi-gun.sh
# Ensure dialog is installed
apt-get install -y dialog

# Determine the current user
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$USER"
fi
# Fallback to 'pi' if no user is detected
[ -z "$CURRENT_USER" ] && CURRENT_USER="pi"

# Validate user existence
if ! id "$CURRENT_USER" >/dev/null 2>&1; then
    dialog --msgbox "Error: User '$CURRENT_USER' does not exist. Please run this script as a valid user." 8 60
    exit 1
fi

# Get the user's home directory
HOME_DIR=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
    dialog --msgbox "Error: Home directory for user '$CURRENT_USER' not found." 8 60
    exit 1
fi

# Elevate privileges if not running as root
if [ "$EUID" -ne 0 ]; then
    if ! command -v dialog &>/dev/null; then
        sudo apt-get install -y dialog
    fi
    dialog --msgbox "This script needs root privileges. Restarting with sudo..." 8 60
    exec sudo bash "$0" "$@"
fi

display_header() {
    clear
    dialog --title "RPI Gun Setup" \
           --msgbox "Welcome to the RPI Gun setup script.\n\n\
This will install and configure your server for the user '$CURRENT_USER'." 10 60
}

install_packages() {
    dialog --infobox "Updating package lists..." 5 60
    sleep 2
    clear
    apt-get update -q

    dialog --infobox "Upgrading system..." 5 60
    sleep 2
    clear
    apt-get upgrade -y -q

    dialog --infobox "Installing required packages..." 5 60
    apt-get install -y -q gcc python3 python3-pip python3-dev libssl-dev libcurl4-openssl-dev libjpeg-dev libjpeg62-turbo-dev libz-dev ffmpeg v4l-utils ca-certificates curl

    dialog --infobox "Installing PIP..." 5 60
    apt-get install -y -q python3-pip

    dialog --msgbox "All required software has been installed. Installing motionEye next..." 7 60
}

motioneye_install() {
    dialog --infobox "Installing motionEye..." 5 60
    sudo pip3 install 'https://github.com/motioneye-project/motioneye/archive/dev.tar.gz' --break-system-packages

    dialog --infobox "Create config directories..." 5 60
    sudo motioneye_init

    dialog --msgbox "motionEye installation and setup complete!\n\nAccess the web interface at http://<RPI_IP_ADDRESS>:8765\n\nDefault credentials are admin with no password." 10 60
}

# ---------------- Final Setup ----------------
finalize_setup() {
    # Wi-Fi reconfiguration
    if dialog --defaultno --yesno "Do you want to reconfigure Wi-Fi connection and access point?\nNOTE: Only run on Pi OS." 8 60; then
        ./reconfigure-wifi.sh || dialog --msgbox "Error reconfiguring Wi-Fi, continuing setup..." 7 60
    fi

    # Completion message
    dialog --msgbox "Setup completed successfully!\n\n RpiGun server is ready for user '$CURRENT_USER'.\n\nThe system will now reboot." 10 60
    reboot || dialog --msgbox "Error: Failed to reboot. Please reboot manually." 7 60
}

# ---------------- Main Execution Flow ----------------
display_header
install_packages
motioneye_install
finalize_setup