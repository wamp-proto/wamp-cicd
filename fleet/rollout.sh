#!/usr/bin/env bash
# rollout.sh - drive ONE batched rollout across one cohort of a fleet of repositories.
#
# Runs on the DEV PC (it needs `gh` credentials and gitsign). The AI assistant does the
# per-repository content work on the AI host between `cut` and `sync`; everything else is here.
#
#   Phase                     Where    What
#   ------------------------  -------  -----------------------------------------------------
#   init <name> --cohort C    dev PC   name the rollout; freeze cohort C + ONE .cicd/.ai pin pair
#   preflight                 dev PC   read-only: remotes, cleanliness, hooks, signing, branches
#   prune                     dev PC   delete local branches already contained in upstream/master
#   file-issues               dev PC   render one issue per repo, file it via ~/file-issue.sh
#   cut                       dev PC   `new-branch <issue>` (signed audit commit) in every repo
#     ...                     AI host  AI implements on each fix_<N>, pushes to the exchange
#   sync                      dev PC   fast-forward each local fix_<N> from the exchange
#   seal                      dev PC   signed tip commit, ONLY where master can't take a merge
#   publish                   dev PC   `publish` each branch (fork + exchange)
#   open-prs                  dev PC   one PR per repo, "Closes #<issue>"
#   status                    dev PC   one table: issue, tips, PR, checks, signature
#   land                      dev PC   guarded local landing + push + branch cleanup
#   finish                    dev PC   close the rollout once every repository has landed
#
# Every phase that changes something is a DRY RUN unless --go is given.
# Every phase takes --only repo[,repo...] to act on a subset.
# Phases are idempotent: re-running one skips repositories that are already done.
#
# init <name> --cohort <cohort> --issue-template <file> [--cicd <sha>] [--ai <sha>]
#   <name>   a label for this rollout, e.g. wave1-2026-09 - NOT a commit. It names the state
#            directory ($FLEET_STATE/<name>/, default ~/.fleet/<fleet>/<name>/) and appears in the issue titles.
#   --cohort the cohort of the fleet's inventory this rollout applies to (required)
#   --issue-template  this rollout's issue text (placeholders: @@SLUG@@ @@ROLLOUT@@ @@COHORT@@ ...);
#            copied into the rollout's state, so later edits of the file change nothing
#   --cicd   wamp-cicd commit to pin in EVERY repository of the cohort (default: current main)
#   --ai     wamp-ai commit to pin in EVERY repository of the cohort (default: current main)
#   One rollout at a time per fleet: `init` refuses while another is open; `finish` closes one
#   once every repository has landed.
#   Both are resolved to full SHAs once, at init, and recorded; later moves of main don't matter.
#
# The Way-A recipes are taken from wamp-cicd AT THE ROLLOUT'S PINNED COMMIT, via a small shim
# justfile per run, so repos that do not import workflow.just yet (the five bootstrap repos) use
# exactly the code being rolled out.

set -euo pipefail

# Which fleet, and its configuration (inventory, clones, state, exchange remote, ...).
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"
FILE_ISSUE="$(command -v "${FILE_ISSUE}" 2>/dev/null || echo "${FILE_ISSUE}")"

GO=0
ONLY=""

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "--> $*"; }
warn() { echo "    WARNING: $*" >&2; }

# Run a mutating command, or show it in a dry run.
run() {
    if [ "${GO}" = 1 ]; then
        echo "    \$ $*"
        "$@"
    else
        echo "    [dry-run] $*"
    fi
}

# The PR is titled like the rollout issue it closes (saved from the draft by file-issues).
pr_title() {  # pr_title <repo> <issue>
    local t; t="$(cat "$(state_dir)/drafts/$1.title" 2>/dev/null || true)"
    echo "${t:-Fleet rollout $(current_rollout)} (#$2)"
}

# -- rollout state -------------------------------------------------------------

current_rollout() {
    [ -f "${FLEET_STATE}/current" ] || die "no rollout initialised; run: $0 init <rollout-name>"
    cat "${FLEET_STATE}/current"
}
state_dir()  { echo "${FLEET_STATE}/$(current_rollout)"; }
pin()        { grep -m1 "^$1=" "$(state_dir)/pins" | cut -d= -f2; }
manifest()   { echo "$(state_dir)/manifest.tsv"; }   # repo  slug  issue  pr

