#!/usr/bin/env bash
#
# Test that every public recipe shows a real one-line description in `just --list`.
#
# `just` shows only the LAST comment line above a recipe. A multi-line comment therefore printed a
# fragment of its final sentence - "merge is local in the first place).", "errand." - for seven
# recipes, in every repository that imports workflow.just. The rule: a recipe's last comment line is
# a complete one-line summary (the explanation, if any, goes above it). This checks it the cheap way:
# every public recipe has a description, and it starts like a sentence (capital letter, or a quote).
#
# Run: bash tests/test-recipe-docs.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check_list() {   # <label> <directory whose justfile to list>
    local label="$1" dir="$2" line name doc
    while IFS= read -r line; do
        case "${line}" in "Available recipes:"|"") continue ;; esac
        name="$(printf '%s' "${line}" | awk '{print $1}')"
        if [[ "${line}" != *" # "* ]]; then
            echo "  FAIL [${label}] ${name}: no description"; FAIL=$((FAIL + 1)); continue
        fi
        doc="${line#* # }"
        if [[ "${doc}" =~ ^[A-Z\`\"] ]]; then
            PASS=$((PASS + 1))
        else
            echo "  FAIL [${label}] ${name}: description is a fragment: \"${doc}\""; FAIL=$((FAIL + 1))
        fi
    done < <(cd "${dir}" && just --list --unsorted 2>/dev/null)
}

echo "== this repository (justfile, workflow.just, fleet/fleet.just) =="
check_list "wamp-cicd" "${ROOT}"

echo "== a repository that imports only workflow.just =="
mkdir -p "${WORK}/repo"
cp "${ROOT}/workflow.just" "${WORK}/repo/workflow.just"
printf "import 'workflow.just'\n" > "${WORK}/repo/justfile"
check_list "workflow.just" "${WORK}/repo"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
