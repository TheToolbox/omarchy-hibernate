#!/usr/bin/env bash
# Prepare hibernation on Btrfs: create a dedicated subvolume and swapfile,
# add an fstab record with low priority, configure kernel resume parameters,
# and refresh initramfs via limine-update.
# Usage: sudo ./hibernate.sh
#        sudo ./hibernate.sh --update
#        sudo ./hibernate.sh --help

set -euo pipefail
IFS=

# Show help message
if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: sudo ./hibernate.sh [--update|--verify|--help]"
  echo "Prepare hibernation on Btrfs with Limine bootloader."
  echo
  echo "This script:"
  echo "  - Creates a Btrfs swap subvolume and swapfile"
  echo "  - Adds swap entry to /etc/fstab"
  echo "  - Adds resume hook to mkinitcpio"
  echo "  - Configures kernel resume parameters"
  echo "  - Updates Limine bootloader configuration"
  echo
  echo "Commands:"
  echo "  --update   Recreate swapfile if RAM has changed"
  echo "  --verify   Verify hibernation configuration is correct"
  echo "  --help     Show this help message"
  echo
  echo "Environment:"
  echo "  DRY_RUN=1  Run in dry-run mode (no changes)"
  exit 0
fi

UPDATE_MODE=0
VERIFY_MODE=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_MODE=1
elif [[ "${1:-}" == "--verify" ]]; then
  VERIFY_MODE=1
fi

SUBVOL_PATH="/swap"
SWAPFILE_PATH="$SUBVOL_PATH/swapfile"
FSTAB_ENTRY="$SWAPFILE_PATH none swap defaults,pri=0 0 0"
HOOKS_CONF_PATH="/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
LIMINE_DEFAULTS="/etc/default/limine"

function fatal() {
  echo "FATAL: $*" >&2
  exit 1
}
function log() { echo ">> $*"; }

# Prompt user for yes/no answer
# Returns 0 for yes, 1 for no
function prompt_yes_no() {
  local prompt="$1"
  local response

  while true; do
    read -r -p "$prompt [Y/n]: " response
    case "${response,,}" in
      y|yes|"") return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer Y or N" ;;
    esac
  done
}

# detect dry-run mode (DRY_RUN=1|true|yes|on)
DRY_RUN_MODE=0
case "${DRY_RUN:-}" in
  1|true|TRUE|yes|YES|on|ON) DRY_RUN_MODE=1 ;;
esac
if (( DRY_RUN_MODE == 1 )); then
  log "Dry-run mode: no changes will be made"
fi

