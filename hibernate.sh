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
  echo "Usage: sudo ./hibernate.sh [--update|--help]"
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
  echo "  --help     Show this help message"
  echo
  echo "Environment:"
  echo "  DRY_RUN=1  Run in dry-run mode (no changes)"
  exit 0
fi

UPDATE_MODE=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_MODE=1
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

# detect dry-run mode (DRY_RUN=1|true|yes|on)
DRY_RUN_MODE=0
case "${DRY_RUN:-}" in
  1|true|TRUE|yes|YES|on|ON) DRY_RUN_MODE=1 ;; 
esac
if (( DRY_RUN_MODE == 1 )); then
  log "Dry-run mode: no changes will be made"
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
  
  # Get the physical offset using filefrag
  offset=$(filefrag -v "$swapfile" | awk '/^ *0:/ {print $4}' | sed 's/\.\.$//')
  
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
      # Remove old resume parameters and add new ones
      sed -i 's/ resume=[^ ]*//g; s/ resume_offset=[^ ]*//g' "$LIMINE_DEFAULTS"
      sed -i "/^KERNEL_CMDLINE\[default\]=/ s|\"$| resume=$resume_device resume_offset=$resume_offset\"|" "$LIMINE_DEFAULTS"
      log "Updated resume parameters in kernel cmdline"
    fi
  else
    # Add resume parameters to kernel cmdline
    if (( DRY_RUN_MODE == 1 )); then
      log "Would add resume=$resume_device resume_offset=$resume_offset to kernel cmdline"
    else
      # Find the KERNEL_CMDLINE[default] line and append resume parameters
      sed -i "/^KERNEL_CMDLINE\[default\]=/ s|\"$| resume=$resume_device resume_offset=$resume_offset\"|" "$LIMINE_DEFAULTS"
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

if (( UPDATE_MODE == 1 )); then
  log "Update mode enabled"
  [[ -e "$SWAPFILE_PATH" ]] || fatal "$SWAPFILE_PATH does not exist. Cannot update."

  # get current swapfile size
  SWAPFILE_CURRENT_BYTES=$(stat -c%s "$SWAPFILE_PATH")
  
  if (( SWAPFILE_CURRENT_BYTES == RAM_BYTES )); then
    log "Swapfile size ($(numfmt --to=iec "$SWAPFILE_CURRENT_BYTES")) already matches RAM size. Nothing to do."
    exit 0
  fi

  log "Swapfile size ($(numfmt --to=iec "$SWAPFILE_CURRENT_BYTES")) does not match RAM size ($(numfmt --to=iec "$RAM_BYTES")). Recreating."

  log "Turning off swap"
  maybe_exec swapoff "$SWAPFILE_PATH"

  log "Removing old swapfile"
  maybe_exec rm "$SWAPFILE_PATH"

  log "Creating new swapfile of size $(numfmt --to=iec "$RAM_BYTES")"
  maybe_exec btrfs filesystem mkswapfile -s "$SWAP_BYTES" "$SWAPFILE_PATH" || fatal "Failed to create Btrfs swapfile"

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

# enable swap now with a low priority
log "Enabling swap (priority 0)"
maybe_exec /sbin/swapon -p 0 "$SWAPFILE_PATH"

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

log "Hibernation setup complete!"
log "Test hibernation with: systemctl hibernate"