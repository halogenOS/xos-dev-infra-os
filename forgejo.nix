{
  config,
  lib,
  pkgs,
  foundrix,
  ...
}:
let
  cfg = config.services.forgejo;

  # A compiled binary, not a shell script: the credentials reach it on
  # stdin only. It proves them by authenticating an RFC 7662 introspection
  # call against the discovered endpoint (Zitadel reserves the
  # client_credentials grant for service accounts, so a token request
  # cannot prove an app credential), catching a typo or a stale secret at
  # entry instead of as a broken login hours later.
  #
  # callPackage on the path, not `foundrixPkgs.oidc-credential-validator`:
  # foundrixPkgs comes from lib.filesystem.packagesFromDirectoryRecursive,
  # which keys on `package.nix`. foundrix's directory-based packages use
  # `default.nix`, so they are NOT exposed as attrs there — the name
  # resolves to a scope, and `lib.getExe` on it fails eval. This is the
  # same way config/filesystem/var-luks.nix reaches var-disk-manager.
  oidcValidator = pkgs.callPackage (foundrix + "/packages/oidc-credential-validator") { };
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

      # KNOWN EXPOSURE: `--secret` is the only channel forgejo's CLI
      # offers for the client secret (verified against forgejo-lts 15.0.3
      # `admin auth add-oauth --help`: no file, stdin or env alternative),
      # so for the duration of this command the value is readable by any
      # local unprivileged user in /proc/<pid>/cmdline. Everything up to
      # here keeps it off argv; this last hop cannot, short of a change in
      # Forgejo. See docs/operator-secrets.md "Known exception".
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

        Written by foundrix.services.operator-secrets, which blocks the boot
        until the credentials are present and proven good against the
        configured SSO issuer. forgejo.service Requires= that collector, so
        a missing credential fails loudly instead of silently skipping the
        unit.
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

    # The OIDC client credentials come from core-infra's Zitadel; nothing
    # may transport them automatically, so an operator carries them in once
    # and the collector proves them against the SSO host (see oidcValidator
    # above) before the boot proceeds. No ConditionPathExists guard here:
    # the Requires=/After= that `requiredBy` installs expresses the
    # requirement properly, so an absent credential blocks with an
    # explanation instead of leaving forgejo.service silently not started.
    foundrix.services.operator-secrets.secrets.forgejo-oidc = {
      description = "Forgejo OIDC client credentials (from core-infra Zitadel)";
      fields = {
        CLIENT_ID = {
          description = "OIDC client identifier";
          order = 10;
        };
        CLIENT_SECRET = {
          description = "OIDC client secret";
          order = 20;
          sensitive = true;
        };
      };
      validateCommand = [
        (lib.getExe oidcValidator)
        "--issuer"
        "https://${config.custom.ssoDomain}"
      ];
      path = toString config.custom.forgejoOidcEnvFile;
      owner = "forgejo";
      mode = "0400";
      requiredBy = [ "forgejo.service" ];
    };

    systemd.services.forgejo = {
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