mf_get() {   # mf_get <repo> <column: issue|pr>
    local col; case "$2" in issue) col=3 ;; pr) col=4 ;; *) die "bad column $2" ;; esac
    awk -F'\t' -v r="$1" -v c="$col" '$1==r {print $c}' "$(manifest)" 2>/dev/null | tail -1
}
mf_set() {   # mf_set <repo> <slug> <issue> <pr>
    local m; m="$(manifest)"
    touch "${m}"
    awk -F'\t' -v r="$1" '$1!=r' "${m}" > "${m}.tmp" || true
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${m}.tmp"
    mv "${m}.tmp" "${m}"
}

# fleet.tsv (frozen at init; ONLY the rollout's cohort members): name  slug  default_branch  cohorts
fleet_col() {  # fleet_col <name> <col#>
    awk -F'\t' -v r="$1" -v c="$2" '$1==r {print $c}' "$(state_dir)/fleet.tsv"
}
main_of() { fleet_col "$1" 3; }
repos() {
    local r
    for r in $(cut -f1 "$(state_dir)/fleet.tsv"); do
        if [ -z "${ONLY}" ] || [[ ",${ONLY}," == *",${r},"* ]]; then echo "${r}"; fi
    done
}
rdir()   { echo "${FLEET_WORK_DIR}/$1"; }
g()      { git -C "$(rdir "$1")" "${@:2}"; }
branch() { echo "fix_$(mf_get "$1" issue)"; }

gh_slug() {  # owner/repo from a remote URL - as CONFIGURED: `git remote get-url` would apply
    # url.*.insteadOf rewrites first, and the slug is then read off the rewritten URL
    g "$1" config --get "remote.$2.url" 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||; s|/$||'
}
slug()       { fleet_col "$1" 2; }
fork_owner() { gh_slug "$1" origin | cut -d/ -f1; }

