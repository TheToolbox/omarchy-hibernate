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

# Create battery monitoring script
cat > "$BATTERY_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Monitor battery and hibernate when it drops below 5%

set -euo pipefail

THRESHOLD=5
CHECK_INTERVAL=60  # Check every 60 seconds

while true; do
  # Get battery percentage
  BATTERY_PATH="/org/freedesktop/UPower/devices/battery_BAT1"

  if ! PERCENTAGE=$(upower -i "$BATTERY_PATH" 2>/dev/null | grep -E "percentage:" | awk '{print $2}' | tr -d '%'); then
    # If battery info unavailable, wait and retry
    sleep "$CHECK_INTERVAL"
    continue
  fi

  # Check if on AC power
  ON_AC=$(upower -i "$BATTERY_PATH" 2>/dev/null | grep -E "state:" | awk '{print $2}')

  # Only hibernate if discharging and below threshold
  if [[ "$ON_AC" == "discharging" ]] && [[ -n "$PERCENTAGE" ]] && (( $(echo "$PERCENTAGE < $THRESHOLD" | bc -l) )); then
    logger -t battery-hibernate "Battery at ${PERCENTAGE}%, hibernating now"
    systemctl hibernate
    exit 0
  fi

  sleep "$CHECK_INTERVAL"
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

# === 3. Update hypridle to use suspend-then-hibernate ===
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

# === 4. Enable and start services ===
log "Enabling battery hibernate monitor service"
systemctl daemon-reload
systemctl enable battery-hibernate-monitor.service
systemctl start battery-hibernate-monitor.service

log ""
log "Automatic hibernation configured successfully!"
log ""
log "Configuration:"
log "  - Suspend-then-hibernate: After 30 minutes of sleep"
log "  - Low battery hibernate: When battery drops below 5%"
log "  - Idle suspend: After 10 minutes of inactivity (then hibernate after 30min)"
log ""
log "To check battery monitor status: systemctl status battery-hibernate-monitor"
log "To restart hypridle: omarchy-restart-hypridle"
log ""
log "You may need to restart hypridle for idle changes to take effect."
