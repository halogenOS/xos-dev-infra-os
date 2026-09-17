{
  networking.hostName = "xos-dev-infra-prod";

  # Forgejo's DOMAIN/ROOT_URL and the Caddy vhost all derive from this, and
  # the forgejo-prod Zitadel app accepts this callback, so the name is the
  # single point of truth. The host was validated under
  # git-staging.halogenos.org first; that name is retired.
  custom.gitDomain = "git.halogenos.org";
  custom.ssoDomain = "sso.halogenos.org";

  # The public site. Only prod serves it; int leaves custom.webDomain null, so
  # the service and its vhosts do not exist there.
  custom.webDomain = "halogenos.org";
}
