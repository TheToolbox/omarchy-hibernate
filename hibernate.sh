#!/usr/bin/env bash
# Prepare hibernation on Btrfs: create a dedicated subvolume and swapfile,
# add an fstab record with low priority, and refresh initramfs via limine-update.
# Usage: sudo ./hibernate.sh
#        sudo ./hibernate.sh --update
#        sudo ./hibernate.sh --help

set -euo pipefail
IFS=

UPDATE_MODE=0
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_MODE=1
fi


SUBVOL_PATH="/swap"
SWAPFILE_PATH="$SUBVOL_PATH/swapfile"
FSTAB_ENTRY="$SWAPFILE_PATH none swap defaults,pri=0 0 0"
HOOKS_CONF_PATH="/etc/mkinitcpio.conf.d/omarchy_hooks.conf"

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

# require root privileges (unless dry-run)
if (( DRY_RUN_MODE == 0 )); then
  [[ $(id -u) -ne 0 ]] && fatal "Run as root (try: sudo)."
else
  log "Dry-run: skipping root requirement"
fi

# ensure Limine configuration is present
[[ -f /boot/EFI/limine/limine.conf ]] || fatal "/boot/EFI/limine/limine.conf not found; Limine config is required."

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
    log "Would run: /usr/bin/limine-update"
  else
    maybe_exec cp -a "$HOOKS_CONF_PATH" "$hooks_backup"
    log "Backed up hooks: $hooks_backup"
    log "Injecting 'resume' into HOOKS"
    sed -ri 's/(HOOKS=\([^)]*)/\1 resume/' "$HOOKS_CONF_PATH"
    maybe_exec /usr/bin/limine-update
  fi
fi

# final check and hint
if (( DRY_RUN_MODE == 1 )); then
  log "Would show swap status with: /sbin/swapon --show"
else
  log "Swap status summary:"
  /sbin/swapon --show
fi

log "Test hibernation with: systemctl hibernate"\n\t'

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: sudo ./hibernate.sh [--update|--help]"
  echo "Prepare hibernation on Btrfs."
  echo
  echo "Commands:"
  echo "  --update   Recreate swapfile if RAM has changed"
  echo "  --help     Show this help message"
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

# require root privileges (unless dry-run)
if (( DRY_RUN_MODE == 0 )); then
  [[ $(id -u) -ne 0 ]] && fatal "Run as root (try: sudo)."
else
  log "Dry-run: skipping root requirement"
fi

# ensure Limine configuration is present
[[ -f /boot/EFI/limine/limine.conf ]] || fatal "/boot/EFI/limine/limine.conf not found; Limine config is required."

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
    log "Would run: /usr/bin/limine-update"
  else
    maybe_exec cp -a "$HOOKS_CONF_PATH" "$hooks_backup"
    log "Backed up hooks: $hooks_backup"
    log "Injecting 'resume' into HOOKS"
    sed -ri 's/(HOOKS=\([^)]*)/\1 resume/' "$HOOKS_CONF_PATH"
    maybe_exec /usr/bin/limine-update
  fi
fi

# final check and hint
if (( DRY_RUN_MODE == 1 )); then
  log "Would show swap status with: /sbin/swapon --show"
else
  log "Swap status summary:"
  /sbin/swapon --show
fi

log "Test hibernation with: systemctl hibernate"