# Copyright (c) typedef int GmbH, Germany, 2025. All rights reserved.
#
# Git branch workflow recipes: `just where`, `just new-branch`, `just land`.
#
# The SCM model these recipes serve - instance-named exchange remotes, the fork
# and shared-repository topologies, and which remote is authoritative for "has
# this landed" - is defined in SCM-EXCHANGE-MODEL.md at the root of the
# aaiare-ansible-collection repository. This file implements; that file decides.
#
# WHY THIS FILE EXISTS (aaiare-metal-typedefint#14)
#
# The collaboration cycle is sound and its clerical layer was unguarded. One day
# of work across two repositories cost ~30 mechanical git commands and two
# hand-written audit files, none of which involved a decision - and every single
# failure that day landed in that clerical layer, not in the thinking:
#
#   - a branch cut from the wrong parent, silently inheriting a broken commit
#   - a local `main` one merge behind, so a pin resolved to the WRONG revision
#   - `git branch -d` deleting a branch that had not landed on main
#   - an audit file committed with only its trailer
#
# So: recipes, not more discipline. "Make the right thing the easy thing",
# applied to the workflow rather than to the estate.
#
# WHY THIS IS A SEPARATE FILE
#
# THIS IS THAT HOME. The file was proven in three typedefint repositories first,
# as byte-identical copies kept in step by a drift check, because guards that
# have never been observed refusing must not propagate to every using repository
# at once - one that refuses wrongly would block work everywhere, and the fix
# would have to travel through this repository's release cycle to reach it.
# That risk is not hypothetical: wamp-ai#16 is a guard in the OTHER shared
# submodule that refused a correct commit message, after it had propagated.
#
# What makes adoption safe is not that the guards are perfect. It is that
# adoption is DOUBLY OPT-IN: a repository sees this file only when it chooses to
# bump the `.cicd` pin, and the recipes do nothing until it also adds
#
#     import '.cicd/workflow.just'
#
# to its own justfile. Removing that line stops them. No repository is opted in
# by this file existing.
#
# NOTHING HERE MAY BE SPECIFIC TO ANY REPOSITORY: no project paths, no venvs, no
# environment names, no recipe names from a root justfile. Anything
# that varies per repository is a variable with a default, below.

# The integration branch these recipes measure against. A variable rather than a
# literal because it is exactly the kind of thing that differs per repository -
# several of the older repos in this estate use `master`.
WORKFLOW_MAIN := 'main'

# Prefix for dev branch names. `just new-branch 14` produces `fix_14`.
WORKFLOW_BRANCH_PREFIX := 'fix_'

# -----------------------------------------------------------------------------
# -- which remote is the authority
# -----------------------------------------------------------------------------

# Print the remote that decides "has this landed?" (internal; prints nothing if
# no remote carries the integration branch).
#
# WHY THIS IS NOT SIMPLY `origin` (aaiare-metal-typedefint#16)
#
# It used to be, and that was right for exactly as long as `origin` meant the
# canonical repository. Under the fork topology it does not: `origin` is the
# maintainer's FORK, whose integration branch falls behind canonical the moment
# a pull request merges. Asking the fork whether work has landed returns a
# confident, stale answer - the same failure shape as every other one this file
# exists to prevent, and one this file would have introduced itself.
#
# So: `upstream` when it carries the integration branch, which is ordinary git
# convention for "the canonical repository"; otherwise `origin`; otherwise the
# first remote that has it at all, which keeps this useful in repositories that
# name things differently.
#
# A no-op wherever no `upstream` remote exists - notably inside the AAIARE
# instance, where `origin` IS the exchange and is the correct answer. Verified
# in both topologies before being trusted, not reasoned about.
#
# Factored out rather than repeated in all three recipes below. It was repeated,
# and a rule living in three places is a rule that will be right in some of them.
_workflow-base-remote:
    #!/usr/bin/env bash
    set -uo pipefail

    for candidate in upstream origin; do
        if git show-ref --verify --quiet "refs/remotes/${candidate}/{{WORKFLOW_MAIN}}"; then
            echo "${candidate}"
            exit 0
        fi
    done

    for remote in $(git remote); do
        if git show-ref --verify --quiet "refs/remotes/${remote}/{{WORKFLOW_MAIN}}"; then
            echo "${remote}"
            exit 0
        fi
    done

# Print the remotes a dev branch should be PUBLISHED to (internal).
#
# "What do I cut from" and "where do I publish" are different questions that
# happened to share an answer under the old topology, and #16 routed them
# through one helper. That was a regression: on a control node the authority is
# `upstream`, the canonical repository, and pushing a dev branch there bypasses
# the fork the entire pull-request gate is built on.
#
# The rule, which needs no per-machine configuration and works in both places:
# `origin` always, plus every other remote that carries the integration branch
# and is not the authority.
#
#   control node  remotes: upstream (authority), origin (fork), <instance>
#                 -> origin + <instance>. The fork for the pull request, the
#                    instance so the AI assistant working inside it can see the
#                    branch. Both are needed, and pushing to one was the other
#                    half of every "my local branch was behind" incident.
#
#   inside an instance  remotes: origin (the exchange, and the authority),
#                       plus collaborator fork bares that carry no integration
#                       branch -> origin alone. Collaborator forks must NOT
#                       receive dev branches, and they are excluded by the
#                       integration-branch test rather than by naming them.
_workflow-publish-remotes:
    #!/usr/bin/env bash
    set -uo pipefail

    authority="$(just --justfile "{{justfile()}}" _workflow-base-remote)"

    printed=""
    for remote in $(git remote); do
        if [ "${remote}" = "origin" ]; then
            printed="${printed} origin"
            continue
        fi
        [ "${remote}" = "${authority}" ] && continue
        git show-ref --verify --quiet "refs/remotes/${remote}/{{WORKFLOW_MAIN}}" || continue
        printed="${printed} ${remote}"
    done

    echo ${printed}

