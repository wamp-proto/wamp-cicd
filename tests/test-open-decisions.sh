#!/usr/bin/env bash
#
# Test the open-A18-decision guard (wamp-cicd #76): `land` refuses a branch carrying
# `.decisions/<aspect>/OPEN-*.toml`, and `where` lists the open decisions.
#
# An open decision is a required human decision nobody has taken yet - the rollout it
# belongs to is stopped on purpose (typedefint/aaiare-fleet-manager#42). It must not
# reach the integration branch, by anyone, so the refusal is asserted, not assumed.
#
# Run: bash tests/test-open-decisions.sh
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
has()   { if grep -qE "$2" "${WORK}/log"; then ok "$1"; else bad "$1" "no line matching /$2/"; fi; }
hasnt() { if grep -qE "$2" "${WORK}/log"; then bad "$1" "a line matches /$2/"; else ok "$1"; fi; }

OPEN=".decisions/python-package/OPEN-20261009-license_deviation.toml"
DECIDED=".decisions/python-package/20261009-license_deviation.toml"

R="${WORK}/repo"; mkdir -p "$R"
q git init -b main "$R"
( cd "$R"
  cp "$WORKFLOW_JUST" workflow.just
  printf "import 'workflow.just'\n" > justfile
  q git add -A && q git commit -m seed )

echo "== no decisions at all =="
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "where says none open" "^  decisions    none open$"

echo ""
echo "== an uncommitted OPEN file does not count (the branch is what lands) =="
( cd "$R" && q git checkout -b fix_1 && mkdir -p .decisions/python-package \
  && printf 'status = "open"\nquestion = "Keep EUPL-1.2?"\n' > "$OPEN" )
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "where still says none open" "^  decisions    none open$"

echo ""
echo "== a committed OPEN file: listed, and the branch does not land =="
( cd "$R" && q git add -A && q git commit -m "the question" )
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "where counts it" "^  decisions    1 OPEN - a required decision"
has "where names the file" "^               ${OPEN//./\\.}$"
has "where shows the question" "^                 Keep EUPL-1\.2\?$"
main_before="$(git -C "$R" rev-parse main)"
( cd "$R" && just land fix_1 ) > "${WORK}/log" 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok "land exits non-zero"; else bad "land exits non-zero" "rc=0"; fi
has "land refuses, counting it" "^REFUSING: fix_1 carries 1 open decision"
has "land names the file" "^    ${OPEN//./\\.}$"
has "land shows the question" "^      Keep EUPL-1\.2\?$"
if [ "$(git -C "$R" rev-parse main)" = "${main_before}" ]; then ok "main is untouched"
else bad "main is untouched" "main moved"; fi

echo ""
echo "== decided (the OPEN file renamed into the decision): nothing open =="
( cd "$R" && q git mv "$OPEN" "$DECIDED" && q git commit -m "decide: keep" )
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "where says none open again" "^  decisions    none open$"
( cd "$R" && just land fix_1 ) > "${WORK}/log" 2>&1
hasnt "land no longer refuses on decisions" "open decision"
has "...it goes on to its next check (no remote in this sandbox)" "^REFUSING: no remote has main\.$"

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
