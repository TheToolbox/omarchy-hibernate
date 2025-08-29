# Hibernation Setup Script for Omarchy (Btrfs + Limine)

This script automates the setup of hibernation on an Omarchy installation with a Btrfs root filesystem and the Limine bootloader.

## Overview

The script performs the following actions:

- Creates a dedicated Btrfs subvolume at `/swap`.
- Creates a swapfile within the subvolume, sized to match the system's total RAM.
- Adds a corresponding low-priority swap entry to `/etc/fstab`.
- Ensures the `resume` hook is present in the `mkinitcpio` configuration.
- Refreshes the initramfs using `limine-update`.

## Requirements

- **System:** An Omarchy installation.
- **Filesystem:** A Btrfs root filesystem.
- **Bootloader:** Limine bootloader installed and configured (`/boot/EFI/limine/limine.conf` must be present).
- **Systemd:** The `systemd-hibernate-resume-generator` must be available.
- **mkinitcpio:** The `omarchy_hooks.conf` file must be present at `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`.
- **Tools:** `btrfs-progs` (with `filesystem mkswapfile`), `sed`, `numfmt`, and `limine-update` must be installed.

## Usage

- **Real run (makes changes):**
  ```bash
  sudo ./hibernate.sh
  ```

- **Dry run (no changes, prints actions):**
  ```bash
  DRY_RUN=1 ./hibernate.sh
  ```

## Notes

- The script will not run if `/swap` or `/swap/swapfile` already exist.
- The script will abort if any non-zram swap is already active.
- The script creates timestamped backups of `/etc/fstab` and the mkinitcpio hooks file before modifying them.

## Testing Hibernation

After a successful real run, test hibernation with the following command:

```bash
systemctl hibernate
```

## Troubleshooting

- Ensure that `btrfs filesystem mkswapfile` is available (requires a recent version of `btrfs-progs`).
- If `limine-update` is missing, install and configure Limine properly or adjust the script for your boot setup.
- If your mkinitcpio hooks file path differs, update the `HOOKS_CONF_PATH` variable in `hibernate.sh`.

## Disclaimer

This script modifies system files and can potentially lead to data loss or an unbootable system. Use it at your own risk. It is highly recommended to perform a dry run and back up your data before running the script.