#!/usr/bin/env bash
# apply-rollout.sh - apply ONE rollout to ONE member repository, and record it.
#
#   apply-rollout.sh <member clone> <definition clone> <cohort>/<NNNN>-<name> --issue <n>
#                    [--footer <line>] [--fleet-url <url>] [--repo <inventory name>] [--allow-unlanded]
#
# The credential-free primitive of "rollouts as migrations" (#64). It runs on the member's rollout
# branch (cut beforehand, with its audit file, by the maintainer) and makes ONE commit:
#
#   1. adopts every EARLIER rollout of the cohort that has no marker yet but whose check.sh says
#      the repository already is in its desired state (writes that marker, without a script hash);
#   2. runs the rollout's apply.sh, from the DEFINITION CLONE - never from the member's .fleet/,
#      so the rollout that first adds .fleet/ needs no special case;
#   3. sets the member's .fleet/ submodule to the definition clone's commit, adding it if missing
#      - from the LOCAL clone's objects only: a private definition repository cannot be fetched on
#      a host without forge credentials. .gitmodules records the canonical forge URL;
#   4. writes the marker .waves/<cohort>/<NNNN>-<name>.toml;
#   5. commits: "Apply rollout <cohort>/<NNNN>-<name> (#<n>)".
#
# A TOOLING SOURCE - a member the definition repository itself pins as a submodule (wamp-cicd as
# .cicd, wamp-ai as .ai) - must carry no submodules: every other repository pins it, and .fleet/
# inside it would nest one level deeper with every bump (TOOLING-STRUCTURE.md). For such a member
# step 3 is different: the definition's pin goes into deps.toml and its checkout into the
# gitignored .deps/<definition repository> (scripts/deps.sh), again from local objects only.
# Everything else - adoption, apply.sh, the markers, the one commit, the exit codes - is the same.
#
# The definition clone's HEAD must be LANDED: contained in the default branch of one of its remotes
# (refs/remotes/<remote>/HEAD). .fleet/ is pinned to that commit, and a commit of an unlanded
# branch is one the forge does not have on its default branch - or at all: the member's CI could
# not check out .fleet/, and once the branch lands as a merge the pin is not on the default branch.
# --allow-unlanded turns that refusal off (sandboxes, dry runs).
#
# It never pushes, never talks to a forge, needs no credentials, and never derives an exchange
# path: it works on the clone it is given. Signing is not its business (the maintainer signs the
# branch's first commit and the landing merge).
#
# apply.sh / check.sh run with the member's root as working directory and this environment:
#   FLEET_NAME FLEET_COHORT FLEET_ROLLOUT FLEET_REPO FLEET_SLUG FLEET_DEFAULT_BRANCH
#   FLEET_DEF_DIR (the definition clone)   FLEET_TOOLS_DIR (wamp-cicd fleet/)
#   FLEET_TOOLING_SOURCE  empty for an ordinary member; for a tooling source the path under which
#                         the others pin it (.cicd or .ai) - then: no submodules, deps.toml instead
#                         (${FLEET_TOOLS_DIR}/../scripts/deps.sh set|sync)
# apply.sh changes files (and may `git add`); it does not commit or push; it is re-runnable.
#
# Exit codes, so an orchestration loop can re-run a half-finished wave:
#    0  applied (one commit made)
#   10  already applied: the marker is there - nothing done
#   11  the member's working tree is not clean - nothing done
#   12  apply.sh failed - the tree is left as it is, for inspection; nothing committed
#   13  an earlier rollout of the cohort is missing and cannot be adopted - nothing done
#   14  the repository is not a member of that cohort (per the definition's fleet.toml)
#   15  the commit was refused (a hook) - changes left staged
#    2  usage, or the definition clone is not in a committed state, or its HEAD is not landed

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
die() { echo "ERROR: $*" >&2; exit "${2:-2}"; }
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MEMBER=""; DEF=""; ROLLOUT=""; ISSUE=""; FOOTER=""; FLEET_URL=""; REPO=""; ALLOW_UNLANDED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --issue) ISSUE="${2:-}"; shift 2 ;;
        --footer) FOOTER="${2:-}"; shift 2 ;;
        --fleet-url) FLEET_URL="${2:-}"; shift 2 ;;
        --repo) REPO="${2:-}"; shift 2 ;;
        --allow-unlanded) ALLOW_UNLANDED=1; shift ;;
        -h|--help) usage ;;
        -*) die "unknown option: $1" ;;
        *) if [ -z "${MEMBER}" ]; then MEMBER="$1"; elif [ -z "${DEF}" ]; then DEF="$1"; elif [ -z "${ROLLOUT}" ]; then ROLLOUT="$1"; else usage; fi; shift ;;
    esac
