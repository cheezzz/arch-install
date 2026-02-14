# Arch Linux Install Automation — Implementation Plan

## Overview

A hybrid bash + Ansible approach to fully automate an Arch Linux install.
The entire project lives in one git repository. The operator boots the Arch
ISO, clones the repo, runs a bootstrap script, then hands off to Ansible
inside arch-chroot for the rest of the setup.

---

## Repository Structure

```
arch-install/
├── bootstrap.sh
├── ansible/
│   ├── playbook.yml
│   ├── vars/
│   │   └── main.yml
│   └── roles/
│       ├── base/
│       ├── bootloader/
│       ├── snapshots/
│       ├── audio/
│       ├── desktop/
│       └── packages/
└── README.md
```

---

## System Specifications

| Setting         | Value                    |
|-----------------|--------------------------|
| Disk            | /dev/nvme0n1             |
| Boot mode       | UEFI                     |
| CPU             | Intel (needs ucode)      |
| GPU             | NVIDIA (nvidia-open)     |
| RAM             | 32GB                     |
| Username        | johlan                   |
| Hostname        | linux                    |
| Timezone        | Africa/Johannesburg      |
| Locale          | en_ZA.UTF-8              |
| Keymap          | us                       |
| Network         | Wired only               |
| Display manager | LightDM (autologin)      |
| Desktop         | Cinnamon                 |
| Display server  | Xorg                     |
| Audio           | PipeWire                 |

---

## Partition Layout

| Partition      | Size      | Filesystem | Mount      | Notes                          |
|----------------|-----------|------------|------------|--------------------------------|
| /dev/nvme0n1p1 | 1GB       | FAT32      | /boot/efi  | EFI system partition           |
| /dev/nvme0n1p2 | Remainder | Btrfs      | /          | Root, no swap partition (zram) |

No swap partition. zram handles swap in RAM given 32GB.

### Btrfs Subvolume Layout (root partition)

| Subvolume  | Mount Point | Notes                                  |
|------------|-------------|----------------------------------------|
| @          | /           | Root                                   |
| @snapshots | /.snapshots | Managed by snapper                     |
| @var_log   | /var/log    | Excluded from rollbacks                |

### /home (separate drive — DO NOT TOUCH)

The /home directory lives on a separate physical drive and already has
an @home subvolume. The bootstrap script must mount it but must never
format, partition, or modify it in any way. The Ansible playbook must
not write to or alter /home either.

---

## bootstrap.sh — Requirements

This script runs on the live Arch ISO as root.

### Steps in order:

1. **Validate prerequisites**
   - Confirm UEFI mode (`/sys/firmware/efi/efivars` exists)
   - Confirm target disk `/dev/nvme0n1` exists
   - Confirm internet connectivity
   - Prompt operator to confirm disk wipe before proceeding

2. **Partition /dev/nvme0n1**
   - Wipe existing partition table
   - Create GPT partition table
   - Partition 1: 1GB, type EFI System
   - Partition 2: Remainder, type Linux filesystem

3. **Format partitions**
   - `/dev/nvme0n1p1`: `mkfs.fat -F32`
   - `/dev/nvme0n1p2`: `mkfs.btrfs -f`

4. **Create Btrfs subvolumes on /dev/nvme0n1p2**
   - Mount root partition temporarily to /mnt
   - Create: `@`, `@snapshots`, `@var_log`
   - Unmount

5. **Mount subvolumes**
   - Mount `@` to `/mnt` with options: `compress=zstd:1,noatime,space_cache=v2,ssd`
   - Create mount points: `/mnt/boot/efi`, `/mnt/.snapshots`, `/mnt/var/log`, `/mnt/home`
   - Mount `@snapshots` to `/mnt/.snapshots`
   - Mount `@var_log` to `/mnt/var/log`
   - Mount `/dev/nvme0n1p1` to `/mnt/boot/efi`
   - Mount the @home subvolume from the separate /home drive to `/mnt/home`
     with options: `compress=zstd:1,noatime,space_cache=v2,ssd,subvol=@home`
     (Read `home_device` from `ansible/vars/main.yml` using:
     `grep '^home_device:' ansible/vars/main.yml | awk '{print $2}'`
     — abort with a clear error if the value is still `/dev/sdX` or empty)

