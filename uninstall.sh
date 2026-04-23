#!/usr/bin/env bash
set -euo pipefail

# Ensure script is run with bash
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Please run with bash: sudo bash uninstall.sh"
  exit 1
fi

# Ensure script is run as root
if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root (e.g., sudo bash uninstall.sh)"
  exit 1
fi

echo "========================================"
echo "  o11 & Multiplexer Proxy Uninstaller   "
echo "========================================"
echo ""

# Confirmation prompt
read -r -p "Are you sure you want to completely remove o11 and the proxy? [y/N]: " confirm < /dev/tty
if [[ ! "$confirm" =~ ^[Yy](es)?$ ]]; then
  echo "Uninstallation aborted by user."
  exit 0
fi

echo ""
echo "[1/4] Stopping o11 and proxy services..."
# We use || true so the script doesn't exit if the service is already stopped/deleted
systemctl stop o11-proxy.service 2>/dev/null || true
systemctl stop o11.service 2>/dev/null || true

echo "[2/4] Disabling systemd services..."
systemctl disable o11-proxy.service 2>/dev/null || true
systemctl disable o11.service 2>/dev/null || true

echo "[3/4] Removing systemd service files..."
rm -f /etc/systemd/system/o11-proxy.service
rm -f /etc/systemd/system/o11.service
systemctl daemon-reload

echo "[4/4] Removing application directory (/home/o11)..."
rm -rf /home/o11

echo ""
echo "=========================================================="
echo " Uninstallation completed successfully!"
echo "=========================================================="
echo " Note: System packages installed by the setup script "
echo " (ffmpeg, unzip, nodejs, npm) were NOT removed automatically"
echo " as they might be required by other software on your server."
echo ""
echo " If you wish to remove them as well, you can run:"
echo "   apt-get remove --purge -y ffmpeg unzip nodejs npm"
echo "   apt-get autoremove -y"
echo "=========================================================="
