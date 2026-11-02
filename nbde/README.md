# Debian 13 with LUKS2 and Tang

This fork adds `--debian-config DIR` to the Debian 13 installer path. The
ordinary installer path is unchanged when that option is absent. Installer
network detection and SSH access remain provided by the upstream scripts.
`netboot.xyz` remains useful as an interactive rescue/install entry point;
this path is intended for installations operated entirely over SSH.

The option is destructive when used to install: it does not turn an existing
root filesystem into LUKS in place. It packages a private directory containing
`preseed.cfg` and supporting files into the local installer initrd. The
configuration is loaded with `preseed/file`, not fetched from a public URL.
The generated initrd has mode 0600. Keep the private directory on tmpfs under
`/run`, outside `/reinstall-tmp`, and do not commit it.

## Prepare an installation

1. Verify an off-host backup and trial restore before changing an existing
   machine. Record disk layout, firmware mode, addresses/routes/DNS, all Docker
   bind mounts and volumes, image digests, SSH host keys and application state.
   Drain customer traffic before the installation reboot. Protect the snapshot
   from ordinary retention until the replacement has been accepted.
2. Check the Tang signing-key thumbprint using a trusted source. The HTTPS URL,
   thumbprint and per-machine early-boot network settings are required:

   ```sh
   python3 nbde/prepare.py /run/debian-private \
     --tang-url https://tang.example.com \
     --thumbprint '<SHA-256 signing-key thumbprint>' \
     --interface ens3 \
     --ip '203.0.113.10::203.0.113.1:255.255.255.0:server:ens3:none:1.1.1.1:8.8.8.8'
   ```

   The directory contains a random temporary bootstrap key and an ephemeral
   installer SSH host key. Save the bootstrap key securely off-host for recovery
   of the first boot. Never embed the permanent recovery key in this directory.
3. Pin `confhome` in the downloaded script to the reviewed fork commit. Run
   from the machine's existing OS, using its management public key:

   ```sh
   bash reinstall.sh debian 13 --ssh-key /root/management.pub \
     --debian-config /run/debian-private --hold 2
   ```

   This prepares the installer. Reboot only after the backup, traffic drain and
   trusted installer SSH host key have been verified. Keep the private config
   available until preparation completes.
4. Connect to the installer using its generated Ed25519 host key and a separate
   known-hosts file. Wait for installation to complete. With `--hold 2`, the
   target remains mounted at `/target`. This allows the controller to restore
   the normal server SSH host keys into the encrypted target before rebooting,
   preserving existing Ansible and CI trust. Preserve the firmware boot mode.

The NBDE profile uses Debian's encrypted atomic LVM recipe, including an
unencrypted `/boot`. It sets `partman-auto-crypto/erase_disks=false`, skipping
the full-partition random overwrite to reduce downtime. Repartitioning and
formatting still replace the old filesystem; recover application files from
the backup. Unoverwritten old plaintext remnants are an accepted tradeoff of
this profile.
The late hook binds Clevis to Tang, verifies that key against the LUKS device,
adds early networking and the HTTPS CA bundle to initramfs, and configures
public-key-only Dropbear on port 2222 for recovery. This initial profile adds
VirtIO network modules; other hardware needs its own driver validation.

## Finish and verify

After an automatic boot succeeds, generate a new random recovery key outside
the server and store it in an encrypted secret store. Transfer both temporary
input files to `/run` over the verified SSH connection, then run:

```sh
sh nbde/finalize.sh /run/bootstrap-key /run/recovery-key
```

This adds and tests a recovery slot with a 128 MiB Argon2id limit for small
servers, revokes the temporary installation slot and saves a header backup in
`/var/lib/nbde/luks-header.bin`. Back up this directory off-host, then delete
both temporary plaintext input files and any installation initrd copies.
Do not preserve a header containing the temporary slot as a recovery artifact.

For production migrations, apply the provisioning needed for management access
and the container runtime first, restore application configuration and state
selectively, and recreate containers from their recorded image digest. Resume
traffic after checking application enrollment and external HTTPS, then complete
monitoring, backup and other provisioning while the application runs. Do not
restore the
old `/etc/fstab`, `/etc/crypttab`, `/boot`, machine-id or Docker daemon metadata
over the new installation. Restore Docker volume contents through a volume
mount with the application stopped. Verify on each host:

- Actual root filesystem is behind LUKS2; recovery and Clevis slots work.
- A cold boot reaches SSH without typing a passphrase.
- Application enrollment, HTTPS and customer origin access work. A local ping
  health check alone does not verify the control plane or customer requests.

Before using a new installer profile, validate early SSH recovery with Tang
unavailable and boot a rebuilt initramfs in a lab/canary. The tested profile
includes CA certificates, early networking and VirtIO drivers. Extra validation
reboots are not required before restoring traffic on every later migration.

## Keep the offline window short

Prepare and verify backups, installer downloads, private configuration and
application restore files while the original service is still running. For a
stateless node, stop it immediately before the installer reboot. For mutable
data, take the bulk backup online and quiesce writes for a final incremental
backup. Keep installer SSH available and act on prompts without leaving the
machine idle at a hold screen.

An in-place reinstall still keeps the machine unavailable while Debian is
installed. When a shorter cutover is required, prepare an encrypted replacement
machine in parallel and move traffic after it is healthy.

Fresh VPS installations follow the same installer/provisioning steps, starting
from the provider's temporary disk-based OS. The upstream preparation script
does not run from a live system whose root is tmpfs. Existing
servers add the verified backup, traffic drain and selective restore steps.
The provider VNC/rescue capability remains the fallback for a failure before
installer SSH or initramfs SSH becomes reachable.