# === VERIFY MODE ===
if (( VERIFY_MODE == 1 )); then
  log "=========================================="
  log "Verifying hibernation configuration"
  log "=========================================="
  log ""

  ERRORS=0
  WARNINGS=0

  # Check 1: Swap subvolume exists
  if [[ -d "$SUBVOL_PATH" ]]; then
    log "✓ Swap subvolume exists: $SUBVOL_PATH"
  else
    log "✗ Swap subvolume NOT found: $SUBVOL_PATH"
    ((ERRORS++))
  fi

  # Check 2: Swapfile exists and has correct size
  if [[ -f "$SWAPFILE_PATH" ]]; then
    SWAPFILE_SIZE=$(stat -c%s "$SWAPFILE_PATH")
    RAM_BYTES=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') * 1024))

    log "✓ Swapfile exists: $SWAPFILE_PATH"
    log "  Size: $(numfmt --to=iec "$SWAPFILE_SIZE")"
    log "  RAM:  $(numfmt --to=iec "$RAM_BYTES")"

    if (( SWAPFILE_SIZE != RAM_BYTES )); then
      log "  ⚠ Warning: Swapfile size doesn't match RAM size"
      log "  Run with --update to fix"
      ((WARNINGS++))
    fi
  else
    log "✗ Swapfile NOT found: $SWAPFILE_PATH"
    ((ERRORS++))
  fi

  # Check 3: Swap is active
  if swapon --show | grep -q "$SWAPFILE_PATH"; then
    log "✓ Swap is active"
  else
    log "✗ Swap is NOT active"
    log "  Run: sudo swapon $SWAPFILE_PATH"
    ((ERRORS++))
  fi

  # Check 4: fstab entry exists
  if grep -Fq "$SWAPFILE_PATH" /etc/fstab; then
    log "✓ fstab entry exists"
  else
    log "✗ fstab entry NOT found"
    ((ERRORS++))
  fi

  # Check 5: Resume hook in mkinitcpio
  if grep -qE '^HOOKS=.*resume' "$HOOKS_CONF_PATH" 2>/dev/null; then
    log "✓ Resume hook configured in mkinitcpio"
  else
    log "✗ Resume hook NOT found in $HOOKS_CONF_PATH"
    ((ERRORS++))
  fi

  # Check 6: Kernel resume parameters (runtime check is primary)
  # First check the actual runtime configuration
  if [[ -f /sys/power/resume ]] && [[ -f /sys/power/resume_offset ]]; then
    RUNTIME_RESUME=$(cat /sys/power/resume 2>/dev/null || echo "")
    RUNTIME_OFFSET=$(cat /sys/power/resume_offset 2>/dev/null || echo "0")

    if [[ "$RUNTIME_RESUME" != "0:0" ]] && [[ "$RUNTIME_OFFSET" != "0" ]]; then
      log "✓ Kernel resume parameters active at runtime"
      log "  /sys/power/resume: $RUNTIME_RESUME"
      log "  /sys/power/resume_offset: $RUNTIME_OFFSET"

      # Verify offset matches swapfile
      if [[ -f "$SWAPFILE_PATH" ]]; then
        ACTUAL_OFFSET=$(filefrag -v "$SWAPFILE_PATH" 2>/dev/null | awk '/^ *0:/ {print $4}' | sed 's/\.\.$//' || echo "")
        if [[ -n "$ACTUAL_OFFSET" ]]; then
          if [[ "$ACTUAL_OFFSET" != "$RUNTIME_OFFSET" ]]; then
            log "  ✗ ERROR: resume_offset mismatch!"
            log "    Runtime:    $RUNTIME_OFFSET"
            log "    Swapfile:   $ACTUAL_OFFSET"
            log "    Run: sudo ./hibernate.sh --update"
            ((ERRORS++))
          else
            log "  ✓ resume_offset matches actual swapfile offset"
          fi
        fi
      fi

      # Also check if parameters are in boot config (for persistence after reboot)
      if [[ -f "$LIMINE_DEFAULTS" ]]; then
        if grep -q "resume=" "$LIMINE_DEFAULTS" && grep -q "resume_offset=" "$LIMINE_DEFAULTS"; then
          log "  ✓ Resume parameters also configured in $LIMINE_DEFAULTS (persistent)"
        else
          log "  ⚠ Warning: Resume parameters NOT in $LIMINE_DEFAULTS"
          log "    They work now but may not survive a reboot"
          log "    Re-run hibernate.sh to add them permanently"
          ((WARNINGS++))
        fi
      fi
    else
      log "✗ Kernel resume parameters NOT configured at runtime"
      log "  /sys/power/resume: $RUNTIME_RESUME"
      log "  /sys/power/resume_offset: $RUNTIME_OFFSET"
      ((ERRORS++))
    fi
  else
    log "✗ /sys/power/resume or /sys/power/resume_offset not available"
    ((ERRORS++))
  fi

  # Check 7: systemd hibernate-resume generator
  if [[ -x /usr/lib/systemd/system-generators/systemd-hibernate-resume-generator ]]; then
    log "✓ systemd hibernate-resume generator present"
  else
    log "✗ systemd hibernate-resume generator NOT found"
    ((ERRORS++))
  fi

  # Summary
  log ""
  log "=========================================="
  if (( ERRORS == 0 )); then
    log "✓ Verification PASSED"
    if (( WARNINGS > 0 )); then
      log "  ($WARNINGS warning(s))"
    fi
    log "=========================================="
    log ""
    log "Hibernation is properly configured!"
    log "Test with: systemctl hibernate"
    exit 0
  else
    log "✗ Verification FAILED"
    log "  $ERRORS error(s), $WARNINGS warning(s)"
    log "=========================================="
    log ""
    log "Please fix the errors above or re-run the setup script."
    exit 1
  fi
