#!/bin/bash

if [ -z "${NON_INTERACTIVE}" ]; then
# edit this:
DISK=/dev/vda
USERNAME=user
USER_FULL_NAME="Debian User"
USER_PASSWORD=hunter2
ROOT_PASSWORD=changeme
LUKS_PASSWORD=luke
HOSTNAME=debian12
ENABLE_SWAP=partition
SWAP_SIZE=2
SECURE_BOOT=true
SSH_PUBLIC_KEY=
AFTER_INSTALLED_CMD=
fi

function notify () {
    echo $@
    if [ -z "${NON_INTERACTIVE}" ]; then
      read -p "Enter to continue"
    fi
}

DEBIAN_VERSION=bookworm
# see https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html#--tpm2-pcrs=PCR
TPM_PCRS="7+14"
# do not enable this on a live-cd
SHARE_APT_ARCHIVE=false
FSFLAGS="compress=zstd:1"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

if [ "$(id -u)" -ne 0 ]; then
    echo 'This script must be run by root' >&2
    exit 1
fi

if [ -z "${DISK}" ]; then
    echo "DISK variable is missing" >&2
    exit 2
fi

if [ -z "${LUKS_PASSWORD}" ]; then
    echo "LUKS_PASSWORD variable is missing" >&2
    exit 3
fi

if [ -z "${NON_INTERACTIVE}" ]; then
    notify install required packages
    apt-get update -y
    apt-get install -y cryptsetup debootstrap uuid-runtime btrfs-progs dosfstools
fi

KEYFILE=luks.key
if [ ! -f efi-part.uuid ]; then
    notify generate uuid for efi partition
    uuidgen > efi-part.uuid
fi
if [ ! -f luks-part.uuid ]; then
    notify generate uuid for luks partition
    uuidgen > luks-part.uuid
fi
if [ ! -f swap-part.uuid ]; then
    notify generate uuid for swap partition
    uuidgen > swap-part.uuid
fi
if [ ! -f btrfs.uuid ]; then
    notify generate uuid for btrfs filesystem
    uuidgen > btrfs.uuid
fi

root_part_type="4f68bce3-e8cd-4db1-96e7-fbcaf984b709"  # X86_64
system_part_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
swap_part_type="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F "
efi_part_uuid=$(cat efi-part.uuid)
luks_part_uuid=$(cat luks-part.uuid)
btrfs_uuid=$(cat btrfs.uuid)
top_level_mount=/mnt/top_level_mount
target=/target
luks_device=root
root_device=/dev/mapper/${luks_device}
kernel_params="luks.options=tpm2-device=auto rw quiet rootfstype=btrfs rootflags=${FSFLAGS} rd.auto=1 splash"
efi_partition=/dev/disk/by-partuuid/${efi_part_uuid}
root_partition=/dev/disk/by-partuuid/${luks_part_uuid}

if [ "${ENABLE_SWAP}" == "partition" ]; then
swap_part_uuid=$(cat swap-part.uuid)
swap_size_blocks=$((${SWAP_SIZE}*2048*1024))
root_start_blocks=$((2099200+${swap_size_blocks}))
swap_partition=/dev/disk/by-partuuid/${swap_part_uuid}
swap_device=swap1
root_partition_nr=3
sfdisk_format=$(cat <<EOF
start=2048, size=2097152, type=${system_part_type}, name="EFI system partition", uuid=${efi_part_uuid}
start=2099200, size=${swap_size_blocks}, type=${swap_part_type}, name="Swap partition", uuid=${swap_part_uuid}
start=${root_start_blocks}, size=4096000, type=${root_part_type}, name="Root partition", uuid=${luks_part_uuid}
EOF
)
else
root_partition_nr=2
swap_partition=none
sfdisk_format=$(cat <<EOF
start=2048, size=2097152, type=${system_part_type}, name="EFI system partition", uuid=${efi_part_uuid}
start=2099200, size=4096000, type=${root_part_type}, name="LUKS partition", uuid=${luks_part_uuid}
EOF
)
fi

if [ ! -f partitions_created.txt ]; then
notify create ${root_partition_nr} partitions on ${DISK}
sfdisk $DISK <<EOF
label: gpt
unit: sectors
sector-size: 512

${sfdisk_format}
EOF

notify resize the root partition on ${DISK} to fill available space
echo ", +" | sfdisk -N ${root_partition_nr} $DISK

sfdisk -d $DISK > partitions_created.txt
fi

function wait_for_file {
    filename="$1"
    while [ ! -e $filename ]
    do
        echo waiting for $filename to be created
        sleep 3
    done
}

wait_for_file ${root_partition}
if [ "${ENABLE_SWAP}" == "partition" ]; then
    wait_for_file ${swap_partition}
fi

