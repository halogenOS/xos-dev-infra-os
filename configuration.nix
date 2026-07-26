{
  foundrixModules,
  modulesPath,
  lib,
  pkgs,
  config,
  ...
}:
let
  userName = "user";
in
{
  imports = [
    "${modulesPath}/profiles/minimal.nix"
    "${modulesPath}/profiles/perlless.nix"
    foundrixModules.profiles.server-baseline
    foundrixModules.config.home-manager
    foundrixModules.config.shell.zsh.lite
    foundrixModules.config.virtualisation.docker
    foundrixModules.config.filesystem.var
    foundrixModules.services.secrets
    foundrixModules.services.operator-secrets
    foundrixModules.services.nftables-dns
    foundrixModules.config.networking.controlled-egress-firewall
    foundrixModules.config.networking.dns-resolvers
    ./home.nix
    ./caddy.nix
    ./forgejo.nix
    ./branding
  ];

  users.users.${userName} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    uid = 1000;
    shell = pkgs.zsh;
    hashedPassword = "$y$j9T$gV9uVMQ5oZ8mg4Opln0cz1$r2wok8rIwQm/7sdOEJT8QtKfCw.Jf3bHKHkZG6nF7c3";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3LlSENwLSVob/uIKNoyjtSrffFs4lzNC9AMqxmEHSz simao@aludepp"
    ];
  };
  users.groups.${userName}.gid = config.users.users.${userName}.uid;

  # The initrd sshd is the remote channel for the /var LUKS passphrase
  # (devices/hetzner imports filesystem.var-luks). nixpkgs would default
  # these to root's keys, and root has none here — same operator, same key.
  boot.initrd.network.ssh.authorizedKeys = config.users.users.${userName}.openssh.authorizedKeys.keys;

  home-manager.users.${userName}.home.stateVersion = "25.05";

  environment.systemPackages = with pkgs; [
    conntrack-tools
  ];

  security.sudo.enable = true;

  services.openssh = {
    enable = true;
    # Forgejo owns :22 for git over SSH; admin sshd moves to :2222
    ports = [ 2222 ];
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  system.nixos-init.enable = true;
  boot.initrd.systemd.enable = true;

  system.etc.overlay.enable = true;
  services.userborn.enable = true;

  nix.settings.trusted-users = [
    "root"
    "@wheel"
  ];

  system.forbiddenDependenciesRegexes = lib.mkForce [ ];

  boot.uki.name = "xos-dev-infra";
  system.nixos.distroId = "xos-dev-infra";
  system.image.id = "xos-dev-infra-hetzner";
  system.image.version = "1";

  system.stateVersion = "25.05";

  # nameservers and FallbackDNS come from foundrix's dns-resolvers module
  services.resolved.settings.Resolve.DNSSEC = "false";

  # ZeroSSL EAB credentials for Caddy
  custom.zerosslEabFile = "/var/credentials/zerossl-eab.env";

  # Dynamic DNS resolution for nftables
  foundrix.services.nftables-dns = {
    enable = true;
    allowedConnections = [
      {
        host = "acme.zerossl.com";
        ports = [ 443 ];
      }
      {
        host = "ari.trust-provider.com";
        ports = [ 443 ];
      }
      {
        host = "zerossl.ocsp.sectigo.com";
        ports = [ 80 ];
      }
      {
        host = "*";
        ports = [ 443 ];
      }
      {
        host = "cloudflare-dns.com";
        ports = [ 53 ];
        protocol = "udp";
      }
      {
        host = "dns.quad9.net";
        ports = [ 53 ];
        protocol = "udp";
      }
    ]
    ++ map (host: {
      inherit host;
      ports = [ 123 ];
      protocol = "udp";
    }) config.networking.timeServers;
    updateInterval = "1h";
  };

  # 2223 (initrd sshd, LUKS passphrase) is deliberately absent: it only ever
  # listens in stage 1, where this firewall does not exist yet, and nothing
  # binds it in the main system.
  networking.firewall.allowedTCPPorts = [
    22   # Forgejo built-in SSH
    2222 # admin OpenSSH
  ]
  ++ lib.optionals ((config.device.name or "") == "qemu") [ 8080 ];

  foundrix.config.networking.controlled-egress-firewall = {
    enable = true;
    allowLinkLocalMetadata = true;
  };

  # The credential validator makes a real HTTPS request to the SSO host; the
  # static "*:443" egress rule must be installed before it, or nftables
  # coming up mid-request drops an in-flight connection and the validator
  # reports `error`.
  systemd.services.operator-secrets.after = [ "nftables.service" ];

  systemd.services.docker = {
    after = [
      "nftables.service"
      "nftables-dns-update.service"
    ];
    wants = [ "nftables-dns-update.service" ];
    partOf = [ "nftables.service" ];
  };

  foundrix.general.qemu.portForwards = [
    { host = 2022; guest = 2222; } # admin ssh
    { host = 2023; guest = 2223; } # initrd ssh (LUKS passphrase)
    { host = 2222; guest = 22; }   # forgejo ssh
    { host = 18080; guest = 8080; }
    { host = 8443; guest = 443; }
  ];

  foundrix.general.qemu = {
    dataDevice = "/dev/disk/by-id/ata-QEMU_HARDDISK_QM00003";
    disks = [ { name = "data"; size = "100G"; } ];
  };
}
