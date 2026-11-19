#!/usr/bin/env bash
# upstream-sync_test.sh -- tests for upstream-sync.sh against local repos.
# Plain bash, no test framework.

# Helpers are called indirectly through check/check_fails.
# shellcheck disable=SC2329
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/upstream-sync.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fail=0

# Layout: release.git (cloudflare/cloudflared, tagged), lexfrei.git
# (lexfrei/cloudflared), origin.git (the fork: master = lexfrei's master,
# miriel = release 2026.11.1 + a fork commit), work = a clone of origin.
setup() {
  rm -rf "${tmp:?}"/*
  git init -q --bare -b master "${tmp}/release.git"
  git init -q --bare -b master "${tmp}/lexfrei.git"
  git init -q --bare -b master "${tmp}/origin.git"
  git init -q -b master "${tmp}/rel"
  git -C "${tmp}/rel" commit -q --allow-empty -m r2026.11.1
  git -C "${tmp}/rel" tag 2026.11.1
  git -C "${tmp}/rel" tag 2026.9.3 HEAD
  git -C "${tmp}/rel" push -q --tags "${tmp}/release.git" master
  git -C "${tmp}/rel" push -q "${tmp}/lexfrei.git" master
  git -C "${tmp}/rel" push -q "${tmp}/origin.git" master
  git -C "${tmp}/rel" checkout -q -b miriel
  git -C "${tmp}/rel" commit -q --allow-empty -m fork-change
  git -C "${tmp}/rel" push -q "${tmp}/origin.git" miriel
  git -C "${tmp}/rel" checkout -q master
  git clone -q "${tmp}/origin.git" "${tmp}/work" 2>/dev/null
}

release() { # release <tag>: a new upstream release commit and tag
  git -C "${tmp}/rel" checkout -q master
  git -C "${tmp}/rel" commit -q --allow-empty -m "r$1"
  git -C "${tmp}/rel" tag "$1"
  git -C "${tmp}/rel" push -q --tags "${tmp}/release.git" master
}

lexfrei_commit() {
  git -C "${tmp}/rel" checkout -q master
  git -C "${tmp}/rel" commit -q --allow-empty -m "$1"
  git -C "${tmp}/rel" push -q "${tmp}/lexfrei.git" master
}

run() { # run <dry_run>
  : > "${tmp}/out"
  (cd "${tmp}/work" && UPSTREAM_URL="${tmp}/lexfrei.git" RELEASE_URL="${tmp}/release.git" \
    DRY_RUN="$1" GITHUB_OUTPUT="${tmp}/out" bash "${script}" >"${tmp}/log" 2>&1)
}

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "ok   - ${label}"
  else
    echo "FAIL - ${label}"
    sed 's/^/    /' "${tmp}/log"
    fail=1
  fi
}

check_fails() {
  local label="$1"
  shift
  if "$@"; then
    echo "FAIL - ${label} (succeeded, want failure)"
    sed 's/^/    /' "${tmp}/log"
    fail=1
  else
    echo "ok   - ${label}"
  fi
}

origin_ref() { git -C "${tmp}/origin.git" rev-parse "$1" 2>/dev/null; }
out_has() { grep -q "$1" "${tmp}/out"; }
log_has() { grep -q "$1" "${tmp}/log"; }
same() { [[ "$1" == "$2" ]]; }
branch_missing() { ! git -C "${tmp}/origin.git" rev-parse --verify -q "$1" >/dev/null; }

# miriel's base is release 2026.11.1: nothing to do.
setup
check "no-op succeeds" run false
check "no PR when the newest release is already in miriel" out_has '^needs_pr=false$'
check "no sync branch is created" branch_missing refs/heads/sync/upstream-2026.11.1

# lexfrei moves: master fast-forwards; releases unchanged so still no PR.
lexfrei_commit L1
check "fast-forward succeeds" run false
check "master follows lexfrei" same "$(origin_ref master)" "$(git -C "${tmp}/lexfrei.git" rev-parse master)"
check "lexfrei moving does not by itself need a PR" out_has '^needs_pr=false$'

# A newer release appears: a branch at the tag commit is published.
release 2026.11.2
check "new release run succeeds" run false
check "PR needed for the new release" out_has '^needs_pr=true$'
check "tag is reported" out_has '^tag=2026.11.2$'
check "sync branch is at the tag commit" same "$(origin_ref refs/heads/sync/upstream-2026.11.2)" "$(git -C "${tmp}/release.git" rev-parse '2026.11.2^{commit}')"

# Re-running with the branch in place is fine and does not move it.
before="$(origin_ref refs/heads/sync/upstream-2026.11.2)"
check "re-run succeeds" run false
check "re-run leaves the branch alone" same "$(origin_ref refs/heads/sync/upstream-2026.11.2)" "${before}"

# Sorting is numeric: 2026.11.10 is newer than 2026.11.9.
release 2026.11.9
release 2026.11.10
check "version sort run succeeds" run false
check "2026.11.10 beats 2026.11.9" out_has '^tag=2026.11.10$'

# Dry run pushes nothing.
setup
release 2026.12.0
check "dry run succeeds" run true
check "dry run reports the PR need" out_has '^needs_pr=true$'
check "dry run creates no branch" branch_missing refs/heads/sync/upstream-2026.12.0

# A branch squatting on the name at another commit is refused.
setup
release 2026.12.0
git -C "${tmp}/rel" push -q "${tmp}/origin.git" master:refs/heads/sync/upstream-2026.12.0
git -C "${tmp}/rel" commit -q --allow-empty -m extra
git -C "${tmp}/rel" push -q -f "${tmp}/origin.git" master:refs/heads/sync/upstream-2026.12.0
check_fails "branch at another commit fails" run false
check "mismatch is explained" log_has "already exists at"

# Diverged master: refused and untouched.
setup
git -C "${tmp}/rel" checkout -q -b local-only
git -C "${tmp}/rel" commit -q --allow-empty -m local-on-master
git -C "${tmp}/rel" push -q "${tmp}/origin.git" local-only:master
git -C "${tmp}/rel" checkout -q master
lexfrei_commit L2
before="$(origin_ref master)"
check_fails "diverged master fails" run false
check "diverged master is untouched" same "$(origin_ref master)" "${before}"
check "diverged master explains itself" log_has "not an ancestor"

exit "${fail}"
