#!/bin/sh
set -eu
set +x
umask 077

# Debian Installer runs this after its ordinary network and SSH setup.
crypto_devices=$(blkid -t TYPE=crypto_LUKS -o device)
set -- $crypto_devices
[ "$#" -eq 1 ] || { echo 'NBDE requires exactly one LUKS device' >&2; exit 1; }
crypto_device=$1
cryptsetup isLuks --type luks2 "$crypto_device"

mkdir -p /target/root/.nbde-setup
cp /configs/debian/bootstrap-key /target/root/.nbde-setup/bootstrap-key
cp /configs/debian/tang.json /target/root/.nbde-setup/tang.json
in-target clevis luks bind -d "$crypto_device" -k /root/.nbde-setup/bootstrap-key \
    tang "$(cat /configs/debian/tang.json)"

# Verify the Tang exchange against this actual LUKS keyslot before rebooting.
in-target /bin/sh -ec '
    clevis luks pass -d "$1" -s 1 > /root/.nbde-setup/check-key
    cryptsetup open --test-passphrase --key-file /root/.nbde-setup/check-key "$1"
' _ "$crypto_device"
rm -rf /target/root/.nbde-setup

mkdir -p /target/etc/initramfs-tools/conf.d /target/etc/initramfs-tools/hooks
cp /configs/debian/initramfs.conf /target/etc/initramfs-tools/conf.d/nbde
cp /configs/debian/ca-hook /target/etc/initramfs-tools/hooks/nbde-ca
chmod 0755 /target/etc/initramfs-tools/hooks/nbde-ca
printf '\nvirtio_net\nvirtio_pci\n' >> /target/etc/initramfs-tools/modules

mkdir -p /target/etc/dropbear/initramfs
cp /configs/ssh_keys /target/etc/dropbear/initramfs/authorized_keys
printf 'DROPBEAR_OPTIONS="-p 2222 -s -j -k"\n' > /target/etc/dropbear/initramfs/dropbear.conf
in-target update-initramfs -u -k all

# Slot 0 is a one-time installation credential. The SSH controller must replace
# it with a new off-host recovery credential after verifying automatic boot.
mkdir -p /target/var/lib/nbde
printf '%s\n' "$crypto_device" > /target/var/lib/nbde/bootstrap-pending
echo 'NBDE configured; rotate the temporary bootstrap key after first boot'
