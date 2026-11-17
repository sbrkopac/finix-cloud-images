# finix-cloud-images

Builds a bootable disk image of [finix](https://github.com/finix-community/finix) for cloud
providers. finix is a NixOS derivative that runs `finit` as PID 1 instead of systemd.

The image is a 1.5 GiB raw disk: BIOS boot through limine, virtio drivers, DHCP, key-only SSH. It
has no cloud-init. Two small boot tasks do the parts of cloud-init's job that matter: one grows the
root filesystem to fill the disk, one fetches your SSH key from the provider's metadata service.

## Status

| What | State |
|---|---|
| Build and image-file checks | Run in CI on every change. |
| Booting | **Not tested in CI.** An earlier revision with the same pins, a key baked in and a fixed `biosDevice` was booted and verified on DigitalOcean. |
| SSH key from the metadata service | New and **not yet booted on any provider**. Bake a key in as well until it has been (see below). |
| `biosDevice = "nodev"` | New. A rebuild on a running machine updates limine's config and stage 2 file and never rewrites the boot code in the MBR. A rebuild that changes the limine version may therefore not boot. |

## Get an image

Fork the repository, then run the **build** workflow from the Actions tab. The image is attached
to the run as the artifact `finix-image`: `finix.img.gz` and its sha256.

To bake keys in, set the repository variable `SSH_AUTHORIZED_KEYS` (Settings, Secrets and
variables, Actions, Variables) to one or more public keys, one per line. Public keys are not
secrets, which is why this is a variable.

To build locally, as root on a Linux host with Nix and flakes enabled:

```bash
bash scripts/build.sh            # writes /var/tmp/finix.img
```

## Use it

Unpack the image and upload it as a custom image. It is a raw disk image.

| Provider | Upload |
|---|---|
| DigitalOcean | Custom images are imported from a URL. Keep the `.img` name inside the `.gz`. |
| OpenStack clouds (OVH Public Cloud and others) | `openstack image create --disk-format raw --container-format bare --file finix.img finix` |

Create a machine from it with an SSH key selected, then:

```bash
ssh finix@<address>
```

The user is `finix`. Root login and passwords are disabled, and `sudo` asks for no password.

## Layout

| Path | What it holds |
|---|---|
| `flake/` | The system. `flake.lock` pins finix and nixpkgs. |
| `flake/finix/authorized_keys` | Keys to bake in. Empty in the repository. |
| `scripts/build.sh` | Runs the four stages: partition, install, bootloader, verify. |
| `scripts/secret-gate.sh` | Refuses a tree that holds a hash, an address or a credential. |
| `docs/DESIGN.md` | Why the image is built the way it is. |

## Changing the system

Edit `flake/finix/configuration.nix`. To move to newer finix and nixpkgs, run `nix flake update`
in `flake/` and let CI rebuild. The partition UUIDs in `hardware-configuration.nix` and
`scripts/common.sh` must stay in step.
