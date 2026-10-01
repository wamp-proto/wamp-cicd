#!/usr/bin/env bash
# ci-results.sh - collect the GitHub Actions results of every PR in the current rollout (DEV PC),
# and ship them to the AI's host for analysis.
#
#   ./ci-results.sh                     collect, then upload to $UPLOAD_TO (host:path, e.g. the AI host's ~/fleet-ci/<fleet>)
#   ./ci-results.sh --no-upload         collect only (local: $FLEET_CI_DIR/<rollout>-<UTC stamp>/)
#   ./ci-results.sh --full-logs         also download the FULL log of every run (large)
#   ./ci-results.sh --rerun-failed      after collecting, re-run the failed jobs (flakes)
#   ./ci-results.sh --only a,b          restrict to some repositories
#   UPLOAD_TO=host:/path ./ci-results.sh
#
# PRs come from the current rollout ($FLEET_STATE/current: fleet.tsv + manifest.tsv). Per PR it saves:
#   pr.json          state, head commit, mergeability, status-check rollup
#   checks.txt       `gh pr checks` table
#   runs.json        every workflow run on the PR's head commit
#   run-<id>.json    jobs + steps of each run
#   run-<id>-<workflow>.failed.log   log of the failed jobs (`gh run view --log-failed`)
#   run-<id>-<workflow>.log          full log (--full-logs only)
# and a SUMMARY.md with one row per repository and the failed jobs by name.

set -uo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"

UPLOAD=1; FULL=0; RERUN=0; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-upload) UPLOAD=0; shift ;;
        --full-logs) FULL=1; shift ;;
        --rerun-failed) RERUN=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "ERROR: gh missing or not authenticated" >&2; exit 1; }
[ -f "${FLEET_STATE}/current" ] || { echo "ERROR: no rollout initialised" >&2; exit 1; }
ROLLOUT="$(cat "${FLEET_STATE}/current")"
STATE="${FLEET_STATE}/${ROLLOUT}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${ROLLOUT}-${STAMP}"
OUT="${FLEET_CI_DIR}/${NAME}"
mkdir -p "${OUT}"

# The per-PR collection and the upload are shared with pr-ci.sh (the single-PR tool).
# shellcheck source=pr-ci.sh
. "${FLEET_TOOLS_DIR}/pr-ci.sh"
PR_CI_FULL="${FULL}"; PR_CI_RERUN="${RERUN}"

ROWS=()
while IFS=$'\t' read -r name slug _main _cohorts; do
    [ -n "${name}" ] || continue
    if [ -n "${ONLY}" ] && [[ ",${ONLY}," != *",${name},"* ]]; then continue; fi
    pr="$(awk -F'\t' -v r="${name}" '$1==r {print $4}' "${STATE}/manifest.tsv" | tail -1)"
    issue="$(awk -F'\t' -v r="${name}" '$1==r {print $3}' "${STATE}/manifest.tsv" | tail -1)"
    d="${OUT}/${name}"; mkdir -p "${d}"
    echo "== ${name}  PR #${pr:-?}  (${slug})"
    if [ -z "${pr}" ]; then echo "   no PR in the manifest - skipped"; ROWS+=("| ${name} | - | - | no PR | |"); continue; fi

    if ! pr_ci_collect "${slug}" "${pr}" "${d}"; then
        echo "   could not read PR"; ROWS+=("| ${name} | #${pr} | - | ERROR reading PR | |"); continue
    fi
    echo "   head ${PR_CI_SHA:0:8}: ${PR_CI_OVERALL}, ${PR_CI_NRUNS} runs"
    ROWS+=("| ${name} | [#${pr}](https://github.com/${slug}/pull/${pr}) (issue #${issue}) | \`${PR_CI_SHA:0:8}\` | ${PR_CI_OVERALL} | ${PR_CI_FAILED:-} |")
done < "${STATE}/fleet.tsv"

{
    echo "# CI results: rollout ${ROLLOUT}, collected ${STAMP}"
    echo ""
    echo "| repository | PR | head | checks | failed (workflow: jobs) |"
    echo "|---|---|---|---|---|"
    printf '%s\n' "${ROWS[@]}"
} > "${OUT}/SUMMARY.md"

echo ""
cat "${OUT}/SUMMARY.md"
echo ""
echo "--> collected into ${OUT}  ($(du -sh "${OUT}" | cut -f1))"

if [ "${UPLOAD}" = 1 ] && [ -z "${UPLOAD_TO}" ]; then
    echo "--> not uploaded: set UPLOAD_TO=host:path (results are local: ${OUT})"
elif [ "${UPLOAD}" = 1 ]; then
    pr_ci_upload "${FLEET_CI_DIR}" "${NAME}" "${UPLOAD_TO}" || true
fi
