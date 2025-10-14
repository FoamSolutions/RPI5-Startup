git clone https://github.com/FoamSolutions/RPI5-Startup.git /home/Foami/RPI5-Startup

cd /home/Foami/RPI5-Startup

sudo chmod +x foami_setup.sh

sudo ./foami_setup.sh

# clock widget 12hr
%I:%M %p

🧠 Foami Setup Script

Automatic installer for Raspberry Pi 5-based spray-foam control systems

This repository provides a one-shot provisioning script for a Raspberry Pi running Bullseye / Bookworm / Trixie.
It configures hardware watchdog support, a static IPv4 link for CODESYS communication, and power-loss protection.

🚀 Features

✅ Sequent Microsystems WatchDog Timer (WDT) auto-install & configuration

Enables I²C

Builds and installs wdt CLI tool

Sets channel 1 and brownout undervoltage = 3000 mV

Verifies expected parameters (ECV = 3600, BUV = 3000)

🧩 Custom UPS Shutdown Script (ups-debug.sh)

Logs all events to /home/Foami/Desktop/wdt.log

Safely shuts down the Pi when voltage < 4 V and charge state = 0

Reloads watchdog during normal operation

🔌 Static IPv4 Networking (for EtherCAT / CODESYS link)

eth1 fixed at 10.0.0.12/24

IPv6 disabled, no gateway/DNS, “never default” routing

Auto-connects on boot via NetworkManager

🧾 CODESYS Control Config patcher

Adds Command=AllowAll below [SysProcess] → Command.0=shutdown

Skips gracefully if file doesn’t exist yet

🌗 System Settings

Hostname = Foami

Timezone = America/New_York

Wi-Fi country = US

Optional dark-mode + Chromium kiosk flags

🧯 Failsafe Design

Idempotent: safe to rerun anytime

Each modified file is automatically timestamp-backed-up
# RPI5-Startup
