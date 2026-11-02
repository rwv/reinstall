#!/usr/bin/env python3
"""Prepare private Debian 13 installer files for LUKS2 + Clevis/Tang."""

import argparse
import json
from pathlib import Path
import re
import secrets
import shlex
import subprocess
from urllib.parse import urlsplit


def prepare(output: Path, tang_url: str, thumbprint: str, interface: str, ip: str) -> None:
    url = urlsplit(tang_url)
    if url.scheme != "https" or not url.hostname or url.username or url.query or url.fragment:
        raise ValueError("Tang must use an HTTPS URL without credentials, query or fragment")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", thumbprint):
        raise ValueError("Expected a SHA-256 Tang signing-key thumbprint")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", interface):
        raise ValueError("Invalid network interface")
    if not ip or any(c in ip for c in "\r\n\x00"):
        raise ValueError("Expected an initramfs-tools IP configuration")

    source = Path(__file__).resolve().parent
    if output.resolve().is_relative_to(source.parent):
        raise ValueError("Write private installer files outside the source checkout (prefer /run)")
    preseed = (source.parent / "debian.cfg").read_text()
    bootstrap_key = secrets.token_hex(32)

    def replace_once(old: str, new: str) -> None:
        nonlocal preseed
        if preseed.count(old) != 1:
            raise ValueError("Upstream preseed changed; review the NBDE adaptation")
        preseed = preseed.replace(old, new, 1)

    replace_once("d-i partman-auto/method string regular", "d-i partman-auto/method string crypto")
    replace_once(
        "    chmod +s /usr/bin/screen; \\\n",
        "    /bin/sh /configs/debian/early.sh; \\\n\n    chmod +s /usr/bin/screen; \\\n",
    )
    # The upstream early hook forces its plaintext expert recipe. Let Debian's
    # encrypted atomic recipe create /boot + encrypted LVM instead.
    forced_recipe = '''    if [ -d /sys/firmware/efi ]; then \\
        debconf-set partman-auto/expert_recipe "$(debconf-get partman-auto/expert_recipe_efi)"; \\
    else \\
        debconf-set partman-auto/expert_recipe "$(debconf-get partman-auto/expert_recipe_bios)"; \\
    fi; \\
'''
    replace_once(forced_recipe, "")
    replace_once(
        "# d-i pkgsel/include string xxx",
        "d-i pkgsel/include string cryptsetup-initramfs clevis clevis-luks clevis-initramfs "
        "ca-certificates dropbear-initramfs",
    )
    # The upstream file ends in preseed/late_command. Its network/SSH setup
    # remains in place, and the crypto setup must succeed before first boot.
    preseed = preseed.rstrip() + "; \\\n    /bin/sh /configs/debian/late.sh\n"
    preseed += """
d-i partman-auto/choose_recipe select atomic
d-i partman-auto-lvm/guided_size string max
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-crypto/confirm boolean true
d-i partman-crypto/confirm_nooverwrite boolean true
d-i partman-auto-crypto/erase_disks boolean true
"""
    # This preseed is private and embedded locally, so the installer can load
    # password questions through its native preseed path, including seen flags.
    preseed += f"d-i partman-crypto/passphrase password {bootstrap_key}\n"
    preseed += f"d-i partman-crypto/passphrase-again password {bootstrap_key}\n"

    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    files = {
        "preseed.cfg": preseed,
        "bootstrap-key": bootstrap_key,
        "tang.json": json.dumps({"url": tang_url.rstrip("/"), "thp": thumbprint}) + "\n",
        "initramfs.conf": f"DEVICE={shlex.quote(interface)}\nIP={shlex.quote(ip)}\n",
    }
    for name in ["early.sh", "late.sh", "ca-hook"]:
        files[name] = (source / name).read_text()
    for name, content in files.items():
        path = output / name
        path.write_text(content)
        path.chmod(0o600)
    # Give the SSH controller a host key it can trust before the install boot.
    # This is an ephemeral installer key, never the normal server host key.
    subprocess.run(
        ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(output / "installer-host-key")],
        check=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--tang-url", required=True)
    parser.add_argument("--thumbprint", required=True)
    parser.add_argument("--interface", required=True)
    parser.add_argument("--ip", required=True, help="initramfs-tools IP value, e.g. dhcp")
    args = parser.parse_args()
    prepare(args.output, args.tang_url, args.thumbprint, args.interface, args.ip)
    print(f"Private installer configuration written to {args.output}")