fi

# helper for commands that change state
maybe_exec() {
  if (( DRY_RUN_MODE == 1 )); then
    log "[dry-run] $*"
    return 0
  else
    log "Running: $*"
    "$@"
  fi
}

# Get the physical offset of the swapfile for resume
get_swapfile_offset() {
  local swapfile="$1"
  local offset

  # For Btrfs swapfiles, use the btrfs-specific tool
  # This is required because Btrfs has special offset calculation requirements
  if command -v btrfs &>/dev/null; then
    offset=$(btrfs inspect-internal map-swapfile "$swapfile" 2>/dev/null | grep "Resume offset:" | awk '{print $3}')
  fi

  # Fallback to filefrag if btrfs tool didn't work (non-Btrfs filesystems)
  if [[ -z "$offset" ]]; then
    offset=$(filefrag -v "$swapfile" | awk '/^ *0:/ {print $4}' | sed 's/\.\.$//')
  fi

  if [[ -z "$offset" ]]; then
    fatal "Could not determine swapfile offset"
  fi

  echo "$offset"
}

# Update kernel command line with resume parameters
update_kernel_cmdline() {
  local resume_device="$1"
  local resume_offset="$2"

  [[ -f "$LIMINE_DEFAULTS" ]] || fatal "$LIMINE_DEFAULTS not found"

  # Backup the file
  local backup="$LIMINE_DEFAULTS.$(date +%Y%m%d%H%M%S).bak"
  if (( DRY_RUN_MODE == 1 )); then
    log "Would back up $LIMINE_DEFAULTS to $backup"
  else
    cp -a "$LIMINE_DEFAULTS" "$backup"
    log "Backed up $LIMINE_DEFAULTS to $backup"
  fi

  # Check if resume parameters already exist
  if grep -q "resume=" "$LIMINE_DEFAULTS"; then
    log "Resume parameters already present in kernel cmdline"
    # Update existing resume parameters if they differ
    if (( DRY_RUN_MODE == 1 )); then
      log "Would update existing resume parameters if needed"
    else
      # Remove old resume parameters everywhere they might appear
      sed -i 's/ resume=[^ "]*//g; s/ resume_offset=[^ "]*//g' "$LIMINE_DEFAULTS"
      # Add them back using a separate append line (limine-update friendly)
      if ! grep -q '^KERNEL_CMDLINE\[default\]+=' "$LIMINE_DEFAULTS"; then
        # Add a new append line after the main KERNEL_CMDLINE[default] definition
        sed -i "/^KERNEL_CMDLINE\[default\]=/a KERNEL_CMDLINE[default]+=\" resume=$resume_device resume_offset=$resume_offset\"" "$LIMINE_DEFAULTS"
      else
        # Append to existing += line
        sed -i "s|^\(KERNEL_CMDLINE\[default\]+=.*\)\"|\\1 resume=$resume_device resume_offset=$resume_offset\"|" "$LIMINE_DEFAULTS"
      fi
      log "Updated resume parameters in kernel cmdline"
    fi
  else
    # Add resume parameters using the += append syntax (limine-update safe)
    if (( DRY_RUN_MODE == 1 )); then
      log "Would add resume=$resume_device resume_offset=$resume_offset to kernel cmdline"
    else
      # Check if there's already a KERNEL_CMDLINE[default]+= line
      if grep -q '^KERNEL_CMDLINE\[default\]+=' "$LIMINE_DEFAULTS"; then
        # Append to existing += line
        sed -i "s|^\(KERNEL_CMDLINE\[default\]+=.*\)\"|\\1 resume=$resume_device resume_offset=$resume_offset\"|" "$LIMINE_DEFAULTS"
      else
        # Add a new append line after the main KERNEL_CMDLINE[default] definition
        sed -i "/^KERNEL_CMDLINE\[default\]=/a KERNEL_CMDLINE[default]+=\" resume=$resume_device resume_offset=$resume_offset\"" "$LIMINE_DEFAULTS"
      fi
      log "Added resume parameters to kernel cmdline"
    fi
  fi
}

