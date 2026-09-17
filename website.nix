{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  package = inputs.website.packages.${pkgs.stdenv.hostPlatform.system}.halogenos-website;

  # The site is server-rendered, so Caddy proxies a running process rather than
  # serving a directory. Forgejo already holds 3000 on this host.
  port = 3001;

  stateDir = "/var/lib/halogenos-website";
in
{
  options.custom.webDomain = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = ''
      Domain the halogenOS website answers on (e.g., halogenos.org). Null on a
      host that does not serve it; the service and both vhosts then do not
      exist at all. The `www` label of the same name redirects to it.
    '';
  };

  config = lib.mkIf (config.custom.webDomain != null) {
    systemd.services.halogenos-website = {
      description = "halogenOS website";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        # Without this the Nitro server binds every interface, and the point of
        # putting Caddy in front is that nothing else can reach it.
        NITRO_HOST = "127.0.0.1";
        NITRO_PORT = toString port;
      };

      serviceConfig = {
        ExecStart = lib.getExe package;
        Restart = "on-failure";

        DynamicUser = true;
        StateDirectory = "halogenos-website";

        # The release catalog is cached under `.data/cache` relative to the
        # working directory, so it survives a restart only while that directory
        # is fixed and writable. Everything else the process needs is in the
        # store.
        WorkingDirectory = stateDir;

        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        # AF_UNIX belongs here even though the server speaks TCP only: name
        # resolution goes through glibc, which reaches the local resolver over
        # a unix socket, and without it the release fetcher cannot resolve the
        # upstream API at all.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };

    services.caddy.virtualHosts = {
      "${config.custom.webDomain}".extraConfig = ''
        reverse_proxy 127.0.0.1:${toString port}
      '';

      # One canonical address for the site. The redirect carries the path so a
      # link written against the www name keeps working, and it is permanent
      # because the apex is the address this site is published under.
      "www.${config.custom.webDomain}".extraConfig = ''
        redir https://${config.custom.webDomain}{uri} permanent
      '';
    };
  };
}