if [ ! -f $KEYFILE ]; then
    # TODO do we want to store this file in the installed system?
    notify generate key file for luks
    dd if=/dev/random of=${KEYFILE} bs=512 count=1
    notify "remove any old luks on ${root_partition} (root)"
    cryptsetup erase --batch-mode ${root_partition}
    wipefs -a ${root_partition}
    if [ -e ${swap_partition} ]; then
        notify "remove any old luks on ${swap_partition} (swap)"
        cryptsetup erase --batch-mode ${swap_partition}
        wipefs -a ${swap_partition}
    fi
fi

function setup_luks {
  cryptsetup isLuks "$1"
  retVal=$?
  if [ $retVal -ne 0 ]; then
      notify setup luks on "$1"
      cryptsetup luksFormat "$1" --type luks2 --batch-mode --key-file $KEYFILE
      notify setup luks password on "$1"
      echo -n "${LUKS_PASSWORD}" > /tmp/passwd
      cryptsetup --key-file=luks.key luksAddKey "$1" /tmp/passwd
      rm -f /tmp/passwd
  else
      echo luks already set up on "$1"
  fi
  cryptsetup luksUUID "$1" > luks.uuid
}

setup_luks ${root_partition}
root_uuid=$(cat luks.uuid)

if [ ! -e ${root_device} ]; then
    notify open luks on root
    cryptsetup luksOpen ${root_partition} ${luks_device} --key-file $KEYFILE
fi

if [ -e /dev/disk/by-partlabel/BaseImage ]; then
    if [ ! -f base_image_copied.txt ]; then
        notify copy base image to ${root_device}
        dd if=/dev/disk/by-partlabel/BaseImage of=${root_device} bs=4M conv=sync status=progress
        notify check the filesystem on root
        btrfs check ${root_device}
        notify change the filesystem uuid on root
        btrfstune -U ${btrfs_uuid} -f ${root_device}  # change the uuid
        touch base_image_copied.txt
    fi
else
    if [ ! -f btrfs_created.txt ]; then
        notify create root filesystem on ${root_device}
        mkfs.btrfs -U ${btrfs_uuid} ${root_device} | tee btrfs_created.txt
    fi
fi
    
if [ ! -f vfat_created.txt ]; then
    notify create esp filesystem on ${efi_partition}
    mkfs.vfat ${efi_partition}
    touch vfat_created.txt
fi

if [ "${ENABLE_SWAP}" == "partition" ]; then
    setup_luks ${swap_partition}
    swap_uuid=$(cat luks.uuid)

    kernel_params="${kernel_params} luks.name=${swap_uuid}=${swap_device} resume=/dev/mapper/${swap_device}"

    if [ ! -e /dev/mapper/${swap_device} ]; then
        notify open luks swap
        cryptsetup luksOpen ${swap_partition} ${swap_device} --key-file $KEYFILE
    fi

    notify making swap
    mkswap /dev/mapper/${swap_device}
    swapon /dev/mapper/${swap_device}
fi  # swap as partition

if grep -qs "${top_level_mount}" /proc/mounts ; then
    echo top-level subvolume already mounted on ${top_level_mount}
else
    notify mount top-level subvolume on ${top_level_mount} and resize to fit the whole partition
    mkdir -p ${top_level_mount}
    mount ${root_device} ${top_level_mount} -o rw,${FSFLAGS},subvolid=5
    btrfs filesystem resize max ${top_level_mount}
fi

if [ ! -e ${top_level_mount}/@ ]; then
    notify create @ and @home subvolumes on ${top_level_mount}
    btrfs subvolume create ${top_level_mount}/@
    btrfs subvolume create ${top_level_mount}/@home
    if [ "${ENABLE_SWAP}" == "file" ]; then
        notify create @swap subvolume for swap file on ${top_level_mount}
        btrfs subvolume create ${top_level_mount}/@swap
        chmod 700 ${top_level_mount}/@swap
    fi
    btrfs subvolume set-default ${top_level_mount}/@
fi

if grep -qs "${target}" /proc/mounts ; then
    echo root subvolume already mounted on ${target}
else
    notify mount root and home subvolume on ${target}
    mkdir -p ${target}
    mount ${root_device} ${target} -o ${FSFLAGS},subvol=@
    mkdir -p ${target}/home
    mount ${root_device} ${target}/home -o ${FSFLAGS},subvol=@home
    if [ "${ENABLE_SWAP}" == "file" ]; then
        notify mount swap subvolume on ${target}
        mkdir -p ${target}/swap
        mount ${root_device} ${target}/swap -o noatime,subvol=@swap
    fi
fi

