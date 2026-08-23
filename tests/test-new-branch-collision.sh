#!/usr/bin/env bash
#
# Test for `just new-branch` remote-collision handling (wamp-cicd #24).
#
# Drives the REAL workflow.just against throwaway git fixtures that reproduce
# the control-node topology - upstream (canonical), origin (fork), and an
# instance exchange - and asserts the property the bug violated:
#
#   THE RECIPE MUST NOT CREATE ANYTHING IT CANNOT FINISH.
#
# Before the fix, `just new-branch 98` cut the branch, generated and committed
# the audit file, and discovered only at push time that fix_98 already existed
# on the exchange - leaving a local branch with the same NAME, a different
# history, and the user standing on it.
#
# The cases below are written so that each FAILS against the pre-fix recipe.
# A guard watched only passing is not known to work (A13).
#
# Run: bash tests/test-new-branch-collision.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$WORKFLOW_JUST" ] || { echo "FATAL: no $WORKFLOW_JUST" >&2; exit 2; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"   # never read the operator's config
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }

# Build one fixture estate. $1 is its directory; the caller then decides where
# fix_98 exists before invoking the recipe.
fixture() {
  local R="$1"
  mkdir -p "$R"
  local b
  for b in canonical fork exchange; do q git init --bare -b main "$R/$b.git"; done

  q git init -b main "$R/seed"
  ( cd "$R/seed"
    echo seed > README.md
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    q git add -A && q git commit -m seed
    for b in canonical fork exchange; do
      q git remote add "$b" "$R/$b.git"; q git push "$b" main
    done )

  # The control node: upstream is the authority, origin the fork, asgard1 the
  # instance exchange. _workflow-publish-remotes returns "origin asgard1".
  q git clone "$R/canonical.git" "$R/devpc"
  ( cd "$R/devpc"
    q git remote rename origin upstream
    q git remote add origin "$R/fork.git"
    q git remote add asgard1 "$R/exchange.git"
    q git fetch --all )
}

# Publish a real fix_98 to one of the bare repos, as another machine would.
publish_elsewhere() {
  local R="$1" where="$2"
  q git clone "$R/$where.git" "$R/other"
  ( cd "$R/other"
    q git checkout -b fix_98
    echo "real work" > work.txt
    q git add -A && q git commit -m "real work, done elsewhere"
    q git push origin fix_98 )
  rm -rf "$R/other"
}

# check <name> <expected_exit> <expect_local_branch: yes|no> [grep-for]
check() {
  local name="$1" expected="$2" want_branch="$3" needle="${4:-}"
  local R="$5"
  local rc=0
  ( cd "$R/devpc" && just new-branch 98 ) > "${WORK}/log" 2>&1 || rc=$?
  local have_branch=no
  ( cd "$R/devpc" && git show-ref --verify --quiet refs/heads/fix_98 ) && have_branch=yes
  local why=""
  [ "$rc" = "$expected" ]           || why="exit=$rc want=$expected"
  [ "$have_branch" = "$want_branch" ] || why="${why} local-branch=$have_branch want=$want_branch"
  if [ -n "$needle" ] && ! grep -q -- "$needle" "${WORK}/log"; then
    why="${why} missing-message:'${needle}'"
  fi
  if [ -z "$why" ]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] $why"
    sed 's/^/         /' "${WORK}/log" | tail -12
    FAIL=$((FAIL + 1))
  fi
}

echo "== the collision the recipe used to discover at push time (#24) =="

R="${WORK}/on-exchange"; fixture "$R"; publish_elsewhere "$R" exchange
check "branch on the exchange: refuse, and create NOTHING" \
      1 no "already exists on" "$R"

R="${WORK}/on-fork"; fixture "$R"; publish_elsewhere "$R" fork
check "branch on the fork alone is found too" \
      1 no "already exists on" "$R"

R="${WORK}/names-remote"; fixture "$R"; publish_elsewhere "$R" exchange
( cd "$R/devpc" && just new-branch 98 ) > "${WORK}/log" 2>&1
if grep -q "git checkout -b fix_98 asgard1/fix_98" "${WORK}/log"; then
  echo "  ok   [the refusal names the remote that has it, and how to get it]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [the refusal names the remote that has it, and how to get it]"
  sed 's/^/         /' "${WORK}/log" | tail -12
  FAIL=$((FAIL + 1))
fi

echo ""
echo "== 'it is not there' is not 'I could not ask' =="

R="${WORK}/unreachable"; fixture "$R"
( cd "$R/devpc" && q git remote set-url asgard1 "$R/does-not-exist.git" )
check "an unreachable remote stops the recipe rather than reading as absent" \
      1 no "could not ask" "$R"

echo ""
echo "== the ordinary case still works =="

R="${WORK}/clean"; fixture "$R"
check "no collision: the branch is created" 0 yes "created from upstream/main" "$R"

pushed=yes
for b in fork exchange; do
  q git ls-remote --exit-code "${WORK}/clean/$b.git" refs/heads/fix_98 || pushed=no
done
if [ "$pushed" = yes ]; then
  echo "  ok   [and published to origin and the exchange]"
  PASS=$((PASS + 1))
else
  echo "  FAIL [and published to origin and the exchange]"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