# require root privileges (unless dry-run)
if (( DRY_RUN_MODE == 0 )); then
  [[ $(id -u) -ne 0 ]] && fatal "Run as root (try: sudo)."
else
  log "Dry-run: skipping root requirement"
fi

# ensure Limine configuration is present
[[ -f /boot/EFI/limine/limine.conf ]] || fatal "/boot/EFI/limine/limine.conf not found; Limine config is required."
[[ -f "$LIMINE_DEFAULTS" ]] || fatal "$LIMINE_DEFAULTS not found; Limine defaults configuration is required."

# verify the root filesystem is Btrfs (this script only supports Btrfs)
ROOT_FSTYPE=$(findmnt -no FSTYPE /)
if [[ "$ROOT_FSTYPE" != "btrfs" ]]; then
  fatal "Root filesystem is $ROOT_FSTYPE, but this script only supports Btrfs filesystems. For other filesystems, you need a different hibernation setup approach with resume_offset configuration."
fi

# determine total RAM to size swapfile equally
RAM_BYTES=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') * 1024))
SWAP_BYTES="${RAM_BYTES}B"

# === Pre-flight checks ===
log "Running pre-flight checks"

# Check 1: Available disk space
ROOT_MOUNTPOINT=$(findmnt -no TARGET /)
AVAILABLE_BYTES=$(df --output=avail -B1 "$ROOT_MOUNTPOINT" | tail -n1)

# Need at least RAM size + 10% buffer for the swapfile
REQUIRED_BYTES=$(( RAM_BYTES + RAM_BYTES / 10 ))

if (( AVAILABLE_BYTES < REQUIRED_BYTES )); then
  log "Warning: Low disk space detected"
  log "  Available: $(numfmt --to=iec "$AVAILABLE_BYTES")"
  log "  Required:  $(numfmt --to=iec "$REQUIRED_BYTES")"
  fatal "Insufficient disk space. Need at least $(numfmt --to=iec "$REQUIRED_BYTES") free."
fi
log "Disk space check: OK ($(numfmt --to=iec "$AVAILABLE_BYTES") available)"

# Check 2: Kernel hibernation support
if [[ ! -f /sys/power/state ]]; then
  fatal "Kernel does not appear to support power management (/sys/power/state not found)"
fi

if ! grep -q "disk" /sys/power/state; then
  fatal "Kernel does not support hibernation (disk state not available in /sys/power/state)"
fi
log "Kernel hibernation support: OK"

# Check 3: btrfs mkswapfile command availability
if ! btrfs filesystem mkswapfile --help &>/dev/null; then
  fatal "btrfs filesystem mkswapfile command not available. Update btrfs-progs to a newer version."
fi
log "Btrfs swapfile support: OK"

if (( UPDATE_MODE == 1 )); then
  log "Update mode enabled"
  [[ -e "$SWAPFILE_PATH" ]] || fatal "$SWAPFILE_PATH does not exist. Cannot update."

  # get current swapfile size
  SWAPFILE_CURRENT_BYTES=$(stat -c%s "$SWAPFILE_PATH")

  NEED_SWAPFILE_UPDATE=0
  if (( SWAPFILE_CURRENT_BYTES != RAM_BYTES )); then
    log "Swapfile size ($(numfmt --to=iec "$SWAPFILE_CURRENT_BYTES")) does not match RAM size ($(numfmt --to=iec "$RAM_BYTES")). Will recreate."
    NEED_SWAPFILE_UPDATE=1
  else
    log "Swapfile size ($(numfmt --to=iec "$SWAPFILE_CURRENT_BYTES")) already matches RAM size."
  fi

  if (( NEED_SWAPFILE_UPDATE == 1 )); then
    log "Turning off swap"
    maybe_exec swapoff "$SWAPFILE_PATH"

    log "Removing old swapfile"
    maybe_exec rm "$SWAPFILE_PATH"

    log "Creating new swapfile of size $(numfmt --to=iec "$RAM_BYTES")"
    maybe_exec btrfs filesystem mkswapfile -s "$SWAP_BYTES" "$SWAPFILE_PATH" || fatal "Failed to create Btrfs swapfile"
  fi

