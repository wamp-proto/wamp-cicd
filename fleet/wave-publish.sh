#!/usr/bin/env bash
# wave-publish.sh - bring the rollout's dev branches from the exchange to GitHub (DEV PC).
#
#   ./wave-publish.sh                   dry run: show what would happen
#   ./wave-publish.sh --go              do it
#   ./wave-publish.sh --go --seal       ... and first add the maintainer-signed "seal" tip commit
#                                       where the landing will be a fast-forward (see below)
#   ./wave-publish.sh --only a,b        restrict to some repositories
#
# Repositories and issue numbers come from the current rollout ($FLEET_STATE/current: fleet.tsv
# + manifest.tsv), so the branch of each repository is fix_<issue>. Per repository:
#
#   1. refuse unless the working tree is clean
#   2. fetch the exchange ($EXCHANGE) and fast-forward the local fix_<issue> to it
#      (created from the exchange if it does not exist locally; a DIVERGED branch is refused)
#   3. git submodule update --init --recursive; git submodule status; just where
#   4. --seal only: in repositories whose integration branch cannot take a merge commit yet (the
#      .ai hook on upstream's default branch has no maintainer-merge support - the Way-A bootstrap),
#      add an empty, gitsign-signed "seal" commit as the branch tip and push it to the exchange too.
#      Landing there is a fast-forward, so the tip must be the maintainer's signed commit. Sealing
#      BEFORE the push means CI runs once, on the final tip.
#   5. push fix_<issue> to the fork (origin), with upstream tracking
#   6. print the GitHub URL that opens the pull request form (compare view)

set -uo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"

GO=0; SEAL=0; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --go) GO=1; shift ;;
        --seal) SEAL=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -f "${FLEET_STATE}/current" ] || { echo "ERROR: no rollout initialised" >&2; exit 1; }
STATE="${FLEET_STATE}/$(cat "${FLEET_STATE}/current")"
WAVE="$(cat "${STATE}/wave")"

run() { if [ "${GO}" = 1 ]; then echo "    \$ $*"; "$@"; else echo "    [dry-run] $*"; fi; }

# Can the default branch's .ai commit-msg hook take a maintainer merge? (no -> bootstrap, seal)
admits_merge() {  # admits_merge <dir> <main>
    local sha
    sha="$(git -C "$1" ls-tree "upstream/$2" .ai 2>/dev/null | awk '{print $3}')"
    [ -n "${sha}" ] || return 1
    git -C "$1/.ai" cat-file -e "${sha}" 2>/dev/null || git -C "$1/.ai" fetch -q origin 2>/dev/null || true
    git -C "$1/.ai" show "${sha}:.githooks/commit-msg" 2>/dev/null | grep -qi 'merge'
}

