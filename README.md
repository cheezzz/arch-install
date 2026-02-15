# Arch Linux Install Automation

Hybrid bash + Ansible automation for a full Arch Linux install with Btrfs,
NVIDIA, Cinnamon, and snapper snapshots.

## Prerequisites

- Arch Linux live ISO booted in UEFI mode
- Wired ethernet connection
- A separate drive with an existing `@home` Btrfs subvolume for `/home`

## Usage

1. Boot the Arch ISO
2. Connect ethernet
3. Clone this repo:
   ```
   git clone https://github.com/cheezzz/arch-install.git
   cd arch-install
   ```
4. Edit `ansible/vars/main.yml` — set `home_device` to the correct device path
   for your `/home` drive (e.g., `/dev/sda1`) and `docker_device` to the drive
   for `/docker` (e.g., `/dev/sdb1`), or `none` to skip
5. Run the bootstrap script:
   ```
   bash bootstrap.sh
   ```
6. Enter the chroot and run Ansible:
   ```
   arch-chroot /mnt
   cd /root/arch-install
   ansible-playbook -i localhost, ansible/playbook.yml
   ```
7. Enter password when prompted (used for both root and user)
8. When the playbook completes:
   ```
   exit
   umount -R /mnt
   reboot
   ```

## What Gets Installed

- **Base**: Arch Linux with Intel microcode, Btrfs
- **Bootloader**: GRUB with btrfs snapshot boot entries
- **Snapshots**: Snapper with automatic timeline and pacman hooks
- **Audio**: PipeWire (socket-activated)
- **Desktop**: Cinnamon on Xorg with NVIDIA (nvidia-open), LightDM autologin
- **Network**: Bridged NM connections + VLAN for VMs (optional)
- **Virtualization**: KVM, libvirt, virt-manager (optional)
- **Packages**: Common tools, dev tools (bun, uv, aws-cli), Docker + `/docker`
  mount, Claude Code, Flatpak apps (Zen Browser, Bitwarden, Obsidian, Telegram,
  Zulip, LocalSend)
- **Fonts**: Inter, Noto, JetBrains Mono Nerd Font with macOS-like rendering
- **Swap**: zram (no swap partition)

## VM Testing

A VM-compatible mode is included for testing in QEMU/KVM.

1. Create a VM with UEFI (OVMF), single virtio disk, 4GB+ RAM
2. Boot the Arch ISO, clone the repo
3. Copy VM vars over the default:
   ```
   cp ansible/vars/vm.yml ansible/vars/main.yml
   ```
4. Run `bash bootstrap.sh` — partitions `/dev/vda`, skips separate `/home` mount
5. Chroot and run the playbook as usual — skips NVIDIA, creates `/home` on root

Key differences from production:
- Disk: `/dev/vda` (partitions `vda1`, `vda2`) instead of NVMe
- No separate home drive — `/home` lives on the root partition
- No NVIDIA drivers or kernel modules
- No bridged networking or virtualization packages
- GRUB cmdline omits `nvidia-drm.modeset=1`

## Configuration

All settings are in `ansible/vars/main.yml`. No values are hardcoded in
roles or the playbook.
