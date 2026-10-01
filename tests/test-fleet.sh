#!/usr/bin/env bash
#
# Test the fleet inventory contract, schema 2 (#60): fleet/lib/check-inventory.py and
# fleet/lib/inventory-repos.py.
#
# An inventory is usually GENERATED from a single source of truth and committed to a fleet's
# definition repository; the rollout tooling reads it and acts on every member of a cohort. A
# malformed entry does not fail loudly there - it silently drops a repository from a rollout, or
# aims one at the wrong slug or branch. So the contract is pinned here: the valid fixture passes,
# and every way of breaking it fails on the check that names the fault.
#
# (Until #60 this file checked the WAMP inventory itself, which lived here as fleet.toml. It now
# lives, generated, in the fleets' definition repositories.)
#
# Run: bash tests/test-fleet.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${HERE}/../fleet/lib/check-inventory.py"
LIST="${HERE}/../fleet/lib/inventory-repos.py"
GOOD="${HERE}/fixtures/fleet.toml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }

# breaks <label> <expected failing check (grep)> <sed expression applied to the valid fixture>
breaks() {
    sed -E "$3" "${GOOD}" > "${WORK}/bad.toml"
    cmp -s "${GOOD}" "${WORK}/bad.toml" && { fail "$1: the mutation changed nothing"; return; }
    out="$(python3 "${CHECK}" "${WORK}/bad.toml" --quiet 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && grep -q -- "$2" <<<"$out"; then ok "$1"; else fail "$1 (rc=$rc): $out"; fi
}

echo "== the valid fixture (the shape a generated inventory has, header comment included)"
out="$(python3 "${CHECK}" "${GOOD}")"; rc=$?
[ "$rc" -eq 0 ] && grep -q ' passed, 0 failed' <<<"$out" && ok "passes: $(tail -1 <<<"$out")" || fail "valid fixture: $out"
python3 "${CHECK}" "${GOOD}" --quiet >"${WORK}/q" 2>&1 && [ ! -s "${WORK}/q" ] && ok "--quiet prints nothing when valid" || fail "--quiet: $(cat "${WORK}/q")"

echo "== every violation fails on its own check"
breaks "schema 1 is refused, saying what changed"   "this is a schema-1 inventory"            's/^schema = 2/schema = 1/'
breaks "an unknown schema"                           "schema is 2"                             's/^schema = 2/schema = 3/'
breaks "an unknown top-level key"                    "only schema, cohort and repo at the top" 's/^schema = 2/schema = 2\nowner = "x"/'
breaks "a per-repository wave (schema-1 leftover)"   "alpha: exactly the known keys"           's/^(slug +=.*acme\/alpha.*)$/\1\nwave = 1/'
breaks "a per-repository kind"                       "alpha: exactly the known keys"           's/^(slug +=.*acme\/alpha.*)$/\1\nkind = "python"/'
breaks "a missing default_branch"                    "bravo: exactly the known keys"           '/^default_branch = "main"/d'
breaks "a slug that is not owner/repo"               "alpha: slug is owner/repo"               's|"acme/alpha"|"alpha"|'
breaks "a slug not ending in the name"               "alpha: slug ends in the name"            's|"acme/alpha"|"acme/alpha2"|'
breaks "a duplicate repository name"                 "names are unique"                        's|^name +=.*"bravo"|name = "alpha"|'
breaks "an undefined cohort on a repository"         "bravo: every cohort is defined"          's|^cohorts += \["way-a"\]$|cohorts = ["way-b"]|'
breaks "cohorts not a list"                          "bravo: cohorts is a list of names"       's|^cohorts += \["way-a"\]$|cohorts = "way-a"|'
breaks "a cohort listed twice"                       "bravo: no cohort listed twice"           's|^cohorts += \["way-a"\]$|cohorts = ["way-a", "way-a"]|'
breaks "a duplicate cohort name"                     "cohort names are unique"                 's|^name +=.*"python"|name = "way-a"|'
breaks "a cohort name that is not a lowercase word"  "name is a lowercase word"                's|^name +=.*"python"|name = "Python 3"|'
breaks "a cohort without a description"              "description says what its members share" 's|^description = "Python packages"|description = ""|'
breaks "an unknown key on a cohort"                  "cohort python: exactly name and description" 's|^description = "Python packages"|description = "Python packages"\nrollouts = []|'

echo "== unreadable input"
echo 'schema = [' > "${WORK}/broken.toml"
python3 "${CHECK}" "${WORK}/broken.toml" --quiet >/dev/null 2>&1; [ $? -eq 2 ] && ok "broken TOML: exit 2" || fail "broken TOML exit code"

echo "== listing repositories (inventory-repos.py)"
[ "$(python3 "${LIST}" "${GOOD}" | cut -f1 | tr '\n' ' ')" = "alpha bravo dormant " ] && ok "all repositories, in order" || fail "all"
[ "$(python3 "${LIST}" "${GOOD}" --cohort way-a | cut -f1 | tr '\n' ' ')" = "alpha bravo " ] && ok "--cohort way-a: its members only" || fail "way-a"
[ "$(python3 "${LIST}" "${GOOD}" --cohort python | cut -f1,2,3,4)" = "$(printf 'alpha\tacme/alpha\tmaster\tway-a,python')" ] && ok "name, slug, default branch, cohorts" || fail "columns"
python3 "${LIST}" "${GOOD}" --cohort nope >/dev/null 2>"${WORK}/e"; rc=$?
[ "$rc" -eq 3 ] && grep -q "cohort 'nope' is not defined" "${WORK}/e" && ok "an undefined cohort is an error, not an empty list" || fail "undefined cohort (rc=$rc)"
python3 "${LIST}" "${GOOD}" | grep -q "^dormant" && ok "a repository in no cohort is listed, but in no cohort's selection" || fail "dormant"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
