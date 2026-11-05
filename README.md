# Tableton

Tableton is a field-deployable edge platform for **Panasonic Toughbook CF-33** tablets. It packages a complete operating system as a bootable container image built on **RHEL Image Mode (bootc)**, so a single rugged tablet can run legacy Windows applications in KVM virtual machines alongside native Linux processes and services.

The device is assumed to be disconnected for most of its life. Updates, rollbacks and configuration are therefore image-based and atomic: the whole OS is replaced as one unit, a failed update rolls back to the last known-good state, and a reboot returns the unit to a clean state.

## What's in the image

`Containerfile` defines two variants as build targets, so they share one definition and cannot drift:

- `base` (`quay.io/rh-ee-sayash/tableton-base`): everything below.
- `vm` (`quay.io/rh-ee-sayash/tableton`, the default and what CI builds): `base` plus a Windows 10 VM disk, shipped read-only in `/usr/share/tableton/windows`, copied to `/var/lib/libvirt/images` and imported into libvirt as `windows-vm` on first boot, with a desktop shortcut to its console.

The `base` target builds on `registry.redhat.io/rhel9/rhel-bootc` and adds:

- **Desktop:** the "Server with GUI" group, booting to `graphical.target`, a custom wallpaper, desktop icons, and the on-screen keyboard enabled on both the login screen and the user session (the CF-33 is a touch device).
- **Virtualization:** the "Virtualization Host" group plus `qemu-kvm`, `libvirt`, `virt-install`, `virt-manager` and `virt-viewer`. The libvirt sockets are enabled at boot.
- **Applications:** Google Chrome (patched to run as root) and Wine from EPEL. Chrome and Virtual Machine Manager are placed on the desktop for root and for new users, and are marked trusted at first login.
- **Login:** root login is allowed in GDM.
- **Validation:** `bootc container lint` runs as the last build step.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Containerfile` | The bootc image definition, with `base` (GUI, KVM, Chrome, Wine, desktop settings) and `vm` (adds the Windows VM) targets. |
| `Containerfile.windows-disk` | A scratch image holding only the Windows 10 disk, published to `quay.io/rh-ee-sayash/windows10-disk` by the seed workflow. |
| `build-and-push+chunk.sh` | Builds a target (`vm` by default, or `base`), rechunks it with `rpm-ostree compose build-chunked-oci`, checks nothing was lost, and pushes the chunked image. CI runs the same script. |
| `create-iso.sh` | Runs `bootc-image-builder` to turn a target's image (`vm` by default, or `base`) into an installer ISO. |
| `config.toml` | `bootc-image-builder` config holding the Kickstart used by the ISO. |
| `setup-windows-vm.sh` | Copies the embedded Windows disk to `/var/lib/libvirt/images` (once; never overwritten) and imports it into libvirt as `windows-vm` (4 GB RAM, 2 vCPUs, NAT network, VNC, autostart). |
| `setup-windows-vm.service` | Oneshot systemd unit that runs the import script once the disk exists and libvirt is up. |
| `files/background.png` | Desktop and login wallpaper. |
| `files/Windows-VM.sh` | Desktop shortcut that opens the Windows VM console with `virt-viewer`. |
| `cirros-test.qcow2` | A small CirrOS disk for testing VM import without a Windows image. |

## Prerequisites

- A RHEL 9 build host with `podman`, running as root (chunking and the ISO build need `--privileged`). `rpm-ostree` is not needed on the host: the script runs it from the image it just built.
- A Red Hat registry pull secret saved as `pull-secret.json` in the repository root. It is used to pull `rhel-bootc` and `bootc-image-builder` and to push the result. Do not commit it.
- Push access to the target registries (`quay.io/rh-ee-sayash/tableton` and `tableton-base` in the scripts; change them for your own registry).
- For the `vm` target, pull access to the private `quay.io/rh-ee-sayash/windows10-disk` (`podman login quay.io`).

## Building

### 1. Build and push the OS image

```bash
./build-and-push+chunk.sh        # vm target   -> quay.io/rh-ee-sayash/tableton
./build-and-push+chunk.sh base   # base target -> quay.io/rh-ee-sayash/tableton-base
```

Options: `-t TAG` also pushes an immutable `:TAG`, `-P` skips the push, `-a AUTHFILE` overrides `pull-secret.json`, `-d FILE` writes the pushed digest. CI runs this same script, so a local build is what CI builds.

The script builds the target as `localhost/<name>-unchunked`, removes the Windows seed image and dangling layers, rechunks it with `rpm-ostree compose build-chunked-oci --bootc --format-version=2` into `:latest`, checks that no file under `/usr`, `/etc` or `/opt` went missing, and pushes. **Only the chunked image is pushed; it is what devices install and update from.** Chunking regroups the files by RPM into many layers whose digests stay the same between builds while their content does, so `bootc upgrade` downloads only the packages that changed, instead of the whole image after every fresh CI build. The previous `:latest` is pulled first so its layer layout is reused.

Chunking drops regular files under `/var` (and `/root`, `/usr/local` and `/opt` can be links into `/var` on bootc). Anything the image needs goes in `/usr` or `/etc`: the Windows disk is in `/usr/share/tableton/windows` (its own layer, via the `user.component` xattr), and root's desktop icons are copied from `/usr/share/tableton/desktop` by `tmpfiles.d` at boot.

The `vm` target copies the Windows disk from `quay.io/rh-ee-sayash/windows10-disk`, seeded once by the "seed Windows 10 disk image" workflow; the disk is not stored in this repository. Building `base` does not pull it.

### 2. Create the installer ISO

```bash
./create-iso.sh        # or: ./create-iso.sh base
```

The ISO is written to `./output`. Its Kickstart (from `config.toml`) does the following:

- Sets the language to `en_US`, a US keyboard and the `Asia/Jerusalem` timezone.
- Wipes the disk and creates a GPT layout: a 600 MB EFI partition, a 2 GB `/boot` (room for bootc rollbacks), 16 GB of swap for the Windows VMs, and an ext4 root that takes the rest of the disk.
- Sets an encrypted root password, DHCP networking, and the hostname `tableton`.
- Runs `bootc switch` in `%post` so that installed devices track `hub-registry.apps.mgmt.cloudlet.tng.topsecret/tableton/tableton:latest` for updates.

Write the ISO to a USB stick (or serve it over HTTP boot) and boot the CF-33 from it. The installation is zero-touch.

## Testing

A bootc image is a container image with a kernel, so you can test it like any other container before building media:

- `podman run` the image to inspect its contents.
- Boot it in a VM with [bcvk](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/managing-image-updates-with-the-bootc-virtualization-kit-bcvk) or the [Podman Desktop bootc extension](https://github.com/podman-desktop/extension-bootc) to get a GUI.
- Use `cirros-test.qcow2` to check the VM import flow without a full Windows disk.

## Updating and servicing devices

- **Updates:** push a new image and run `bootc upgrade` on the device, or let Red Hat Edge Manager roll it out when the maintenance network is up. Only the changed layers are downloaded, and the new image is applied on the next boot.
- **Rollback:** `bootc rollback` returns to the previous deployment if an update misbehaves.
- **Local configuration:** `/etc` and `/var` stay writable. Changes made there take effect without a rebuild or network access and are preserved across updates through a 3-way merge.
- **Experiments:** `bootc usr-overlay` adds a temporary writable layer over `/usr` for the current boot, so you can install tools for debugging. The overlay is discarded on reboot.

## Architecture context

Tableton is the Tier 4 component of the Cloudlet edge stack. The full design is in the *Tableton CF33 – Characterization & Architecture* document. In short:

- **OS:** RHEL for Edge in Image Mode. The core OS is immutable, and updates are atomic and image-based with rollback.
- **Workloads:** a hybrid of KVM virtual machines (legacy GUI applications) and native Linux processes. MicroShift is an optional later addition for containerized workloads.
- **Networking:** two separate profiles. Application traffic runs over a private IP-over-radio network. A regular infrastructure network is used only for maintenance and updates, and is assumed to be disconnected most of the time.
- **Storage:** the architecture calls for an LVM-based layout with a dedicated volume for VM disks in `/var/lib/libvirt/images`, plus a volume group reserved for a future MicroShift LVMS CSI driver. The current Kickstart uses plain partitions instead.
- **Fleet services:** Red Hat Edge Manager for fleet management and onboarding, Ansible Automation Platform for building images and installation media, GitLab and ArgoCD for source control and GitOps delivery, Vault for secrets, and Grafana for metrics and logs when a device is connected.
- **Security:** the device is physically pre-hardened. CIS software hardening and FDO secure onboarding are planned for later stages.