done
[ -n "${MEMBER}" ] && [ -n "${DEF}" ] && [ -n "${ROLLOUT}" ] || usage
[[ "${ISSUE}" =~ ^[0-9]+$ ]] || die "--issue <number> is required"
[[ "${ROLLOUT}" =~ ^([a-z][a-z0-9-]*)/([0-9]{4}-[a-z0-9][a-z0-9-]*)$ ]] || die "rollout must be <cohort>/<NNNN>-<name>, got '${ROLLOUT}'"
COHORT="${BASH_REMATCH[1]}"; RNAME="${BASH_REMATCH[2]}"
MEMBER="$(cd "${MEMBER}" 2>/dev/null && pwd)" || die "no such member clone"
DEF="$(cd "${DEF}" 2>/dev/null && pwd)" || die "no such definition clone"
git -C "${MEMBER}" rev-parse --git-dir >/dev/null 2>&1 || die "${MEMBER} is not a git repository"
RDIR="${DEF}/rollouts/${COHORT}/${RNAME}"
[ -d "${RDIR}" ] || die "no rollout ${ROLLOUT} in ${DEF}"

# The definition must be in a committed state: the marker names a commit, and what ran must be it.
[ -z "$(git -C "${DEF}" status --porcelain -- rollouts fleet.toml 2>/dev/null)" ] \
    || die "the definition clone has uncommitted changes under rollouts/ or fleet.toml"
DEF_COMMIT="$(git -C "${DEF}" rev-parse HEAD 2>/dev/null)" || die "${DEF} is not a git repository"
if [ "${ALLOW_UNLANDED}" != 1 ]; then
    landed=""
    while read -r ref; do
        [ -n "${ref}" ] || continue
        if git -C "${DEF}" merge-base --is-ancestor "${DEF_COMMIT}" "${ref}" 2>/dev/null; then landed="${ref}"; break; fi
    done < <(git -C "${DEF}" for-each-ref --format='%(symref)' 'refs/remotes/*/HEAD' | sort -u)
    if [ -z "${landed}" ]; then
        echo "ERROR: the definition clone's HEAD (${DEF_COMMIT:0:12}, $(git -C "${DEF}" rev-parse --abbrev-ref HEAD)) is not landed:" >&2
        echo "       it is not contained in the default branch of any of its remotes (refs/remotes/<remote>/HEAD)." >&2
        echo "       Land that branch first, fetch, and check out the default branch - members pin .fleet/ to this commit." >&2
        echo "       (A remote without a known default branch: git -C ${DEF} remote set-head <remote> <branch>.)" >&2
        echo "       For a sandbox or a dry run: --allow-unlanded." >&2
        exit 2
    fi
fi
python3 "${HERE}/lib/check-rollout.py" "${RDIR}" --quiet || die "rollout ${ROLLOUT} is not valid (failed checks above)"

# Is this repository a member of the cohort? By its inventory name: --repo, else the clone's
# directory name (which is the inventory name by convention, ~/work/<fleet>/<name>).
[ -n "${REPO}" ] || REPO="$(basename "${MEMBER}")"
row="$(python3 "${HERE}/lib/inventory-repos.py" "${DEF}/fleet.toml" --cohort "${COHORT}" | awk -F'\t' -v r="${REPO}" '$1==r')" \
    || die "cannot read the cohort '${COHORT}' from ${DEF}/fleet.toml"
[ -n "${row}" ] || { echo "ERROR: '${REPO}' is not a member of cohort '${COHORT}' in ${DEF}/fleet.toml" >&2; exit 14; }
SLUG="$(cut -f2 <<<"${row}")"; DEFAULT_BRANCH="$(cut -f3 <<<"${row}")"