declare -a SUMMARY=()
failed=0
while IFS=$'\t' read -r name slug main _kind wave; do
    [ "${wave}" = "${WAVE}" ] || continue
    if [ -n "${ONLY}" ] && [[ ",${ONLY}," != *",${name},"* ]]; then continue; fi
    issue="$(awk -F'\t' -v r="${name}" '$1==r {print $3}' "${STATE}/manifest.tsv" | tail -1)"
    d="${FLEET_WORK_DIR}/${name}"; b="fix_${issue}"
    echo ""
    echo "================ ${name}  (${b}, issue #${issue})"
    if [ -z "${issue}" ]; then echo "    SKIP: no issue in the rollout manifest"; failed=1; continue; fi
    if [ -n "$(git -C "${d}" status --porcelain)" ]; then
        echo "    SKIP: working tree not clean"; git -C "${d}" status --short | sed 's/^/      /'
        failed=1; continue
    fi

    git -C "${d}" fetch -q --prune "${EXCHANGE}" || { echo "    SKIP: could not fetch ${EXCHANGE}"; failed=1; continue; }
    git -C "${d}" fetch -q upstream 2>/dev/null || true
    if ! git -C "${d}" show-ref -q --verify "refs/remotes/${EXCHANGE}/${b}"; then
        echo "    SKIP: ${EXCHANGE} has no ${b}"; failed=1; continue
    fi
    if git -C "${d}" show-ref -q --verify "refs/heads/${b}"; then
        run git -C "${d}" checkout -q "${b}"
        if [ "$(git -C "${d}" rev-parse "${b}")" != "$(git -C "${d}" rev-parse "${EXCHANGE}/${b}")" ]; then
            if git -C "${d}" merge-base --is-ancestor "${b}" "${EXCHANGE}/${b}"; then
                echo "    fast-forward ${b} to ${EXCHANGE}/${b}:"
                git -C "${d}" log --oneline --no-decorate "${b}..${EXCHANGE}/${b}" | sed 's/^/      /'
                run git -C "${d}" merge -q --ff-only "${EXCHANGE}/${b}"
            elif ! git -C "${d}" merge-base --is-ancestor "${EXCHANGE}/${b}" "${b}"; then
                echo "    SKIP: ${b} has DIVERGED from ${EXCHANGE}/${b} - reconcile by hand"; failed=1; continue
            fi
        fi
    else
        run git -C "${d}" checkout -q -b "${b}" "${EXCHANGE}/${b}"
    fi

    if [ "${GO}" = 1 ]; then
        git -C "${d}" submodule update -q --init --recursive
        echo "    submodules:"; git -C "${d}" submodule status | sed 's/^/      /'
        echo "    just where:"; (cd "${d}" && just where 2>&1 | sed -n '2,12p' | sed 's/^/    /')
    else
        echo "    [dry-run] git submodule update --init --recursive; git submodule status; just where"
    fi

    sealed="-"
    if ! admits_merge "${d}" "${main}"; then
        # Any maintainer-signed tip will do - `land` checks exactly this - not only a "Seal #"
        # commit: a signed commit of real work (e.g. a release key) is as good a tip, and
        # sealing on top of it again would only restart CI.
        if git -C "${d}" cat-file commit "${b}" 2>/dev/null | grep -q '^gpgsig'; then
            sealed="signed"
        elif [ "${SEAL}" = 1 ]; then
            run git -C "${d}" commit -q --allow-empty -S \
                -m "Seal #${issue} for landing (maintainer-signed tip; Way-A bootstrap fast-forward)"
            run git -C "${d}" push -q "${EXCHANGE}" "${b}"
            sealed="sealed"
        else
            sealed="NEEDS SEAL"
        fi
    fi

    run git -C "${d}" push -q -u origin "${b}"
    owner="$(git -C "${d}" remote get-url origin | sed -E 's|.*github\.com[:/]||; s|/.*||')"
    pr="$(awk -F'\t' -v r="${name}" '$1==r {print $4}' "${STATE}/manifest.tsv" | tail -1)"
    if [ -n "${pr}" ]; then
        url="https://github.com/${slug}/pull/${pr}"         # PR exists: CI re-runs on this push
        echo "    PR:       ${url}"
    else
        url="https://github.com/${slug}/compare/${main}...${owner}:${b}?expand=1"
        echo "    open PR:  ${url}"
    fi
    SUMMARY+=("$(printf '%-19s %-9s %-11s %s' "${name}" "${b}" "${sealed}" "${url}")")
done < "${STATE}/fleet.tsv"

echo ""
echo "================ summary"
printf '%-19s %-9s %-11s %s\n' REPO BRANCH SEAL "PULL REQUEST"
printf '%s\n' "${SUMMARY[@]}"
[ "${GO}" = 1 ] || echo "(dry run - nothing changed; re-run with --go)"
if printf '%s\n' "${SUMMARY[@]}" | grep -q 'NEEDS SEAL'; then
    echo ""
    echo "NEEDS SEAL: those repositories will land by fast-forward, so their tip must be a signed commit."
    echo "Re-run with --go --seal (CI then runs once, on the final tip), or seal later before landing."
fi
exit "${failed}"