# The shim: WORKFLOW_MAIN first, then the rollout's own workflow.just. Sub-invocations inside
# workflow.just re-enter via `just --justfile {{justfile()}}` with NO working directory, so they
# run in the directory the justfile lives in. The shim therefore has to live in the repository
# ROOT (as a repo's own justfile does) - kept out of `git status` via .git/info/exclude, so the
# clean-tree guards in new-branch/publish/land still see a clean tree.
SHIM_NAME=".fleet-shim.just"
wf() {
    local repo="$1"; shift
    local d excl
    d="$(rdir "${repo}")"
    excl="$(g "${repo}" rev-parse --git-path info/exclude)"
    case "${excl}" in /*) ;; *) excl="${d}/${excl}" ;; esac
    mkdir -p "$(dirname "${excl}")"
    grep -qxF "/${SHIM_NAME}" "${excl}" 2>/dev/null || echo "/${SHIM_NAME}" >> "${excl}"
    printf "WORKFLOW_MAIN := '%s'\nimport '%s/workflow.just'\n" "$(main_of "${repo}")" "$(state_dir)" > "${d}/${SHIM_NAME}"
    (cd "${d}" && just --justfile "${d}/${SHIM_NAME}" "$@")
}

# Can the integration branch's .ai commit-msg hook take a maintainer merge commit?
# (autobahn-python: yes. The five bootstrap repos: no - their old hook refuses any commit
# on master, so the bootstrap lands by fast-forward and the tip must be the signed commit.)
master_admits_merge() {
    local repo="$1" sha
    sha="$(g "${repo}" ls-tree "upstream/$(main_of "${repo}")" .ai | awk '{print $3}')"
    [ -n "${sha}" ] || return 1
    git -C "$(rdir "${repo}")/.ai" cat-file -e "${sha}" 2>/dev/null \
        || git -C "$(rdir "${repo}")/.ai" fetch -q origin 2>/dev/null || true
    git -C "$(rdir "${repo}")/.ai" show "${sha}:.githooks/commit-msg" 2>/dev/null | grep -qi 'merge'
}

tip_is_signed() { g "$1" cat-file commit "$2" | grep -q '^gpgsig'; }

# -- phases --------------------------------------------------------------------

cmd_init() {
    local id="${1:-}"; shift || true
    local usage="usage: $0 init <rollout-name> --cohort <cohort> --issue-template <file> [--cicd <sha>] [--ai <sha>]"
    [ -n "${id}" ] || die "${usage}"
    local cicd="" ai="" cohort="" template=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --cicd) cicd="$2"; shift 2 ;;
            --ai)   ai="$2"; shift 2 ;;
            --cohort) cohort="$2"; shift 2 ;;
            --issue-template) template="$2"; shift 2 ;;
            *) die "unknown: $1" ;;
        esac
    done
    [ -n "${cohort}" ] || die "${usage}"
    [ -f "${template}" ] || die "no issue template for this rollout: --issue-template <file>  (${usage})"
    # One rollout at a time per fleet (so: at most one open rollout per repository - overlapping
    # cohorts must never pin a repository two ways at once).
    if [ -f "${FLEET_STATE}/current" ] && [ "$(cat "${FLEET_STATE}/current")" != "${id}" ]; then
        die "rollout '$(cat "${FLEET_STATE}/current")' is still open in fleet '${FLEET_NAME}': land it and run '$0 finish' first"
    fi
    [ -n "${cicd}" ] || cicd="$(git ls-remote "${CICD_URL}" HEAD | awk '{print $1}')"
    [ -n "${ai}" ]   || ai="$(git ls-remote "${AI_URL}" HEAD | awk '{print $1}')"

    # From the canonical URL, not from a named remote: on the dev PC `origin` is the
    # maintainer's FORK, and a clone may carry other remotes that cannot be fetched at all.
    # Every landed commit is reachable from canonical main.
    note "fetching canonical wamp-cicd main into ${CICD_DIR}"
    git -C "${CICD_DIR}" fetch -q "${CICD_URL}" main \
        || die "could not fetch ${CICD_URL} main"
    # A short SHA on the command line becomes the full one, so every issue and pin agrees.
    cicd="$(git -C "${CICD_DIR}" rev-parse --verify -q "${cicd}^{commit}" 2>/dev/null || echo "${cicd}")"
    git -C "${CICD_DIR}" cat-file -e "${cicd}:workflow.just" \
        || die "wamp-cicd ${cicd:0:7} has no workflow.just"
    git -C "${CICD_DIR}" cat-file -e "${cicd}:templates/CONTRIBUTING.md" \
        || die "wamp-cicd ${cicd:0:7} has no templates/CONTRIBUTING.md - land wamp-cicd#16 first"

    local d="${FLEET_STATE}/${id}"
    mkdir -p "${d}/drafts"
    printf 'cicd=%s\nai=%s\n' "${cicd}" "${ai}" > "${d}/pins"
    git -C "${CICD_DIR}" show "${cicd}:workflow.just" > "${d}/workflow.just"

    # Freeze the fleet for this rollout: a copy of the fleet's inventory (FLEET_INVENTORY, from
    # the fleet's configuration), and where it came from.
    [ -f "${FLEET_INVENTORY}" ] || die "fleet '${FLEET_NAME}': no inventory at ${FLEET_INVENTORY}"
    python3 "${FLEET_TOOLS_DIR}/lib/check-inventory.py" "${FLEET_INVENTORY}" --quiet \
        || die "fleet '${FLEET_NAME}': invalid inventory ${FLEET_INVENTORY} (failed checks above)"
    cp "${FLEET_INVENTORY}" "${d}/fleet.toml"
    # The inventory is usually a symlink into the definition repository's clone: record THAT commit.
    local inv_rev; inv_rev="$(git -C "$(dirname "$(readlink -f "${FLEET_INVENTORY}")")" rev-parse --short HEAD 2>/dev/null || echo "not in git")"
    printf 'inventory=%s @ %s\n' "${FLEET_INVENTORY}" "${inv_rev}" >> "${d}/pins"
    note "fleet '${FLEET_NAME}': ${FLEET_INVENTORY} (${inv_rev})"
    python3 "${FLEET_TOOLS_DIR}/lib/inventory-repos.py" "${d}/fleet.toml" --cohort "${cohort}" > "${d}/fleet.tsv" \
        || die "fleet '${FLEET_NAME}': cannot select cohort '${cohort}'"
    echo "${cohort}" > "${d}/cohort"
    cp "${template}" "${d}/issue-template.md"
    local members
    members="$(cut -f1 "${d}/fleet.tsv" | tr '\n' ' ')"
    [ -n "${members}" ] || die "cohort '${cohort}' of fleet '${FLEET_NAME}' has no repositories"

    touch "${d}/manifest.tsv"
    echo "${id}" > "${FLEET_STATE}/current"
    note "rollout ${id}: cohort ${cohort} = ${members}"
    note "pins: .cicd -> ${cicd:0:7}, .ai -> ${ai:0:7}  (state: ${d})"
}

cmd_preflight() {
    local blockers=0 r d open contained notc
    command -v gh >/dev/null || die "gh not installed"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
    [ -x "${FILE_ISSUE}" ] || warn "${FILE_ISSUE} not found or not executable (install: just fleet-install-tools)"

    for r in $(repos); do
        m="$(main_of "${r}")"
        d="$(rdir "${r}")"
        echo ""
        echo "== ${r}"
        [ -d "${d}/.git" ] || { warn "no git checkout at ${d}"; blockers=$((blockers+1)); continue; }
        for rem in upstream origin ${EXCHANGE}; do
            g "${r}" remote get-url "${rem}" >/dev/null 2>&1 \
                || { warn "remote '${rem}' missing"; blockers=$((blockers+1)); }
        done
        # Any OTHER remote that carries the default branch becomes a publish target for
        # workflow.just's new-branch/publish - it would push YOUR dev branch into someone
        # else's fork (it happened: two contributors' forks as remotes in one clone). Blocker
        # until removed.
        local extra
        extra="$(g "${r}" remote | grep -vxE "upstream|origin|${EXCHANGE}" | tr '\n' ' ' || true)"
        if [ -n "${extra}" ]; then
            warn "extra remote(s): ${extra}- new-branch/publish would push dev branches there; remove them (git remote rm <name>)"
            blockers=$((blockers+1))
        fi
        # All three: new-branch cuts from upstream and publishes only to remotes whose
        # ${m} tracking ref it can see (origin + the exchange remote).
        for rem in upstream origin ${EXCHANGE}; do
            g "${r}" fetch -q --prune "${rem}" 2>/dev/null || warn "could not fetch ${rem}"
        done
        echo "   slug:        $(slug "${r}")   fork: $(fork_owner "${r}")   default: ${m}"
        # The fleet is a claim; the remotes are the facts. Disagreement is a blocker.
        if [ "$(gh_slug "${r}" upstream)" != "$(slug "${r}")" ]; then
            warn "upstream remote is $(gh_slug "${r}" upstream), fleet.toml says $(slug "${r}")"
            blockers=$((blockers+1))
        fi
        local hb
        hb="$(g "${r}" ls-remote --symref upstream HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2); print $2}' || true)"
        if [ "${hb}" != "${m}" ]; then
            warn "upstream default branch is '${hb}', fleet.toml says '${m}'"
            blockers=$((blockers+1))
        fi
        echo "   on:          $(g "${r}" branch --show-current)   dirty: $(g "${r}" status --porcelain | wc -l)"
        echo "   hooksPath:   $(g "${r}" config core.hooksPath || echo UNSET)"
        [ "$(g "${r}" config core.hooksPath || true)" = ".ai/.githooks" ] \
            || { warn "hooks not enforced: just --justfile .ai/justfile setup-repo"; blockers=$((blockers+1)); }
        echo "   signing:     format=$(g "${r}" config gpg.format || echo -) program=$(g "${r}" config gpg.x509.program || echo -)"
        [ "$(g "${r}" config gpg.format || true)" = "x509" ] \
            || { warn "gitsign not configured for this repo (signed cut/merge impossible)"; blockers=$((blockers+1)); }
        if master_admits_merge "${r}"; then
            echo "   landing:     signed merge commit (master's .ai hook admits maintainer merges)"
        else
            echo "   landing:     BOOTSTRAP - fast-forward; tip must be a signed 'seal' commit"
        fi
        open="$(g "${r}" for-each-ref --format='%(refname:lstrip=2)' refs/heads | grep -vx "${m}" || true)"
        contained=0; notc=""
        for b in ${open}; do
            if g "${r}" merge-base --is-ancestor "${b}" "upstream/${m}"; then
                contained=$((contained+1))
            else
                notc="${notc} ${b}"
            fi
        done
        echo "   branches:    $(echo "${open}" | grep -c . || true) local besides ${m}: ${contained} already in upstream/${m} (prune can delete)"
        if [ -n "${notc}" ]; then
            echo "                NOT in upstream/${m} (decide by hand - squash-merged? abandoned?):"
            for b in ${notc}; do echo "                  ${b}"; done
            blockers=$((blockers+1))
        fi
        # Branch protection: a local landing pushes to upstream master directly.
        local prot pjson
        if pjson="$(gh api "repos/$(slug "${r}")/branches/${m}/protection" 2>/dev/null)"; then
            prot="$(printf '%s' "${pjson}" | python3 -c 'import sys,json; p=json.load(sys.stdin); print("linear_history=%s enforce_admins=%s pr_reviews=%s" % (p.get("required_linear_history",{}).get("enabled"), p.get("enforce_admins",{}).get("enabled"), "required_pull_request_reviews" in p))' 2>/dev/null || echo unreadable)"
        else
            prot="not protected (or not readable)"
        fi
        echo "   protection:  ${prot}"
    done

    echo ""
    if [ -f "${FLEET_STATE}/current" ]; then
        echo "rollout $(current_rollout): .cicd=$(pin cicd | cut -c1-7) .ai=$(pin ai | cut -c1-7)"
    fi
    if [ "${blockers}" -gt 0 ]; then
        echo "${blockers} blocker(s). Fix them (or 'prune'), then run preflight again."
        exit 1
    fi
    echo "preflight OK."
}

cmd_prune() {
    local r b cur
    for r in $(repos); do
        m="$(main_of "${r}")"
        note "${r}"
        g "${r}" fetch -q --prune upstream
        cur="$(g "${r}" branch --show-current)"
        for b in $(g "${r}" for-each-ref --format='%(refname:lstrip=2)' refs/heads | grep -vx "${m}" || true); do
            if g "${r}" merge-base --is-ancestor "${b}" "upstream/${m}"; then
                if [ "${b}" = "${cur}" ]; then
                    run g "${r}" checkout -q "${m}"
                    cur="${m}"
                fi
                run g "${r}" branch -d "${b}"
            else
                echo "    keep ${b} (not contained in upstream/${m} - decide by hand)"
            fi
        done
    done
}

cmd_file_issues() {
    local ISSUE_TEMPLATE; ISSUE_TEMPLATE="$(state_dir)/issue-template.md"
    [ -f "${ISSUE_TEMPLATE}" ] || die "rollout $(current_rollout) has no issue template (init --issue-template <file>)"
    local r s draft out num cicd ai waya fleet_list cicd_verb
    cicd="$(pin cicd)"; ai="$(pin ai)"
    fleet_list="$(repos | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    for r in $(repos); do
        if [ -n "$(mf_get "${r}" issue)" ]; then
            note "${r}: already filed as #$(mf_get "${r}" issue)"; continue
        fi
        s="$(slug "${r}")"
        if grep -qE "^import .*workflow\.just" "$(rdir "${r}")/justfile" 2>/dev/null; then
            waya="This repository already uses Way-A; only the pins move."
        else
            waya="**Bootstrap:** this is the first Way-A branch here; it lands by fast-forward onto a maintainer-signed tip, because the current \`.ai\` hook cannot yet admit a merge commit on master."
        fi
        if g "${r}" ls-tree HEAD .cicd | grep -q commit; then cicd_verb="Pin"; else cicd_verb="Add"; fi
        draft="$(state_dir)/drafts/${r}.md"
        sed -e "s|@@SLUG@@|${s}|g" -e "s|@@ROLLOUT@@|$(current_rollout)|g" \
            -e "s|@@CICD@@|${cicd}|g" -e "s|@@AI@@|${ai}|g" \
            -e "s|@@CICD7@@|${cicd:0:7}|g" -e "s|@@AI7@@|${ai:0:7}|g" \
            -e "s|@@WAYA_NOTE@@|${waya}|g" -e "s|@@MAIN@@|$(main_of "${r}")|g" \
            -e "s|@@COHORT@@|$(cat "$(state_dir)/cohort")|g" -e "s|@@FLEET_LIST@@|${fleet_list}|g" \
            -e "s|@@CICD_VERB@@|${cicd_verb}|g" "${ISSUE_TEMPLATE}" > "${draft}"
        # Keep the title: file-issue.sh ARCHIVES the draft once filed, and `open-prs` titles each
        # pull request like its issue.
        grep -m1 '^Title:' "${draft}" | cut -d: -f2- | sed 's/^ *//' > "${draft%.md}.title" || true
        note "${r}: draft ${draft}  (Repo: ${s})"
        if [ "${GO}" = 1 ]; then
            out="$(cd "$(dirname "${FILE_ISSUE}")" && "${FILE_ISSUE}" "${draft}" 2>&1)" \
                || { echo "${out}"; die "file-issue failed for ${r}"; }
            echo "${out}" | sed 's/^/    /'
            num="$(echo "${out}" | grep -oE "github\.com/${s}/issues/[0-9]+" | tail -1 | grep -oE '[0-9]+$' || true)"
            [ -n "${num}" ] || die "could not find the issue number for ${r} in file-issue output"
            mf_set "${r}" "${s}" "${num}" ""
            note "${r}: #${num}"
        else
            echo "    [dry-run] ${FILE_ISSUE} ${draft}"
        fi
    done
}

