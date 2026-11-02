#!/bin/sh
# Run after a successful automatic boot, with both input files on tmpfs.
set -eu
set +x
umask 077

[ "$#" -eq 2 ] || { echo 'Usage: finalize.sh BOOTSTRAP_KEY_FILE RECOVERY_KEY_FILE' >&2; exit 2; }
bootstrap_file=$1
recovery_file=$2
state_dir=/var/lib/nbde
[ -r "$bootstrap_file" ] && [ -r "$recovery_file" ]
[ -f "$state_dir/bootstrap-pending" ]
crypto_device=$(cat "$state_dir/bootstrap-pending")
cryptsetup isLuks --type luks2 "$crypto_device"

check_dir=$(mktemp -d /run/nbde-finalize.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
trap 'exit 1' HUP INT TERM
clevis luks pass -d "$crypto_device" -s 1 > "$check_dir/tang-key"
cryptsetup open --test-passphrase --key-file "$check_dir/tang-key" "$crypto_device"

# High-entropy per-machine recovery keys still get a memory-hard KDF, bounded
# so they can be used from the initramfs on a 1 GB server.
if ! cryptsetup open --test-passphrase --key-slot 2 --key-file "$recovery_file" "$crypto_device" 2>/dev/null; then
    cryptsetup luksAddKey --key-slot 2 --key-file "$bootstrap_file" \
        --pbkdf argon2id --pbkdf-memory 131072 --pbkdf-parallel 1 \
        "$crypto_device" "$recovery_file"
fi
cryptsetup open --test-passphrase --key-file "$recovery_file" "$crypto_device"
if cryptsetup luksDump --dump-json-metadata "$crypto_device" | jose fmt -j- -g keyslots -g 0 >/dev/null; then
    cryptsetup luksKillSlot --batch-mode --key-file "$recovery_file" "$crypto_device" 0
fi

chmod 0700 "$state_dir"
cryptsetup luksHeaderBackup --batch-mode --header-backup-file "$state_dir/.luks-header.new" "$crypto_device"
mv "$state_dir/.luks-header.new" "$state_dir/luks-header.bin"
rm "$state_dir/bootstrap-pending"
echo 'Recovery key verified, temporary installation key revoked, LUKS header saved'
