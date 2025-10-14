#!/usr/bin/env bash
# Configure power button to trigger hibernation instead of power off
#
# This script modifies /etc/systemd/logind.conf to make the physical power
# button hibernate the system instead of shutting it down or being ignored.
#
# Usage: sudo ./configure-power-button-hibernate.sh
#
# What it does:
#   1. Backs up the existing logind.conf file
#   2. Changes HandlePowerKey from 'ignore' to 'hibernate'
#   3. Reloads systemd-logind to apply changes immediately
#
# Requirements:
#   - Must be run as root (use sudo)
#   - Hibernation must already be configured and working
#   - System must have /etc/systemd/logind.conf
#
# Safety:
#   - Creates timestamped backup of logind.conf before making changes
#   - Uses systemctl kill -s HUP to reload config without killing user sessions
#
# To revert:
#   Edit /etc/systemd/logind.conf and change HandlePowerKey back to your
#   preferred value (ignore, poweroff, suspend, etc.), then run:
#   sudo systemctl kill -s HUP systemd-logind

set -euo pipefail

function fatal() {
  echo "FATAL: $*" >&2
  exit 1
}

function log() {
  echo ">> $*"
}

# Require root
[[ $(id -u) -eq 0 ]] || fatal "Run as root (try: sudo)"

LOGIND_CONF="/etc/systemd/logind.conf"

log "Configuring power button to trigger hibernation"

# Backup the file
BACKUP="${LOGIND_CONF}.$(date +%Y%m%d%H%M%S).bak"
cp -a "$LOGIND_CONF" "$BACKUP"
log "Backed up $LOGIND_CONF to $BACKUP"

# Change HandlePowerKey from ignore to hibernate
sed -i 's/^HandlePowerKey=ignore/HandlePowerKey=hibernate/' "$LOGIND_CONF"

log "Updated power button configuration"

# Reload systemd-logind configuration without killing sessions
log "Reloading systemd-logind configuration"
systemctl kill -s HUP systemd-logind

log ""
log "Power button now configured to trigger hibernation!"
log "Press the power button (briefly) to hibernate the system."
log ""
log "Note: The changes take effect immediately."
log "      If you want to change this back, edit $LOGIND_CONF"
log "      and set HandlePowerKey=ignore (or poweroff, suspend, etc.)"
log "      then run: sudo systemctl kill -s HUP systemd-logind"