marker() { echo ".waves/${COHORT}/$1.toml"; }
if [ -e "${MEMBER}/$(marker "${RNAME}")" ]; then
    echo "--> ${REPO}: ${ROLLOUT} is already applied ($(marker "${RNAME}"))"; exit 10
fi
if [ -n "$(git -C "${MEMBER}" status --porcelain)" ]; then
    echo "ERROR: ${REPO}: the working tree is not clean" >&2; git -C "${MEMBER}" status --short >&2; exit 11
fi

# The footer must not trip the .ai commit-msg hook: its patterns are per line, case-insensitive,
# and match the AI names as SUBSTRINGS. Checked here, before anything is changed.
if [ -n "${FOOTER}" ] && grep -q -i -E "((authored by|co-authored by|generated by).*(claude|gemini|copilot|ai|artificial intelligence))|(((co-)?authored-by:|generated-by:|signed-off-by:).*(claude|gemini|copilot|ai|artificial intelligence))|((generated with|created with|built with|made with).*(claude|gemini|copilot|ai))" <<<"${FOOTER}"; then
    die "--footer would be rejected by the commit-msg hook (authorship attribution): ${FOOTER}"
fi

# Is this member a tooling source? Yes when the definition repository's own .gitmodules pins it:
# compared by <owner>/<repo>, the last two components of the URL. Nothing is hard-coded here and
# the inventory has no key for it.
owner_repo() { local u="${1%.git}"; u="${u%/}"; u="${u//://}"; awk -F/ 'NF>=2 {print tolower($(NF-1) "/" $NF)}' <<<"${u}"; }
TOOLING_SOURCE=""; CICD_DEP=""
if [ -f "${DEF}/.gitmodules" ]; then
    while read -r key u; do
        [ -n "${key}" ] || continue
        name="${key#submodule.}"; name="${name%.url}"
        path="$(git -C "${DEF}" config -f .gitmodules --get "submodule.${name}.path" 2>/dev/null || true)"
        [ "$(owner_repo "${u}")" = "${SLUG,,}" ] && TOOLING_SOURCE="${path}"
        [ "${path}" = .cicd ] && CICD_DEP="$(basename "${u%.git}")"
    done < <(git -C "${DEF}" config -f .gitmodules --get-regexp '^submodule\..*\.url$' 2>/dev/null || true)
fi
DEPS_SH="${HERE}/../scripts/deps.sh"
export FLEET_NAME="${FLEET_NAME:-$(basename "${DEF}" | sed 's/-fleet$//')}"

# The canonical URL of the definition repository, recorded in .gitmodules (or deps.toml): what the
# member already records, else --fleet-url, else FLEET_DEF_URL (the environment, or the fleet's
# <fleet>.env), else the definition clone's forge remote. (An exchange path is not canonical.)
DEF_DEP="$(basename "${DEF}")"
if [ -n "${TOOLING_SOURCE}" ]; then url="$(bash "${DEPS_SH}" get --root "${MEMBER}" "${DEF_DEP}" 2>/dev/null | cut -d' ' -f2 || true)"
else url="$(git -C "${MEMBER}" config -f .gitmodules --get submodule..fleet.url 2>/dev/null || true)"; fi
[ -n "${url}" ] || url="${FLEET_URL}"
if [ -z "${url}" ] && [ -z "${FLEET_DEF_URL:-}" ]; then
    FLEET_DEF_URL="$(bash -c '. "$1" >/dev/null 2>&1 && printf %s "${FLEET_DEF_URL:-}"' _ "${HERE}/lib/config.sh" 2>/dev/null || true)"
fi
[ -n "${url}" ] || url="${FLEET_DEF_URL:-}"
if [ -z "${url}" ]; then
    for r in upstream origin; do
        u="$(git -C "${DEF}" config --get "remote.${r}.url" 2>/dev/null || true)"
        if [[ "${u}" =~ github\.com[:/](.+)$ ]]; then url="https://github.com/${BASH_REMATCH[1]%.git}.git"; break; fi
    done
fi
[ -n "${url}" ] || die "cannot tell the definition repository's forge URL: pass --fleet-url <url> (or set FLEET_DEF_URL)"
[ -z "${TOOLING_SOURCE}" ] || DEF_DEP="$(basename "${url%.git}")"