# Print the remotes whose copy of BRANCH contains commits the local one does not
# (internal). Empty output means the local branch is the newest copy of itself.
#
# THE QUESTION NOBODY WAS ASKING (aaiare-metal-typedefint#18).
#
# `land` and `git merge --ff-only` both answer "has this commit landed?"
# faithfully. Neither answers "is my local branch the newest copy of itself?",
# and that gap cost five separate incidents in one week:
#
#   fix_15   merged one commit behind the exchange; the lost commit documented
#            an estate-wide fix, and `land` reported success - truthfully, about
#            the wrong commit.
#   fix_31   published to the fork missing the entire document the branch existed
#            to add.
#   fix_39   two commits sat unpushed, so a pull request carried an audit file
#            and nothing else.
#   fix_24   same, and `land` then DELETED the exchange branch after confirming
#            the local tip had landed. It had. The work was orphaned.
#   fix_18_2 diverged; `just install` silently used a two-revision-old collection
#            until the digest gave it away.
#
# Every one was invisible until something else noticed. This makes it a question
# a recipe asks, every time, instead of one a human must remember.
_workflow-branch-behind branch:
    #!/usr/bin/env bash
    set -uo pipefail

    behind=""
    for remote in $(git remote); do
        ref="refs/remotes/${remote}/{{branch}}"
        git show-ref --verify --quiet "${ref}" || continue
        # Not an ancestor => that remote has commits this local branch lacks.
        if ! git merge-base --is-ancestor "${remote}/{{branch}}" "{{branch}}" 2>/dev/null; then
            behind="${behind} ${remote}"
        fi
    done

    echo ${behind}

# -----------------------------------------------------------------------------
# -- where am I
# -----------------------------------------------------------------------------

# Answer "which branch am I on, and has this work landed?" (read-only).
#
# The question this answers is invisible, and being unable to see it was behind
# three separate failures in one day: a branch cut from the wrong parent, a
# stale local main that made a pin resolve to the wrong revision, and a branch
# deleted before it had landed anywhere.
#
# Read-only and safe to run at any time, including on a dirty tree mid-work.
#
# The commit list is the load-bearing part. A dev branch adds a handful of
# commits to the integration branch; printing them means an unexpected one - a
# commit inherited from another branch because this one was cut from the wrong
# parent - is visible immediately rather than after it has been merged.
where:
    #!/usr/bin/env bash
    set -uo pipefail

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "not a git repository" >&2
        exit 1
    fi

    branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached HEAD)')"
    repo="$(basename "$(git rev-parse --show-toplevel)")"

    if [ -z "$(git status --porcelain)" ]; then
        tree="clean"
    else
        tree="$(git status --porcelain | wc -l) file(s) modified or untracked"
    fi

    hooks_state="$(just --justfile "{{justfile()}}" _workflow-hooks-state)"
    subs_state="$(just --justfile "{{justfile()}}" _workflow-submodule-state)"

    echo ""
    echo "  repository   ${repo}"
    echo "  branch       ${branch}"
    echo "  working tree ${tree}"
    echo "  hooks        ${hooks_state#*|}"
    echo "  submodules   ${subs_state#*|}"
    echo ""

    # Per remote, rather than assuming which remote means what. Remote names and
    # roles differ by machine and by repository: on the arena host there is one
    # remote and it is the bare repository; on a workstation there may be a bare
    # repository, a fork and an upstream. Reporting each remote's own answer is
    # both more honest and more portable than encoding a layout.
    remotes="$(git remote)"
    if [ -z "${remotes}" ]; then
        echo "  remotes      (none)"
    else
        echo "  remotes"
        for remote in ${remotes}; do
            url="$(git remote get-url "${remote}" 2>/dev/null || echo '?')"
            printf '    %-16s %s\n' "${remote}" "${url}"

            main_ref="refs/remotes/${remote}/{{WORKFLOW_MAIN}}"
            if git show-ref --verify --quiet "${main_ref}"; then
                if git merge-base --is-ancestor HEAD "${remote}/{{WORKFLOW_MAIN}}" 2>/dev/null; then
                    landed="LANDED - {{WORKFLOW_MAIN}} contains this commit"
                else
                    landed="NOT landed on {{WORKFLOW_MAIN}}"
                fi
            else
                landed="no {{WORKFLOW_MAIN}} here"
            fi

            branch_ref="refs/remotes/${remote}/${branch}"
            if git show-ref --verify --quiet "${branch_ref}"; then
                if [ "$(git rev-parse HEAD)" = "$(git rev-parse "${remote}/${branch}")" ]; then
                    pushed="in sync"
                else
                    pushed="DIFFERS from local"
                fi
            else
                pushed="branch not pushed here"
            fi

            printf '    %-16s %s; %s\n' "" "${pushed}" "${landed}"
        done
    fi
    echo ""

    # See _workflow-base-remote for why this is not simply `origin`.
    base_remote="$(just --justfile "{{justfile()}}" _workflow-base-remote)"

    if [ -z "${base_remote}" ]; then
        echo "  No remote has {{WORKFLOW_MAIN}} - nothing to compare against."
        echo ""
        exit 0
    fi

    base="${base_remote}/{{WORKFLOW_MAIN}}"
    ahead="$(git rev-list --count "${base}..HEAD" 2>/dev/null || echo '?')"
    behind="$(git rev-list --count "HEAD..${base}" 2>/dev/null || echo '?')"

    echo "  vs ${base}   ${ahead} ahead, ${behind} behind"
    echo ""

    if [ "${ahead}" != "0" ] && [ "${ahead}" != "?" ]; then
        echo "  this branch adds:"
        git log --oneline --no-decorate "${base}..HEAD" | sed 's/^/    /'
        echo ""
        echo "  If a commit above is not yours, this branch was cut from the"
        echo "  wrong parent. Cut from ${base}, not from another dev branch."
        echo ""
    fi

    if [ "${behind}" != "0" ] && [ "${behind}" != "?" ]; then
        echo "  ${base} has moved on by ${behind} commit(s) since this branch"
        echo "  was cut. Normal, and worth knowing before landing."
        echo ""
    fi

