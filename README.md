# Hibernation Setup Script for Omarchy (Btrfs + Limine)

This script automates the complete setup of hibernation on an Omarchy installation with a Btrfs root filesystem and the Limine bootloader.

## Overview

The script performs the following actions:

- Creates a dedicated Btrfs subvolume at `/swap` (if it doesn't exist).
- Creates a hibernation swapfile (`/swap/hibernation_swapfile`) within the subvolume, sized to match the system's total RAM.
- Adds a corresponding low-priority swap entry to `/etc/fstab`.
- Ensures the `resume` hook is present in the `mkinitcpio` configuration.
- **Calculates the swap file's physical offset and configures kernel resume parameters**.
- **Updates `/etc/default/limine` with `resume` and `resume_offset` parameters**.
- Refreshes the initramfs and bootloader configuration using `limine-update`.

## ⚠️ **Important: Btrfs-Only Support**

**This script is designed exclusively for Btrfs filesystems and will NOT work with other filesystems (ext4, XFS, etc.).** It is intended specifically for Omarchy installations (as of August 29, 2025), which use Btrfs by default. The script uses Btrfs-native swapfile creation (`btrfs filesystem mkswapfile`) and automatically calculates the required `resume_offset` parameter for proper hibernation support.

If you are not using Btrfs, this script will fail during the filesystem check and you will need a different hibernation setup approach.

## Requirements

- **System:** An Omarchy installation.
- **Filesystem:** A Btrfs root filesystem.
- **Bootloader:** Limine bootloader installed and configured:
  - `/boot/EFI/limine/limine.conf` must be present
  - `/etc/default/limine` must be present for kernel cmdline configuration
- **Systemd:** The `systemd-hibernate-resume-generator` must be available.
- **mkinitcpio:** The `omarchy_hooks.conf` file must be present at `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`.
- **Tools:** `btrfs-progs` (with `filesystem mkswapfile`), `filefrag`, `sed`, `numfmt`, and `limine-update` must be installed.

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
- If a hibernation swapfile already exists but doesn't match your current RAM size, the script will prompt you to recreate it. Use `--update` to skip prompts.
- The script will abort if any non-zram swap (other than the hibernation swapfile) is active.
- The script creates timestamped backups of `/etc/fstab`, mkinitcpio hooks, and Limine configuration before modifying them.

## Post-Installation: Adding Hibernate to Menu

After running the main hibernation setup, you'll want to add a hibernate option to your Omarchy system menu:

```bash
./add-hibernate-to-menu.sh
```

This script:
- Adds a "Hibernate" option to the Omarchy system menu
- Places it after "Suspend" in the menu
- Creates a backup of the menu file before making changes

After running this, you can access hibernate from the System menu in Omarchy.

## Optional: Automatic Hibernation

To configure automatic hibernation triggers:

```bash
sudo ./configure-auto-hibernate.sh
```

This configures:
- **Suspend-then-hibernate**: After being suspended for 30 minutes, the system will hibernate
- **Lid close behavior**: Closing the lid triggers suspend-then-hibernate (hibernate after 30min)
- **Low battery hibernation**: When battery drops below 5%, the system will hibernate automatically (requires `upower`)
- **Idle suspend**: After 10 minutes of inactivity, suspend (then hibernate after 30min)

**Note**: This script is idempotent and safe to run multiple times. If you install `upower` after running the script, simply run it again to enable battery hibernation monitoring.

## Optional: Power Button Hibernation

To configure the power button to trigger hibernation:

```bash
sudo ./configure-power-button-hibernate.sh
```

After running this, pressing the power button (briefly) will hibernate the system instead of being ignored.

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