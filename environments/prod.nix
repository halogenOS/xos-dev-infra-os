{
  networking.hostName = "xos-dev-infra-prod";

  # Deployed first under git-staging so existing git.halogenos.org (GitLab)
  # users are unaffected. Once Forgejo is confirmed working here, flip this
  # to "git.halogenos.org" and redeploy — nothing else changes: Forgejo's
  # DOMAIN/ROOT_URL and the Caddy vhost all derive from gitDomain, and the
  # forgejo-prod Zitadel app already accepts both redirect URIs.
  custom.gitDomain = "git-staging.halogenos.org";
  custom.ssoDomain = "sso.halogenos.org";
}