else
  # refuse to proceed if targets already exist
  [[ ! -e "$SUBVOL_PATH" ]] || fatal "$SUBVOL_PATH already exists."
  [[ ! -e "$SWAPFILE_PATH" ]] || fatal "$SWAPFILE_PATH already exists."

  # ensure no non-zram swap is currently active
  if swapon --noheadings --raw --bytes | grep -v '^/dev/zram' | grep -q .; then
    fatal "Detected active swap (non-zram)."
  fi

  # create dedicated Btrfs subvolume
  log "Creating Btrfs subvolume at $SUBVOL_PATH"
  maybe_exec btrfs subvolume create "$SUBVOL_PATH" || fatal "Could not create Btrfs subvolume $SUBVOL_PATH"

  # create Btrfs-native swapfile sized to RAM
  log "Creating swapfile of size $(numfmt --to=iec "$RAM_BYTES")"
  maybe_exec btrfs filesystem mkswapfile -s "$SWAP_BYTES" "$SWAPFILE_PATH" || fatal "Failed to create Btrfs swapfile"
fi

# confirm systemd hibernate-resume generator is available
[[ -x /usr/lib/systemd/system-generators/systemd-hibernate-resume-generator ]] || fatal "systemd-hibernate-resume-generator missing; hibernation support required."
log "Found systemd-hibernate-resume generator"

# mkinitcpio hooks config must exist
[[ -f "$HOOKS_CONF_PATH" ]] || fatal "$HOOKS_CONF_PATH not found (required)."

# enable swap now with a low priority (skip if already active)
if swapon --show | grep -q "$SWAPFILE_PATH"; then
  log "Swap already active"
else
  log "Enabling swap (priority 0)"
  maybe_exec /sbin/swapon -p 0 "$SWAPFILE_PATH"
fi

# add fstab record if missing
if ! grep -Fq "$SWAPFILE_PATH" /etc/fstab; then
  FSTAB_BAK="/etc/fstab.$(date +%Y%m%d%H%M%S).bak"
  if (( DRY_RUN_MODE == 1 )); then
    log "Would back up /etc/fstab to $FSTAB_BAK"
    log "Would append the following to /etc/fstab:"
    printf '\n# Swapfile (Btrfs) for hibernation support\n%s\n' "$FSTAB_ENTRY"
  else
    log "Backing up /etc/fstab"
    maybe_exec cp -a /etc/fstab "$FSTAB_BAK"
    log "Appending swap entry to /etc/fstab"
    printf '\n# Swapfile (Btrfs) for hibernation support\n%s\n' "$FSTAB_ENTRY" >>/etc/fstab
  fi
else
  log "fstab already contains this swapfile entry"
fi

# ensure the 'resume' hook is present, then rebuild initramfs
hooks_current=$(grep -E '^HOOKS=' "$HOOKS_CONF_PATH" || true)
if [[ -n "$hooks_current" && ! $hooks_current =~ resume ]]; then
  # timestamped backup of hooks file
  hooks_backup="$HOOKS_CONF_PATH.$(date +%Y%m%d%H%M%S).bak"
  if (( DRY_RUN_MODE == 1 )); then
    log "Would back up hooks to: $hooks_backup"
    log "Would inject 'resume' into HOOKS in $HOOKS_CONF_PATH"
  else
    maybe_exec cp -a "$HOOKS_CONF_PATH" "$hooks_backup"
    log "Backed up hooks: $hooks_backup"
    log "Injecting 'resume' into HOOKS"
    sed -ri 's/(HOOKS=\([^)]*)/\1 resume/' "$HOOKS_CONF_PATH"
  fi
