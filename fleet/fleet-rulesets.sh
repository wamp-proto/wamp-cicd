#!/usr/bin/env bash
# fleet-rulesets.sh - make default-branch protection consistent across the fleet (DEV PC).
#
#   ./fleet-rulesets.sh                          dry run: show classic protection + rulesets per repo
#   ./fleet-rulesets.sh --go                     apply ruleset "master" (from rulesets/master.json),
#                                                then delete the classic branch protection
#   ./fleet-rulesets.sh --go --integrity         also apply "master-integrity" (deletion +
#                                                non_fast_forward, NO bypass: nobody force-pushes/deletes)
#   ./fleet-rulesets.sh --only a,b               restrict to some repositories
#
# Repositories come from the current rollout's fleet.tsv (all waves). Per repository:
#   1. show the classic protection of the default branch and the existing rulesets
#   2. create the ruleset, or update it in place if one of the same name exists (idempotent)
#   3. only after the ruleset is active: delete the classic protection (no unprotected window)
# Rulesets and classic protection stack (the most restrictive wins), so step 3 is what lifts
# e.g. enforce_admins.

set -uo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"

GO=0; INTEGRITY=0; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --go) GO=1; shift ;;
        --integrity) INTEGRITY=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "ERROR: gh missing or not authenticated" >&2; exit 1; }
STATE="${FLEET_STATE}/$(cat "${FLEET_STATE}/current")"
FILES=("${FLEET_RULESETS}/master.json")
[ "${INTEGRITY}" = 1 ] && FILES+=("${FLEET_RULESETS}/master-integrity.json")
for f in "${FILES[@]}"; do python3 -m json.tool "$f" >/dev/null || { echo "ERROR: bad JSON $f" >&2; exit 1; }; done

failed=0
while IFS=$'\t' read -r name slug main _kind _wave; do
    if [ -n "${ONLY}" ] && [[ ",${ONLY}," != *",${name},"* ]]; then continue; fi
    echo ""
    echo "================ ${name}  (${slug}, default branch ${main})"

    classic=0
    if p="$(gh api "repos/${slug}/branches/${main}/protection" 2>/dev/null)"; then
        classic=1
        printf '%s' "$p" | python3 -c 'import sys,json; p=json.load(sys.stdin)
f=lambda k: (p.get(k) or {}).get("enabled")
print("    classic:   enforce_admins=%s linear_history=%s force_push=%s deletions=%s pr_reviews=%s status_checks=%s" % (
 f("enforce_admins"), f("required_linear_history"), f("allow_force_pushes"), f("allow_deletions"),
 "required_pull_request_reviews" in p, (p.get("required_status_checks") or {}).get("contexts")))'
    else
        echo "    classic:   none"
    fi
    existing="$(gh api "repos/${slug}/rulesets" 2>/dev/null || echo '[]')"
    echo "    rulesets:  $(printf '%s' "${existing}" | python3 -c 'import sys,json; print(", ".join("%s(#%s,%s)" % (r["name"],r["id"],r["enforcement"]) for r in json.load(sys.stdin)) or "none")')"

    ok=1
    for f in "${FILES[@]}"; do
        rs="$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["name"])' "$f")"
        id="$(printf '%s' "${existing}" | python3 -c 'import sys,json; n=sys.argv[1]; print(next((str(r["id"]) for r in json.load(sys.stdin) if r["name"]==n), ""))' "${rs}")"
        if [ -n "${id}" ] && [ "$(gh api "repos/${slug}/rulesets/${id}" | python3 "${FLEET_TOOLS_DIR}/lib/ruleset-matches.py" "$f")" = yes ]; then
            echo "    ruleset '${rs}' (#${id}) up to date"; continue
        fi
        if [ "${GO}" != 1 ]; then
            if [ -n "${id}" ]; then echo "    [dry-run] update ruleset '${rs}' (#${id}) - differs"; else echo "    [dry-run] create ruleset '${rs}'"; fi
            continue
        fi
        if [ -n "${id}" ]; then
            gh api -X PUT "repos/${slug}/rulesets/${id}" --input "$f" >/dev/null && echo "    updated ruleset '${rs}' (#${id})" || { echo "    FAILED to update '${rs}'"; ok=0; }
        else
            gh api -X POST "repos/${slug}/rulesets" --input "$f" >/dev/null && echo "    created ruleset '${rs}'" || { echo "    FAILED to create '${rs}'"; ok=0; }
        fi
    done

    if [ "${classic}" = 1 ]; then
        if [ "${GO}" != 1 ]; then
            echo "    [dry-run] delete classic protection of ${main} (after the ruleset is active)"
        elif [ "${ok}" = 1 ]; then
            gh api -X DELETE "repos/${slug}/branches/${main}/protection" >/dev/null \
                && echo "    deleted classic protection of ${main}" || { echo "    FAILED to delete classic protection"; failed=1; }
        else
            echo "    classic protection KEPT (ruleset step failed)"; failed=1
        fi
    fi
done < "${STATE}/fleet.tsv"

[ "${GO}" = 1 ] || echo -e "\n(dry run - nothing changed; re-run with --go)"
exit "${failed}"
