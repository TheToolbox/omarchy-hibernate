#!/usr/bin/env bash
# Safely add hibernate option to Omarchy system menu
# Usage: ./add-hibernate-to-menu.sh

set -euo pipefail

MENU_FILE="$HOME/.local/share/omarchy/bin/omarchy-menu"

function fatal() {
  echo "FATAL: $*" >&2
  exit 1
}

function log() {
  echo ">> $*"
}

# Verify the menu file exists
[[ -f "$MENU_FILE" ]] || fatal "Menu file not found: $MENU_FILE"

# Check if hibernate is already in the menu
if grep -q "Hibernate" "$MENU_FILE"; then
  log "Hibernate option already exists in the menu"
  exit 0
fi

# Check if show_system_menu function exists
if ! grep -q "show_system_menu()" "$MENU_FILE"; then
  fatal "show_system_menu function not found in $MENU_FILE"
fi

# Create backup
BACKUP_FILE="${MENU_FILE}.$(date +%Y%m%d%H%M%S).bak"
log "Creating backup: $BACKUP_FILE"
cp -a "$MENU_FILE" "$BACKUP_FILE"

# Add hibernate option to the system menu
# We'll add it after Suspend and before Relaunch
log "Adding Hibernate option to system menu"

# Find the Suspend line and add Hibernate after it
sed -i '/show_system_menu() {/,/^}$/ {
  s|\(  case \$(menu "System" ".*Suspend\)|\1\\n󰒲  Hibernate|
  /\*Suspend\*) systemctl suspend ;;/a\
  *Hibernate*) systemctl hibernate ;;
}' "$MENU_FILE"

log "Hibernate option successfully added to system menu"
log "Backup saved to: $BACKUP_FILE"
log ""
log "The hibernate option will appear in the Omarchy menu:"
log "  Open the System menu and select Hibernate"
