{
  networking.hostName = "xos-dev-infra-int";

  custom.gitDomain = "git-int.halogenos.org";
  # dev-infra-int authenticates against the prod Zitadel on core-infra-prod
  custom.ssoDomain = "sso.halogenos.org";

  # int-only: drop to sulogin on emergency instead of hanging
  boot.kernelParams = [ "systemd.setenv=SYSTEMD_SULOGIN_FORCE=1" ];
}