export FLEET_COHORT="${COHORT}" FLEET_ROLLOUT="${RNAME}" FLEET_REPO="${REPO}" FLEET_SLUG="${SLUG}"
export FLEET_DEFAULT_BRANCH="${DEFAULT_BRANCH}" FLEET_DEF_DIR="${DEF}" FLEET_TOOLS_DIR="${HERE}"
export FLEET_TOOLING_SOURCE="${TOOLING_SOURCE}"
# The .cicd pin as staged (the index): before apply.sh that is HEAD's, after it and `git add -A`
# it is the pin the commit will set. Empty when the repository has no .cicd.
# A tooling source has no .cicd: its wamp-cicd pin, if it has one, is in deps.toml.
cicd_pin() {
    if [ -n "${TOOLING_SOURCE}" ]; then
        [ -z "${CICD_DEP}" ] || bash "${DEPS_SH}" get --root "${MEMBER}" "${CICD_DEP}" 2>/dev/null | cut -d' ' -f1 || true
    else
        git -C "${MEMBER}" ls-files -s -- .cicd 2>/dev/null | awk '$1=="160000"{print $2}'
    fi
}
CICD_BEFORE="$(cicd_pin)"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 1. Adopt earlier rollouts of the cohort - or stop: nothing is skipped.
ADOPTED=()
while read -r earlier; do
    [ -n "${earlier}" ] || continue
    [[ "${earlier}" < "${RNAME}" ]] || continue
    [ -e "${MEMBER}/$(marker "${earlier}")" ] && continue
    chk="${DEF}/rollouts/${COHORT}/${earlier}/check.sh"
    if [ -x "${chk}" ] && (cd "${MEMBER}" && FLEET_ROLLOUT="${earlier}" "${chk}") >/dev/null 2>&1; then
        ADOPTED+=("${earlier}")
    else
        echo "ERROR: ${REPO}: the earlier rollout ${COHORT}/${earlier} has no marker here and cannot be adopted" >&2
        echo "       (its check.sh is missing or does not pass). Apply it first: nothing is skipped." >&2
        exit 13
    fi
