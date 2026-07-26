{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Every raster size is derived from the one SVG, so the mark has a single
  # source of truth. Forgejo asks for both forms and falls back to its own
  # orange assets for any file we do not place: SVG for the navbar and the
  # favicon, PNG for Open Graph cards and the iOS home-screen icon.
  #
  # apple-touch-icon keeps the transparent background: iOS composites it onto
  # black, which is what this mark is drawn for (it is core-infra's "dark"
  # logo variant), so a baked-in background would only risk a seam.
  assets = pkgs.runCommand "xos-forgejo-branding" { nativeBuildInputs = [ pkgs.resvg ]; } ''
    img=$out/assets/img
    css=$out/assets/css
    mkdir -p "$img" "$css"

    install -m444 ${./logo.svg} "$img/logo.svg"
    install -m444 ${./logo.svg} "$img/favicon.svg"
    install -m444 ${./theme-halogenos.css} "$css/theme-halogenos.css"

    resvg --width 512 ${./logo.svg} "$img/logo.png"
    resvg --width 180 ${./logo.svg} "$img/favicon.png"
    resvg --width 180 ${./logo.svg} "$img/apple-touch-icon.png"
  '';

  # Upstream's list as of forgejo-lts 15.0.x, kept so enabling ours does not
  # silently drop the accessibility themes: THEMES is a plain replacement, not
  # a merge. Refresh it if a Forgejo upgrade adds themes. DEFAULT_THEME is not
  # validated against it (modules/setting/ui.go just ini-maps both), but THEMES
  # is what lets a signed-in user pick a theme at all.
  upstreamThemes = [
    "forgejo-auto"
    "forgejo-light"
    "forgejo-dark"
    "gitea-auto"
    "gitea-light"
    "gitea-dark"
    "forgejo-auto-deuteranopia-protanopia"
    "forgejo-light-deuteranopia-protanopia"
    "forgejo-dark-deuteranopia-protanopia"
    "forgejo-auto-tritanopia"
    "forgejo-light-tritanopia"
    "forgejo-dark-tritanopia"
  ];
in
{
  # Forgejo only ever reads custom/public, so the whole subtree can be a store
  # symlink — which also means a rebuild replaces every asset atomically and
  # leaves nothing stale behind. custom/conf, which holds the generated
  # secret_key and app.ini, stays writable and untouched.
  systemd.tmpfiles.rules = [
    "L+ ${config.services.forgejo.customDir}/public - - - - ${assets}"
  ];

  services.forgejo.settings.ui = {
    DEFAULT_THEME = "halogenos";
    THEMES = lib.concatStringsSep "," ([ "halogenos" ] ++ upstreamThemes);
  };
}
