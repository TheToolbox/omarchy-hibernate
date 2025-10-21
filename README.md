# Hibernation Setup Script for Omarchy (Btrfs + Limine)

This script automates the complete setup of hibernation on an Omarchy installation with a Btrfs root filesystem and the Limine bootloader.

## Overview

The script sets up complete hibernation support in one run:

- Creates a dedicated Btrfs subvolume at `/swap` (if it doesn't exist)
- Creates a hibernation swapfile (`/swap/hibernation_swapfile`) sized to match your RAM
- Adds swap entry to `/etc/fstab` and ensures `resume` hook in mkinitcpio
- Calculates swap file offset and configures kernel resume parameters
- Updates `/etc/default/limine` with `resume` and `resume_offset` parameters
- Refreshes initramfs and bootloader configuration

Optional Features (prompted during configuration):
- System menu integration (adds "Hibernate" option)
- Automatic hibernation (suspend-then-hibernate after 30 min, lid-close behavior, low battery)
- Power button hibernation

## ⚠️ **Important: Btrfs-Only Support**

**This script is designed exclusively for Btrfs filesystems and will NOT work with other filesystems (ext4, XFS, etc.).** It is intended specifically for Omarchy installations (as of August 29, 2025), which use Btrfs by default. The script uses Btrfs-native swapfile creation (`btrfs filesystem mkswapfile`) and automatically calculates the required `resume_offset` parameter for proper hibernation support.

If you are not using Btrfs, this script will fail during the filesystem check and you will need a different hibernation setup approach.

## Requirements

**Required:**
- **System:** An Omarchy installation
- **Filesystem:** Btrfs root filesystem
- **Bootloader:** Limine bootloader installed and configured:
  - `/boot/EFI/limine/limine.conf` must be present
  - `/etc/default/limine` must be present for kernel cmdline configuration
- **Systemd:** The `systemd-hibernate-resume-generator` must be available
- **mkinitcpio:** The `omarchy_hooks.conf` file must be present at `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`
- **Tools:** `btrfs-progs` (with `filesystem mkswapfile`), `filefrag`, `sed`, `numfmt`, and `limine-update`

**Optional (for automatic hibernation features):**
- `upower` - Required for battery level monitoring and low-battery hibernation

## Usage

- **Real run (makes changes):**
  ```bash
  sudo ./hibernate.sh
  ```

- **Dry run (no changes, prints actions):**
  ```bash
  DRY_RUN=1 ./hibernate.sh
  ```

- **Updating the swapfile:**
  If you change the amount of RAM in your system, simply re-run the script. It will detect the size mismatch and prompt you to recreate the swapfile:
  ```bash
  sudo ./hibernate.sh
  ```

  To skip the prompt and force recreation (useful for scripts):
  ```bash
  sudo ./hibernate.sh --update
  ```

- **Getting help:**
  To see the available commands, use the `--help` flag:
  ```bash
  ./hibernate.sh --help
  ```


## Notes

- The script is **idempotent** - safe to run multiple times. If hibernation is already configured, it will verify and update the configuration as needed.
- The script creates timestamped backups of `/etc/fstab`, mkinitcpio hooks, and Limine configuration before modifying them.
- During the setup, you'll be prompted for optional features (menu integration, automatic hibernation, power button). You can decline any of these and run the individual scripts later if needed.

## Testing Hibernation

After a successful real run, test hibernation with the following command:

```bash
systemctl hibernate
```

Or open the System menu in Omarchy and select Hibernate.

## Troubleshooting

- Ensure that `btrfs filesystem mkswapfile` is available (requires a recent version of `btrfs-progs`).
- If `limine-update` is missing, install and configure Limine properly or adjust the script for your boot setup.
- If your mkinitcpio hooks file path differs, update the `HOOKS_CONF_PATH` variable in `hibernate.sh`.

## Disclaimer

This script modifies system files and can potentially lead to data loss or an unbootable system. Use it at your own risk. It is highly recommended to perform a dry run and back up your data before running the script.