#!/usr/bin/env bash
# next.sh - who is behind: per repository and cohort, the next rollout to apply (read-only).
#
#   ./next.sh                  every repository of the fleet, every cohort it is in
#   ./next.sh --cohort NAME    one cohort
#
# A cohort's rollouts are rollouts/<cohort>/<NNNN>-<name>/ in the fleet's definition (the clone
# the inventory symlink points into). A repository has received a rollout when its marker
# .waves/<cohort>/<NNNN>-<name>.toml is on its default branch. "next" is the first one without.
# A wave of rollout R is exactly the repositories whose next rollout in R's cohort is R.

set -uo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"
# shellcheck source=lib/rollouts.sh
. "${FLEET_TOOLS_DIR}/lib/rollouts.sh"

COHORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cohort) COHORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
DEF="$(dirname "$(readlink -f "${FLEET_INVENTORY}")")"
if [ -n "${COHORT}" ]; then REPOS_TSV="$(python3 "${FLEET_TOOLS_DIR}/lib/inventory-repos.py" "${FLEET_INVENTORY}" --cohort "${COHORT}")" || exit 1
else REPOS_TSV="$(python3 "${FLEET_TOOLS_DIR}/lib/inventory-repos.py" "${FLEET_INVENTORY}")" || exit 1; fi

printf '%-30s %-12s %-8s %s\n' REPO COHORT APPLIED NEXT
behind=0; unknown=0
while IFS=$'\t' read -r name _slug main cohorts; do
    [ -n "${name}" ] || continue
    d="${FLEET_WORK_DIR}/${name}"
    if [ -z "${cohorts}" ]; then printf '%-30s %-12s %-8s %s\n' "${name}" "-" "-" "(in no cohort)"; continue; fi
    for c in ${cohorts//,/ }; do
        [ -z "${COHORT}" ] || [ "${c}" = "${COHORT}" ] || continue
        if [ ! -e "${d}/.git" ]; then printf '%-30s %-12s %-8s %s\n' "${name}" "${c}" "?" "(not cloned)"; continue; fi
        ref="$(default_ref "${d}" "${main}")"
        IFS=$'\t' read -r nx adopts < <(next_due "${d}" "${ref}" "${DEF}" "${c}" "${name}"; echo) || true
        if [ "${nx}" = "?" ]; then unknown=$((unknown+1)); nx="? (${adopts})"
        elif [ -n "${nx}" ]; then behind=$((behind+1)); [ -z "${adopts}" ] || nx="${nx}  (adopts ${adopts//,/, })"; fi
        printf '%-30s %-12s %-8s %s\n' "${name}" "${c}" "$(applied_count "${d}" "${ref}" "${DEF}" "${c}")" "${nx:-up to date}"
    done
done <<<"${REPOS_TSV}"
echo ""
[ "${unknown}" = 0 ] || echo "${unknown} could not be judged: a clone must be clean and on its default branch as landed"
echo "${behind} repository/cohort pair(s) behind (definition: ${DEF} @ $(git -C "${DEF}" rev-parse --short HEAD 2>/dev/null || echo '?'))"
