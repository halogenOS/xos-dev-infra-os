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

  # This is the sign-in button's label AND a path segment of the OAuth callback
  # URL: Forgejo routes /user/oauth2/{name}/callback and its
  # AuthSourceProvider.DisplayName() returns the same source name, with no
  # separate display-name field anywhere (there is no such flag on
  # `admin auth add-oauth`). So changing it changes the redirect URI, which
  # core-infra's Zitadel registers verbatim — the two must be edited together,
  # and core-infra has to be converged before this host is switched, or Zitadel
  # rejects the callback. Kept free of whitespace and URL-reserved characters
  # for that reason.
  authSourceName = "SSO";

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

      # Keyed on the TYPE column rather than the name, because the name is a
      # display concern that can change (it did: zitadel -> SSO). A name-keyed
      # lookup answers "not found" after a rename and then ADDS a second
      # source, which shows up as two sign-in buttons, one of them pointing at
      # a callback Zitadel has never heard of. This module declares exactly one
      # OAuth2 source, so the type is the stable key and update-oauth renames
      # in place. Column 3 is the type in `admin auth list`'s space-padded
      # output; safe to index because the names set here carry no whitespace.
      mapfile -t oauth_ids < <(
        "''${forgejo_cmd[@]}" admin auth list \
          | awk 'NR>1 && $3 == "OAuth2" { print $1 }'
      )

      if [ "''${#oauth_ids[@]}" -gt 1 ]; then
        echo "refusing to converge: several OAuth2 auth sources exist (ids: ''${oauth_ids[*]})" >&2
        echo "this module owns exactly one; remove the strays before retrying" >&2
        exit 1
      fi

      existing_id="''${oauth_ids[0]:-}"

      # KNOWN EXPOSURE: `--secret` is the only channel forgejo's CLI
      # offers for the client secret (verified against forgejo-lts 15.0.3
      # `admin auth add-oauth --help`: no file, stdin or env alternative),
      # so for the duration of this command the value is readable by any
      # local unprivileged user in /proc/<pid>/cmdline. Everything up to
      # here keeps it off argv; this last hop cannot, short of a change in
      # Forgejo. See docs/operator-secrets.md "Known exception".
      args=(
        --name ${authSourceName}
        --provider openidConnect
        --key "$CLIENT_ID"
        --secret "$CLIENT_SECRET"
        --auto-discover-url "https://${config.custom.ssoDomain}/.well-known/openid-configuration"
        --scopes "openid profile email"
        --group-claim-name roles
        --admin-group admin
        # Replaces the generic OIDC glyph on the button with our own mark.
        # Served by the branding module out of custom/public, and relative so
        # it survives the git-staging -> git domain flip untouched.
        --icon-url /assets/img/logo.svg
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
    # Anubis sits between Caddy and Forgejo: browser-like user agents solve
    # a proof-of-work challenge before reaching the forge, which is what
    # keeps AI scrapers from crawling every commit of every repository.
    # Default policy — git and API clients pass through unchallenged. Open
    # Graph passthrough keeps link previews working without exempting each
    # messenger's scraper individually.
    services.anubis.instances.forgejo.settings = {
      TARGET = "http://127.0.0.1:${toString config.services.forgejo.settings.server.HTTP_PORT}";
      OG_PASSTHROUGH = true;
      OG_EXPIRY_TIME = "24h";
    };

    # Caddy reaches the instance over its unix socket.
    users.users.caddy.extraGroups = [ config.users.groups.anubis.name ];

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
          # The conventional git@ in clone URLs, decoupled from the unix
          # user the service runs as (which stays `forgejo`, along with all
          # state ownership). The built-in SSH server both displays and
          # accepts this name.
          BUILTIN_SSH_SERVER_USER = "git";
          LANDING_PAGE = "explore";
        };

        session.COOKIE_SECURE = true;

        service = {
          DISABLE_REGISTRATION = true;
          ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = false;
          ENABLE_NOTIFY_MAIL = false;
          # Zitadel is the only identity source: no local passwords exist,
          # so the username/password form is dead weight on the sign-in
          # page. This leaves just the "Sign in with zitadel" button.
          # ENABLE_BASIC_AUTHENTICATION stays untouched — git-over-https
          # token auth must keep working.
          ENABLE_PASSWORD_SIGNIN_FORM = false;
          ENABLE_INTERNAL_SIGNIN = false;
        };

        oauth2_client = {
          ENABLE_AUTO_REGISTRATION = true;
          ACCOUNT_LINKING = "auto";
          # Derive the Forgejo username from the local part of the email
          # rather than from preferred_username. Zitadel hands over its
          # loginname verbatim, and ours are email addresses
          # (admin@halogenos.org) — but Forgejo only permits alphanumerics,
          # dash, underscore and dot, so auto-registration died with
          # "CreateUser: name is invalid". This mode splits at the "@", which
          # fixes it for every user at once instead of requiring each Zitadel
          # account to be renamed.
          #
          # Safe because the username is cosmetic after creation: Forgejo
          # links accounts by auth source + OIDC subject, not by name. The one
          # exposure is a collision if two local parts ever match, which a
          # single org on one domain cannot produce.
          USERNAME = "email";
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
        # The built-in SSH server binds 0.0.0.0:22 as the forgejo user, which
        # needs CAP_NET_BIND_SERVICE — and needs it in the INIT user
        # namespace: upstream's hardening sets PrivateUsers=true, and inside
        # that private namespace the ambient capability cannot bind host
        # ports (bind: permission denied, service crash-loop). mkForce on
        # the bounding set because upstream's "" is a RESET marker in
        # systemd's list merging, so plain merging would be order-dependent.
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
        PrivateUsers = lib.mkForce false;
        EnvironmentFile = [ (toString config.custom.forgejoOidcEnvFile) ];
      };

      preStart = lib.mkAfter ''
        ${lib.getExe oidcSetup}
      '';
    };

    environment.systemPackages = [ pkgs.git ];
  };
}
