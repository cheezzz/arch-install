# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hybrid bash + Ansible automation for a full Arch Linux install with Btrfs, NVIDIA, Cinnamon, and snapper snapshots. The operator boots the Arch ISO, runs `bootstrap.sh` to partition/format/pacstrap, then chroots and runs Ansible for the rest.

## Running

```bash
# From live Arch ISO:
bash bootstrap.sh

# Inside chroot:
arch-chroot /mnt
cd /root/arch-install
ansible-playbook -i localhost, ansible/playbook.yml
```

For VM testing, copy VM vars first: `cp ansible/vars/vm.yml ansible/vars/main.yml`

## Architecture

**Two-phase design:**
1. **`bootstrap.sh`** — Runs on live ISO. Partitions disk, creates Btrfs subvolumes (`@`, `@snapshots`, `@var_log`), mounts everything, runs pacstrap, generates fstab, copies repo into chroot. Reads `disk` and `separate_home` from `ansible/vars/main.yml`.
2. **Ansible playbook** — Runs inside arch-chroot against localhost. Eight roles executed in order: `base` → `bootloader` → `snapshots` → `audio` → `desktop` → `network` → `virtualization` → `packages`. Prompts for a password at runtime via `vars_prompt`.

**All configuration lives in `ansible/vars/main.yml`** — no hardcoded values in roles or the playbook. The `vm.yml` variant disables NVIDIA, separate home drive, bridge networking, and virtualization for QEMU/KVM testing.

**Key variables:** `disk`, `home_device`, `hostname`, `username`, `timezone`, `locale`, `keymap`, `aur_helper`, `nvidia_gpu`, `separate_home`, `docker_device`, `bridge_interface`, `vlan_id`, `enable_bridge_network`, `enable_virtualization`

## Ansible Roles

| Role | Purpose |
|------|---------|
| `base` | Timezone, locale, hostname, hosts, root/user creation, sudo, NetworkManager |
| `bootloader` | GRUB with EFI, grub-btrfs for snapshot boot entries, conditional NVIDIA cmdline |
| `snapshots` | Snapper config for root, fixes `@snapshots` subvolume conflict, timeline timers |
| `audio` | PipeWire stack (socket-activated, no enable needed) |
| `desktop` | Xorg, conditional NVIDIA drivers + early KMS, Cinnamon, LightDM autologin |
| `network` | NM keyfiles for bridged networking + VLAN, gated on `enable_bridge_network` |
| `virtualization` | KVM/libvirt/virt-manager stack, gated on `enable_virtualization` |
| `packages` | Pacman config, zram, fonts + fontconfig, common tools, dev tools, Docker + `/docker` mount, AUR helper (paru), Claude Code, Flatpak apps |

## Critical Constraints

- **Never format, partition, or modify the home drive** — it's a separate physical drive with existing data
- `home_device` has no safe default; must fail clearly if unset (prevents accidental data loss)
- NVIDIA-related tasks are gated on `nvidia_gpu` variable (false for VMs)
- `separate_home` controls whether `/home` mounts from a separate drive or lives on root
- Ansible runs inside arch-chroot against localhost, not over SSH
