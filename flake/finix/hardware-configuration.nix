# Hardware config for the cloud image. Hand-written, not generated.
{ ... }:

{
  # virtio is what KVM clouds present. ata_piix and ahci are kept so the same
  # image also boots under VirtualBox or plain QEMU for a local test.
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "ahci"
    "sd_mod"
    "sr_mod"
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
  ];

  # Explicit, so networking cannot fail to come up on a machine with no console.
  boot.kernelModules = [ "virtio_net" ];

  # Mounted by UUID, so the image boots whether the disk enumerates as
  # /dev/sda or /dev/vda. The UUIDs are pinned by scripts/common.sh, which lets
  # this file be correct before the disk exists.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/7c4e1a9d-2b3f-4c58-9e6a-0d1f2a3b4c5d";
    fsType = "ext4";
  };

  # /boot must be vfat even on BIOS: limine's installer accepts nothing else.
  # It is a plain FAT32 partition on an MBR disk, not an ESP.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/5A1F-09D8";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  swapDevices = [ ];
}
