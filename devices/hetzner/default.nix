{
  lib,
  pkgs,
  foundrixModules,
  ...
}:
{
  imports = [
    ./filesystems.nix
    foundrixModules.hardware.cloud.hetzner
    foundrixModules.profiles.image.server-writable
    # /var carries the operator-provided credentials, so it is encrypted.
    # This is the ONLY /var provisioner imported anywhere in this config —
    # adding runtime.repart.var back alongside it fails eval on the
    # foundrix.traits.filesystem.varProvisioner enum, which is the point:
    # repart would format the volume unencrypted. No host is deployed yet,
    # so both environments are simply born encrypted (no migration).
    foundrixModules.config.filesystem.var-luks
  ];

  # var-disk-manager selects the data volumes by this glob directly, so the
  # /dev/dynamic indirection (config.device.dynamic) and the repart-only
  # image.device.dataDevice that consumed it are both gone with repart.
  foundrix.config.filesystem.var-luks.volumeGlob = "/dev/disk/by-id/scsi-0HC_Volume_*";

  # config/initrd/ssh.nix defaults to 2222, which this host's admin sshd
  # already owns (Forgejo has :22). Two different host keys on one host:port
  # is exactly the collision the dedicated initrd port exists to prevent.
  foundrix.config.initrd.ssh.port = 2223;

  device = {
    name = "hetzner";
    platforms = [ "x86_64" ];
    crossCompile = false;
  };

  foundrix.config.image.boot.systemd-boot.timeout = 1;
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  # Produce a .raw.zst artifact for hcloud-upload-image. btrfs-writable
  # defaults compression off (btrfs already compresses internally), but the
  # upload tool consumes the compressed image, so opt back in.
  image.repart.compression.enable = true;

  # Ensure IPv6 is configured before DNS resolution
  systemd.services.hetzner-ipv6.before = [ "nftables-dns-update.service" ];
}
