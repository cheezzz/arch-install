#!/usr/bin/env bash
set -euo pipefail

MOUNT="/mnt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="${SCRIPT_DIR}/ansible/vars/main.yml"
BTRFS_OPTS="compress=zstd:1,noatime,space_cache=v2,ssd"

# Read vars
DISK="$(grep '^disk:' "${VARS_FILE}" | awk '{print $2}')"
[[ -z "${DISK}" ]] && { printf '\n\e[1;31m!! disk is not set in %s\e[0m\n' "${VARS_FILE}" >&2; exit 1; }

SEPARATE_HOME="$(grep '^separate_home:' "${VARS_FILE}" | awk '{print $2}')"
SEPARATE_HOME="${SEPARATE_HOME:-true}"

# Detect partition suffix: NVMe uses p1/p2, virtio/SATA uses 1/2
if [[ "${DISK}" == *nvme* || "${DISK}" == *mmcblk* ]]; then
    PART1="${DISK}p1"
    PART2="${DISK}p2"
else
    PART1="${DISK}1"
    PART2="${DISK}2"
fi

# --- Helper functions ---
msg() { printf '\n\e[1;34m>> %s\e[0m\n' "$1"; }
err() { printf '\n\e[1;31m!! %s\e[0m\n' "$1" >&2; exit 1; }

# --- Step 1: Validate prerequisites ---
msg "Validating prerequisites"

[[ -d /sys/firmware/efi/efivars ]] || err "Not booted in UEFI mode"
[[ -b "${DISK}" ]]                 || err "Disk ${DISK} not found"
ping -c 1 -W 3 archlinux.org &>/dev/null || err "No internet connectivity"

if [[ "${SEPARATE_HOME}" == "true" ]]; then
    HOME_DEVICE="$(grep '^home_device:' "${VARS_FILE}" | awk '{print $2}')"
    [[ -z "${HOME_DEVICE}" || "${HOME_DEVICE}" == "/dev/sdX" ]] && \
        err "home_device is not set in ${VARS_FILE} — edit it before running"
    [[ -b "${HOME_DEVICE}" ]] || err "Home device ${HOME_DEVICE} not found"

    echo ""
    echo "WARNING: This will WIPE ${DISK} completely."
    echo "The home drive ${HOME_DEVICE} will NOT be touched."
    echo ""
else
    echo ""
    echo "WARNING: This will WIPE ${DISK} completely."
    echo "/home will be created on the root partition."
    echo ""
fi

read -rp "Type YES to continue: " CONFIRM
[[ "${CONFIRM}" == "YES" ]] || err "Aborted by operator"

# --- Step 2: Partition disk ---
msg "Partitioning ${DISK}"

sgdisk --zap-all "${DISK}"
sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:"EFI" "${DISK}"
sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"ROOT" "${DISK}"
partprobe "${DISK}"
sleep 1

# --- Step 3: Format partitions ---
msg "Formatting partitions"

mkfs.fat -F32 "${PART1}"
mkfs.btrfs -f "${PART2}"

# --- Step 4: Create Btrfs subvolumes ---
msg "Creating Btrfs subvolumes"

mount "${PART2}" "${MOUNT}"
btrfs subvolume create "${MOUNT}/@"
btrfs subvolume create "${MOUNT}/@snapshots"
btrfs subvolume create "${MOUNT}/@var_log"
umount "${MOUNT}"

# --- Step 5: Mount subvolumes ---
msg "Mounting subvolumes"

mount -o "${BTRFS_OPTS},subvol=@" "${PART2}" "${MOUNT}"

mkdir -p "${MOUNT}/boot/efi"
mkdir -p "${MOUNT}/.snapshots"
mkdir -p "${MOUNT}/var/log"
mkdir -p "${MOUNT}/home"

mount -o "${BTRFS_OPTS},subvol=@snapshots" "${PART2}" "${MOUNT}/.snapshots"
mount -o "${BTRFS_OPTS},subvol=@var_log"   "${PART2}" "${MOUNT}/var/log"
mount "${PART1}" "${MOUNT}/boot/efi"

if [[ "${SEPARATE_HOME}" == "true" ]]; then
    mount -o "${BTRFS_OPTS},subvol=@home" "${HOME_DEVICE}" "${MOUNT}/home"
fi

# --- Step 6: Pacstrap base system ---
msg "Installing base system with pacstrap"

pacstrap -K "${MOUNT}" \
    base base-devel linux linux-headers linux-firmware \
    intel-ucode btrfs-progs ansible python-passlib git

# --- Step 7: Generate fstab ---
msg "Generating fstab"

genfstab -U "${MOUNT}" >> "${MOUNT}/etc/fstab"

# --- Step 8: Copy repo into chroot ---
msg "Copying repo into chroot"

cp -r "${SCRIPT_DIR}" "${MOUNT}/root/arch-install"

# --- Step 9: Print next steps ---
msg "Bootstrap complete!"

echo ""
echo "Next steps:"
echo "  arch-chroot ${MOUNT}"
echo "  cd /root/arch-install"
echo "  ansible-playbook -i localhost, ansible/playbook.yml"
echo ""
echo "After the playbook finishes:"
echo "  exit"
echo "  umount -R ${MOUNT}"
echo "  reboot"
echo ""
