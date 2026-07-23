# GitLab → Forgejo migration

The halogenOS GitLab at `git.halogenos.org` (group `halogenOS`, 546 public
repos, no subgroups) is being replaced by the Forgejo instances defined in
this repo. Forgejo prod is configured to take over the **same domain**
(`custom.gitDomain = git.halogenos.org`), so migration must happen while
GitLab still owns the domain; the DNS flip is the final step.

Only git data (branches + tags) is migrated. The GitLab carries no issues,
merge requests, wikis, releases, labels or milestones. Repos land flat in a
single Forgejo organization named after the group, keeping their names.

## Staging-first cutover

To avoid disturbing current `git.halogenos.org` (GitLab) users, the prod
Forgejo is brought up **under `git-staging.halogenos.org` first**
(`environments/prod.nix` sets `custom.gitDomain` there). Once it is
confirmed working end-to-end, that one line flips to `git.halogenos.org` and
the host is redeployed — nothing else changes: Forgejo's `DOMAIN`/`ROOT_URL`
and the Caddy vhost all derive from `gitDomain`, and the `forgejo-prod`
Zitadel app already accepts both redirect URIs, so the credential entered at
first boot stays valid across the repoint.

The migration therefore runs in two passes:

1. **Rehearsal on staging** — while `gitDomain = "git-staging.halogenos.org"`,
   run the script with `FORGEJO_URL=https://git-staging.halogenos.org`. This
   proves the whole chain (SSO login, token, server-side clone) against live
   SSO without touching anything users see, and it warms all 546 repos.
2. **Cutover** — flip `gitDomain` to `git.halogenos.org`, redeploy, make
   GitLab read-only, run the script once more against the now-live
   `https://git.halogenos.org` to pick up any last pushes (only new repos are
   retried; for repos that changed since the rehearsal, delete them in
   Forgejo first or re-push manually), then point DNS for `git.halogenos.org`
   at the Forgejo host. After the flip, existing `git.halogenos.org/...`
   clone URLs must resolve to Forgejo — that continuity is only testable at
   flip time.

## Mechanism

`scripts/migrate-gitlab-to-forgejo.sh` enumerates the group via GitLab's
public API and drives Forgejo's server-side migration API
(`POST /api/v1/repos/migrate`, `service: git`) — the Forgejo host clones each
repo directly from GitLab. Per repo it preserves description, default branch
(AOSP-style branches like `XOS-16.2`) and the archived flag. Empty repos on
GitLab are not migrated at all. Already-existing repos are skipped, so the
script is resumable by re-running it.

Rejected alternatives:

- **Local `git clone --mirror` + push**: moves every byte through the
  operator's machine twice; hundreds of AOSP repos, some multi-GB. The
  server-side migration API clones GitLab→Forgejo directly.
- **`service: gitlab` migration**: only adds metadata migration (issues/MRs),
  which the source doesn't have, and would require a GitLab token. Plain
  `git` service needs nothing.
- **Pull mirrors with later detach**: explicitly not wanted — this is a
  one-time cutover; GitLab is abandoned afterwards.

## Runbook

1. Log into the target Forgejo as an admin (Zitadel `admin` role) and create
   an access token: *Settings → Applications*, scopes `write:organization`
   and `write:repository`.
2. Run, from any machine that can reach both sides (staging rehearsal):

   ```sh
   FORGEJO_URL=https://git-staging.halogenos.org \
   FORGEJO_TOKEN=... \
   ./scripts/migrate-gitlab-to-forgejo.sh
   ```

   Source defaults to `https://git.halogenos.org` group `halogenOS`, target
   org `halogenOS`; override with `GITLAB_URL`/`GITLAB_GROUP`/`TARGET_ORG`.
3. Verify: repo count matches the script's summary, spot-check default
   branches and tags of a few repos (e.g. a kernel and a frameworks repo).
4. If a migration fails server-side, Forgejo can leave a broken repo behind:
   delete it in the Forgejo UI, then re-run the script (existing repos are
   skipped, the deleted one is retried).
5. Cutover per "Staging-first cutover" above: flip `gitDomain` to
   `git.halogenos.org`, redeploy, make GitLab read-only, run the script once
   more against the live domain to pick up any last pushes, then repoint DNS.
