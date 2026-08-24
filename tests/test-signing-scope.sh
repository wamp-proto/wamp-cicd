#!/usr/bin/env bash
#
# Test that `just where` reports signing keys set at GLOBAL scope (wamp-cicd #41).
#
# MERGE-AND-SIGNING-POLICY.md used to say: set `gpg.format` and
# `gpg.x509.program` per repository - explicitly not globally, with the reason
# written out - and then, four paragraphs later, `git config --global
# commit.gpgsign true`. Follow both and the machine is left in a state the same
# document describes as a failure: `commit.gpgsign` selects only WHETHER to
# sign, the other two decide HOW, so a repository under no policy is asked to
# sign with a backend it does not configure, and a PLAIN `git commit` there is
# refused with "No secret key".
#
# The last case below does not read config back - it makes a commit in a
# repository under no policy and asserts it FAILS. Without that, this file would
# only prove that a warning matches a config key, not that the state the warning
# is about is actually harmful (A13).
#
# Detectable only from a policy repository: the repositories that break have no
# `just` and nothing to run. So the check lives in `where`, which is the recipe
# run in the repositories that are themselves fine.
#
# Run: bash tests/test-signing-scope.sh
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

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log"; FAIL=$((FAIL + 1)); }

has()  { if grep -qE "$2" "${WORK}/log"; then ok "$1"; else bad "$1" "no line matching /$2/"; fi; }
hasnt(){ if grep -qE "$2" "${WORK}/log"; then bad "$1" "unexpected line matching /$2/"; else ok "$1"; fi; }

# A policy repository: the three keys set LOCALLY, which is the correct shape.
mk() {
  local R="$1"
  mkdir -p "$R"
  q git init -b main "$R"
  ( cd "$R"
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    git config gpg.format x509
    git config gpg.x509.program gitsign
    git config commit.gpgsign true
    git config workflow.signingIdentity test@example.invalid
    q git add -A && q git commit --no-gpg-sign -m seed )
}

# reset_global [k=v ...]
reset_global() { : > "$GIT_CONFIG_GLOBAL"; for kv in "$@"; do git config --global "${kv%%=*}" "${kv#*=}"; done; }

echo "== nothing global: the row is silent =="

reset_global
R="${WORK}/clean"; mk "$R"
( cd "$R" && just where ) > "${WORK}/log" 2>&1
hasnt "no GLOBAL SCOPE line when every key is local" "GLOBAL SCOPE"
has   "...and the signing row is still printed"      "^  signing      "

echo ""
echo "== commit.gpgsign global: named, with the consequence =="

reset_global commit.gpgsign=true
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "commit.gpgsign is named"        "^  *GLOBAL SCOPE: commit\.gpgsign$"
has "the consequence is spelled out" "cannot"
has "...and 'No secret key' is quoted, because that is what the operator sees" "No secret key"

echo ""
echo "== the backend keys, global =="

reset_global gpg.format=x509
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "gpg.format alone is named" "^  *GLOBAL SCOPE: gpg\.format$"

reset_global gpg.format=x509 gpg.x509.program=gitsign commit.gpgsign=true
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "all three are named, in one line" "^  *GLOBAL SCOPE: gpg\.format, gpg\.x509\.program, commit\.gpgsign$"

echo ""
echo "== commit.gpgsign global but FALSE is not an offence =="

reset_global commit.gpgsign=false
( cd "$R" && just where ) > "${WORK}/log" 2>&1
hasnt "false is not reported" "GLOBAL SCOPE"

echo ""
echo "== the state being warned about really does break other repositories =="

# No policy, no gitsign config - the ordinary repository next door.
reset_global commit.gpgsign=true
N="${WORK}/next-door"; mkdir -p "$N"
q git init -b main "$N"
( cd "$N" && echo x > f && git add -A )
if ( cd "$N" && git commit -m "sync" ) > "${WORK}/log" 2>&1; then
  bad "a plain 'git commit' next door is refused" "it succeeded - the warning would be about nothing"
else
  ok "a plain 'git commit' next door is refused"
fi

# ...and the same commit succeeds once the global key is gone. Proves the key is
# the cause, not something else about the fixture.
reset_global
if ( cd "$N" && git commit -m "sync" ) > "${WORK}/log" 2>&1; then
  ok "...and succeeds again once the global key is removed"
else
  bad "...and succeeds again once the global key is removed" "still failing"
fi

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" = 0 ]
