#!/usr/bin/env bash
# wave-ci-results.sh - collect the GitHub Actions results of every PR in the current rollout (DEV PC),
# and ship them to the AI's host for analysis.
#
#   ./wave-ci-results.sh                     collect, then upload to $UPLOAD_TO (host:path, e.g. the AI host's ~/fleet-ci/<fleet>)
#   ./wave-ci-results.sh --no-upload         collect only (local: $FLEET_CI_DIR/<rollout>-<UTC stamp>/)
#   ./wave-ci-results.sh --full-logs         also download the FULL log of every run (large)
#   ./wave-ci-results.sh --rerun-failed      after collecting, re-run the failed jobs (flakes)
#   ./wave-ci-results.sh --only a,b          restrict to some repositories
#   UPLOAD_TO=host:/path ./wave-ci-results.sh
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
WAVE="$(cat "${STATE}/wave")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${ROLLOUT}-${STAMP}"
OUT="${FLEET_CI_DIR}/${NAME}"
mkdir -p "${OUT}"

# one-line python helpers over the saved JSON (no jq dependency)
py() { python3 -c "$1" "${@:2}"; }

ROWS=()
while IFS=$'\t' read -r name slug _main _kind wave; do
    [ "${wave}" = "${WAVE}" ] || continue
    if [ -n "${ONLY}" ] && [[ ",${ONLY}," != *",${name},"* ]]; then continue; fi
    pr="$(awk -F'\t' -v r="${name}" '$1==r {print $4}' "${STATE}/manifest.tsv" | tail -1)"
    issue="$(awk -F'\t' -v r="${name}" '$1==r {print $3}' "${STATE}/manifest.tsv" | tail -1)"
    d="${OUT}/${name}"; mkdir -p "${d}"
    echo "== ${name}  PR #${pr:-?}  (${slug})"
    if [ -z "${pr}" ]; then echo "   no PR in the manifest - skipped"; ROWS+=("| ${name} | - | - | no PR | |"); continue; fi

    gh pr view "${pr}" --repo "${slug}" \
        --json number,url,state,isDraft,headRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup \
        > "${d}/pr.json" 2>"${d}/pr.err" || { echo "   could not read PR"; ROWS+=("| ${name} | #${pr} | - | ERROR reading PR | |"); continue; }
    [ -s "${d}/pr.err" ] || rm -f "${d}/pr.err"
    sha="$(py 'import json,sys; print(json.load(open(sys.argv[1]))["headRefOid"])' "${d}/pr.json")"
    rc=0; gh pr checks "${pr}" --repo "${slug}" > "${d}/checks.txt" 2>&1 || rc=$?
    case "${rc}" in 0) overall="pass" ;; 8) overall="pending" ;; *) overall="FAIL" ;; esac

    gh run list --repo "${slug}" --commit "${sha}" --limit 100 \
        --json databaseId,workflowName,name,event,status,conclusion,url,createdAt > "${d}/runs.json" 2>/dev/null \
        || echo "[]" > "${d}/runs.json"

    failed_jobs=""
    while IFS=$'\t' read -r id wf status concl; do
        [ -n "${id}" ] || continue
        wfs="$(echo "${wf}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
        gh run view "${id}" --repo "${slug}" --json jobs,status,conclusion,workflowName,url > "${d}/run-${id}.json" 2>/dev/null
        if [ "${status}" = "completed" ] && [ "${concl}" != "success" ] && [ "${concl}" != "skipped" ] && [ "${concl}" != "neutral" ]; then
            gh run view "${id}" --repo "${slug}" --log-failed > "${d}/run-${id}-${wfs}.failed.log" 2>&1
            jobs="$(py 'import json,sys
d=json.load(open(sys.argv[1]))
print("; ".join(j["name"] for j in d.get("jobs",[]) if j.get("conclusion") not in ("success","skipped","neutral",None)))' "${d}/run-${id}.json" 2>/dev/null)"
            failed_jobs="${failed_jobs}${wf}: ${jobs}<br>"
            if [ "${RERUN}" = 1 ]; then gh run rerun "${id}" --repo "${slug}" --failed >/dev/null 2>&1 && echo "   re-running failed jobs of ${wf} (${id})"; fi
        fi
        if [ "${FULL}" = 1 ] && [ "${status}" = "completed" ]; then
            gh run view "${id}" --repo "${slug}" --log > "${d}/run-${id}-${wfs}.log" 2>&1
        fi
    done < <(py 'import json,sys
for r in json.load(open(sys.argv[1])):
    print("\t".join(str(r.get(k,"")) for k in ("databaseId","workflowName","status","conclusion")))' "${d}/runs.json")

    nruns="$(py 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${d}/runs.json")"
    echo "   head ${sha:0:8}: ${overall}, ${nruns} runs"
    ROWS+=("| ${name} | [#${pr}](https://github.com/${slug}/pull/${pr}) (issue #${issue}) | \`${sha:0:8}\` | ${overall} | ${failed_jobs:-} |")
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
    host="${UPLOAD_TO%%:*}"; path="${UPLOAD_TO#*:}"
    tarball="${FLEET_CI_DIR}/${NAME}.tar.gz"
    tar -C "${FLEET_CI_DIR}" -czf "${tarball}" "${NAME}"
    scp -q "${tarball}" "${host}:/tmp/" \
        && ssh "${host}" "mkdir -p '${path}' && tar -xzf '/tmp/${NAME}.tar.gz' -C '${path}' && rm -f '/tmp/${NAME}.tar.gz'" \
        && echo "--> uploaded to ${host}:${path}/${NAME}/" \
        || echo "--> UPLOAD FAILED (results are local: ${OUT})" >&2
fi
