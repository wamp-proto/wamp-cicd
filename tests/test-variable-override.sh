#!/usr/bin/env bash
#
# Test that a repository can override WORKFLOW_MAIN and WORKFLOW_BRANCH_PREFIX
# (wamp-cicd #47).
#
# `workflow.just` said for eight months that these variables exist "because it
# is exactly the kind of thing that differs per repository", and the form it
# documented - the bare override, alone in the importing justfile - did not
# work at all:
#
#     error: Variable `WORKFLOW_MAIN` has multiple definitions
#
# Nothing could have caught that. No repository in the estate was both on
# `master` AND onboarded, so the only route to the defect was someone trying
# it, which is what typedefint-organize#4 did. A configuration option that has
# never been exercised is a claim, and this one was false from the day it was
# written.
#
# THE FAILURES ARE AT PARSE TIME, which is what makes them worth a test rather
# than a note: `just` refuses the whole justfile, so a repository in this state
# cannot run ANY recipe - not `where`, not `land`, not its own build. A regression
# here does not degrade the workflow, it removes it.
#
# Two ways to get it wrong, and the second only appears after this fix:
#
#   1. no `set allow-duplicate-variables` anywhere   -> "multiple definitions"
#   2. the `set` in BOTH this file and the importer  -> "Setting ... is redefined"
#
# So the test asserts the working form, the no-override form, and (2) - because
# (2) is a NEW way to break an importer that this change introduced, and any
# repository that adopted the two-line workaround before the fix hits it at the
# next pin bump.
#
# Run: bash tests/test-variable-override.sh
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

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log"; FAIL=$((FAIL + 1)); }

# repo <name> <branch> <justfile-body>
repo() {
  R="${WORK}/$1"; rm -rf "$R"; mkdir -p "$R"
  q git init -b "$2" "$R"
  cp "$WORKFLOW_JUST" "$R/workflow.just"
  printf '%b' "$3" > "$R/justfile"
  ( cd "$R" && q git add -A && q git commit -m seed )
}

# evaluates <name> <VAR> <expected>
evaluates() {
  ( cd "$R" && just --evaluate ) > "${WORK}/log" 2>&1
  if grep -qE "^$2 +:= \"$3\"$" "${WORK}/log"; then ok "$1"; else bad "$1" "$2 is not \"$3\""; fi
}

# refuses <name> <extended-regex the error must match>
refuses() {
  ( cd "$R" && just --evaluate ) > "${WORK}/log" 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then bad "$1" "expected a parse failure, got exit 0"
  elif grep -qE "$2" "${WORK}/log"; then ok "$1"
  else bad "$1" "failed, but not with /$2/"; fi
}

IMPORT="import 'workflow.just'\n"

echo "== the documented form: one line in the importer =="

repo main-default main "${IMPORT}"
evaluates "no override: WORKFLOW_MAIN defaults to main" WORKFLOW_MAIN main
evaluates "no override: prefix defaults to fix_"        WORKFLOW_BRANCH_PREFIX fix_

repo master-repo master "${IMPORT}\nWORKFLOW_MAIN := 'master'\n"
evaluates "override wins: WORKFLOW_MAIN is master"      WORKFLOW_MAIN master
evaluates "...and the prefix is untouched"              WORKFLOW_BRANCH_PREFIX fix_

# ORDER MUST NOT MATTER. `just` evaluates the file as a whole, but an operator
# who puts the override above the import has not made a mistake and must not be
# told they have.
repo before-import master "WORKFLOW_MAIN := 'master'\n${IMPORT}"
evaluates "override BEFORE the import works too"        WORKFLOW_MAIN master

echo ""
echo "== the never-exercised variable is overridable as well =="

# WORKFLOW_BRANCH_PREFIX has never been changed by any repository. It is
# asserted here so that "you may override it" stops being an untested claim -
# which is the whole subject of #47.
repo prefix-repo main "${IMPORT}\nWORKFLOW_BRANCH_PREFIX := 'issue_'\n"
evaluates "prefix override wins"                        WORKFLOW_BRANCH_PREFIX issue_
evaluates "...and WORKFLOW_MAIN is untouched"           WORKFLOW_MAIN main

repo both-repo master "${IMPORT}\nWORKFLOW_MAIN := 'master'\nWORKFLOW_BRANCH_PREFIX := 'issue_'\n"
evaluates "both at once: main"                          WORKFLOW_MAIN master
evaluates "both at once: prefix"                        WORKFLOW_BRANCH_PREFIX issue_

echo ""
echo "== the way this change lets an importer break itself =="

# An importer that ALSO sets allow-duplicate-variables gets a parse error, and
# the error names a line in THIS file rather than in theirs - so the message is
# confusing at exactly the moment it matters. Asserted so that anyone who
# removes the `set` from workflow.just discovers it here rather than in a
# repository that can no longer run a single recipe.
repo double-set master "set allow-duplicate-variables := true\n${IMPORT}\nWORKFLOW_MAIN := 'master'\n"
refuses "importer setting it too is refused, by design" \
        "Setting .allow-duplicate-variables. .*redefined"

echo ""
echo "== the recipes still parse and are all present =="

repo full main "${IMPORT}"
( cd "$R" && just --list ) > "${WORK}/log" 2>&1
for r in where new-branch publish land what commit-on-main submodules-at-head; do
  if grep -qE "^    ${r}( |$)" "${WORK}/log"; then ok "recipe ${r} is present"
  else bad "recipe ${r} is present" "missing from --list"; fi
done

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
