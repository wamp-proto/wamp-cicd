#!/usr/bin/env bash
# fleet-hygiene.sh - one-time cleanup of the wave's working copies on the DEV PC, before `cut`.
#
#   ./fleet-hygiene.sh                 dry run: show what would change
#   ./fleet-hygiene.sh --go            apply
#   ./fleet-hygiene.sh --only a,b      restrict to some repositories
#
# Repositories come from the current rollout ($FLEET_STATE/current, same as wamp-fleet-rollout.sh).
# Per repository:
#   1. refuse unless the working tree is clean; switch to the default branch if needed
#   2. BACK UP every local branch except the default branch into one git bundle, and verify it:
#        $FLEET_STATE/<rollout>/backup/<repo>-branches-<date>.bundle
#      (restore any branch:  git fetch <bundle> 'refs/heads/<name>:refs/heads/<name>')
#   3. delete those local branches (git branch -D) - remote copies are NOT touched
#   4. signing, as in autobahn-python: gpg.format=x509, gpg.x509.program=gitsign, commit.gpgsign=true
#   5. hooks: core.hooksPath=.ai/.githooks (initializing the .ai submodule if needed)

set -euo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"

GO=0
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --go) GO=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -f "${FLEET_STATE}/current" ] || { echo "ERROR: no rollout initialised (wamp-fleet-rollout.sh init ...)" >&2; exit 1; }
ROLLOUT="$(cat "${FLEET_STATE}/current")"
STATE="${FLEET_STATE}/${ROLLOUT}"
WAVE="$(cat "${STATE}/wave")"
BACKUP="${STATE}/backup"
STAMP="$(date +%Y%m%d-%H%M%S)"

run() { if [ "${GO}" = 1 ]; then echo "    \$ $*"; "$@"; else echo "    [dry-run] $*"; fi; }

setcfg() {  # setcfg <repo-dir> <key> <value>  - only when different
    local cur; cur="$(git -C "$1" config --local --get "$2" || true)"
    if [ "${cur}" = "$3" ]; then
        echo "    ok        $2=$3"
    else
        echo "    set       $2=$3   (was: ${cur:-unset})"
        run git -C "$1" config --local "$2" "$3"
    fi
}

command -v gitsign >/dev/null || echo "WARNING: gitsign not on PATH - signing config will be set but cannot sign yet" >&2

problems=0
while IFS=$'\t' read -r name _slug main _kind wave; do
    [ "${wave}" = "${WAVE}" ] || continue
    if [ -n "${ONLY}" ] && [[ ",${ONLY}," != *",${name},"* ]]; then continue; fi
    d="${FLEET_WORK_DIR}/${name}"
    echo ""
    echo "== ${name}  (default branch: ${main})"
    if [ ! -d "${d}/.git" ] && [ ! -f "${d}/.git" ]; then echo "    SKIP: no checkout at ${d}"; problems=$((problems+1)); continue; fi
    if [ -n "$(git -C "${d}" status --porcelain)" ]; then
        echo "    SKIP: working tree not clean"; git -C "${d}" status --short | sed 's/^/      /'
        problems=$((problems+1)); continue
    fi

    cur="$(git -C "${d}" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
    if [ "${cur}" != "${main}" ]; then
        echo "    on ${cur} -> switching to ${main}"
        run git -C "${d}" checkout -q "${main}"
    fi

    # lstrip=2, not :short - a branch that shares a name with a tag would print as "heads/<name>"
    mapfile -t branches < <(git -C "${d}" for-each-ref --format='%(refname:lstrip=2)' refs/heads | grep -vx "${main}" || true)
    if [ "${#branches[@]}" = 0 ]; then
        echo "    branches  none besides ${main}"
    else
        bundle="${BACKUP}/${name}-branches-${STAMP}.bundle"
        echo "    branches  ${#branches[@]} to delete, backed up first -> ${bundle}"
        if [ "${GO}" = 1 ]; then
            mkdir -p "${BACKUP}"
            refs=(); for b in "${branches[@]}"; do refs+=("refs/heads/${b}"); done
            git -C "${d}" bundle create -q "${bundle}" "${refs[@]}"
            git -C "${d}" bundle verify -q "${bundle}" >/dev/null 2>&1 \
                || { echo "    ERROR: bundle does not verify - NOT deleting anything"; problems=$((problems+1)); continue; }
            echo "    bundle    verified ($(git bundle list-heads "${bundle}" | wc -l) branches)"
            for b in "${branches[@]}"; do git -C "${d}" branch -q -D "${b}"; done
            echo "    deleted   ${#branches[@]} local branches"
        else
            printf '    [dry-run] bundle + delete: %s\n' "$(printf '%s ' "${branches[@]}" | cut -c1-150)"
        fi
    fi

    setcfg "${d}" gpg.format x509
    setcfg "${d}" gpg.x509.program gitsign
    setcfg "${d}" commit.gpgsign true

    if [ ! -d "${d}/.ai/.githooks" ]; then
        echo "    .ai       not initialised -> git submodule update --init .ai"
        run git -C "${d}" submodule update --init .ai
    fi
    setcfg "${d}" core.hooksPath .ai/.githooks
done < "${STATE}/fleet.tsv"

echo ""
if [ "${GO}" = 1 ]; then
    echo "done. Backups: ${BACKUP}/  (restore: git fetch <bundle> 'refs/heads/<b>:refs/heads/<b>')"
else
    echo "dry run - nothing changed; re-run with --go to apply."
fi
echo "Then: ./wamp-fleet-rollout.sh preflight"
[ "${problems}" = 0 ]
