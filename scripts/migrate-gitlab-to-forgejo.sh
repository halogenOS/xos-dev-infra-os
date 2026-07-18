#!/usr/bin/env bash
# One-time migration of all public repos from a GitLab group into a single
# flat Forgejo organization. Git data only (branches + tags); the source has
# no issues/MRs/wiki/releases to carry over.
#
# Idempotent: repos that already exist in the target org are skipped, so the
# script can be interrupted and re-run. A migration that failed server-side
# can leave a broken repo behind in Forgejo — delete it there and re-run.
#
# Required:
#   FORGEJO_URL    e.g. https://git-int.halogenos.org
#   FORGEJO_TOKEN  Forgejo access token (write:organization, write:repository)
# Optional:
#   GITLAB_URL     source GitLab (default https://git.halogenos.org)
#   GITLAB_GROUP   source group (default halogenOS)
#   TARGET_ORG     Forgejo org to migrate into (default same as GITLAB_GROUP)
#   REPO_FILTER    only migrate repos whose path matches this regex (for
#                  testing / partial runs)
set -euo pipefail

GITLAB_URL=${GITLAB_URL:-https://git.halogenos.org}
GITLAB_GROUP=${GITLAB_GROUP:-halogenOS}
FORGEJO_URL=${FORGEJO_URL:?set FORGEJO_URL to the target Forgejo base URL}
FORGEJO_TOKEN=${FORGEJO_TOKEN:?set FORGEJO_TOKEN to a Forgejo access token}
TARGET_ORG=${TARGET_ORG:-$GITLAB_GROUP}
REPO_FILTER=${REPO_FILTER:-.*}

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

# forgejo <expected-status-regex> <method> <path> [json-body]
# Prints the response body; fails if the status doesn't match.
forgejo() {
  local expect=$1 method=$2 path=$3 body=${4:-}
  local args=(
    -sS -X "$method" --max-time 7200
    -H "Authorization: token $FORGEJO_TOKEN"
    -H "Content-Type: application/json"
    -o /tmp/forgejo-resp.$$ -w '%{http_code}'
    "$FORGEJO_URL/api/v1$path"
  )
  [ -n "$body" ] && args+=(-d "$body")
  local status
  status=$(curl "${args[@]}")
  cat /tmp/forgejo-resp.$$
  rm -f /tmp/forgejo-resp.$$
  [[ $status =~ ^($expect)$ ]]
}

echo "Enumerating $GITLAB_URL group $GITLAB_GROUP..."
projects=$(
  page=1
  while :; do
    resp=$(curl -sSf --max-time 60 \
      "$GITLAB_URL/api/v4/groups/$GITLAB_GROUP/projects?per_page=100&page=$page&include_subgroups=true")
    jq -c --arg filter "$REPO_FILTER" '.[] | select(.path | test($filter))' <<<"$resp"
    [ "$(jq 'length' <<<"$resp")" -lt 100 ] && break
    page=$((page + 1))
  done
)
if [ -z "$projects" ]; then
  echo "No projects matched (filter: $REPO_FILTER)." >&2
  exit 1
fi
total=$(wc -l <<<"$projects")
echo "Found $total projects."

if ! forgejo 200 GET "/orgs/$TARGET_ORG" >/dev/null; then
  echo "Creating organization $TARGET_ORG..."
  forgejo 201 POST /orgs \
    "$(jq -n --arg name "$TARGET_ORG" '{username: $name, visibility: "public"}')" >/dev/null
fi

n=0 migrated=0 skipped=0 empty=0 failed=0
failures=()
while IFS= read -r project; do
  n=$((n + 1))
  name=$(jq -r .path <<<"$project")
  clone_addr=$(jq -r .http_url_to_repo <<<"$project")
  default_branch=$(jq -r '.default_branch // empty' <<<"$project")
  archived=$(jq -r .archived <<<"$project")
  prefix="[$n/$total] $name:"

  if forgejo 200 GET "/repos/$TARGET_ORG/$name" >/dev/null; then
    echo "$prefix exists, skipping"
    skipped=$((skipped + 1))
    continue
  fi

  if [ -z "$default_branch" ]; then
    echo "$prefix empty on GitLab, not migrating"
    empty=$((empty + 1))
    continue
  fi

  echo "$prefix migrating from $clone_addr"
  body=$(jq -n --arg addr "$clone_addr" --arg owner "$TARGET_ORG" --arg name "$name" \
    --arg desc "$(jq -r '.description // ""' <<<"$project")" \
    '{clone_addr: $addr, repo_owner: $owner, repo_name: $name,
      service: "git", mirror: false, private: false, description: $desc}')
  if ! forgejo 201 POST /repos/migrate "$body" >/dev/null; then
    echo "$prefix migration FAILED" >&2
    failed=$((failed + 1)); failures+=("$name")
    continue
  fi

  patch=$(jq -n --arg branch "$default_branch" --argjson archived "$archived" \
    '{default_branch: $branch, archived: $archived}')
  forgejo 200 PATCH "/repos/$TARGET_ORG/$name" "$patch" >/dev/null \
    || echo "$prefix warning: could not set default branch/archived flag" >&2
  migrated=$((migrated + 1))
done <<<"$projects"

echo
echo "Done: $migrated migrated, $skipped skipped (already present), $empty empty (not migrated), $failed failed."
if [ "$failed" -gt 0 ]; then
  printf 'Failed: %s\n' "${failures[@]}" >&2
  echo "Delete any broken repos in Forgejo, then re-run to retry." >&2
  exit 1
fi
