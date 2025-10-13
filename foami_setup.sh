#!/usr/bin/env bash
set -euo pipefail

# ============================ CONFIG (edit if needed) ============================
NEW_HOSTNAME="Foami"

# --- Network (NetworkManager) ---
ETH_IFACE="eth1"
PIN_ETH1_BY_MAC="false"
ETH1_MAC="XX:XX:XX:XX:XX:XX"
CON_NAME="CODESYS-ETH"
IPV4_ADDR="10.0.0.12/24"
IPV4_GATEWAY=""
IPV4_DNS=""
AUTOCONNECT="yes"
IPV6_METHOD="disabled"
DISABLE_DHCPCD="true"

# --- Codesys ---
CODESYS_CFG="/etc/codesyscontrol/CODESYSControl_User.cfg"

# --- Timezone + Wi-Fi country ---
TIMEZONE="America/New_York"
WIFI_COUNTRY="US"
CREATE_WIFI_PROFILE="false"
WIFI_IFACE="wlan0"
WIFI_SSID="YourSSIDHere"
WIFI_PSK="YourPassHere"

# --- Logging ---
LOG_FILE="/var/log/foami_setup.log"
REPORT_FILE="/tmp/foami_setup_report.txt"
mkdir -p "$(dirname "$LOG_FILE")"
: >"$LOG_FILE"
: >"$REPORT_FILE"

timestamp() { date '+%F %T'; }
say() { echo "[Foami $(timestamp)] $*" | tee -a "$LOG_FILE"; }
diag() { printf "%s\n" "$*" >>"$REPORT_FILE"; }
hr() { printf -- '------------------------------------------------------------\n' | tee -a "$LOG_FILE"; }

run() {
  local label="$1"; shift
  say "$label"
  local tmpo tmpe code
  tmpo="$(mktemp)"; tmpe="$(mktemp)"
  if "$@" >"$tmpo" 2>"$tmpe"; then code=0; else code=$?; fi
  {
    echo ">>> $label"
    echo "\$ $*"
    [ -s "$tmpo" ] && { echo "STDOUT:"; cat "$tmpo"; }
    [ -s "$tmpe" ] && { echo "STDERR:"; cat "$tmpe"; }
    echo "EXIT=$code"
  } >>"$LOG_FILE"
  diag "$label => exit=$code"
  rm -f "$tmpo" "$tmpe"
  return $code
}

trap 'say "ERROR: Script aborted at line $LINENO."; diag "ABORT line=$LINENO"; exit 1' ERR
require_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 2; }; }

# ============================ TASKS =============================================

set_hostname() {
  local cur; cur="$(hostname)"
  diag "HOSTNAME.before=$cur"
  if [ "$cur" != "$NEW_HOSTNAME" ]; then
    echo "$NEW_HOSTNAME" >/etc/hostname
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
    else
      echo -e "127.0.0.1\tlocalhost\n127.0.1.1\t${NEW_HOSTNAME}" >>/etc/hosts
    fi
    run "hostnamectl set-hostname $NEW_HOSTNAME" hostnamectl set-hostname "$NEW_HOSTNAME" || true
  fi
  diag "HOSTNAME.after=$(hostname)"
}

enable_i2c() {
  run "apt update" apt-get update -y || true
  run "install raspi-config i2c-tools build-essential git" apt-get install -y raspi-config i2c-tools build-essential git || true
  run "raspi-config nonint do_i2c 0" raspi-config nonint do_i2c 0 || true
  grep -q '^i2c-dev$' /etc/modules || echo 'i2c-dev' >>/etc/modules
  run "modprobe i2c-dev" modprobe i2c-dev || true
  for CFG in /boot/config.txt /boot/firmware/config.txt; do
    [ -f "$CFG" ] || continue
    if grep -q '^dtparam=i2c_arm' "$CFG"; then
      sed -i 's/^dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "$CFG"
    else
      printf "\n# enabled by setup script\ndtparam=i2c_arm=on\n" >>"$CFG"
    fi
    diag "I2C.cfg=$(basename "$CFG") set=on"
  done
}