# -----------------------------------------------------------------------------
# -- is this working copy enforcing anything?
# -----------------------------------------------------------------------------

# Print `<state>|<message>` for hook enforcement (internal).
#
# WHY THIS EXISTS (aaiare-metal-typedefint#58)
#
# `.ai/.githooks/commit-msg` already refuses commits on the integration branch.
# It is versioned, correct, and reviewed - and whether it RUNS is decided by
# `core.hooksPath`, which is LOCAL git config: not committed, not inherited by a
# clone, and silent when absent.
#
# One clone in this estate was found running with `core.hooksPath = /dev/null` -
# the exact value the hook's own error message tells a human to set in order to
# get past it, in a three-step procedure whose third step re-arms it. Step three
# had not been performed. Every commit-msg check had been off there for months,
# on the machine that holds the credentials and signs.
#
# A hook that is not installed cannot report that it is not installed. So the
# report has to come from here, and `where` is where it goes: run before every
# branch cut, publish and land.
#
# Note that ANY value other than the hooks directory means not enforced - unset
# and `/dev/null` alike. A check that only tested for "unset" would have called
# that clone healthy.
_workflow-hooks-state:
    #!/usr/bin/env bash
    set -uo pipefail
    root="$(git rev-parse --show-toplevel)"
    hooks="${root}/.ai/.githooks"

    # Most repositories that will eventually use this file carry no `.ai`
    # submodule. Absent is not a failure; unenforced-while-present is.
    if [ ! -d "${hooks}" ]; then
        echo "na|no .ai/.githooks in this repository"
        exit 0
    fi

    configured="$(git config --get core.hooksPath || true)"
    if [ -z "${configured}" ]; then
        echo "bad|NOT ENFORCED - core.hooksPath is unset"
        exit 0
    fi

    resolved="$(cd "${root}" && realpath -m "${configured}" 2>/dev/null || echo "${configured}")"
    if [ "${resolved}" != "$(realpath -m "${hooks}")" ]; then
        echo "bad|NOT ENFORCED - core.hooksPath is ${configured}"
        exit 0
    fi

    echo "ok|ENFORCED (${configured})"

# Report whether every submodule is at the revision this repository pins.
#
# OFFLINE and instant, which is why it belongs in `where`. Whether that pinned
# revision is upstream HEAD is a different question, needs the network, and is
# `just submodules-at-head` - the same split as any check that must not fail for
# reasons unrelated to the change under review.
_workflow-submodule-state:
    #!/usr/bin/env bash
    set -uo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [ ! -f "${root}/.gitmodules" ]; then
        echo "na|no submodules"
        exit 0
    fi
    status="$(git submodule status 2>/dev/null || true)"
    if [ -z "${status}" ]; then
        echo "na|no submodules"
        exit 0
    fi
    # `git submodule status` prefixes a line with `+` when the checkout differs
    # from the pin and `-` when it is not initialised. Blank means in sync.
    drifted="$(echo "${status}" | grep -c '^[+-]' || true)"
    count="$(echo "${status}" | grep -c . || true)"
    if [ "${drifted}" != "0" ]; then
        names="$(echo "${status}" | grep '^[+-]' | awk '{print $2}' | tr '\n' ' ')"
        echo "bad|${drifted} of ${count} NOT at the pinned revision: ${names}"
        exit 0
    fi
    echo "ok|${count} at their pinned revision"