cmd_cut() {
    local r n
    for r in $(repos); do
        n="$(mf_get "${r}" issue)"; [ -n "${n}" ] || die "${r}: no issue in manifest (file-issues first)"
        if g "${r}" show-ref --verify --quiet "refs/heads/fix_${n}"; then
            note "${r}: fix_${n} already exists"; continue
        fi
        note "${r}: new-branch ${n}"
        if [ "${GO}" = 1 ]; then wf "${r}" new-branch "${n}"; else echo "    [dry-run] just (shim) new-branch ${n}   in $(rdir "${r}")"; fi
    done
    echo ""
    echo "Next: the AI works on each fix_<N> on the AI host and pushes to the exchange; then run 'sync'."
}

cmd_sync() {
    local r b
    for r in $(repos); do
        b="$(branch "${r}")"
        note "${r}: ${b}"
        g "${r}" fetch -q --prune "${EXCHANGE}"
        g "${r}" show-ref --verify --quiet "refs/heads/${b}" || die "${r}: no local ${b}"
        g "${r}" show-ref --verify --quiet "refs/remotes/${EXCHANGE}/${b}" || { warn "${EXCHANGE} has no ${b}"; continue; }
        if [ "$(g "${r}" rev-parse "${b}")" = "$(g "${r}" rev-parse "${EXCHANGE}/${b}")" ]; then
            echo "    up to date"; continue
        fi
        if g "${r}" merge-base --is-ancestor "${b}" "${EXCHANGE}/${b}"; then
            [ -z "$(g "${r}" status --porcelain)" ] || die "${r}: working tree not clean"
            run g "${r}" checkout -q "${b}"
            run g "${r}" merge --ff-only "${EXCHANGE}/${b}"
            g "${r}" log --oneline "${b}..${EXCHANGE}/${b}" 2>/dev/null | sed 's/^/      /' || true
        else
            die "${r}: ${b} has DIVERGED from ${EXCHANGE}/${b} - reconcile by hand"
        fi
    done
}

