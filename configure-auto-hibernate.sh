#!/usr/bin/env bash
# Configure automatic hibernation for Omarchy
# - Hibernate after 30 minutes of sleep
# - Hibernate when battery drops below 5%
# Usage: sudo ./configure-auto-hibernate.sh

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

# === 1. Configure suspend-then-hibernate ===
log "Configuring suspend-then-hibernate after 30 minutes of sleep"

SLEEP_CONF_DIR="/etc/systemd/sleep.conf.d"
SLEEP_CONF="$SLEEP_CONF_DIR/10-hibernate.conf"

# Create directory if it doesn't exist
mkdir -p "$SLEEP_CONF_DIR"

# Create sleep configuration
cat > "$SLEEP_CONF" <<'EOF'
# Hibernate after being suspended for 30 minutes
[Sleep]
AllowSuspendThenHibernate=yes
HibernateDelaySec=30min
EOF

log "Created $SLEEP_CONF"

# === 2. Configure low battery hibernation ===
log "Configuring hibernation on low battery (<5%)"

BATTERY_SCRIPT="/usr/local/bin/battery-hibernate-monitor"
BATTERY_SERVICE="/etc/systemd/system/battery-hibernate-monitor.service"

# Check if upower is available
if ! command -v upower >/dev/null 2>&1; then
  log "Warning: upower not found. Skipping battery hibernation setup."
  log "Install upower package if you want low battery hibernation."
else
  # Auto-detect battery device
  log "Auto-detecting battery device"
  BATTERY_DEVICE=""

  # Use upower to enumerate battery devices and find one with a valid native-path
  for bat in $(upower -e | grep battery); do
  NATIVE_PATH=$(upower -i "$bat" 2>/dev/null | grep "native-path:" | awk '{print $2}')
  if [[ -n "$NATIVE_PATH" ]] && [[ "$NATIVE_PATH" != "(null)" ]]; then
    BATTERY_DEVICE="$bat"
    log "Found battery device: $BATTERY_DEVICE (native: $NATIVE_PATH)"
    break
  fi
done

  if [[ -z "$BATTERY_DEVICE" ]]; then
    log "Warning: No battery device found. Low battery hibernation will be disabled."
    log "This is normal for desktop systems without a battery."
    BATTERY_DEVICE="/org/freedesktop/UPower/devices/battery_BAT1"
    log "Using fallback path (may be inactive): $BATTERY_DEVICE"
  fi

  # Create battery monitoring script with detected device
  cat > "$BATTERY_SCRIPT" <<EOF
#!/usr/bin/env bash
# Monitor battery and hibernate when it drops below 5%

set -euo pipefail

THRESHOLD=5
CHECK_INTERVAL=60  # Check every 60 seconds
BATTERY_PATH="$BATTERY_DEVICE"

while true; do
  # Get battery percentage
  if ! PERCENTAGE=\$(upower -i "\$BATTERY_PATH" 2>/dev/null | grep -E "percentage:" | awk '{print \$2}' | tr -d '%'); then
    # If battery info unavailable, wait and retry
    sleep "\$CHECK_INTERVAL"
    continue
  fi

  # Check if on AC power
  ON_AC=\$(upower -i "\$BATTERY_PATH" 2>/dev/null | grep -E "state:" | awk '{print \$2}')

  # Only hibernate if discharging and below threshold
  # Use bash arithmetic (convert percentage to integer for comparison)
  if [[ "\$ON_AC" == "discharging" ]] && [[ -n "\$PERCENTAGE" ]] && (( \${PERCENTAGE%.*} < \$THRESHOLD )); then
    logger -t battery-hibernate "Battery at \${PERCENTAGE}%, hibernating now"
    systemctl hibernate
    exit 0
  fi

  sleep "\$CHECK_INTERVAL"
done
EOF

  chmod +x "$BATTERY_SCRIPT"
  log "Created $BATTERY_SCRIPT"

  # Create systemd service
  cat > "$BATTERY_SERVICE" <<'EOF'
[Unit]
Description=Battery Hibernate Monitor
After=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/battery-hibernate-monitor
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  log "Created $BATTERY_SERVICE"
fi

# === 3. Configure lid switch to use suspend-then-hibernate ===
log "Configuring lid switch to use suspend-then-hibernate"

LOGIND_CONF_DIR="/etc/systemd/logind.conf.d"
LOGIND_CONF="$LOGIND_CONF_DIR/10-lid-hibernate.conf"

# Create directory if it doesn't exist
mkdir -p "$LOGIND_CONF_DIR"

# Create logind configuration
cat > "$LOGIND_CONF" <<'EOF'
# Use suspend-then-hibernate when lid is closed
# This ensures the 30-minute hibernate delay triggers even when closing the lid
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
EOF

log "Created $LOGIND_CONF"

# === 4. Update hypridle to use suspend-then-hibernate ===
log "Updating hypridle configuration to use suspend-then-hibernate"

# Determine the actual user's home directory
if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  USER_HOME="$HOME"
fi

HYPRIDLE_CONF="$USER_HOME/.config/hypr/hypridle.conf"

# Check if hypridle config exists
if [[ ! -f "$HYPRIDLE_CONF" ]]; then
  log "Warning: hypridle.conf not found at $HYPRIDLE_CONF"
  log "Skipping hypridle configuration. You can manually add:"
  log "  listener {"
  log "      timeout = 600"
  log "      on-timeout = systemctl suspend-then-hibernate"
  log "  }"
else
  # Check if hypridle already has a suspend listener
  if ! grep -q "systemctl suspend-then-hibernate" "$HYPRIDLE_CONF"; then
    # Add suspend-then-hibernate listener after 10 minutes of idle
    cat >> "$HYPRIDLE_CONF" <<'EOF'

listener {
    timeout = 600                                         # 10min
    on-timeout = systemctl suspend-then-hibernate         # suspend, then hibernate after 30min
}
EOF

    # Fix ownership if running via sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
      chown "$SUDO_USER:$SUDO_USER" "$HYPRIDLE_CONF"
    fi

    log "Added suspend-then-hibernate listener to hypridle.conf"
  else
    log "hypridle.conf already has suspend-then-hibernate configured"
  fi
fi

# === 5. Enable and start services ===
systemctl daemon-reload

# Only enable battery monitor if upower is available
if command -v upower >/dev/null 2>&1; then
  log "Enabling battery hibernate monitor service"
  systemctl enable battery-hibernate-monitor.service
  # Start the service, but don't fail the script if it fails to start
  # (it might fail on first run but work after reboot)
  systemctl start battery-hibernate-monitor.service || log "Warning: Failed to start battery monitor (may need reboot)"
fi

log ""
log "Automatic hibernation configured successfully!"
log ""
log "Configuration:"
log "  - Suspend-then-hibernate: After 30 minutes of sleep"
log "  - Lid close behavior: suspend-then-hibernate (hibernate after 30min)"
if command -v upower >/dev/null 2>&1; then
  log "  - Low battery hibernate: When battery drops below 5%"
fi
log "  - Idle suspend: After 10 minutes of inactivity (then hibernate after 30min)"
log ""
if command -v upower >/dev/null 2>&1; then
  log "To check battery monitor status: systemctl status battery-hibernate-monitor"
fi
log "To restart hypridle: omarchy-restart-hypridle"
log ""
log "Note: Logind changes take effect immediately for new lid close events."
log "You may need to restart hypridle for idle changes to take effect."
