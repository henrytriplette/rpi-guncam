#!/usr/bin/env bash
#
# NOTE: This script is only intended for Raspberry PI pc's as some wifi cards will not act as an access ponint
# WiFi/AP Setup Script - only run if you have no intention of using the PI over ethernet
#
# This script will configure your Raspberry Pi as:
#   A Wi-Fi client at home
#   A password-protected Access Point when away from home
#
# Requirements: network-manager, hostapd, dnsmasq, iw, iproute2
# Main mini-pi-setup.sh will Install  network-manager hostapd dnsmasq iw iproute2 whiptail 
#
# config file gets generated at /etc/raspi-ap.conf
# generated switching script is generated from this and placed at /usr/local/bin/wifi-or-ap-onboot.sh
# Operation - if the pi starts up and does NOT find the home wifi after 50 seconds, then the wifi card turns into an access point until next reboot.
# Users can connect to the access point that the user names with this script and with a password.

set -euo pipefail

CONFIG_FILE="/etc/raspi-ap.conf"
LOG_FILE="/var/log/wifi-or-ap.log"
AP_IP="192.168.50.1/24"
AP_NET="192.168.50.0/24"
AP_DHCP_START="192.168.50.10"
AP_DHCP_END="192.168.50.50"
WLAN_IF="wlan0"

########################
# Utility functions
########################

require_root() {
  [[ $EUID -eq 0 ]] || { echo "This script must be run as root"; exit 1; }
}

have() { command -v "$1" >/dev/null 2>&1; }

