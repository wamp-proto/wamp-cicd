#!/usr/bin/env bash
#
# Test scripts/community-files.sh - deploy and drift-check of the shared community files (#16).
#
# The files are COPIES in every repository (GitHub does not follow a symlink into a
# submodule), so the drift check is the only thing that keeps them the same. A check that
# passes when it should fail is worse than none: the files would drift while CI stayed
# green. So every refusal is asserted here, not only the happy path.
#
# The case that matters most is the last one. A repository runs the check from ITS OWN
# pinned `.cicd`, so a template changed upstream must not break a repository that has not
# bumped its pin yet - and must be reported once it does.
#
# Run: bash tests/test-community-files.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CICD="$(cd "${HERE}/.." && pwd)"
SCRIPT="${CICD}/scripts/community-files.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SCRIPT" ] || { echo "FATAL: no $SCRIPT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log"; FAIL=$((FAIL + 1)); }

# run <expected-exit> <label> <args...>  - run the script, assert its exit status
run() {
    local want="$1" label="$2"; shift 2
    local got=0
    bash "$SCRIPT" "$@" >"${WORK}/log" 2>&1 || got=$?
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "exit ${got}, wanted ${want}"; fi
}
has() {  # has <label> <pattern>  - the last run's output contains pattern
    if grep -qE "$2" "${WORK}/log"; then ok "$1"; else bad "$1" "output lacks: $2"; fi
}

R="${WORK}/repo"
mkdir -p "$R"

echo "deploy into a fresh repository"
run 0 "deploy succeeds" deploy "$R"
for f in CONTRIBUTING.md .github/pull_request_template.md .audit/README.md; do
    t="$(case "$f" in CONTRIBUTING.md) echo CONTRIBUTING.md ;; .github/*) echo pull_request_template.md ;; .audit/*) echo audit-README.md ;; esac)"
    if cmp -s "${CICD}/templates/${t}" "${R}/${f}"; then ok "deployed ${f} is byte-identical"; else bad "deployed ${f}" "differs from template"; fi
done
if cmp -s "${CICD}/templates/DEVELOPMENT.md" "${R}/DEVELOPMENT.md"; then ok "DEVELOPMENT.md seeded"; else bad "DEVELOPMENT.md" "not seeded"; fi

echo "check after deploy"
run 0 "check passes on a fresh deploy" check "$R"

echo "DEVELOPMENT.md belongs to the repository"
echo "project-specific notes" > "${R}/DEVELOPMENT.md"
run 0 "redeploy succeeds" deploy "$R"
if grep -q "project-specific notes" "${R}/DEVELOPMENT.md"; then ok "redeploy does not overwrite DEVELOPMENT.md"; else bad "redeploy" "overwrote DEVELOPMENT.md"; fi
run 0 "check accepts any DEVELOPMENT.md content" check "$R"

echo "drift is refused"
echo "local edit" >> "${R}/CONTRIBUTING.md"
run 1 "check fails on an edited CONTRIBUTING.md" check "$R"
has "names the drifted file" "DRIFTED +CONTRIBUTING.md"
bash "$SCRIPT" deploy "$R" >/dev/null
run 0 "deploy repairs the drift" check "$R"

rm "${R}/.audit/README.md"
run 1 "check fails on a missing .audit/README.md" check "$R"
has "names the missing file" "MISSING +.audit/README.md"
bash "$SCRIPT" deploy "$R" >/dev/null

mv "${R}/DEVELOPMENT.md" "${WORK}/dev.bak"
run 1 "check fails without DEVELOPMENT.md" check "$R"
has "explains why DEVELOPMENT.md is required" "CONTRIBUTING.md links to it"
mv "${WORK}/dev.bak" "${R}/DEVELOPMENT.md"

echo "the obsolete PR template directory"
mkdir -p "${R}/.github/PULL_REQUEST_TEMPLATE"; echo x > "${R}/.github/PULL_REQUEST_TEMPLATE/pull_request_template.md"
run 1 "check fails while .github/PULL_REQUEST_TEMPLATE/ exists" check "$R"
has "names the obsolete directory" "OBSOLETE +.github/PULL_REQUEST_TEMPLATE"
run 0 "deploy removes it" deploy "$R"
if [ ! -e "${R}/.github/PULL_REQUEST_TEMPLATE" ]; then ok "obsolete directory gone"; else bad "obsolete dir" "still there"; fi
run 0 "check passes afterwards" check "$R"

echo "idempotence"
run 0 "a second deploy succeeds" deploy "$R"
has "reports nothing to change" "unchanged +CONTRIBUTING.md"

echo "argument handling"
run 2 "refuses a missing repository root" check "${WORK}/nope"
run 2 "refuses an unknown mode" frobnicate "$R"

echo "the check uses the repository's PINNED templates, not the canonical ones"
# A repository with its own .cicd copy (the pinned revision), deployed from that copy.
P="${WORK}/pinned-repo"; mkdir -p "${P}/.cicd"
cp -r "${CICD}/scripts" "${CICD}/templates" "${P}/.cicd/"
bash "${P}/.cicd/scripts/community-files.sh" deploy "$P" >/dev/null
# The canonical template moves on upstream (simulated on a scratch copy of wamp-cicd).
U="${WORK}/upstream-cicd"; cp -r "${CICD}" "$U"
echo "a new upstream rule" >> "${U}/templates/CONTRIBUTING.md"
SCRIPT="${P}/.cicd/scripts/community-files.sh"
run 0 "the pinned check still passes after upstream changed" check "$P"
SCRIPT="${U}/scripts/community-files.sh"
run 1 "after bumping the pin, the same files are reported as drifted" check "$P"
has "names CONTRIBUTING.md after the bump" "DRIFTED +CONTRIBUTING.md"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" = 0 ]
