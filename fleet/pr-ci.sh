#!/usr/bin/env bash
# pr-ci.sh - collect ONE pull request's CI results and failed-job logs, and hand them to the AI host.
#
#   pr-ci.sh https://github.com/<owner>/<repo>/pull/<n>     (paste from the browser)
#   pr-ci.sh <owner>/<repo>#<n>
#   pr-ci.sh <owner>/<repo> <n>
#   options: --full-logs (also every completed run's full log), --rerun-failed, --no-upload
#
# For repositories the AI host cannot read itself (private ones): runs where `gh` is
# authenticated, collects into ${PR_CI_DIR:-~/fleet-ci}/<owner>/<repo>/pr<n>-<UTC stamp>/:
#   pr.json, checks.txt, runs.json, run-<id>.json, run-<id>-<workflow>.failed.log,
#   run-<id>-job-<id>.failed.log (failed jobs of runs still in progress), SUMMARY.md
# and uploads it to ${PR_CI_UPLOAD_TO}/<owner>/<repo>/ (host:path), staged INSIDE that path, never
# in the target's /tmp. PR_CI_UPLOAD_TO comes from the environment or ~/.config/fleet/pr-ci.conf
# (one line: PR_CI_UPLOAD_TO=host:/path). Unset: the results stay local.
#
# Reading only: nothing on the forge changes, except with --rerun-failed.
# Also a library: fleet/ci-results.sh sources this file for pr_ci_collect and pr_ci_upload.

# pr_ci_collect <slug> <pr> <dir>  - collect into <dir>; sets PR_CI_SHA PR_CI_OVERALL PR_CI_FAILED
# PR_CI_NRUNS. Honours PR_CI_FULL=1 and PR_CI_RERUN=1. Returns 1 if the PR cannot be read.
pr_ci_collect() {
    local slug="$1" pr="$2" d="$3" rc id wf status concl wfs jobs jid jname
    _py() { python3 -c "$1" "${@:2}"; }
    mkdir -p "${d}"
    PR_CI_SHA=""; PR_CI_OVERALL=""; PR_CI_FAILED=""; PR_CI_NRUNS=0
    gh pr view "${pr}" --repo "${slug}" \
        --json number,url,state,isDraft,headRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup \
        > "${d}/pr.json" 2>"${d}/pr.err" || return 1
    [ -s "${d}/pr.err" ] || rm -f "${d}/pr.err"
    PR_CI_SHA="$(_py 'import json,sys; print(json.load(open(sys.argv[1]))["headRefOid"])' "${d}/pr.json")"
    rc=0; gh pr checks "${pr}" --repo "${slug}" > "${d}/checks.txt" 2>&1 || rc=$?
    case "${rc}" in 0) PR_CI_OVERALL="pass" ;; 8) PR_CI_OVERALL="pending" ;; *) PR_CI_OVERALL="FAIL" ;; esac

    gh run list --repo "${slug}" --commit "${PR_CI_SHA}" --limit 100 \
        --json databaseId,workflowName,name,event,status,conclusion,url,createdAt > "${d}/runs.json" 2>/dev/null \
        || echo "[]" > "${d}/runs.json"

    while IFS=$'\t' read -r id wf status concl; do
        [ -n "${id}" ] || continue
        wfs="$(echo "${wf}" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//')"
        gh run view "${id}" --repo "${slug}" --json jobs,status,conclusion,workflowName,url > "${d}/run-${id}.json" 2>/dev/null
        if [ "${status}" = "completed" ] && [ "${concl}" != "success" ] && [ "${concl}" != "skipped" ] && [ "${concl}" != "neutral" ]; then
            gh run view "${id}" --repo "${slug}" --log-failed > "${d}/run-${id}-${wfs}.failed.log" 2>&1
            jobs="$(_py 'import json,sys
