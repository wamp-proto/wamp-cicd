#!/usr/bin/env bash
#
# Test the informational rows of `just where` (wamp-cicd #36).
#
# `where` is the recipe this workflow is READ through - it is how an operator
# decides whether a tree is safe to act on. A row that is wrong, or that reads
# the same in two states that differ, is therefore expensive out of proportion
# to its size: the signing row said "gitsign as <identity>" in repositories
# where nothing had been signed for three weeks, and nobody had a reason to
# look. So the rows are asserted rather than eyeballed.
#
# Covered here: the commit the tree is standing on, the submodule pins, and the
# empty-repository case that has no HEAD to name. The signing row is asserted
# in tests/test-workflow-signing.sh.
#
# Run: bash tests/test-where-output.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$WORKFLOW_JUST" ] || { echo "FATAL: no $WORKFLOW_JUST" >&2; exit 2; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
git config --global protocol.file.allow always   # submodules from local paths

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log"; FAIL=$((FAIL + 1)); }

# has <name> <extended-regex>
has() {
  if grep -qE "$2" "${WORK}/log"; then ok "$1"; else bad "$1" "no line matching /$2/"; fi
}

echo "== the commit the tree is standing on =="

R="${WORK}/plain"; mkdir -p "$R"
q git init -b main "$R"
( cd "$R"
  cp "$WORKFLOW_JUST" workflow.just
  printf "import 'workflow.just'\n" > justfile
  q git add -A && q git commit -m "a subject worth reading" )
sha="$(git -C "$R" rev-parse --short HEAD)"
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "the short sha is printed"  "^  commit       ${sha}$"
has "the subject is printed"    "^  message      a subject worth reading$"

echo ""
echo "== a repository with no commit yet =="

R="${WORK}/empty"; mkdir -p "$R"
q git init -b main "$R"
cp "$WORKFLOW_JUST" "$R/workflow.just"
printf "import 'workflow.just'\n" > "$R/justfile"
( cd "$R" && just where ) > "${WORK}/log" 2>&1; rc=$?
if [ "$rc" = 0 ]; then
  has "no HEAD: says so rather than erroring" "^  commit       \(none\)$"
  has "...and the message row says why"       "^  message      no commit yet$"
else
  bad "no HEAD: says so rather than erroring" "where exited ${rc}"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "== submodule pins are named, not just counted =="

R="${WORK}/subs"; mkdir -p "$R"
for m in ai cicd; do
  q git init -b main "$R/src-$m"
  ( cd "$R/src-$m" && echo "$m" > f && q git add -A && q git commit -m "$m" )
done
q git init -b main "$R/repo"
( cd "$R/repo"
  cp "$WORKFLOW_JUST" workflow.just
  printf "import 'workflow.just'\n" > justfile
  q git add -A && q git commit -m seed
  q git submodule add "$R/src-ai" .ai
  q git submodule add "$R/src-cicd" .cicd
  q git commit -m "add submodules" )
ai="$(git -C "$R/src-ai" rev-parse --short=7 HEAD)"
cicd="$(git -C "$R/src-cicd" rev-parse --short=7 HEAD)"
( cd "$R/repo" && just where ) > "${WORK}/log" 2>&1
has "both pins are named, with their shas" \
    "^  submodules   2 at their pinned revision \(\.ai=>${ai}, \.cicd=>${cicd}\)$"

# A DRIFTED SUBMODULE MUST STILL SAY SO, and must not be dressed up with pins:
# the pinned sha is not what the checkout is at, so printing it would be a
# statement about a tree that does not exist.
( cd "$R/repo/.cicd" && q git checkout -q --detach HEAD && echo drift > g \
  && q git add -A && q git commit -m drift )
( cd "$R/repo" && just where ) > "${WORK}/log" 2>&1
has "a drifted submodule is reported as NOT at the pin" \
    "^  submodules   1 of 2 NOT at the pinned revision: \.cicd"

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