check_requirements() {
  local missing=()
  for c in nmcli hostapd dnsmasq iw ip whiptail; do
    have "$c" || missing+=("$c")
  done
  if ((${#missing[@]})); then
    echo "Missing required commands: ${missing[*]}"
    echo "Install: sudo apt install network-manager hostapd dnsmasq iw iproute2 whiptail"
    exit 1
  fi
}

ensure_logfile() {
  : >"$LOG_FILE" 2>/dev/null || {
    echo "Failed to create/truncate $LOG_FILE. Check permissions."
    exit 1
  }
  chmod 644 "$LOG_FILE" 2>/dev/null || true
}

log() { echo "[wifi-or-ap] $(date '+%F %T') $*" | tee -a "$LOG_FILE"; }

########################
# Config functions
########################

make_or_update_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    . "$CONFIG_FILE"
    whiptail --title "Existing Config Found" --msgbox "Found existing $CONFIG_FILE.\n\nPress OK to update or overwrite values. Leave empty to keep current." 12 60
  else
    COUNTRY="GB"
    HOME_SSID=""
    HOME_PASS=""
    AP_SSID="$(hostname)"
    AP_PASS="12345678"
  fi

  # Country code
  COUNTRY=$(whiptail --inputbox "Enter WiFi Country Code:" 10 60 "${COUNTRY:-GB}" 3>&1 1>&2 2>&3) || exit 1

  # Scan for WiFi networks
  nmcli device wifi rescan >/dev/null 2>&1 || true
  sleep 2
  mapfile -t wifi_list < <(nmcli -t -f SSID,SIGNAL device wifi list | sort -t: -k2 -nr | grep -v "^:")

  if [ ${#wifi_list[@]} -eq 0 ]; then
    whiptail --msgbox "No WiFi networks found. Are any in range?" 10 60
    exit 1
  fi

  menu_items=()
  for i in "${!wifi_list[@]}"; do
    IFS=':' read -r ssid signal <<< "${wifi_list[$i]}"
    menu_items+=("$i" "$ssid (Signal ${signal}%)")
  done

  selection=$(whiptail --title "WiFi Networks" --menu "Select your Home WiFi:" 20 70 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || true
  if [[ -n "$selection" ]]; then
    HOME_SSID=$(echo "${wifi_list[$selection]}" | cut -d: -f1)
  fi
  if [[ -z "${HOME_SSID:-}" ]]; then
    whiptail --msgbox "Home WiFi SSID is required!" 10 60
    exit 1
  fi

  HOME_PASS=$(whiptail --passwordbox "Enter WiFi Password for $HOME_SSID:" 10 60 "${HOME_PASS:-}" 3>&1 1>&2 2>&3) || exit 1

  AP_SSID=$(whiptail --inputbox "Access Point SSID:" 10 60 "${AP_SSID:-PiAP-$(hostname)}" 3>&1 1>&2 2>&3) || exit 1
  AP_PASS=$(whiptail --passwordbox "Access Point Password (min 8 chars):" 10 60 "${AP_PASS:-}" 3>&1 1>&2 2>&3) || exit 1

  if (( ${#AP_PASS} < 8 )); then
    whiptail --msgbox "AP password must be at least 8 characters." 10 60
    exit 1
  fi

  # ---- Confirmation step ----
  CONFIRM_TEXT="Please confirm your settings:\n
Home WiFi SSID : $HOME_SSID
Home WiFi Pass : $HOME_PASS
Country Code   : $COUNTRY

Access Point SSID : $AP_SSID
Access Point Pass : $AP_PASS

Proceed with these settings?"
  if ! whiptail --title "Confirm Settings" --yesno "$CONFIRM_TEXT" 20 70; then
    whiptail --msgbox "Setup cancelled. No changes written." 10 60
    exit 1
  fi

  # Save config
  install -m 600 /dev/null "$CONFIG_FILE"
  cat >"$CONFIG_FILE" <<EOF
COUNTRY="$COUNTRY"
HOME_SSID="$HOME_SSID"
HOME_PASS="$HOME_PASS"
AP_SSID="$AP_SSID"
AP_PASS="$AP_PASS"
WLAN_IF="$WLAN_IF"
AP_IP="$AP_IP"
AP_NET="$AP_NET"
AP_DHCP_START="$AP_DHCP_START"
AP_DHCP_END="$AP_DHCP_END"
EOF

  log "Saved config to $CONFIG_FILE"
}

########################
# AP config
########################

write_ap_configs() {
  mkdir -p /etc/hostapd /etc/dnsmasq.d
  . "$CONFIG_FILE"

  cat > /etc/hostapd/hostapd.conf <<EOF
country_code=$COUNTRY
interface=$WLAN_IF
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=3
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=0
EOF

  if [[ -f /etc/default/hostapd ]]; then
    if grep -q '^#\?\s*DAEMON_CONF=' /etc/default/hostapd; then
      sed -i 's|^#\?\s*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    else
      echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
    fi
  fi

  cat > /etc/dnsmasq.d/raspi-ap.conf <<EOF
interface=$WLAN_IF
bind-interfaces
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,255.255.255.0,24h
EOF

  log "Wrote /etc/hostapd/hostapd.conf and /etc/dnsmasq.d/raspi-ap.conf"
}

########################
# Boot script
########################

install_boot_script() {
  cat > /usr/local/bin/wifi-or-ap-onboot.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/raspi-ap.conf"
LOG_FILE="/var/log/wifi-or-ap.log"
log(){ echo "[wifi-or-ap] $(date '+%F %T') $*" | tee -a "$LOG_FILE"; }

[[ -f "$CONFIG_FILE" ]] || { log "Missing $CONFIG_FILE"; exit 1; }
. "$CONFIG_FILE"

log "Starting boot: HOME_SSID='$HOME_SSID'"

# reset wlan
rmmod brcmfmac >/dev/null 2>&1 || true
modprobe brcmfmac >/dev/null 2>&1 || true
rfkill unblock wifi || true
ip link set "$WLAN_IF" down || true
ip addr flush dev "$WLAN_IF" || true
ip link set "$WLAN_IF" up || true
iw reg set "$COUNTRY" || true

systemctl stop hostapd dnsmasq 2>/dev/null || true
systemctl start NetworkManager 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
nmcli -t -f NAME connection show | grep -Fxq "$HOME_SSID" && nmcli connection delete "$HOME_SSID" || true
nmcli connection add type wifi con-name "$HOME_SSID" ifname "$WLAN_IF" ssid "$HOME_SSID" \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$HOME_PASS" ipv4.method auto ipv6.method ignore autoconnect yes >/dev/null 2>&1 || true

ss_seen=0
for i in $(seq 1 20); do
  nmcli device wifi rescan >/dev/null 2>&1 || true
  if nmcli -t -f SSID device wifi list | grep -Fxq "$HOME_SSID"; then
    ss_seen=1
    log "WIFI visible (attempt $i). Trying to connect..."
    if nmcli connection up "$HOME_SSID" >/dev/null 2>&1; then
      if nmcli -t -f DEVICE,STATE,CONNECTION dev status | grep -q "^$WLAN_IF:connected:$HOME_SSID$"; then
        log "Connected to $HOME_SSID."
        MODE="Wi-Fi Mode"
        IP_ADDR=$(nmcli -t -f IP4.ADDRESS device show "$WLAN_IF" | cut -d/ -f1)
        break
      fi
    fi
  fi
  sleep 5
done

if [[ "$ss_seen" -eq 0 || -z "${IP_ADDR:-}" ]]; then
  log "Switching to AP mode"
  systemctl stop NetworkManager 2>/dev/null || true
  ip link set "$WLAN_IF" down || true
  ip addr flush dev "$WLAN_IF" || true
  ip addr add "$AP_IP" dev "$WLAN_IF"
  ip link set "$WLAN_IF" up || true
  sleep 1
  systemctl restart hostapd dnsmasq || { log "AP services failed"; exit 1; }
  MODE="Access Point Mode"
  IP_ADDR=$(echo "$AP_IP" | cut -d/ -f1)
fi

STATUS_HTML="/var/www/html/status.html"
mkdir -p /var/www/html

# Base HTML
cat > "$STATUS_HTML" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Mini-Pi Status</title>
<style>
  body {
    display: flex;
    justify-content: center;
    align-items: center;
    height: 100vh;
    font-family: Arial, sans-serif;
    background-color: #f0f0f0;
    margin: 0;
    text-align: center;
  }
  .status-box {
    background: #fff;
    padding: 40px;
    border-radius: 15px;
    box-shadow: 0 0 15px rgba(0,0,0,0.2);
  }
  h1 { margin-bottom: 20px; }
  p { font-size: 1.2em; margin: 10px 0; }
</style>
</head>
<body>
  <div class="status-box">
    <h1>Mini-Pi Status</h1>
    <p>Mode: <b>$MODE</b></p>
    <p>IP Address: <b>$IP_ADDR</b></p>
EOF

# Add Wi-Fi specific info if in Wi-Fi mode
if [[ "$MODE" == "Wi-Fi Mode" ]]; then
  cat >> "$STATUS_HTML" <<EOF
    <p>Connected SSID: <b>$HOME_SSID</b></p>
EOF
fi

# Add AP info if in AP mode
if [[ "$MODE" == "Access Point Mode" ]]; then
  cat >> "$STATUS_HTML" <<EOF
    <p>AP SSID: <b>$AP_SSID</b></p>
    <p>AP Password: <b>$AP_PASS</b></p>
EOF
fi

# Close HTML
cat >> "$STATUS_HTML" <<EOF
  </div>
</body>
</html>
EOF

log "Status page generated at $STATUS_HTML"
EOS

  chmod +x /usr/local/bin/wifi-or-ap-onboot.sh
  log "Installed /usr/local/bin/wifi-or-ap-onboot.sh"
}

########################
# Systemd service
########################

install_systemd_service() {
  cat > /etc/systemd/system/wifi-or-ap-onboot.service <<'EOF'
[Unit]
Description=Choose Wi-Fi or AP at boot (one-shot)
After=NetworkManager.service
Wants=NetworkManager.service
ConditionPathExists=/etc/raspi-ap.conf

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-or-ap-onboot.sh
RemainAfterExit=yes
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now wifi-or-ap-onboot.service
  log "Enabled systemd service wifi-or-ap-onboot.service"
}

########################
# Main
########################

main() {
  require_root
  check_requirements
  ensure_logfile
  make_or_update_config
  write_ap_configs
  install_boot_script
  install_systemd_service
  whiptail --title "Setup Complete" --msgbox "Wi-Fi/AP setup complete.\n\nOn boot, the Pi will connect to WiFi if available or start as an AP.\n\nHome WiFi SSID: $HOME_SSID\nAP SSID: $AP_SSID\nAP Pass: $AP_PASS" 15 70
}

main "$@"