done < <(find "${DEF}/rollouts/${COHORT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

# 2. apply.sh, from the definition clone.
SCRIPT_HASH=""
if [ -f "${RDIR}/apply.sh" ]; then
    echo "--> ${REPO}: applying ${ROLLOUT}"
    if ! (cd "${MEMBER}" && bash "${RDIR}/apply.sh"); then
        echo "ERROR: ${REPO}: apply.sh of ${ROLLOUT} failed - the working tree is left as it is" >&2; exit 12
    fi
    SCRIPT_HASH="sha256:$(sha256sum "${RDIR}/apply.sh" | cut -d' ' -f1)"
elif [ -x "${RDIR}/check.sh" ] && (cd "${MEMBER}" && "${RDIR}/check.sh") >/dev/null 2>&1; then
    echo "--> ${REPO}: ${ROLLOUT} has no apply.sh; its check.sh passes - adopting it"
else
    echo "ERROR: ${REPO}: ${ROLLOUT} has no apply.sh and cannot be adopted (no passing check.sh)" >&2; exit 13
fi

# 3. The definition, pinned at its commit, from LOCAL objects only (no network): the .fleet/
# submodule - or, in a tooling source, the deps.toml entry and .deps/<definition repository>.
if [ -n "${TOOLING_SOURCE}" ]; then
(
    cd "${MEMBER}" || exit 1
    [ ! -e .fleet ] && ! git config -f .gitmodules --get submodule..fleet.url >/dev/null 2>&1 \
        || { echo "ERROR: ${REPO} is a tooling source but carries a .fleet submodule - remove it first" >&2; exit 1; }
    git check-ignore -q .deps/x 2>/dev/null || { echo ".deps/" >> .gitignore; }
    bash "${DEPS_SH}" set "${DEF_DEP}" "${url}" "${DEF_COMMIT}" >/dev/null \
        && bash "${DEPS_SH}" sync --from "${DEF_DEP}=${DEF}" "${DEF_DEP}" >/dev/null \
        || { echo "ERROR: could not pin ${DEF_DEP} in deps.toml / .deps from ${DEF}" >&2; exit 1; }
) || exit 12
else
(
    cd "${MEMBER}" || exit 1
    if [ ! -e .fleet/.git ] && git config -f .gitmodules --get submodule..fleet.url >/dev/null 2>&1; then
        # Recorded, but not initialised in this clone (a fresh clone): initialise it from the
        # LOCAL definition clone, by rewriting the recorded forge URL for this one command.
        git submodule --quiet init .fleet
        git -c protocol.file.allow=always -c "url.${DEF}.insteadOf=$(git config -f .gitmodules --get submodule..fleet.url)" \
            submodule --quiet update .fleet >/dev/null 2>&1 \
            || { echo "ERROR: could not initialise .fleet from ${DEF}" >&2; exit 1; }
        git -C .fleet -c protocol.file.allow=always fetch --quiet "${DEF}" HEAD \
            || { echo "ERROR: could not update .fleet from ${DEF}" >&2; exit 1; }
    elif [ ! -e .fleet/.git ]; then
        git -c protocol.file.allow=always submodule add --quiet --force "${DEF}" .fleet >/dev/null 2>&1 \
            || { echo "ERROR: could not add .fleet from ${DEF}" >&2; exit 1; }
    else
        git -C .fleet -c protocol.file.allow=always fetch --quiet "${DEF}" HEAD \
            || { echo "ERROR: could not update .fleet from ${DEF}" >&2; exit 1; }
    fi
    git -C .fleet checkout --quiet "${DEF_COMMIT}" || { echo "ERROR: .fleet: no commit ${DEF_COMMIT}" >&2; exit 1; }
    # .gitmodules (what everyone else clones from) and this clone's own setting both say the
    # canonical URL; the checkout above already came from the local definition clone.
    git config -f .gitmodules submodule..fleet.url "${url}"
    git config submodule..fleet.url "${url}"
    git -C .fleet remote set-url origin "${url}" 2>/dev/null || true
) || exit 12
fi

# 4. The markers. An ADOPTED rollout records the .cicd pin its check.sh passed on (before apply.sh
# ran); the rollout that ran records the pin THIS COMMIT sets. No .cicd: the key is left out.
git -C "${MEMBER}" add -A
CICD_AFTER="$(cicd_pin)"
write_marker() {  # write_marker <rollout name> <script hash or empty> <.cicd pin or empty>
    local f="${MEMBER}/$(marker "$1")"
    mkdir -p "$(dirname "${f}")"
    {
        echo "rollout = \"${COHORT}/$1\""
        echo "fleet   = \"${url%.git}@${DEF_COMMIT}\""
        if [ -n "$2" ]; then echo "script  = \"$2\""; else echo "adopted = true   # already in the desired state (check.sh); apply.sh did not run"; fi
        [ -z "$3" ] || echo "cicd    = \"$3\""
        echo "issue   = ${ISSUE}"
        echo "applied = $(now)"
    } > "${f}"
}
for a in ${ADOPTED[@]+"${ADOPTED[@]}"}; do write_marker "${a}" "" "${CICD_BEFORE}"; done
write_marker "${RNAME}" "${SCRIPT_HASH}" "${CICD_AFTER}"

# 5. One commit. The tree was clean before, so everything staged here is this rollout's.
git -C "${MEMBER}" add -A
body="Definition: ${url%.git} at ${DEF_COMMIT:0:12}."
[ "${#ADOPTED[@]}" -eq 0 ] || body="${body}
Adopted, already in place: $(printf "${COHORT}/%s " "${ADOPTED[@]}")"
msg="Apply rollout ${ROLLOUT} (#${ISSUE})

${body}"
[ -z "${FOOTER}" ] || msg="${msg}

${FOOTER}"
if ! git -C "${MEMBER}" commit --quiet -m "${msg}"; then
    echo "ERROR: ${REPO}: the commit was refused (see above); the changes are left staged" >&2; exit 15
fi
echo "--> ${REPO}: ${ROLLOUT} applied: $(git -C "${MEMBER}" log -1 --format='%h %s')"
[ "${#ADOPTED[@]}" -eq 0 ] || echo "    adopted: ${ADOPTED[*]}"
