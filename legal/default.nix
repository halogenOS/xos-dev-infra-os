{
  config,
  lib,
  pkgs,
  ...
}:
let
  # ---------------------------------------------------------------------------
  # The published identity. This is the ONLY place these facts are written down
  # in this repo; everything else is derived from here or from custom.*Domain,
  # so the cutover from git-staging to git rewrites the documents by itself.
  #
  # Deliberately kept out of foundrix: foundrix is infrastructure, and whose
  # name and address appear on a service is not infrastructure's business.
  # (foundrix still renders the Zitadel privacy policy from a template of its
  # own; removing that is tracked as separate cleanup.)
  # ---------------------------------------------------------------------------
  operator = {
    name = "Simão Gomes Viana";
    # A c/o forwarding address, so a private home address is not published.
    careOf = "c/o IP-Management #10911";
    street = "Ludwig-Erhard-Str. 18";
    city = "20459 Hamburg";
    countryEn = "Germany";
    countryDe = "Deutschland";
  };

  contact = {
    legal = "legal@halogenos.org";
    privacy = "privacy@halogenos.org";
    # For reports about published content. Not a DSA point of contact: nobody
    # outside the operator can obtain an account, so nothing here is stored on
    # behalf of a third party and the service is not an intermediary.
    abuse = "abuse@halogenos.org";
  };

  # Competent authority follows the controller's actual establishment (Bavaria),
  # not the c/o mailing address in Hamburg.
  authority = {
    name = "Bayerisches Landesamt für Datenschutzaufsicht (BayLDA)";
    address = "Promenade 18, 91522 Ansbach";
    website = "https://www.lda.bayern.de";
  };

  hosting.provider = "Hetzner Online GmbH";

  # Bump when the text changes materially — it is a statement to readers about
  # the version they are looking at, so it must not float with the build.
  lastUpdated = {
    en = "26 July 2026";
    de = "26. Juli 2026";
  };

  # Tokens shared by both languages.
  commonVars = {
    operatorName = operator.name;
    operatorCareOf = operator.careOf;
    operatorStreet = operator.street;
    operatorCity = operator.city;
    operatorCountryEn = operator.countryEn;
    operatorCountryDe = operator.countryDe;
    emailLegal = contact.legal;
    emailPrivacy = contact.privacy;
    emailAbuse = contact.abuse;
    gitDomain = config.custom.gitDomain;
    ssoDomain = config.custom.ssoDomain;
    hostingProvider = hosting.provider;
    authorityName = authority.name;
    authorityAddress = authority.address;
    authorityWebsite = authority.website;
    lastUpdatedEn = lastUpdated.en;
    lastUpdatedDe = lastUpdated.de;
  };

  # Place names have to be substituted per language: "Serverhosting in
  # Nuremberg, Germany" would be wrong in the German text.
  langVars = {
    en = {
      hostingLocation = "Nuremberg, Germany";
      dataLocation = "the European Union";
    };
    de = {
      hostingLocation = "Nürnberg, Deutschland";
      dataLocation = "der Europäischen Union";
    };
  };

  # `substitute` comes from stdenv's setup.sh and replaces @token@ literally,
  # with no shell involved in the value — so an apostrophe or an umlaut in an
  # address cannot break out into the build script.
  substArgs =
    vars:
    lib.concatStringsSep " " (
      lib.mapAttrsToList (name: value: "--subst-var-by ${lib.escapeShellArg name} ${lib.escapeShellArg value}") vars
    );

  # route -> { src, lang }. The route is the public URL; the German documents
  # keep German URLs, which is also how a reader tells them apart at a glance.
  #
  # The HTML is the source and is edited directly. It started life as Markdown
  # run through pandoc, but that indirection kept imposing its own decisions —
  # a default stylesheet outranking ours on specificity, and `@token@` parsed
  # as a citation key — while buying nothing. Editing the markup we actually
  # serve is simpler to reason about and drops a tool from the closure.
  documents = {
    imprint = {
      src = ./imprint.en.html;
      lang = "en";
    };
    privacy = {
      src = ./privacy.en.html;
      lang = "en";
    };
    terms = {
      src = ./terms.en.html;
      lang = "en";
    };
    impressum = {
      src = ./impressum.de.html;
      lang = "de";
    };
    datenschutz = {
      src = ./datenschutz.de.html;
      lang = "de";
    };
    nutzungsbedingungen = {
      src = ./nutzungsbedingungen.de.html;
      lang = "de";
    };
  };

  legalDocs = pkgs.runCommand "xos-legal-documents" { } (
    ''
      mkdir -p $out
      install -m444 ${./style.css} $out/legal.css
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (route: doc: ''
        substitute ${doc.src} $out/${route}.html ${substArgs (commonVars // langVars.${doc.lang})}
      '') documents
    )
  );

  # Forgejo's supported extension point for footer links — a custom template
  # slot rather than an override of an upstream one, so it does not carry the
  # usual "templates break on upgrade" risk. §5 DDG wants the imprint reachable
  # from everywhere, which in practice means the footer of every page.
  forgejoTemplates = pkgs.runCommand "xos-forgejo-legal-templates" { } ''
    mkdir -p $out/custom
    cat > $out/custom/extra_links_footer.tmpl <<'EOF'
    <a href="/imprint">Imprint</a>
    <a href="/privacy">Privacy</a>
    <a href="/terms">Terms</a>
    EOF
  '';
in
{
  systemd.tmpfiles.rules = [
    "L+ ${config.services.forgejo.customDir}/templates - - - - ${forgejoTemplates}"
  ];

  # Templates are read once at start-up (unlike custom/public, which is served
  # from disk per request), so without this a switch would swap the symlink and
  # change nothing until the next restart.
  systemd.services.forgejo.restartTriggers = [ forgejoTemplates ];

  # Served on the Forgejo domain, ahead of the reverse proxy. Caddy orders
  # `handle` before `reverse_proxy`, and a request matching none of these falls
  # through to Forgejo untouched, so caddy.nix needs no change.
  services.caddy.virtualHosts."${config.custom.gitDomain}".extraConfig = lib.mkBefore (
    lib.concatStrings (
      lib.mapAttrsToList (route: _: ''
        handle /${route} {
          root * ${legalDocs}
          rewrite * /${route}.html
          file_server
        }
      '') documents
    )
    # The shared stylesheet the documents link to. Served from the same store
    # path, so it is swapped atomically with them and can never be a version behind.
    + ''
      handle /legal.css {
        root * ${legalDocs}
        file_server
      }
    ''
  );
}
