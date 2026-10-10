#!/usr/bin/env bash
#
# Test `just check-aspect` / `just list-aspect` and the `where` row (wamp-cicd #78).
#
# One fixture repository declares five aspects, provided three ways - a submodule, a .deps/
# checkout (deps.toml), and the repository itself - plus one with no provider at all. The
# provider's toy checks pass or fail on a marker file, so each verdict is provoked, not assumed:
#   pass      submodule provider, check passes
#   fail      submodule provider, check fails
#   dep       .deps/ provider, check passes
#   selfasp   implemented by the repository itself
#   ghost     declared, no provider - "not implemented", not a failure
# and then the two ways a check cannot run: provider not checked out, provider not at its pin.
#
# Run: bash tests/test-aspects.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
ASPECTS_PY="${HERE}/../scripts/aspects.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$WORKFLOW_JUST" ] || { echo "FATAL: no $WORKFLOW_JUST" >&2; exit 2; }
command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
    || { echo "FATAL: needs python3 >= 3.11" >&2; exit 2; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
printf '[protocol "file"]\n\tallow = always\n' > "$GIT_CONFIG_GLOBAL"

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log"; FAIL=$((FAIL + 1)); }
has()   { if grep -qE "$2" "${WORK}/log"; then ok "$1"; else bad "$1" "no line matching /$2/"; fi; }
hasnt() { if grep -qE "$2" "${WORK}/log"; then bad "$1" "a line matches /$2/"; else ok "$1"; fi; }
rc_is() { if [ "$RC" = "$2" ]; then ok "$1"; else bad "$1" "exit $RC, expected $2"; fi; }

# A toy check: passes when the target has the marker file `<aspect>.ok`.
toy_check() {
    mkdir -p "$1/aspects/$2/scripts"
    printf '# toy\n' > "$1/aspects/$2/SKILL.md"
    cat > "$1/aspects/$2/scripts/check.py" <<EOF
import sys
from pathlib import Path
ok = (Path(sys.argv[1]) / "$2.ok").exists()
print(f"$2 toy check: {'OK' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
EOF
}

# The provider: aspects pass, fail, dep.
P="${WORK}/provider"; mkdir -p "$P"; q git init -b main "$P"
for a in pass fail dep; do toy_check "$P" "$a"; done
( cd "$P" && q git add -A && q git commit -m provider )
PIN="$(git -C "$P" rev-parse HEAD)"
( cd "$P" && echo later > later.txt && q git add -A && q git commit -m later )   # a newer commit

R="${WORK}/repo"; mkdir -p "$R"; q git init -b main "$R"
( cd "$R"
  cp "$WORKFLOW_JUST" workflow.just
  mkdir -p scripts && cp "$ASPECTS_PY" scripts/aspects.py
  printf "import 'workflow.just'\n" > justfile
  q git submodule add "$P" .prov
  git -C .prov checkout -q "$PIN" && q git add .prov
  toy_check . selfasp
  touch pass.ok dep.ok selfasp.ok                      # fail.ok missing: `fail` fails
  printf '[prov]\nurl    = "%s"\ncommit = "%s"\n' "$P" "$PIN" > deps.toml
  mkdir -p .deps && q git clone "$P" .deps/prov && git -C .deps/prov checkout -q "$PIN"
  printf '.deps/\n' > .gitignore
  cat > aspects.toml <<EOF
aspects = ["pass", "fail", "dep", "selfasp", "ghost"]

[provider.pass]
repo = "acme/provider"
path = ".prov"

[provider.fail]
repo = "acme/provider"
path = ".prov"

[provider.dep]
repo = "acme/provider"
path = ".deps/prov"
EOF
  q git add -A && q git commit -m seed )

echo "== list-aspect =="
( cd "$R" && just list-aspect ) > "${WORK}/log" 2>&1
has "pass: submodule provider at its pin" "^  pass +acme/provider +\.prov +${PIN:0:7} +implemented$"
has "dep: .deps provider at the deps.toml pin" "^  dep +acme/provider +\.deps/prov +${PIN:0:7} +implemented$"
has "selfasp: this repository" "^  selfasp +\(this repository\) +\. "
has "ghost: not implemented" "^  ghost .*not implemented \(no provider declared\)$"

echo ""
echo "== check-aspect, one aspect at a time =="
( cd "$R" && just check-aspect '' pass ) > "${WORK}/log" 2>&1; RC=$?
rc_is "pass: exit 0" 0; has "pass: ok, from the pin" "^pass: ok \(acme/provider @ ${PIN:0:7}\)$"
( cd "$R" && just check-aspect '' fail ) > "${WORK}/log" 2>&1; RC=$?
rc_is "fail: exit non-zero" 1; has "fail: FAIL" "^fail: FAIL"; has "fail: the check's own output is shown" "fail toy check: FAIL"
( cd "$R" && just check-aspect '' ghost ) > "${WORK}/log" 2>&1; RC=$?
rc_is "ghost: not implemented is not a failure" 0
( cd "$R" && just check-aspect '' nosuch ) > "${WORK}/log" 2>&1; RC=$?
rc_is "an undeclared aspect: exit 2" 2; has "an undeclared aspect: said so" "^nosuch: not declared in aspects.toml$"

echo ""
echo "== check-aspect, all =="
( cd "$R" && just check-aspect ) > "${WORK}/log" 2>&1; RC=$?
rc_is "all: one failing check fails the run" 1
has "all: dep ok" "^dep: ok"; has "all: selfasp ok" "^selfasp: ok"
( cd "$R" && just where ) > "${WORK}/log" 2>&1
has "where: the row counts and names the failing one" "^  aspects      5 declared: 3 ok, 1 FAIL, 1 not implemented - failing: fail; run: just check-aspect$"

echo ""
echo "== the check runs from the PIN, not from a newer provider commit =="
( cd "$R" && git -C .prov checkout -q main ) # checkout moved past the pin
( cd "$R" && just check-aspect '' pass ) > "${WORK}/log" 2>&1; RC=$?
rc_is "not at its pin: exit non-zero" 1
has "not at its pin: CANNOT CHECK, both commits named" "^pass: CANNOT CHECK - \.prov is checked out at [0-9a-f]{7}, its pin is ${PIN:0:7}$"
( cd "$R" && git -C .prov checkout -q "$PIN" )

echo ""
echo "== a provider that is not checked out cannot pass =="
( cd "$R" && rm -rf .deps )
( cd "$R" && just check-aspect '' dep ) > "${WORK}/log" 2>&1; RC=$?
rc_is "not checked out: exit non-zero" 1
has "not checked out: says how to fix it" "^dep: CANNOT CHECK - \.deps/prov is not checked out - run: just deps$"

echo ""
echo "== no aspects.toml =="
E="${WORK}/empty"; mkdir -p "$E"; q git init -b main "$E"
( cd "$E"; cp "$WORKFLOW_JUST" workflow.just; mkdir -p scripts; cp "$ASPECTS_PY" scripts/; printf "import 'workflow.just'\n" > justfile; q git add -A; q git commit -m seed )
( cd "$E" && just check-aspect ) > "${WORK}/log" 2>&1; RC=$?
rc_is "no aspects.toml: exit 0" 0; has "no aspects.toml: said so" "^no aspects.toml - this repository declares no aspects$"
( cd "$E" && just where ) > "${WORK}/log" 2>&1
has "where: none declared" "^  aspects      none declared$"

echo ""
echo "== a venv that does not exist =="
( cd "$R" && just check-aspect nosuchvenv ) > "${WORK}/log" 2>&1; RC=$?
rc_is "missing venv: exit non-zero" 1; has "missing venv: said so" "ERROR: no venv 'nosuchvenv' here"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
