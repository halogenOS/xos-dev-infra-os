# Forgejo branding

halogenOS brand colour is `#00B4E7`. Everything visual lives in
[`../branding`](../branding): the logo, the theme, and the module that installs
both. Zitadel's side of the same identity is configured in core-infra
(`branding/default.nix` + `instance.branding`), and the two are meant to look
like one product because a user crosses between them mid-login.

## Assets

`branding/logo.svg` is the single source of truth. Forgejo reads a fixed set of
filenames out of `$FORGEJO_CUSTOM/public/assets/img/`, and falls back to its own
orange assets for any it does not find, so the module places:

| File | Where it shows |
| --- | --- |
| `logo.svg` | navbar, app icon |
| `favicon.svg`, `favicon.png` | browser tab |
| `logo.png` | Open Graph cards, home page |
| `apple-touch-icon.png` | iOS home screen |

The PNGs are rasterized from the SVG with `resvg` at build time rather than
committed, so there is exactly one file to edit and the sizes cannot drift apart.
`avatar_default.png` and `repo_default.png` are deliberately left upstream:
Forgejo generates identicons for users, so a branded default would rarely appear
and would look like a bug when it did.

The whole `custom/public` subtree is a single `L+` tmpfiles symlink to the store
path. Forgejo only ever reads from there, so this gets atomic asset swaps on
rebuild with no stale leftovers, while `custom/conf` — which holds the generated
`secret_key` and `app.ini` — stays writable and untouched.

### The logo is a port, not a redraw

`branding/logo.svg` reproduces core-infra's `branding/generate-logo.py`
(a Pillow renderer for Zitadel) as vectors, because Forgejo wants an SVG for the
navbar and favicon and raster would blur. Every coordinate is that script's
constant divided by its `SUPERSAMPLE`; the header comment carries the
derivation. Verified by rendering both at 512 and diffing: **mean absolute
difference 2.1/255**, with the residual confined to the shadow's falloff, where
Pillow's box-blur approximation and a true Gaussian legitimately differ.

Two quirks of that script are reproduced on purpose, because the goal is to
match **the asset Zitadel actually serves**, not the script's apparent intent:

- The pale triangle is opaque, though `draw_triangle_with_gradient` is passed
  `opacity=140`. The function fills at that alpha and then calls
  `gradient.putalpha(mask)`, which replaces the entire alpha channel. Rendering
  it at the intended 55% turns the mark into a symmetric star instead of one
  triangle overlapping another — the shipped look is the better one.
- The drop shadow is full strength, though `add_drop_shadow` asks for `0.4`,
  via the same `putalpha` overwrite.

If core-infra ever fixes those, this file has to be revisited in the same
change, or the two logos drift apart.

## Theme

`theme-halogenos.css` is installed to `custom/public/assets/css/` and selected
by `[ui] DEFAULT_THEME = halogenos`; Forgejo resolves a theme name to
`theme-<name>.css`, so **the filename is the contract**. `[ui] THEMES` is also
set, because it is a plain replacement rather than a merge — omitting our theme
there would make it unselectable, and dropping upstream's entries would remove
the accessibility themes.

The file imports the stock auto theme and overrides only the brand surface, so
upstream's ~200 lines of variable churn stay upstream's problem. `@import` is
hoisted, so our `:root` rules win on cascade order at equal specificity. The
ramp is written once in terms of two anchors (`--hx-emph`/`--hx-deemph`) that
the dark block flips, because upstream's naming is scheme-relative: in the light
theme `dark-N` gets darker and `light-N` lighter, and in the dark theme it
inverts. `--color-accent` and `--color-highlight-*` are defined upstream in
terms of that ramp, so they follow on their own.

**The light scheme darkens the brand colour** for `--color-primary`. `#00B4E7`
is ~2.4:1 against white, below the 4.5:1 minimum, and this variable colours link
and button *text*. Upstream makes the same move — a deep `#c2410c` in its light
theme against the bright `#fb923c` of its dark one. The brand colour still
carries the light scheme through the page tint and the logo, and appears
unmodified as `--color-primary` in the dark scheme, where the background is
`#001220`.

## The auth source name is a URL

The sign-in button reads "Sign in with SSO" because the auth source is *named*
`SSO`. Forgejo has no display-name field: `AuthSourceProvider.DisplayName()`
returns the source name, `admin auth add-oauth` has no such flag, and the same
name is a path segment of the callback route `/user/oauth2/{name}/callback`.

So the label, the callback URL, and core-infra's registered `redirectUris` are
one coupled fact spread over two repos. Zitadel matches `redirect_uri` exactly.
**Converge core-infra before switching a dev-infra host**; changing one side
alone breaks login.

The converge script keys its lookup on the auth source *type*, not its name.
A name-keyed lookup reports "not found" after a rename and then adds a second
source — two sign-in buttons, one aimed at a callback Zitadel never registered.
Since this module declares exactly one OAuth2 source, the type is the stable
key, `update-oauth` renames in place, and finding more than one is a hard error
rather than a guess.

## Rejected alternatives

- **Naming the source `halogenOS SSO`** to get that exact label. The space lands
  in the callback path (`/user/oauth2/halogenOS%20SSO/callback`), and Zitadel
  compares redirect URIs exactly — raw space versus `%20` is a mismatch waiting
  to be debugged, and Zitadel may refuse a URI containing a literal space.
- **Overriding `templates/user/auth/oauth_container.tmpl`** to decouple label
  from name. Forgejo warns that its templates break across upgrades, and with
  the password form disabled that button is the only way in, so a broken
  template is an outage.
- **Copying upstream's theme and editing it.** Inherits maintenance of every
  variable upstream adds, renames, or removes, to change perhaps fifteen of
  them.
- **Committing the PNGs.** Two sources of truth that silently disagree the first
  time only one is regenerated.
- **Pointing `services.forgejo.customDir` at a store path.** Forgejo writes
  `conf/secret_key` and `app.ini` there; it must stay writable.
