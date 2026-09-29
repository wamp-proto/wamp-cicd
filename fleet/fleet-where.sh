#!/usr/bin/env bash
# fleet-where.sh - one look at every fleet repository (DEV PC): git settings, state, `just where`.
#
#   ./fleet-where.sh                 summary table (one row per repository) + problems
#   ./fleet-where.sh --where         ... plus the full `just where` of every repository
#   ./fleet-where.sh --wave 1        restrict to one wave of fleet.tsv
#   ./fleet-where.sh --only a,b      restrict to some repositories
#
# Read-only: fetches the remotes, changes nothing else. Per repository it checks
#   branch / clean / default branch == upstream == exchange     (in sync everywhere?)
#   core.hooksPath=.ai/.githooks                                 (policy hooks enforced?)
#   gpg.format=x509, gpg.x509.program=gitsign, commit.gpgsign    (maintainer signing ready?)
#   submodules at their pinned revision, .cicd / .ai pins        (fleet-consistent?)
#   `.cicd/scripts/community-files.sh check .`                   (managed files unchanged?)
#   `just where` answers                                         (Way-A recipes available?)

set -uo pipefail

WAMP_DIR="${WAMP_DIR:-$HOME/work/wamp}"
STATE_ROOT="${STATE_ROOT:-$HOME/.wamp-fleet}"
EXCHANGE="${EXCHANGE:-exchange}"   # name of the git remote that points at the exchange
WHERE=0; WAVE=""; ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --where) WHERE=1; shift ;;
        --wave) WAVE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
STATE="${STATE_ROOT}/$(cat "${STATE_ROOT}/current")"

cfg() { git -C "$1" config --get "$2" 2>/dev/null || echo "-"; }
PROBLEMS=()
printf '%-20s %-9s %-5s %-13s %-6s %-7s %-8s %-8s %-7s %-9s %s\n' \
    REPO BRANCH CLEAN "MAIN=UP=EXCH" HOOKS SIGNING .cicd .ai SUBMOD COMMUNITY "JUST WHERE"
while IFS=$'\t' read -r name _slug main _kind wave; do
    [ -z "${WAVE}" ] || [ "${wave}" = "${WAVE}" ] || continue
    if [ -n "${ONLY}" ] && [[ ",${ONLY}," != *",${name},"* ]]; then continue; fi
    d="${WAMP_DIR}/${name}"
    if [ ! -d "${d}/.git" ]; then printf '%-20s (no clone at %s)\n' "${name}" "${d}"; continue; fi
    for rem in upstream "${EXCHANGE}"; do git -C "${d}" fetch -q "${rem}" 2>/dev/null || true; done

    br="$(git -C "${d}" branch --show-current)"; br="${br:-DETACHED}"
    [ -z "$(git -C "${d}" status --porcelain)" ] && clean=yes || { clean=NO; PROBLEMS+=("${name}: working tree not clean"); }
    l="$(git -C "${d}" rev-parse -q --verify "${main}" 2>/dev/null)"
    u="$(git -C "${d}" rev-parse -q --verify "upstream/${main}" 2>/dev/null)"
    x="$(git -C "${d}" rev-parse -q --verify "${EXCHANGE}/${main}" 2>/dev/null)"
    if [ -n "${l}" ] && [ "${l}" = "${u}" ] && [ "${u}" = "${x}" ]; then sync="yes ${l:0:7}"
    else sync="NO"; PROBLEMS+=("${name}: ${main} ${l:0:7} / upstream ${u:0:7} / ${EXCHANGE} ${x:0:7} differ"); fi

    [ "$(cfg "${d}" core.hooksPath)" = ".ai/.githooks" ] && hooks=yes || { hooks=NO; PROBLEMS+=("${name}: core.hooksPath is '$(cfg "${d}" core.hooksPath)'"); }
    if [ "$(cfg "${d}" gpg.format)" = x509 ] && [ "$(cfg "${d}" gpg.x509.program)" = gitsign ] \
       && [ "$(cfg "${d}" commit.gpgsign)" = true ] && command -v gitsign >/dev/null; then sign=gitsign
    else sign=NO; PROBLEMS+=("${name}: signing not configured (gpg.format=$(cfg "${d}" gpg.format) gpg.x509.program=$(cfg "${d}" gpg.x509.program) commit.gpgsign=$(cfg "${d}" commit.gpgsign))"); fi

    cicd="$(git -C "${d}" ls-tree "${main}" .cicd 2>/dev/null | awk '{print substr($3,1,7)}')"
    ai="$(git -C "${d}" ls-tree "${main}" .ai 2>/dev/null | awk '{print substr($3,1,7)}')"
    [ -z "$(git -C "${d}" submodule status 2>/dev/null | grep -E '^[-+U]')" ] && sub=pinned || { sub=OFF; PROBLEMS+=("${name}: submodules not at their pinned revision (git submodule update --init --recursive)"); }
    if [ -f "${d}/.cicd/scripts/community-files.sh" ]; then
        (cd "${d}" && bash .cicd/scripts/community-files.sh check . >/dev/null 2>&1) && comm=ok || { comm=DRIFT; PROBLEMS+=("${name}: community files drifted"); }
    else comm="-"; fi
    (cd "${d}" && timeout 60 just where >/dev/null 2>&1) && jw=ok || { jw=FAILS; PROBLEMS+=("${name}: 'just where' fails"); }

    printf '%-20s %-9s %-5s %-13s %-6s %-7s %-8s %-8s %-7s %-9s %s\n' \
        "${name}" "${br}" "${clean}" "${sync}" "${hooks}" "${sign}" "${cicd:--}" "${ai:--}" "${sub}" "${comm}" "${jw}"
    if [ "${WHERE}" = 1 ]; then (cd "${d}" && just where 2>&1 | sed 's/^/      /'); fi
done < "${STATE}/fleet.tsv"

echo ""
if [ "${#PROBLEMS[@]}" -eq 0 ]; then echo "OK: no problems"; else printf 'PROBLEM  %s\n' "${PROBLEMS[@]}"; fi