6. **Pacstrap base system**
   ```
   base base-devel linux linux-headers linux-firmware
   intel-ucode btrfs-progs ansible git
   ```

7. **Generate fstab**
   - `genfstab -U /mnt >> /mnt/etc/fstab`

8. **Copy repo into chroot**
   - Copy the entire repo to `/mnt/root/arch-install/`

9. **Print next steps and exit**
    - Tell operator to run:
      ```
      arch-chroot /mnt
      cd /root/arch-install
      ansible-playbook -i localhost, ansible/playbook.yml
      ```

---

## vars/main.yml — All Configuration

Everything configurable must live here. No hardcoded values anywhere
in roles or playbook.yml. The vars file should include at minimum:

```yaml
disk: /dev/nvme0n1
home_device: /dev/sdX          # operator fills this in before running
hostname: linux
username: johlan
timezone: Africa/Johannesburg
locale: en_ZA.UTF-8
keymap: us
autologin: true
aur_helper: paru
```

---

## Ansible Playbook — roles/base

Target: localhost (running inside arch-chroot)

Tasks:
- Set timezone (`ln -sf /usr/share/zoneinfo/{{ timezone }} /etc/localtime`)
- Run `hwclock --systohc`
- Configure `/etc/locale.gen` and run `locale-gen`
- Set `LANG` in `/etc/locale.conf`
- Set keymap in `/etc/vconsole.conf`
- Set hostname in `/etc/hostname`
- Configure `/etc/hosts`:
  ```
  127.0.0.1  localhost
  ::1        localhost
  127.0.1.1  {{ hostname }}.localdomain  {{ hostname }}
  ```
- Set root password (use `user_password` from `vars_prompt`, do not hardcode)
- Create user `{{ username }}`:
  - Add to groups: `wheel`
  - Shell: `/bin/bash`
  - Create home directory (already exists on separate drive, use `--no-create-home`)
- Set user password (same `user_password`)
- Configure sudo:
  - Uncomment `%wheel ALL=(ALL:ALL) ALL` in `/etc/sudoers` using `visudo`/`lineinfile`
  - Do NOT use NOPASSWD
- Enable NetworkManager service

Packages to install in this role:
```
networkmanager sudo
```

---

## Ansible Playbook — roles/bootloader

Tasks:
- Install packages: `grub efibootmgr grub-btrfs`
- Run `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB`
- Update `/etc/default/grub`:
  - Ensure `GRUB_CMDLINE_LINUX` includes `rootflags=subvol=@ nvidia-drm.modeset=1`
  - Enable `GRUB_DISABLE_SUBMENU=y` (cleaner snapshot menu)
- Run `grub-mkconfig -o /boot/grub/grub.cfg`
- Enable `grub-btrfsd` service (watches for new snapshots and updates GRUB menu)

---

## Ansible Playbook — roles/snapshots

Tasks:
- Install packages: `snapper snap-pac`
- Create snapper config for root:
  `snapper -c root create-config /`
- Fix snapper's auto-created subvolume (conflicts with our @snapshots):
  - `btrfs subvolume delete /.snapshots`
  - `mkdir /.snapshots`
  - `mount -o subvol=@snapshots,compress=zstd:1,noatime,space_cache=v2,ssd /dev/nvme0n1p2 /.snapshots`
    (use `{{ disk }}p2` from vars)
- Configure snapper timeline in `/etc/snapper/configs/root`:
  - `TIMELINE_CREATE="yes"`
  - `TIMELINE_CLEANUP="yes"`
  - `NUMBER_LIMIT="10"`
  - `TIMELINE_LIMIT_HOURLY="5"`
  - `TIMELINE_LIMIT_DAILY="7"`
  - `TIMELINE_LIMIT_WEEKLY="2"`
  - `TIMELINE_LIMIT_MONTHLY="1"`
- Enable services:
  - `snapper-timeline.timer`
  - `snapper-cleanup.timer`

Note: snap-pac automatically creates pre/post snapshots around every
pacman transaction — no additional config needed.

---

## Ansible Playbook — roles/audio

Tasks:
- Install packages:
  ```
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
  ```
- PipeWire services are socket-activated on Arch and start automatically
  on user login — no explicit enable step needed

---

## Ansible Playbook — roles/desktop