cmd_seal() {
    local r b n
    for r in $(repos); do
        b="$(branch "${r}")"; n="$(mf_get "${r}" issue)"
        if master_admits_merge "${r}"; then
            note "${r}: no seal needed (landing makes a signed merge commit)"; continue
        fi
        if tip_is_signed "${r}" "${b}"; then
            note "${r}: ${b} tip already signed"; continue
        fi
        note "${r}: sealing ${b} with a maintainer-signed tip commit"
        [ -z "$(g "${r}" status --porcelain)" ] || die "${r}: working tree not clean"
        run g "${r}" checkout -q "${b}"
        run g "${r}" commit --allow-empty -S -m "Seal #${n} for landing (maintainer-signed tip; Way-A bootstrap fast-forward)"
    done
}

cmd_publish() {
    local r b
    for r in $(repos); do
        b="$(branch "${r}")"
        note "${r}: publish ${b}"
        if [ "${GO}" = 1 ]; then wf "${r}" publish "${b}"; else echo "    [dry-run] just (shim) publish ${b}"; fi
    done
}

cmd_open_prs() {
    local r s n b pr out
    for r in $(repos); do
        m="$(main_of "${r}")"
        s="$(slug "${r}")"; n="$(mf_get "${r}" issue)"; b="$(branch "${r}")"
        pr="$(mf_get "${r}" pr)"
        [ -n "${pr}" ] || pr="$(gh pr list --repo "${s}" --head "${b}" --state all --json number -q '.[0].number' 2>/dev/null || true)"
        if [ -n "${pr}" ]; then
            mf_set "${r}" "${s}" "${n}" "${pr}"; note "${r}: PR #${pr} exists"; continue
        fi
        note "${r}: opening PR for ${b}"
        if [ "${GO}" = 1 ]; then
            out="$(gh pr create --repo "${s}" --base "${m}" --head "$(fork_owner "${r}"):${b}" \
                   --title "$(pr_title "${r}" "${n}")" \
                   --body "Closes #${n}

Part of the batched fleet rollout \`$(current_rollout)\` (the same pins in every repository of its cohort):
\`.cicd\` → \`$(pin cicd | cut -c1-7)\`, \`.ai\` → \`$(pin ai | cut -c1-7)\`.
See #${n} for the change list and acceptance criteria. The AI-assistance disclosure is in \`.audit/\`.")"
            pr="$(echo "${out}" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | tail -1)"
            mf_set "${r}" "${s}" "${n}" "${pr}"
            note "${r}: PR #${pr}"
        else
            echo "    [dry-run] gh pr create --repo ${s} --head $(fork_owner "${r}"):${b} ..."
        fi
    done
}

checks_state() {  # pass | pending | FAIL | none
    local rc=0
    gh pr checks "$2" --repo "$1" >/dev/null 2>&1 || rc=$?
    case "${rc}" in 0) echo pass ;; 8) echo pending ;; 1) echo FAIL ;; *) echo none ;; esac
}

cmd_status() {
    local r s n b pr loc ex fk head chk sig land
    printf '%-16s %-6s %-9s %-8s %-8s %-8s %-6s %-9s %-7s %s\n' \
        REPO ISSUE BRANCH LOCAL EXCHANGE FORK PR PR-HEAD CHECKS SIGNED/LANDING
    for r in $(repos); do
        s="$(slug "${r}")"; n="$(mf_get "${r}" issue)"; pr="$(mf_get "${r}" pr)"
        [ -n "${n}" ] || { printf '%-16s (not filed)\n' "${r}"; continue; }
        b="fix_${n}"
        g "${r}" fetch -q "${EXCHANGE}" 2>/dev/null || true
        g "${r}" fetch -q origin 2>/dev/null || true
        loc="$(g "${r}" rev-parse --short "${b}" 2>/dev/null || echo -)"
        ex="$(g "${r}" rev-parse --short "${EXCHANGE}/${b}" 2>/dev/null || echo -)"
        fk="$(g "${r}" rev-parse --short "origin/${b}" 2>/dev/null || echo -)"
        head="-"; chk="-"
        if [ -n "${pr}" ]; then
            head="$(gh pr view "${pr}" --repo "${s}" --json headRefOid -q .headRefOid 2>/dev/null | cut -c1-7 || echo -)"
            chk="$(checks_state "${s}" "${pr}")"
        fi
        if master_admits_merge "${r}"; then land="merge"; else land="ff"; fi
        if [ "${loc}" != "-" ] && tip_is_signed "${r}" "${b}"; then sig="signed"; else sig="unsigned"; fi
        printf '%-16s #%-5s %-9s %-8s %-8s %-8s %-6s %-9s %-7s %s\n' \
            "${r}" "${n}" "${b}" "${loc}" "${ex}" "${fk}" "${pr:+#${pr}}" "${head}" "${chk}" "${sig}/${land}"
    done
}

cmd_land() {
    local r s n b pr tip head chk
    for r in $(repos); do
        m="$(main_of "${r}")"
        s="$(slug "${r}")"; n="$(mf_get "${r}" issue)"; pr="$(mf_get "${r}" pr)"; b="fix_${n}"
        note "${r}: landing ${b} (PR #${pr})"
        [ -n "${pr}" ] || die "${r}: no PR in manifest"
        [ -z "$(g "${r}" status --porcelain)" ] || die "${r}: working tree not clean"
        for rem in $(g "${r}" remote); do g "${r}" fetch -q --prune "${rem}" 2>/dev/null || true; done

        if g "${r}" merge-base --is-ancestor "${b}" "upstream/${m}" 2>/dev/null; then
            grep -q "^${r}	" "$(state_dir)/landed.tsv" 2>/dev/null \
                || printf '%s\t%s\n' "${r}" "$(g "${r}" rev-parse "${b}")" >> "$(state_dir)/landed.tsv"
            note "${r}: already contained in upstream/${m}"; continue
        fi

        # The copy a reviewer saw, the copy CI tested, and the copy about to land: all the same.
        tip="$(g "${r}" rev-parse "${b}")"
        head="$(gh pr view "${pr}" --repo "${s}" --json headRefOid -q .headRefOid)"
        [ "${tip}" = "${head}" ] || die "${r}: local ${b} (${tip:0:7}) != PR head (${head:0:7})"
        for rem in origin ${EXCHANGE}; do
            [ "$(g "${r}" rev-parse "${rem}/${b}" 2>/dev/null || true)" = "${tip}" ] \
                || die "${r}: ${rem}/${b} is not the local tip - publish first"
        done
        chk="$(checks_state "${s}" "${pr}")"
        [ "${chk}" = "pass" ] || die "${r}: PR #${pr} checks are '${chk}', not 'pass'"
        g "${r}" merge-base --is-ancestor "upstream/${m}" "${b}" \
            || die "${r}: ${b} does not contain upstream/${m} - rebase decision needed"

        if [ "${GO}" != 1 ]; then
            if master_admits_merge "${r}"; then
                echo "    [dry-run] signed merge --no-ff -S ${b} into ${m}, push, delete branch"
            else
                echo "    [dry-run] fast-forward ${m} to signed tip ${tip:0:7}, push, delete branch"
            fi
            continue
        fi

        local start; start="$(g "${r}" branch --show-current)"
        trap 'g "'"${r}"'" merge --abort 2>/dev/null || true; g "'"${r}"'" checkout -q "'"${start}"'" 2>/dev/null || true' ERR
        g "${r}" checkout -q "${m}"
        g "${r}" merge --ff-only "upstream/${m}"
        if master_admits_merge "${r}"; then
            g "${r}" merge --no-ff -S -m "Merge branch '${b}' (#${n})" "${b}"
            if ! tip_is_signed "${r}" HEAD; then
                # Never leave an unsigned merge on the integration branch, even locally.
                g "${r}" reset -q --hard "upstream/${m}"
                g "${r}" checkout -q "${start}"
                die "${r}: merge commit came out UNSIGNED - rolled back, nothing pushed"
            fi
        else
            tip_is_signed "${r}" "${b}" || die "${r}: ${b} tip is not signed - run 'seal' first"
            g "${r}" merge --ff-only "${b}"
        fi
        g "${r}" submodule update --init --recursive --quiet || true
        for rem in upstream origin ${EXCHANGE}; do
            g "${r}" remote get-url "${rem}" >/dev/null 2>&1 && g "${r}" push -q "${rem}" "${m}"
        done
        g "${r}" fetch -q upstream
        g "${r}" merge-base --is-ancestor "${tip}" "upstream/${m}" \
            || die "${r}: pushed, but upstream/${m} does not contain ${tip:0:7} - NOT deleting ${b}"
        trap - ERR
        g "${r}" branch -D "${b}"
        for rem in origin ${EXCHANGE}; do
            g "${r}" push -q "${rem}" --delete "${b}" 2>/dev/null || warn "could not delete ${b} on ${rem}"
        done
        # The record `finish` reads: this repository landed, and with which tip.
        printf '%s\t%s\n' "${r}" "${tip}" >> "$(state_dir)/landed.tsv"
        note "${r}: landed; ${m} is now $(g "${r}" rev-parse --short HEAD)"
    done
}

# Close the rollout: only when EVERY repository of its cohort has landed (recorded by `land`, and
# still contained in the upstream default branch). Then another rollout may be started.
cmd_finish() {
    local r m tip open=0
    for r in $(repos); do
        m="$(main_of "${r}")"
        tip="$(awk -F'\t' -v r="${r}" '$1==r {print $2}' "$(state_dir)/landed.tsv" 2>/dev/null | tail -1)"
        if [ -z "${tip}" ]; then note "${r}: NOT landed"; open=$((open+1)); continue; fi
        g "${r}" fetch -q upstream 2>/dev/null || true
        if g "${r}" merge-base --is-ancestor "${tip}" "upstream/${m}" 2>/dev/null; then
            note "${r}: landed (${tip:0:7} in upstream/${m})"
        else
            note "${r}: recorded as landed, but upstream/${m} does not contain ${tip:0:7}"; open=$((open+1))
        fi
    done
    [ "${open}" -eq 0 ] || die "rollout $(current_rollout): ${open} repository(ies) not landed - it stays open"
    if [ "${GO}" = 1 ]; then
        local id; id="$(current_rollout)"
        rm -f "${FLEET_STATE}/current"
        note "rollout ${id}: finished (its state stays in ${FLEET_STATE}/${id})"
    else
        echo "    [dry-run] close rollout $(current_rollout)"
    fi
}

usage() {
    sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# -- main ----------------------------------------------------------------------

[ $# -ge 1 ] || usage 1
cmd="$1"; shift
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --go)   GO=1; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) args+=("$1"); shift ;;
    esac
done

case "${cmd}" in
    init)        cmd_init "${args[@]}" ;;
    preflight)   cmd_preflight ;;
    prune)       cmd_prune ;;
    file-issues) cmd_file_issues ;;
    cut)         cmd_cut ;;
    sync)        cmd_sync ;;
    seal)        cmd_seal ;;
    publish)     cmd_publish ;;
    open-prs)    cmd_open_prs ;;
    status)      cmd_status ;;
    land)        cmd_land ;;
    finish)      cmd_finish ;;
    *) usage 1 ;;
esac
