#!/bin/bash

# edit this:
DISK=/dev/vdb

DEBIAN_VERSION=bookworm
FSFLAGS="compress=zstd:9"

target=/target
root_device=${DISK}2

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
. ${SCRIPT_DIR}/_make_image_lib.sh

notify install required packages
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap uuid-runtime btrfs-progs dosfstools

if [ ! -f efi-part.uuid ]; then
    echo generate uuid for efi partition
    uuidgen > efi-part.uuid
fi
if [ ! -f base-image-part.uuid ]; then
    echo generate uuid for base image partition
    uuidgen > base-image-part.uuid
fi
if [ ! -f top-part.uuid ]; then
    echo generate uuid for top partition
    uuidgen > top-part.uuid
fi
efi_uuid=$(cat efi-part.uuid)
base_image_uuid=$(cat base-image-part.uuid)
top_uuid=$(cat top-part.uuid)

if [ ! -f partitions_created.txt ]; then
# TODO mark the BaseImage partition as read-only (bit 60 - 0x1000000000000000)
notify create 2 partitions on ${DISK}
sfdisk $DISK <<EOF
label: gpt
unit: sectors
sector-size: 512

${DISK}1: start=2048, size=409600, type=uefi, name="EFI system partition", uuid=${efi_uuid}
${DISK}2: start=411648, size=409600, type=linux, name="BaseImage", uuid=${base_image_uuid}
EOF

notify resize the second partition on ${DISK} to fill available space
echo ", +" | sfdisk -N 2 $DISK

sfdisk -d $DISK > partitions_created.txt
fi

if [ ! -f btrfs_created.txt ]; then
    notify create root filesystem on ${root_device}
    mkfs.btrfs -f ${root_device} | tee btrfs_created.txt
fi
if [ ! -f vfat_created.txt ]; then
    notify create esp filesystem on ${DISK}1
    mkfs.vfat ${DISK}1 | tee vfat_created.txt
fi

if grep -qs "/mnt/btrfs1" /proc/mounts ; then
    echo top-level subvolume already mounted on /mnt/btrfs1
else
    notify mount top-level subvolume on /mnt/btrfs1
    mkdir -p /mnt/btrfs1
    mount ${root_device} /mnt/btrfs1 -o ${FSFLAGS}
fi

if [ ! -e /mnt/btrfs1/@ ]; then
    notify create @, @swap and @home subvolumes on /mnt/btrfs1
    btrfs subvolume create /mnt/btrfs1/@
    btrfs subvolume create /mnt/btrfs1/@home
    btrfs subvolume create /mnt/btrfs1/@swap
    btrfs subvolume set-default /mnt/btrfs1/@
fi

if grep -qs "${target}" /proc/mounts ; then
    echo root subvolume already mounted on ${target}
else
    notify mount root and home subvolume on ${target}
    mkdir -p ${target}
    mount ${root_device} ${target} -o ${FSFLAGS},subvol=@
    mkdir -p ${target}/home
    mount ${root_device} ${target}/home -o ${FSFLAGS},subvol=@home
fi

mkdir -p ${target}/var/cache/apt/archives
if grep -qs "${target}/var/cache/apt/archives" /proc/mounts ; then
    echo apt cache directory already bind mounted on target
else
    notify bind mounting apt cache directory to target
    mount /var/cache/apt/archives ${target}/var/cache/apt/archives -o bind
fi

if [ ! -f ${target}/etc/debian_version ]; then
    notify install debian on ${target}
    debootstrap ${DEBIAN_VERSION} ${target} http://deb.debian.org/debian
fi

if grep -qs "${target}/proc" /proc/mounts ; then
    echo bind mounts already set up on ${target}
else
    notify bind mount dev, proc, sys, run, var/tmp on ${target}
    mount -t proc none ${target}/proc
    mount --make-rslave --rbind /sys ${target}/sys
    mount --make-rslave --rbind /dev ${target}/dev
    mount --make-rslave --rbind /run ${target}/run
    mount --make-rslave --rbind /var/tmp ${target}/var/tmp
fi

notify setup sources.list
cat <<EOF > ${target}/etc/apt/sources.list
deb http://deb.debian.org/debian ${DEBIAN_VERSION} main contrib non-free non-free-firmware
deb http://security.debian.org/ ${DEBIAN_VERSION}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_VERSION}-backports main contrib non-free non-free-firmware
EOF

notify enable ${DEBIAN_VERSION}-backports
mkdir -p ${target}/etc/apt/preferences.d
cp "${SCRIPT_DIR}/installer-files/etc/apt/preferences.d/99backports-temp" "${target}/etc/apt/preferences.d/"

notify install required packages on ${target}
cat <<EOF > ${target}/tmp/packages.txt
locales
adduser
passwd
sudo
systemd
btrfs-progs
tasksel
network-manager
firmware-linux
bluez-firmware
dahdi-firmware-nonfree
firmware-amd-graphics
firmware-ath9k-htc
firmware-atheros
firmware-bnx2
firmware-bnx2x
firmware-brcm80211
firmware-cavium
firmware-intel-sound
firmware-iwlwifi
firmware-libertas
firmware-misc-nonfree
firmware-myricom
firmware-netronome
firmware-netxen
firmware-qcom-media
firmware-qcom-soc
firmware-qlogic
firmware-realtek
firmware-samsung
firmware-siano
firmware-ti-connectivity
firmware-tomu
firmware-zd1211
hdmi2usb-fx2-firmware
midisport-firmware
sigrok-firmware-fx2lafw
binutils
console-setup
cryptsetup
dmraid
exim4-daemon-light
kpartx
lvm2
mdadm
pigz
pkg-config
tpm2-tools
tpm-udev
mokutil
sbsigntool
openssl
EOF
cat <<EOF > ${target}/tmp/run2.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
xargs apt-get install -y < /tmp/packages.txt
EOF
chroot ${target}/ bash /tmp/run2.sh

notify running tasksel
chroot ${target}/ tasksel

if grep -qs "${target}/var/cache/apt/archives" /proc/mounts ; then
    notify unmounting apt cache directory from target
    umount ${target}/var/cache/apt/archives
else
    echo  apt cache directory not mounted to target
fi

notify downloading remaining .deb files for the installer
chroot ${target}/ apt-get install -y --download-only locales systemd systemd-boot dracut btrfs-progs tasksel network-manager cryptsetup tpm2-tools linux-image-amd64 openssh-server

notify cleaning up
rm -f ${target}/etc/machine-id
rm -f ${target}/etc/crypttab
rm -f ${target}/var/log/*log
rm -f ${target}/var/log/apt/*log

shrink_btrfs_filesystem ${target}

echo umounting all filesystems
read -p "Enter to continue"
umount -R ${target}
umount -R /mnt/btrfs1

echo "NOW REBOOT AND CONTINUE WITH PART 2"
