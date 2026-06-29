#!/usr/bin/env bash
set -Eeuo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Please run with bash: sudo bash uninstall.sh" >&2
  exit 1
fi

if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root, for example: sudo bash uninstall.sh" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/home/o11}"
CONFIG_DIR="${CONFIG_DIR:-/etc/o11v3-ts}"
RUN_USER="${RUN_USER:-o11}"
FORCE="${FORCE:-0}"
REMOVE_USER="${REMOVE_USER:-0}"

echo "========================================"
echo "     o11v3-ts simple uninstaller"
echo "========================================"
echo ""

if [ "$FORCE" != "1" ]; then
  if [ ! -r /dev/tty ]; then
    echo "No interactive terminal found. Set FORCE=1 to uninstall non-interactively." >&2
    exit 1
  fi
  read -r -p "Completely remove o11v3-ts services and ${APP_DIR}? [y/N]: " confirm < /dev/tty
  if [[ ! "$confirm" =~ ^[Yy](es)?$ ]]; then
    echo "Uninstallation aborted."
    exit 0
  fi
fi

echo "Stopping services..."
systemctl stop o11-proxy.service 2>/dev/null || true
systemctl stop o11.service 2>/dev/null || true

echo "Disabling services..."
systemctl disable o11-proxy.service 2>/dev/null || true
systemctl disable o11.service 2>/dev/null || true

echo "Removing systemd units..."
rm -f /etc/systemd/system/o11-proxy.service
rm -f /etc/systemd/system/o11.service
systemctl daemon-reload

echo "Removing files..."
rm -rf "$APP_DIR"
rm -rf "$CONFIG_DIR"

if [ "$REMOVE_USER" = "1" ] && id -u "$RUN_USER" >/dev/null 2>&1; then
  userdel "$RUN_USER" 2>/dev/null || true
fi

echo ""
echo "Uninstallation completed."
echo "Packages installed by setup, such as ffmpeg, unzip, curl, and nodejs, were left installed."