require_nm() {
  run "Install NetworkManager" bash -lc 'command -v nmcli >/dev/null || (apt-get update -y && apt-get install -y network-manager)'
  run "Enable NetworkManager" systemctl enable --now NetworkManager || true
  if [ "${DISABLE_DHCPCD,,}" = "true" ]; then
    run "Disable dhcpcd" systemctl disable --now dhcpcd || true
  fi
  if [ "${PIN_ETH1_BY_MAC,,}" = "true" ]; then
    if [[ "$ETH1_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
      say "Pinning ${ETH_IFACE} to MAC ${ETH1_MAC}"
      cat >/etc/udev/rules.d/10-eth1-persistent.rules <<EOF
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="${ETH1_MAC}", NAME="${ETH_IFACE}"
EOF
      run "Reload udev" bash -lc "udevadm control --reload && udevadm trigger" || true
    else
      diag "ETH1.pin_mac=invalid"
    fi
  fi
  mkdir -p /etc/NetworkManager/conf.d
  echo -e "[main]\nplugins=keyfile\n" >/etc/NetworkManager/conf.d/10-keyfile.conf
  run "Restart NetworkManager" systemctl restart NetworkManager || true
}

nm_ipv4_point_to_point() {
  local dev="$ETH_IFACE"
  say "Setting ${CON_NAME} on ${dev} to ${IPV4_ADDR}"
  run "NM manage $dev" nmcli device set "$dev" managed yes || true
  run "Flush IPs" ip addr flush dev "$dev" || true
  run "Kill dhclient" pkill -9 dhclient || true
  nmcli -t -f NAME,DEVICE connection show | awk -F: -v IF="$dev" '$2==IF{print $1}' | while read -r old; do
    [ "$old" = "$CON_NAME" ] && continue
    run "Delete profile $old" nmcli connection delete "$old" >/dev/null 2>&1 || true
  done
  if nmcli -t -f NAME connection show | grep -Fxq "$CON_NAME"; then
    run "Modify $CON_NAME" nmcli connection modify "$CON_NAME" \
      connection.interface-name "$dev" connection.autoconnect yes \
      ipv4.method manual ipv4.addresses "$IPV4_ADDR" ipv6.method "${IPV6_METHOD}"
  else
    run "Create $CON_NAME" nmcli connection add type ethernet ifname "$dev" con-name "$CON_NAME" \
      ipv4.method manual ipv4.addresses "$IPV4_ADDR" ipv6.method "${IPV6_METHOD}"
  fi
  run "Down $CON_NAME" nmcli connection down "$CON_NAME" || true
  run "Up $CON_NAME" nmcli connection up "$CON_NAME" || { nmcli device connect "$dev" && nmcli connection up "$CON_NAME" || true; }
  diag "NM.active=$(nmcli -f NAME,DEVICE,TYPE,STATE connection show --active | tr -s ' ' | tr '\n' ';')"
}

patch_codesys_cfg() {
  if [ -f "$CODESYS_CFG" ]; then
    cp -a "$CODESYS_CFG" "${CODESYS_CFG}.bak.$(date +%Y%m%d_%H%M%S)"
    if ! grep -q '^Command=AllowAll' "$CODESYS_CFG"; then
      awk '
        /^\[SysProcess\]/{print; inproc=1; next}
        inproc && /^Command\.0=shutdown/{print; print "Command=AllowAll"; inproc=0; next}
        {print}
      ' "$CODESYS_CFG" >"${CODESYS_CFG}.tmp" && mv "${CODESYS_CFG}.tmp" "$CODESYS_CFG"
      diag "CODESYS.allow_all=added"
    else
      diag "CODESYS.allow_all=exists"
    fi
  else
    diag "CODESYS.file_absent=yes"
  fi
}

tz_wifi() {
  run "Set timezone" timedatectl set-timezone "$TIMEZONE" || true
  run "Set Wi-Fi country" raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
  if [ "${CREATE_WIFI_PROFILE,,}" = "true" ] && command -v nmcli >/dev/null 2>&1; then
    local WCON="HOME-WIFI-US"
    nmcli -t -f NAME connection show | grep -Fx "$WCON" >/dev/null 2>&1 && nmcli connection delete "$WCON" || true
    run "Create Wi-Fi profile" nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$WCON" ssid "$WIFI_SSID"
    run "Set Wi-Fi PSK" nmcli connection modify "$WCON" wifi-sec.key-mgmt wpa-psk 802-11-wireless-security.psk "$WIFI_PSK"
    run "Up Wi-Fi" nmcli connection up "$WCON" || true
  fi
  diag "TIMEZONE=$(timedatectl | sed -n 's/^ *Time zone: //p')"
}

# ============================ MAIN ==============================================
require_root
hr; say "Starting Foami setup (Pi5-safe, WDT disabled)…"
hr; set_hostname
hr; enable_i2c
hr; require_nm
hr; nm_ipv4_point_to_point
hr; patch_codesys_cfg
hr; tz_wifi
hr; say "Setup complete. Log: $LOG_FILE"
echo "==== FOAMI DIAG BEGIN ===="
cat "$REPORT_FILE"
echo "LOG_TAIL:"; tail -n 40 "$LOG_FILE" || true
echo "==== FOAMI DIAG END ===="
