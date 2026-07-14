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
    foundrixModules.config.runtime.repart.var
    foundrixModules.services.secrets
    foundrixModules.services.nftables-dns
    foundrixModules.config.networking.controlled-egress-firewall
    foundrixModules.config.networking.dns-resolvers
    ./home.nix
    ./caddy.nix
    ./forgejo.nix
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

  networking.firewall.allowedTCPPorts = [
    22   # Forgejo built-in SSH
    2222 # admin OpenSSH
  ]
  ++ lib.optionals ((config.device.name or "") == "qemu") [ 8080 ];

  foundrix.config.networking.controlled-egress-firewall = {
    enable = true;
    allowLinkLocalMetadata = true;
  };

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
    { host = 2222; guest = 22; }   # forgejo ssh
    { host = 18080; guest = 8080; }
    { host = 8443; guest = 443; }
  ];

  foundrix.general.qemu = {
    dataDevice = "/dev/disk/by-id/ata-QEMU_HARDDISK_QM00003";
    disks = [ { name = "data"; size = "100G"; } ];
  };
}