# Check every submodule against its upstream HEAD. NEEDS THE NETWORK.
#
# Deliberately not part of `where`, which must stay offline and instant.
# `aaiare-metal-typedefint#5` asked for this as a one-time campaign; a one-time
# campaign is true on the day it is run, and this estate has already had a stale
# pin silently disable hook enforcement once. So it is a recipe rather than an
# errand.
submodules-at-head:
    #!/usr/bin/env bash
    set -uo pipefail
    root="$(git rev-parse --show-toplevel)"
    if [ ! -f "${root}/.gitmodules" ]; then
        echo "--> no submodules here."
        exit 0
    fi

    behind=0
    while read -r _ path _; do
        [ -n "${path}" ] || continue
        url="$(git config -f "${root}/.gitmodules" --get "submodule.${path}.url" || true)"
        pinned="$(git submodule status "${path}" | awk '{print $1}' | tr -d '+-')"
        head="$(git ls-remote "${url}" HEAD 2>/dev/null | awk '{print $1}')"
        if [ -z "${head}" ]; then
            printf '    %-10s ? could not reach %s\n' "${path}" "${url}"
            continue
        fi
        if [ "${pinned}" = "${head}" ]; then
            printf '    %-10s at upstream head (%s)\n' "${path}" "${pinned:0:8}"
        else
            printf '    %-10s BEHIND: pinned %s, upstream %s\n' \
                "${path}" "${pinned:0:8}" "${head:0:8}"
            behind=$((behind + 1))
        fi
    done < <(git config -f "${root}/.gitmodules" --get-regexp '^submodule\..*\.path$' \
             | awk '{print $1, $2}' | sed 's/^submodule\.//; s/\.path//')

    if [ "${behind}" != "0" ]; then
        echo ""
        echo "  ${behind} submodule(s) behind upstream head."
        exit 1
    fi
    echo "--> all submodules at upstream head."

