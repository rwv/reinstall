#!/bin/sh
set -eu
set +x

if [ -f /configs/debian/installer-host-key ]; then
    mkdir -p /etc/ssh
    cp /configs/debian/installer-host-key /etc/ssh/ssh_host_ed25519_key
    cp /configs/debian/installer-host-key.pub /etc/ssh/ssh_host_ed25519_key.pub
    chmod 0600 /etc/ssh/ssh_host_ed25519_key
fi