d=json.load(open(sys.argv[1]))
print("; ".join(j["name"] for j in d.get("jobs",[]) if j.get("conclusion") not in ("success","skipped","neutral",None)))' "${d}/run-${id}.json" 2>/dev/null)"
            PR_CI_FAILED="${PR_CI_FAILED}${wf}: ${jobs}<br>"
            if [ "${PR_CI_RERUN:-0}" = 1 ]; then gh run rerun "${id}" --repo "${slug}" --failed >/dev/null 2>&1 && echo "   re-running failed jobs of ${wf} (${id})"; fi
        fi
        if [ "${status}" != "completed" ]; then
            # A run still in progress can already have failed jobs; `--log-failed` only works on
            # a completed run, so fetch those jobs one by one (their logs are final).
            while IFS=$'\t' read -r jid jname; do
                [ -n "${jid}" ] || continue
                gh run view --repo "${slug}" --job "${jid}" --log > "${d}/run-${id}-job-${jid}.failed.log" 2>&1
                PR_CI_FAILED="${PR_CI_FAILED}${wf} (in progress): ${jname}<br>"
            done < <(_py 'import json,sys
for j in json.load(open(sys.argv[1])).get("jobs",[]):
    if j.get("status")=="completed" and j.get("conclusion") in ("failure","cancelled","timed_out"):
        print("%s\t%s" % (j["databaseId"], j["name"]))' "${d}/run-${id}.json" 2>/dev/null)
        fi
        if [ "${PR_CI_FULL:-0}" = 1 ] && [ "${status}" = "completed" ]; then
            gh run view "${id}" --repo "${slug}" --log > "${d}/run-${id}-${wfs}.log" 2>&1
        fi
    done < <(_py 'import json,sys
for r in json.load(open(sys.argv[1])):
    print("\t".join(str(r.get(k,"")) for k in ("databaseId","workflowName","status","conclusion")))' "${d}/runs.json")
    PR_CI_NRUNS="$(_py 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "${d}/runs.json")"
}

# pr_ci_upload <parent-dir> <name> <host:path>  - copy <parent-dir>/<name>/ to host:path/<name>/.
# Staged inside host:path (the destination's own permissions apply), never in the host's /tmp.
pr_ci_upload() {
    local parent="$1" name="$2" host="${3%%:*}" path="${3#*:}"
    tar -C "${parent}" -czf - "${name}" \
        | ssh "${host}" "umask 077 && mkdir -p '${path}' && cat > '${path}/.${name}.tar.gz' && tar -xzf '${path}/.${name}.tar.gz' -C '${path}' && rm -f '${path}/.${name}.tar.gz'" \
        && echo "--> uploaded to ${host}:${path}/${name}/" \
        || { echo "--> UPLOAD FAILED (results are local: ${parent}/${name})" >&2; return 1; }
}

pr_ci_main() {
    set -uo pipefail
    local target="" num="" upload=1 slug pr stamp base name out conf
    PR_CI_FULL=0; PR_CI_RERUN=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --full-logs) PR_CI_FULL=1 ;;
            --rerun-failed) PR_CI_RERUN=1 ;;
            --no-upload) upload=0 ;;
            -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
            -*) echo "unknown option: $1" >&2; return 2 ;;
            *) if [ -z "${target}" ]; then target="$1"; else num="$1"; fi ;;
        esac
        shift
    done
    if [[ "${target}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([0-9]+) ]]; then
        slug="${BASH_REMATCH[1]}"; pr="${BASH_REMATCH[2]}"
    elif [[ "${target}" =~ ^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$ ]]; then
        slug="${BASH_REMATCH[1]}"; pr="${BASH_REMATCH[2]}"
    elif [[ "${target}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && [[ "${num}" =~ ^[0-9]+$ ]]; then
        slug="${target}"; pr="${num}"
    else
        echo "usage: pr-ci.sh <PR URL> | <owner>/<repo>#<n> | <owner>/<repo> <n>   (see --help)" >&2; return 2
    fi
    command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { echo "ERROR: gh missing or not authenticated" >&2; return 1; }

    conf="${XDG_CONFIG_HOME:-$HOME/.config}/fleet/pr-ci.conf"
    if [ -z "${PR_CI_UPLOAD_TO:-}" ] && [ -f "${conf}" ]; then
        PR_CI_UPLOAD_TO="$(grep -m1 '^PR_CI_UPLOAD_TO=' "${conf}" | cut -d= -f2- || true)"
    fi

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    base="${PR_CI_DIR:-$HOME/fleet-ci}/${slug}"
    name="pr${pr}-${stamp}"
    out="${base}/${name}"
    echo "== ${slug} PR #${pr}"
    if ! pr_ci_collect "${slug}" "${pr}" "${out}"; then
        echo "ERROR: could not read ${slug} PR #${pr}: $(cat "${out}/pr.err" 2>/dev/null)" >&2; return 1
    fi
    {
        echo "# CI results: ${slug} PR #${pr}, collected ${stamp}"
        echo ""
        echo "| PR | head | checks | runs | failed (workflow: jobs) |"
        echo "|---|---|---|---|---|"
        echo "| [#${pr}](https://github.com/${slug}/pull/${pr}) | \`${PR_CI_SHA:0:8}\` | ${PR_CI_OVERALL} | ${PR_CI_NRUNS} | ${PR_CI_FAILED:-} |"
    } > "${out}/SUMMARY.md"
    cat "${out}/SUMMARY.md"
    echo ""
    echo "--> collected into ${out}  ($(du -sh "${out}" | cut -f1))"
    if [ "${upload}" = 0 ]; then
        :
    elif [ -z "${PR_CI_UPLOAD_TO:-}" ]; then
        echo "--> not uploaded: set PR_CI_UPLOAD_TO=host:path (or put it in ${conf})"
    else
        pr_ci_upload "${base}" "${name}" "${PR_CI_UPLOAD_TO%/}/${slug}"
    fi
}

# Run only when executed, not when sourced (ci-results.sh sources the functions above).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then pr_ci_main "$@"; fi
