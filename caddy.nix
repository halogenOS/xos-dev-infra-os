{
  config,
  lib,
  ...
}:
{
  options.custom = {
    zerosslEabFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to ZeroSSL EAB credentials file with:
        EAB_KID=your-key-id
        EAB_HMAC_KEY=your-hmac-key
      '';
    };
  };

  config = {
    services.caddy = {
      enable = true;
      globalConfig = lib.mkForce ''
        admin off
        acme_ca https://acme.zerossl.com/v2/DV90
        acme_eab {
          key_id {$EAB_KID}
          mac_key {$EAB_HMAC_KEY}
        }
        log {
          level INFO
        }
      '';

      virtualHosts.":443" = {
        extraConfig = ''
          respond 421
        '';
      };

      virtualHosts."${config.custom.gitDomain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:${toString config.services.forgejo.settings.server.HTTP_PORT}
        '';
      };
    };

    systemd.services.caddy.serviceConfig.EnvironmentFile = lib.mkIf (
      config.custom.zerosslEabFile != null
    ) [
      config.custom.zerosslEabFile
    ];

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