Tasks:
- Install Xorg:
  ```
  xorg-server xorg-xinit xorg-xrandr
  ```
- Install NVIDIA drivers:
  ```
  nvidia-open nvidia-utils nvidia-settings
  ```
- Configure NVIDIA early KMS:
  - Add `nvidia nvidia_modeset nvidia_uvm nvidia_drm` to the `MODULES` array
    in `/etc/mkinitcpio.conf`
  - Run `mkinitcpio -P`
- Install Cinnamon and supporting packages:
  ```
  cinnamon nemo nemo-fileroller
  lightdm lightdm-gtk-greeter
  ```
- Configure LightDM autologin:
  - Create group `autologin` if it doesn't exist
  - Add `{{ username }}` to the `autologin` group
  - Edit `/etc/lightdm/lightdm.conf` under the `[Seat:*]` section:
    - Set `autologin-user={{ username }}`
    - Set `autologin-session=cinnamon`
- Enable `lightdm` service

---

## Ansible Playbook — roles/packages

Tasks:
- Configure pacman:
  - Enable `Color` and `ParallelDownloads = 10` in `/etc/pacman.conf`
  - Enable `[multilib]` repo
- Install zram:
  ```
  zram-generator
  ```
  - Create `/etc/systemd/zram-generator.conf`:
    ```ini
    [zram0]
    zram-size = ram / 2
    compression-algorithm = zstd
    ```
- Install fonts:
  ```
  inter-font noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd
  ```
- Configure fontconfig for macOS-like font rendering:
  - Create `/etc/fonts/local.conf`:
    - Antialiasing: enabled
    - Hinting: enabled, hintstyle: hintslight
    - Subpixel rendering: rgb
    - LCD filter: lcddefault
  - Set default font families:
    - sans-serif: Inter
    - monospace: JetBrains Mono Nerd Font
- Install common tools:
  ```
  git curl wget htop btop bash-completion
  gvfs gvfs-smb ntfs-3g
  xdg-user-dirs xdg-utils
  jq tree vim kitty
  ```
- Install applications:
  ```
  libreoffice-fresh celluloid
  file-roller p7zip unzip zip
  ```
- Install AUR helper (paru):
  - Clone `https://aur.archlinux.org/paru.git` as `{{ username }}`
  - Build and install with `makepkg -si`
- Install dev tools (via pacman):
  ```
  aws-cli-v2 uv bun
  ```
- Install Claude Code:
  - Run as `{{ username }}`: `curl -fsSL https://claude.ai/install.sh | bash`
- Install Flatpak and apps:
  ```
  flatpak
  ```
  - Enable Flathub: `flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo`
  - Install Flatpak apps:
    ```
    app.zen_browser.zen
    com.bitwarden.desktop
    md.obsidian.Obsidian
    org.telegram.desktop
    org.zulip.Zulip
    org.localsend.localsend_app
    ```
- Wrangler is used via `bunx wrangler` — no global install needed

---

## playbook.yml — Role Order

```yaml
- hosts: localhost
  connection: local
  become: true
  vars_files:
    - vars/main.yml
  vars_prompt:
    - name: user_password
      prompt: "Password (used for both root and {{ username }})"
      private: true
      confirm: true
  roles:
    - base
    - bootloader
    - snapshots
    - audio
    - desktop
    - packages
```

---

## README.md — Operator Instructions

The README must document the full process clearly:

1. Boot Arch ISO
2. Connect ethernet
3. `git clone <repo-url>`
4. `cd arch-install`
5. Edit `ansible/vars/main.yml` — set `home_device` to the correct device path
6. `bash bootstrap.sh`
7. `arch-chroot /mnt`
8. `cd /root/arch-install`
9. `ansible-playbook -i localhost, ansible/playbook.yml`
10. Enter password when prompted (used for both root and user)
11. When playbook completes: `exit`, `umount -R /mnt`, `reboot`

---

## Important Constraints for the Agent

- Never format, partition, or modify the home drive
- Never commit secrets or passwords
- All configuration must go through `vars/main.yml`
- No hardcoded values in roles
- The `home_device` variable has no default — the playbook must fail
  clearly if it is not set, to prevent accidental data loss
- Ansible runs inside arch-chroot against localhost, not over SSH
- Test each role can run independently where possible

