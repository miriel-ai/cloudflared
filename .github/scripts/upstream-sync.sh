#!/usr/bin/env bash
# upstream-sync.sh -- keep the miriel-ai/cloudflared fork in step with upstream.
#
# 1. Fast-forward the fork's `master` to lexfrei/cloudflared's `master`
#    (plain push, never forced; a diverged master is refused).
# 2. Find the newest cloudflare/cloudflared release tag (YYYY.M.P). If the
#    integration branch (`miriel`) does not contain it, publish that tag's
#    commit as the branch sync/upstream-<tag> so a PR can merge it into
#    `miriel` with a merge commit.
#
# Environment:
#   UPSTREAM_URL   lexfrei/cloudflared repository URL        (required)
#   RELEASE_URL    cloudflare/cloudflared repository URL     (required)
#   MIRROR_BRANCH  fork branch mirroring UPSTREAM_URL        (default: master)
#   BASE_BRANCH    integration branch that gets the PR       (default: miriel)
#   DRY_RUN        "true" to report without pushing          (default: false)
#   GITHUB_OUTPUT  when set, receives needs_pr, tag, branch, sha
#
# Exit status is non-zero on any failure, including a rejected push.

set -euo pipefail

: "${UPSTREAM_URL:?UPSTREAM_URL is required}"
: "${RELEASE_URL:?RELEASE_URL is required}"
MIRROR_BRANCH="${MIRROR_BRANCH:-master}"
BASE_BRANCH="${BASE_BRANCH:-miriel}"
DRY_RUN="${DRY_RUN:-false}"

err="$(mktemp)"
trap 'rm -f "${err}"' EXIT

# push_ff <sha> <ref>: a plain push; GitHub rejects anything but a
# fast-forward (or a new ref). Explains the one rejection we expect.
push_ff() {
  if ! git push origin "$1:$2" 2>"${err}"; then
    cat "${err}" >&2
    if grep -q "without .workflows. permission" "${err}"; then
      echo "::error::GITHUB_TOKEN cannot push commits that change .github/workflows/*. Upstream changed workflow files, so $2 has to be pushed by someone whose credentials carry the workflows permission."
    else
      echo "::error::pushing $2 was rejected."
    fi
    return 1
  fi
}

git fetch --quiet --no-tags origin \
  "+refs/heads/${MIRROR_BRANCH}:refs/remotes/origin/${MIRROR_BRANCH}" \
  "+refs/heads/${BASE_BRANCH}:refs/remotes/origin/${BASE_BRANCH}"
git fetch --quiet --no-tags "${UPSTREAM_URL}" "+refs/heads/master:refs/remotes/upstream/master"

# 1. Mirror branch.
mirror="$(git rev-parse "refs/remotes/origin/${MIRROR_BRANCH}")"
upstream="$(git rev-parse refs/remotes/upstream/master)"

if [[ "${mirror}" == "${upstream}" ]]; then
  echo "${MIRROR_BRANCH} is already at upstream master (${upstream:0:12})."
elif git merge-base --is-ancestor "${mirror}" "${upstream}"; then
  echo "Fast-forwarding ${MIRROR_BRANCH} ${mirror:0:12} -> ${upstream:0:12}."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "dry run: not pushing."
  else
    push_ff "${upstream}" "refs/heads/${MIRROR_BRANCH}"
  fi
else
  echo "::error::${MIRROR_BRANCH} (${mirror:0:12}) is not an ancestor of upstream master (${upstream:0:12}); it has commits upstream does not. Not touching it; a person has to reconcile it."
  exit 1
fi

# 2. Newest cloudflare/cloudflared release tag.
tag="$(git ls-remote --tags --refs "${RELEASE_URL}" \
  | sed -n 's|.*refs/tags/\([0-9]\{4\}\.[0-9]\{1,2\}\.[0-9]\{1,2\}\)$|\1|p' \
  | sort -V | tail -n 1)"
[[ -n "${tag}" ]] || { echo "::error::no YYYY.M.P release tag found at ${RELEASE_URL}."; exit 1; }

git fetch --quiet --no-tags "${RELEASE_URL}" "+refs/tags/${tag}:refs/remotes/release/${tag}"
sha="$(git rev-parse "refs/remotes/release/${tag}^{commit}")"
branch="sync/upstream-${tag}"

needs_pr=false
if git merge-base --is-ancestor "${sha}" "refs/remotes/origin/${BASE_BRANCH}"; then
  echo "Newest release ${tag} (${sha:0:12}) is already in ${BASE_BRANCH}; nothing to merge."
else
  needs_pr=true
  echo "Release ${tag} (${sha:0:12}) is not in ${BASE_BRANCH}."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "dry run: not pushing ${branch}."
  else
    # A new ref, or the same commit again. A tag never moves, so an existing
    # branch at another commit is a surprise worth stopping for.
    existing="$(git ls-remote --heads origin "refs/heads/${branch}" | cut -f1)"
    if [[ -n "${existing}" && "${existing}" != "${sha}" ]]; then
      echo "::error::${branch} already exists at ${existing:0:12}, not ${sha:0:12}. Not touching it."
      exit 1
    fi
    if [[ -z "${existing}" ]]; then
      push_ff "${sha}" "refs/heads/${branch}"
    fi
  fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "needs_pr=${needs_pr}"
    echo "tag=${tag}"
    echo "branch=${branch}"
    echo "sha=${sha}"
  } >> "${GITHUB_OUTPUT}"
fi
