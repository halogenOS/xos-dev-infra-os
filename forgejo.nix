{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.forgejo;
  appIni = "${cfg.stateDir}/custom/conf/app.ini";

  # Idempotent Zitadel OIDC auth source setup.
  # Runs as forgejo user inside forgejo.service's preStart, so the HTTP
  # server literally cannot start before this has succeeded.
  oidcSetup = pkgs.writeShellApplication {
    name = "forgejo-oidc-setup";
    runtimeInputs = [
      cfg.package
      pkgs.gawk
    ];
    text = ''
      : "''${CLIENT_ID:?CLIENT_ID missing from OIDC env file}"
      : "''${CLIENT_SECRET:?CLIENT_SECRET missing from OIDC env file}"

      forgejo_cmd=(forgejo --config ${appIni})

      "''${forgejo_cmd[@]}" migrate

      existing_id=$(
        "''${forgejo_cmd[@]}" admin auth list \
          | awk 'NR>1 && $2 == "zitadel" { print $1; exit }'
      )

      args=(
        --name zitadel
        --provider openidConnect
        --key "$CLIENT_ID"
        --secret "$CLIENT_SECRET"
        --auto-discover-url "https://${config.custom.ssoDomain}/.well-known/openid-configuration"
        --scopes "openid profile email"
        --group-claim-name roles
        --admin-group admin
      )

      if [ -n "$existing_id" ]; then
        "''${forgejo_cmd[@]}" admin auth update-oauth --id "$existing_id" "''${args[@]}"
      else
        "''${forgejo_cmd[@]}" admin auth add-oauth "''${args[@]}"
      fi
    '';
  };
in
{
  options.custom = {
    gitDomain = lib.mkOption {
      type = lib.types.str;
      description = "Forgejo web domain (e.g., git.halogenos.org)";
    };
    ssoDomain = lib.mkOption {
      type = lib.types.str;
      description = "Zitadel SSO domain used as OIDC issuer (e.g., sso.halogenos.org)";
    };
    forgejoOidcEnvFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/credentials/forgejo-oidc.env";
      description = ''
        Path to OIDC credentials env file containing:
        CLIENT_ID=<zitadel client id>
        CLIENT_SECRET=<zitadel client secret>

        Forgejo refuses to start if this file is missing.
      '';
    };
  };

  config = {
    services.forgejo = {
      enable = true;

      stateDir = "/var/lib/forgejo";
      repositoryRoot = "/var/lib/forgejo/repositories";

      database = {
        type = "postgres";
        createDatabase = true;
      };

      settings = {
        server = {
          DOMAIN = config.custom.gitDomain;
          ROOT_URL = "https://${config.custom.gitDomain}/";
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = 3000;
          PROTOCOL = "http";
          DISABLE_SSH = false;
          SSH_PORT = 22;
          START_SSH_SERVER = true;
          SSH_LISTEN_HOST = "0.0.0.0";
          LANDING_PAGE = "explore";
        };

        session.COOKIE_SECURE = true;

        service = {
          DISABLE_REGISTRATION = true;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = false;
          ENABLE_NOTIFY_MAIL = false;
        };

        oauth2_client = {
          ENABLE_AUTO_REGISTRATION = true;
          ACCOUNT_LINKING = "auto";
          USERNAME = "preferred_username";
          UPDATE_AVATAR = true;
        };

        packages.ENABLED = false;
        actions.ENABLED = false;

        log.LEVEL = "Info";
      };
    };

    systemd.services.forgejo = {
      unitConfig.ConditionPathExists = toString config.custom.forgejoOidcEnvFile;

      serviceConfig = {
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        EnvironmentFile = [ (toString config.custom.forgejoOidcEnvFile) ];
      };

      preStart = lib.mkAfter ''
        ${lib.getExe oidcSetup}
      '';
    };

    environment.systemPackages = [ pkgs.git ];
  };
}