if [ "${ENABLE_SWAP}" == "file" ]; then
    notify make swap file at ${target}/swap/swapfile
    btrfs filesystem mkswapfile --size ${SWAP_SIZE}G ${target}/swap/swapfile
    swapon ${target}/swap/swapfile
    swapfile_offset=$(btrfs inspect-internal map-swapfile -r ${target}//swap/swapfile)
    kernel_params="${kernel_params} luks.name=${root_uuid}=${luks_device} resume=${root_device} resume_offset=${swapfile_offset}"
fi

if [ ! -f ${target}/etc/debian_version ]; then
    notify install debian on ${target}
    debootstrap ${DEBIAN_VERSION} ${target} http://deb.debian.org/debian
fi

if grep -qs "${target}/proc" /proc/mounts ; then
    echo bind mounts already set up on ${target}
else
    notify bind mount dev, proc, sys, run on ${target}
    mount -t proc none ${target}/proc
    mount --make-rslave --rbind /sys ${target}/sys
    mount --make-rslave --rbind /dev ${target}/dev
    mount --make-rslave --rbind /run ${target}/run
fi

if grep -qs "${efi_partition} " /proc/mounts ; then
    echo efi esp partition ${efi_partition} already mounted on ${target}/boot/efi
else
    notify mount efi esp partition ${efi_partition} on ${target}/boot/efi
    mkdir -p ${target}/boot/efi
    mount ${efi_partition} ${target}/boot/efi -o umask=077
fi

if [ ! -z "${HOSTNAME}" ]; then
    notify setup hostname
    echo "$HOSTNAME" > ${target}/etc/hostname
fi

notify setup timezone
echo "${TIMEZONE}" > ${target}/etc/timezone
rm -f ${target}/etc/localtime
(cd ${target} && ln -s /usr/share/zoneinfo/${TIMEZONE} etc/localtime)

notify setup fstab
mkdir -p ${target}/root/btrfs1
cat <<EOF > ${target}/etc/fstab
UUID=${btrfs_uuid} /home btrfs defaults,subvol=@home,${FSFLAGS} 0 1
UUID=${btrfs_uuid} /root/btrfs1 btrfs defaults,subvolid=5,${FSFLAGS} 0 1
PARTUUID=${efi_part_uuid} /boot/efi vfat defaults,umask=077 0 2
EOF

if [ "${ENABLE_SWAP}" == "partition" ]; then
cat <<EOF >> ${target}/etc/fstab
/dev/mapper/${swap_device} swap swap defaults 0 0
EOF
elif [ "${ENABLE_SWAP}" == "file" ]; then
cat <<EOF >> ${target}/etc/fstab
UUID=${btrfs_uuid} /swap btrfs defaults,subvol=@swap,noatime 0 0
/swap/swapfile none swap defaults 0 0
EOF
fi

notify setup sources.list
cat <<EOF > ${target}/etc/apt/sources.list
deb http://deb.debian.org/debian ${DEBIAN_VERSION} main contrib non-free non-free-firmware
deb http://security.debian.org/ ${DEBIAN_VERSION}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_VERSION}-backports main contrib non-free non-free-firmware
EOF

if [ "$SHARE_APT_ARCHIVE" = true ] ; then
    mkdir -p ${target}/var/cache/apt/archives
    if grep -qs "${target}/var/cache/apt/archives" /proc/mounts ; then
        echo apt cache directory already bind mounted on target
    else
        notify bind mounting apt cache directory to target
        mount /var/cache/apt/archives ${target}/var/cache/apt/archives -o bind
    fi
fi

if grep -qs 'root:\$' ${target}/etc/shadow ; then
    echo root password already set up
elif [ ! -z "${ROOT_PASSWORD}" ]; then
    notify set up root password
    echo "root:${ROOT_PASSWORD}" > ${target}/tmp/passwd
    chroot ${target}/ bash -c "chpasswd < /tmp/passwd"
    rm -f ${target}/tmp/passwd
fi

if [ ! -z "${USERNAME}" ]; then
    if grep -qs "^${USERNAME}:" ${target}/etc/shadow ; then
        echo ${USERNAME} user already set up
    else
        notify set up ${USERNAME} user
        chroot ${target}/ bash -c "adduser ${USERNAME} --disabled-password --gecos "${USER_FULL_NAME}""
        chroot ${target}/ bash -c "adduser ${USERNAME} sudo"
        if [ ! -z "${USER_PASSWORD}" ]; then
            echo "${USERNAME}:${USER_PASSWORD}" > ${target}/tmp/passwd
            chroot ${target}/ bash -c "chpasswd < /tmp/passwd"
            rm -f ${target}/tmp/passwd
        fi
    fi
fi

notify configuring dracut and kernel command line
mkdir -p ${target}/etc/dracut.conf.d
cat <<EOF > ${target}/etc/dracut.conf.d/90-luks.conf
add_dracutmodules+=" systemd crypt btrfs tpm2-tss "
kernel_cmdline="${kernel_params}"
EOF
cat <<EOF > ${target}/etc/kernel/cmdline
${kernel_params}
EOF

if [ "${ENABLE_SWAP}" == "partition" ]; then
cat <<EOF > ${target}/etc/dracut.conf.d/90-hibernate.conf
add_dracutmodules+=" resume "
EOF
fi

notify install required packages on ${target}
if [ -z "${NON_INTERACTIVE}" ]; then
    chroot ${target}/ apt-get update -y
fi
cat <<EOF > ${target}/tmp/run1.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get install locales systemd systemd-boot dracut btrfs-progs tasksel network-manager cryptsetup sudo tpm2-tools tpm-udev -y
bootctl install
EOF
chroot ${target}/ sh /tmp/run1.sh

notify checking for tpm
cp ${KEYFILE} ${target}/
chmod 600 ${target}/${KEYFILE}
cat <<EOF > ${target}/tmp/run4.sh
systemd-cryptenroll --tpm2-device=list > /tmp/tpm-list.txt
if grep -qs "/dev/tpm" /tmp/tpm-list.txt ; then
      echo tpm available, enrolling
      echo "... on root"
      systemd-cryptenroll --unlock-key-file=/${KEYFILE} --tpm2-device=auto ${root_partition} --tpm2-pcrs=${TPM_PCRS}
      if [ -e "${swap_partition}" ]; then
          echo "... on swap"
          systemd-cryptenroll --unlock-key-file=/${KEYFILE} --tpm2-device=auto ${swap_partition} --tpm2-pcrs=${TPM_PCRS}
      fi
else
    echo tpm not avaialble
fi
EOF
chroot ${target}/ bash /tmp/run4.sh
rm ${target}/${KEYFILE}

notify install kernel and firmware on ${target}
cat <<EOF > ${target}/tmp/packages.txt
dracut
linux-image-amd64
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
mokutil
sbsigntool
openssl
EOF
cat <<EOF > ${target}/tmp/run2.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
xargs apt-get install -y < /tmp/packages.txt
systemctl disable systemd-networkd.service  # seems to fight with NetworkManager
systemctl disable systemd-networkd.socket
systemctl disable systemd-networkd-wait-online.service
EOF
chroot ${target}/ bash /tmp/run2.sh

if [ ! -z "${SSH_PUBLIC_KEY}" ]; then
    notify adding ssh public key to user and root authorized_keys file
    mkdir -p ${target}/root/.ssh
    chmod 700 ${target}/root/.ssh
    echo "${SSH_PUBLIC_KEY}" > ${target}/root/.ssh/authorized_keys
    chmod 600 ${target}/root/.ssh/authorized_keys

    if [ ! -z "${USERNAME}" ]; then
        mkdir -p ${target}/home/${USERNAME}/.ssh
        chmod 700 ${target}/home/${USERNAME}/.ssh
        echo "${SSH_PUBLIC_KEY}" > ${target}/home/${USERNAME}/.ssh/authorized_keys
        chmod 600 ${target}/home/${USERNAME}/.ssh/authorized_keys
        chroot ${target}/ chown -R ${USERNAME} /home/${USERNAME}/.ssh

        notify installing openssh-server
        chroot ${target}/ apt-get install -y openssh-server
    fi
fi

if [ -z "${NON_INTERACTIVE}" ]; then
    notify running tasksel
    chroot ${target}/ tasksel
fi

if [ "${SECURE_BOOT}" = true ] ; then
notify setting up secure boot
cat <<EOF > ${target}/tmp/run3.sh
mkdir -p /var/lib/shim-signed/mok
cd /var/lib/shim-signed/mok/
openssl req -nodes -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -days 36500 -subj "/CN=${HOSTNAME}/"
openssl x509 -inform der -in MOK.der -out MOK.pem
mokutil --generate-hash=${ROOT_PASSWORD} > /tmp/mokutil.hash
mokutil --import MOK.der --hash-file /tmp/mokutil.hash
rm /tmp/mokutil.hash
EOF
chroot ${target}/ bash /tmp/run3.sh
fi

notify reverting backports apt-pin
rm -f ${target}/etc/apt/preferences.d/99backports-temp

notify umounting all filesystems
if [ "${ENABLE_SWAP}" == "partition" ]; then
    swapoff /dev/mapper/${swap_device}
elif [ "${ENABLE_SWAP}" == "file" ]; then
    swapoff ${target}/swap/swapfile
fi
umount -R ${target}
umount -R ${top_level_mount}

notify closing luks
cryptsetup luksClose ${luks_device}
if [ "${ENABLE_SWAP}" == "partition" ]; then
  cryptsetup luksClose /dev/mapper/${swap_device}
fi

notify INSTALLATION FINISHED

if [ ! -z "${AFTER_INSTALLED_CMD}" ]; then
  notify running ${AFTER_INSTALLED_CMD}
  sh -c "${AFTER_INSTALLED_CMD}"
fi