# Check that this repository's copy of workflow.just has not drifted.
#
# "One home, three copies" holds only while the copies are the same. A copy that
# drifts quietly is worse than no copy: the recipes would mean different things
# in different repositories while looking identical, and guards are exactly the
# kind of code nobody re-reads.
#
# Compares against every SIBLING checkout that carries the file, so it needs no
# list of repository names and stays true as repositories are added or removed.
# Skips - rather than fails - where no sibling is present: this file is expected
# to be cloned alone, and a check that cannot pass there would be switched off.
check-workflow-just:
    #!/usr/bin/env bash
    set -uo pipefail
    here="$(git rev-parse --show-toplevel)/workflow.just"
    parent="$(dirname "$(git rev-parse --show-toplevel)")"

    # A REPOSITORY THAT HAS MIGRATED HAS NOTHING TO DRIFT.
    #
    # Once a repository imports this file from `.cicd`, it keeps no local copy -
    # and `diff` against a path that does not exist would report drift against
    # every sibling that still has one, which is the opposite of the truth. So
    # the migrated case is detected and reported as what it is.
    #
    # This whole recipe becomes pointless when the last local copy is gone: a
    # drift check over a file with one home cannot fail, and a check that cannot
    # fail is worse than no check (A6). Delete it with the last copy.
    if [ ! -f "${here}" ]; then
        echo "--> this repository has no local workflow.just; it imports the"
        echo "    shared one from .cicd, so there is nothing to drift."
        exit 0
    fi

    found=0
    drift=0
    for other in "${parent}"/*/workflow.just; do
        [ -f "${other}" ] || continue
        [ "${other}" = "${here}" ] && continue
        found=$((found + 1))
        name="$(basename "$(dirname "${other}")")"
        if diff -q "${here}" "${other}" >/dev/null; then
            echo "--> identical to ${name}"
        else
            echo "DRIFT: workflow.just differs from ${name}" >&2
            diff -u "${other}" "${here}" >&2 || true
            drift=$((drift + 1))
        fi
    done
    if [ "${found}" -eq 0 ]; then
        echo "--> no sibling checkout carries workflow.just; nothing to compare."
        exit 0
    fi
    [ "${drift}" -eq 0 ] || exit 1
    echo "--> ${found} sibling copy/copies checked, no drift."

# Commit directly on the integration branch, WITHOUT disabling any hook (#61).
#
# WHY THIS EXISTS
#
# `.ai/.githooks/commit-msg` refuses commits on the integration branch, and its
# error message offers a three-step escape: disable `core.hooksPath`, commit,
# re-arm. One clone in this estate ran with step three outstanding for months
# (#58). When the hook was deliberately re-tested it refused correctly, and was
# then bypassed by that very procedure within seconds, by the person testing it.
#
# So the escape hatch is the problem, not the hook.
#
# WHY THIS DOES NOT DISABLE ANYTHING
#
# The hook refuses commits ON THE INTEGRATION BRANCH. It does not refuse the
# commit. So this makes the commit on a temporary branch - which is exactly what
# the hook's own message asks for - and fast-forwards. The commit ends up in the
# same place, and:
#
#   * `core.hooksPath` is never touched, so there is no window in which
#     enforcement is off, nothing to re-arm, and no third step to forget;
#   * EVERY other check still runs. `core.hooksPath` is all-or-nothing, so
#     disabling it would also switch off the AI-authorship checks and the message
#     rules. Here they apply to this commit exactly as to any other;
#   * a failure leaves nothing behind: the temporary branch is deleted and the
#     integration branch never moved.
#
# WHAT THIS IS NOT
#
# It is not a mechanism that prevents misuse. Routing around a guard legitimately
# is still routing around it, and nothing available here can tell who is typing.
#
# That gap is covered elsewhere, deliberately: every audit file declares AI
# assistance, and the human reviews what arrives from the exchange repository
# before it is pushed upstream. THAT review is the control this recipe leans on -
# so this recipe records its own use, in the commit message, permanently, where
# the review will see it. The `/dev/null` route records nothing.
#
# AI assistants MUST NOT use this recipe, in the same sense that they must not
# create tags: stated as policy, not enforced by code.
commit-on-main reason message:
    #!/usr/bin/env bash
    set -uo pipefail

    branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '')"
    if [ "${branch}" != "{{WORKFLOW_MAIN}}" ]; then
        echo "REFUSING: this is for {{WORKFLOW_MAIN}}, and you are on '${branch}'." >&2
        echo "  On a dev branch, an ordinary 'git commit' is already allowed." >&2
        exit 1
    fi

    # Committing on the integration branch in a clone that checks nothing is the
    # union of both problems this recipe exists between.
    hooks_state="$(just --justfile "{{justfile()}}" _workflow-hooks-state)"
    if [ "${hooks_state%%|*}" = "bad" ]; then
        echo "REFUSING: ${hooks_state#*|}" >&2
        echo "" >&2
        echo "  This recipe exists so that hooks never have to be disabled." >&2
        echo "  Running it while they already are defeats the entire point." >&2
        echo "" >&2
        echo "    just --justfile .ai/justfile setup-repo" >&2
        exit 1
    fi

    temp="_commit-on-main-$(date -u +%Y%m%d%H%M%S)"
    start="$(git rev-parse HEAD)"

    # From here on, every exit path returns to the integration branch and leaves
    # no temporary branch behind - including the paths where the hook refuses.
    cleanup() {
        git switch --quiet "{{WORKFLOW_MAIN}}" 2>/dev/null || true
        git branch -D "${temp}" >/dev/null 2>&1 || true
    }

    git switch --quiet -c "${temp}" || exit 1

    if ! git commit -m "{{message}}

    Committed directly on {{WORKFLOW_MAIN}} via \`just commit-on-main\`, which
    made this commit on a branch so that no hook had to be disabled (#61).
    Reason: {{reason}}"; then
        echo "" >&2
        echo "--> The commit was refused. Nothing has changed:" >&2
        cleanup
        echo "    {{WORKFLOW_MAIN}} is still at $(git rev-parse --short "${start}")," \
             "and no temporary branch remains." >&2
        exit 1
    fi

    made="$(git rev-parse HEAD)"
    git switch --quiet "{{WORKFLOW_MAIN}}"
    if ! git merge --ff-only "${made}" >/dev/null 2>&1; then
        echo "REFUSING: {{WORKFLOW_MAIN}} moved while this ran; not forcing it." >&2
        echo "  The commit is preserved on branch ${temp}." >&2
        exit 1
    fi
    git branch -D "${temp}" >/dev/null 2>&1 || true

    echo ""
    echo "--> {{WORKFLOW_MAIN}} $(git rev-parse --short "${start}") -> $(git rev-parse --short HEAD)"
    echo "    No hook was disabled; core.hooksPath is untouched."
    echo "    The reason is recorded in the commit message, where review will see it."

# -----------------------------------------------------------------------------
# -- start a branch
# -----------------------------------------------------------------------------

# Start a dev branch for an issue (usage: `just new-branch 14`).
#
# Replaces nine commands and a hand-edited file. Every guard below is earned by
# a specific failure, none is speculative:
#
#   dirty tree      uncommitted work has been carried across a `checkout` more
#                   than once, and a `git status` before switching is exactly
#                   the step that gets skipped under load.
#   branch open     the one-branch-per-repo rule, previously enforced by memory.
#                   Two open branches on one repo produced a branch cut from the
#                   wrong parent, which then looked already-merged and made a
#                   later pull report "divergent branches".
#   fetch first     the branch is cut from FRESHLY FETCHED integration-branch
#                   state, never from whatever this working copy last saw. A
#                   local main one merge behind is invisible and silently
#                   produced a pin resolving to the wrong revision.
#
# The audit file comes from the `.ai` submodule's own generator rather than
# being written here: one home per artifact. If `.ai` is absent the branch is
# still created and the omission is stated - most repositories that will
# eventually use this file do not carry that submodule.
new-branch issue:
    #!/usr/bin/env bash
    set -euo pipefail

    branch="{{WORKFLOW_BRANCH_PREFIX}}{{issue}}"
    root="$(git rev-parse --show-toplevel)"
    cd "${root}"

    # A branch cut in a clone that enforces nothing produces commits nothing
    # checked (#58). Refused here rather than only reported, because `new-branch`
    # is the entry point to all work and the fix is one command.
    hooks_state="$(just --justfile "{{justfile()}}" _workflow-hooks-state)"
    if [ "${hooks_state%%|*}" = "bad" ]; then
        echo "REFUSING: ${hooks_state#*|}" >&2
        echo "" >&2
        echo "  This clone would not check commit messages, AI authorship, or" >&2
        echo "  commits onto {{WORKFLOW_MAIN}}. The hooks exist and are correct;" >&2
        echo "  they are simply not switched on here." >&2
        echo "" >&2
        echo "    just --justfile .ai/justfile setup-repo" >&2
        echo "" >&2
        echo "  If you disabled them deliberately, this is the step that was" >&2
        echo "  going to be forgotten." >&2
        exit 1
    fi

    if [ -n "$(git status --porcelain)" ]; then
        echo "REFUSING: the working tree is not clean." >&2
        echo "" >&2
        git status --short >&2
        echo "" >&2
        echo "  Commit, stash or discard first. Starting a branch on top of" >&2
        echo "  uncommitted work carries it onto the new branch silently." >&2
        exit 1
    fi

    # Any local branch other than the integration branch counts as open. Cheap,
    # and it fails in the safe direction: a leftover merged branch is a false
    # positive that costs one `git branch -d`, while a missed open branch is the
    # wrong-parent bug.
    open="$(git for-each-ref --format='%(refname:short)' refs/heads \
            | grep -v "^{{WORKFLOW_MAIN}}$" || true)"
    if [ -n "${open}" ]; then
        echo "REFUSING: a dev branch is already open here:" >&2
        echo "" >&2
        echo "${open}" | sed 's/^/    /' >&2
        echo "" >&2
        echo "  One open dev branch per repository. Land it first (just land)," >&2
        echo "  or delete it if it is already merged." >&2
        exit 1
    fi

    if git show-ref --verify --quiet "refs/heads/${branch}"; then
        echo "REFUSING: branch ${branch} already exists." >&2
        exit 1
    fi

    # Which remote to cut from - see _workflow-base-remote. Cutting from the
    # fork rather than from canonical would start the branch behind before a
    # line of work is done.
    base_remote="$(just --justfile "{{justfile()}}" _workflow-base-remote)"
    if [ -z "${base_remote}" ]; then
        echo "REFUSING: no remote has {{WORKFLOW_MAIN}}; cannot establish a base." >&2
        exit 1
    fi

    echo "--> Fetching ${base_remote}"
    git fetch --prune "${base_remote}"

    git checkout {{WORKFLOW_MAIN}}
    git merge --ff-only "${base_remote}/{{WORKFLOW_MAIN}}"

    base_sha="$(git rev-parse --short HEAD)"
    git checkout -b "${branch}"

    # Called, not reimplemented. `.ai` is a submodule with its own lifecycle, and
    # a second copy of the template here is how the three spellings that already
    # exist in this estate came about.
    if [ -f "${root}/.ai/justfile" ]; then
        just --justfile "${root}/.ai/justfile" generate-audit-file >/dev/null
        audit="$(git status --porcelain | awk '/\.audit\// {print $2}' | head -1)"
        if [ -n "${audit}" ]; then
            sed -i "s|^Related issue(s):.*|Related issue(s): #{{issue}}|" "${audit}"
            git add "${audit}"
            echo "--> Audit file ${audit} (issue #{{issue}})"
        fi
    else
        echo "--> NOTE: no .ai submodule here, so no audit file was generated."
    fi

    # Only commit if the audit file produced something to commit. Without the
    # `.ai` submodule there is nothing staged, and an unconditional `git commit`
    # fails - which used to abort here leaving the branch created but unpushed.
    # Found by running this in a repository that has no .ai, which is what most
    # future users of this file will look like.
    if [ -n "$(git diff --cached --name-only)" ]; then
        git commit -q -m "start new dev branch; add audit file"
    else
        echo "--> Nothing to commit; ${branch} starts at ${base_sha}."
    fi

    # Published to the PUBLISH remotes, not to the authority (#18). Cutting
    # from `upstream` is right; pushing a dev branch there is not - it bypasses
    # the fork the pull-request gate is built on. See _workflow-publish-remotes.
    publish_to="$(just --justfile "{{justfile()}}" _workflow-publish-remotes)"
    if [ -z "${publish_to}" ]; then
        echo "REFUSING: no remote to publish ${branch} to." >&2
        exit 1
    fi
    for remote in ${publish_to}; do
        git push -q "${remote}" "${branch}"
    done

    echo ""
    echo "--> ${branch} created from ${base_remote}/{{WORKFLOW_MAIN}} at ${base_sha}"
    echo "    and published to:${publish_to}"
    echo ""
    just --justfile "{{justfile()}}" where

# -----------------------------------------------------------------------------
# -- publish a branch
# -----------------------------------------------------------------------------

# Bring this dev branch up to date across every remote, then publish it.
#
# THE RECIPE THAT SHOULD HAVE EXISTED ALL WEEK (#18).
#
# Four of the five "my local branch was behind" incidents happened in the gap
# where no recipe existed: the sequence was typed by hand, and a step that
# refused did not stop the steps after it. On 2026-08-05 `git merge --ff-only`
# correctly aborted on a diverged branch, and the `git push` and `just install`
# on the following lines of the pasted block ran anyway - so a deploy used a
# collection two revisions old, and only the pin digest caught it.
#
# A refusal that does not stop the sequence is half a guard. So this does the
# whole thing, and stops.
#
#   fetch every remote      - a remote not fetched cannot be compared against
#   diverged?               - REFUSE, name the remote, print the rebase command
#   behind?                 - fast-forward, and say so
#   push to publish remotes - the fork for review, the instance for the AI
#
# Never force-pushes and never rebases on its own: a diverged branch is a
# decision, not a mechanical fix.
publish branch='':
    #!/usr/bin/env bash
    set -euo pipefail

    root="$(git rev-parse --show-toplevel)"
    cd "${root}"

    branch="{{branch}}"
    if [ -z "${branch}" ]; then
        branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '')"
        if [ -z "${branch}" ] || [ "${branch}" = "{{WORKFLOW_MAIN}}" ]; then
            echo "REFUSING: not on a dev branch (on '${branch:-detached HEAD}')." >&2
            echo "  Name one explicitly:  just publish <branch>" >&2
            exit 1
        fi
    fi

    if [ -n "$(git status --porcelain)" ]; then
        echo "REFUSING: the working tree is not clean." >&2
        git status --short >&2
        exit 1
    fi

    echo "--> Fetching all remotes"
    for remote in $(git remote); do
        git fetch --prune --quiet "${remote}" 2>/dev/null || true
    done

    behind="$(just --justfile "{{justfile()}}" _workflow-branch-behind "${branch}")"

    for remote in ${behind}; do
        if git merge-base --is-ancestor "${branch}" "${remote}/${branch}"; then
            echo "--> ${branch} is behind ${remote}; fast-forwarding"
            git merge --ff-only "${remote}/${branch}"
        else
            echo "" >&2
            echo "REFUSING: ${branch} has DIVERGED from ${remote}/${branch}." >&2
            echo "" >&2
            echo "  only here:" >&2
            git log --oneline --no-decorate "${remote}/${branch}..${branch}" | sed 's/^/    /' >&2
            echo "  only on ${remote}:" >&2
            git log --oneline --no-decorate "${branch}..${remote}/${branch}" | sed 's/^/    /' >&2
            echo "" >&2
            echo "  Reconcile deliberately, then run this again:" >&2
            echo "    git rebase ${remote}/${branch}" >&2
            exit 1
        fi
    done

    publish_to="$(just --justfile "{{justfile()}}" _workflow-publish-remotes)"
    if [ -z "${publish_to}" ]; then
        echo "REFUSING: no remote to publish ${branch} to." >&2
        exit 1
    fi

    for remote in ${publish_to}; do
        echo "--> Pushing ${branch} to ${remote}"
        git push --quiet "${remote}" "${branch}"
    done

    echo ""
    echo "--> ${branch} at $(git rev-parse --short "${branch}") published to:${publish_to}"
    echo ""

# -----------------------------------------------------------------------------
# -- finish a branch
# -----------------------------------------------------------------------------

# Delete the current dev branch, but only once it has actually landed.
#
# THE GUARD THAT MATTERS: `git branch -d` accepts "merged into its own upstream
# tracking branch" as sufficient, and a pushed branch satisfies that trivially -
# `origin/fix_6` obviously contains `fix_6`. So `-d` deleted a branch that had
# landed nowhere, with a warning that reads like bookkeeping. This checks
# containment in the INTEGRATION branch instead, which is the question the
# operator thought they were asking.
#
# THE OTHER GUARD (#16): "landed" is decided by the AUTHORITATIVE remote, which
# is not necessarily `origin` - see _workflow-base-remote. Under the fork
# topology `origin` is the fork, and asking the fork whether work has landed
# gets a confident stale answer.
#
# Once containment is verified, the branch is deleted locally AND on every
# remote that still carries it. Deleting only the local copy is why 22 landed
# dev branches had accumulated across three repositories by 2026-08-03.
#
# Pushes only to remotes that already exist. On the arena host there is no forge
# remote at all, so this recipe cannot push to a forge there - the trust
# boundary is enforced by the machine's configuration rather than by the recipe
# knowing where it is running.
#
# Takes an optional branch name, so it can also be run from the integration
# branch: `just land fix_14`. Without a forge pull request the merge happens
# locally, which leaves you standing on the integration branch with the dev
# branch still to clean up - and requiring a checkout back onto a branch purely
# in order to delete it is silly. Found by using the recipe (#12 is why the
# merge is local in the first place).
land branch='':
    #!/usr/bin/env bash
    set -euo pipefail

    root="$(git rev-parse --show-toplevel)"
    cd "${root}"

    branch="{{branch}}"
    if [ -z "${branch}" ]; then
        branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '')"
        if [ -z "${branch}" ] || [ "${branch}" = "{{WORKFLOW_MAIN}}" ]; then
            echo "REFUSING: not on a dev branch (on '${branch:-detached HEAD}')." >&2
            echo "  Name one explicitly:  just land <branch>" >&2
            exit 1
        fi
    fi

    if [ "${branch}" = "{{WORKFLOW_MAIN}}" ]; then
        echo "REFUSING: {{WORKFLOW_MAIN}} is the integration branch." >&2
        exit 1
    fi

    if ! git show-ref --verify --quiet "refs/heads/${branch}"; then
        echo "REFUSING: no such branch: ${branch}" >&2
        exit 1
    fi

    if [ -n "$(git status --porcelain)" ]; then
        echo "REFUSING: the working tree is not clean." >&2
        git status --short >&2
        exit 1
    fi

    # See _workflow-base-remote. THIS is the line the whole recipe turns on: ask
    # the fork instead of canonical and the containment check below passes on
    # work that has landed nowhere anyone else reads.
    base_remote="$(just --justfile "{{justfile()}}" _workflow-base-remote)"
    if [ -z "${base_remote}" ]; then
        echo "REFUSING: no remote has {{WORKFLOW_MAIN}}." >&2
        exit 1
    fi

    # Fetch EVERY remote, not just the authority: the question below is about
    # this branch's copies elsewhere, and a remote that was not fetched cannot
    # answer it. `land` used to fetch only the authority, which is exactly how
    # fix_24 got deleted while the exchange held the real work.
    echo "--> Fetching all remotes"
    for remote in $(git remote); do
        git fetch --prune --quiet "${remote}" 2>/dev/null || true
    done

    # IS THIS LOCAL BRANCH THE NEWEST COPY OF ITSELF? (#18)
    #
    # Asked BEFORE the containment check, because the containment check is
    # perfectly capable of answering "yes, landed" about a stale local tip -
    # which it did, and the branch was then deleted on every remote, orphaning
    # the commits nobody had merged.
    behind="$(just --justfile "{{justfile()}}" _workflow-branch-behind "${branch}")"
    if [ -n "${behind}" ]; then
        echo "" >&2
        echo "REFUSING: ${branch} is BEHIND its own copy on:${behind}" >&2
        echo "" >&2
        echo "  Those remotes hold commits this local branch does not. Landing" >&2
        echo "  now would verify the wrong tip and delete the branch anyway." >&2
        echo "" >&2
        for remote in ${behind}; do
            echo "  not in your ${branch}, present on ${remote}:" >&2
            git log --oneline --no-decorate "${branch}..${remote}/${branch}" \
                | sed 's/^/    /' >&2
        done
        echo "" >&2
        echo "  Fix with:  git merge --ff-only ${behind## }/${branch}" >&2
        echo "  or, if you have local commits too:  git rebase ${behind## }/${branch}" >&2
        exit 1
    fi

    head_sha="$(git rev-parse "${branch}")"

    if ! git merge-base --is-ancestor "${head_sha}" "${base_remote}/{{WORKFLOW_MAIN}}"; then
        echo "" >&2
        echo "REFUSING: ${base_remote}/{{WORKFLOW_MAIN}} does not contain ${branch}." >&2
        echo "" >&2
        echo "  This work has NOT landed. Deleting it now would lose it from" >&2
        echo "  every branch that anyone reads." >&2
        echo "" >&2
        echo "  Note that 'git branch -d' would ACCEPT this: it checks the" >&2
        echo "  branch's own upstream, which a pushed branch always satisfies." >&2
        echo "" >&2
        echo "  Not yet on {{WORKFLOW_MAIN}}:" >&2
        git log --oneline --no-decorate "${base_remote}/{{WORKFLOW_MAIN}}..${branch}" \
            | sed 's/^/    /' >&2
        exit 1
    fi

    git checkout {{WORKFLOW_MAIN}}
    before="$(git rev-parse --short HEAD)"
    git merge --ff-only "${base_remote}/{{WORKFLOW_MAIN}}"
    after="$(git rev-parse --short HEAD)"

    # Only remotes that exist, and only those whose integration branch is behind.
    for remote in $(git remote); do
        if ! git show-ref --verify --quiet "refs/remotes/${remote}/{{WORKFLOW_MAIN}}"; then
            continue
        fi
        if [ "$(git rev-parse "${remote}/{{WORKFLOW_MAIN}}")" != "$(git rev-parse HEAD)" ]; then
            echo "--> Pushing {{WORKFLOW_MAIN}} to ${remote}"
            git push "${remote}" {{WORKFLOW_MAIN}}
        fi
    done

    git branch -D "${branch}"

    # And on every remote that still carries it (#16). This used to delete the
    # local branch only, so a landed branch survived on the exchange and on the
    # forge indefinitely: 22 of them had accumulated across three repositories
    # by 2026-08-03, every one provably contained in {{WORKFLOW_MAIN}}, and each
    # one an invitation to check out something already merged.
    #
    # Safe precisely because it comes AFTER the containment check above. The
    # commits are in {{WORKFLOW_MAIN}} on the authoritative remote; only the
    # label goes. Deleting a branch ref that has not landed is what the guard
    # above exists to refuse, and this line is downstream of it.
    deleted_from=""
    for remote in $(git remote); do
        if git ls-remote --exit-code --heads "${remote}" "${branch}" >/dev/null 2>&1; then
            if git push --quiet "${remote}" --delete "${branch}" 2>/dev/null; then
                deleted_from="${deleted_from} ${remote}"
            else
                echo "--> NOTE: could not delete ${branch} on ${remote} (no write access?)."
            fi
        fi
    done

    echo ""
    if [ "${before}" = "${after}" ]; then
        echo "--> {{WORKFLOW_MAIN}} already at ${after}; ${branch} deleted (it had landed)."
    else
        echo "--> {{WORKFLOW_MAIN}} ${before} -> ${after}; ${branch} deleted."
    fi
    if [ -n "${deleted_from}" ]; then
        echo "    also deleted on:${deleted_from}"
    fi
    echo ""