else
  log "Resume hook already present or hooks not configured"
fi

# Calculate swap offset and update kernel cmdline
log "Calculating swapfile offset"
SWAP_OFFSET=$(get_swapfile_offset "$SWAPFILE_PATH")
log "Swapfile offset: $SWAP_OFFSET"

# Determine resume device (encrypted root)
RESUME_DEVICE="/dev/mapper/root"
log "Resume device: $RESUME_DEVICE"

# Update kernel cmdline with resume parameters
log "Updating kernel command line with resume parameters"
update_kernel_cmdline "$RESUME_DEVICE" "$SWAP_OFFSET"

# Rebuild initramfs with limine-update
log "Rebuilding initramfs and updating bootloader"
maybe_exec /usr/bin/limine-update

# final check and hint
if (( DRY_RUN_MODE == 1 )); then
  log "Would show swap status with: /sbin/swapon --show"
else
  log "Swap status summary:"
  /sbin/swapon --show
fi

log ""
log "=========================================="
log "Hibernation setup complete!"
log "=========================================="
log ""

# Skip prompts in dry-run mode
if (( DRY_RUN_MODE == 1 )); then
  log "Dry-run mode: Skipping post-installation prompts"
  log ""
  log "After a real run, you can:"
  log "  1. Add hibernate to Omarchy menu: ./add-hibernate-to-menu.sh"
  log "  2. Configure automatic hibernation: sudo ./configure-auto-hibernate.sh"
  log "  3. Configure power button to hibernate: sudo ./configure-power-button-hibernate.sh"
  exit 0
fi

# Prompt for menu integration
log ""
if prompt_yes_no "Add hibernate option to Omarchy system menu?"; then
  log ""
  if [[ -f "./add-hibernate-to-menu.sh" ]]; then
    log "Running add-hibernate-to-menu.sh..."
    if ./add-hibernate-to-menu.sh; then
      log "Menu integration successful!"
    else
      log "Warning: Menu integration failed. You can run ./add-hibernate-to-menu.sh manually later."
    fi
  else
    log "Warning: add-hibernate-to-menu.sh not found in current directory"
  fi
else
  log "Skipped. You can run ./add-hibernate-to-menu.sh later."
fi

# Prompt for automatic hibernation
log ""
if prompt_yes_no "Configure automatic hibernation (suspend-then-hibernate, low battery)?"; then
  log ""
  if [[ -f "./configure-auto-hibernate.sh" ]]; then
    log "Running configure-auto-hibernate.sh..."
    if bash ./configure-auto-hibernate.sh; then
      log "Automatic hibernation configured!"
    else
      log "Warning: Auto-hibernation setup failed. You can run sudo ./configure-auto-hibernate.sh manually later."
    fi
  else
    log "Warning: configure-auto-hibernate.sh not found in current directory"
  fi
else
  log "Skipped. You can run sudo ./configure-auto-hibernate.sh later."
fi

# Prompt for power button configuration
log ""
if prompt_yes_no "Configure power button to trigger hibernation?"; then
  log ""
  if [[ -f "./configure-power-button-hibernate.sh" ]]; then
    log "Running configure-power-button-hibernate.sh..."
    if bash ./configure-power-button-hibernate.sh; then
      log "Power button configured!"
    else
      log "Warning: Power button setup failed. You can run sudo ./configure-power-button-hibernate.sh manually later."
    fi
  else
    log "Warning: configure-power-button-hibernate.sh not found in current directory"
  fi
else
  log "Skipped. You can run sudo ./configure-power-button-hibernate.sh later."
fi

log ""
log "=========================================="
log "Setup complete!"
log "=========================================="
log ""
log "Test hibernation with: systemctl hibernate"
log "Or open the System menu and select Hibernate"
