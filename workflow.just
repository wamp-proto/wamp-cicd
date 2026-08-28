# Copyright (c) typedef int GmbH, Germany, 2025. All rights reserved.
#
# Git branch workflow recipes: `just where`, `just new-branch`, `just land`.
#
# The SCM model these recipes serve - instance-named exchange remotes, the fork
# and shared-repository topologies, and which remote is authoritative for "has
# this landed" - is defined in SCM-EXCHANGE-MODEL.md beside this file. How an
# approved branch LANDS - merge commits rather than squashes, and a merge signed
# by the maintainer rather than by the forge - is MERGE-AND-SIGNING-POLICY.md,
# also beside this file. This file implements; those files decide.
#
# The model used to live in a private repository, so nine repositories carried
# an implementation of a model none of their contributors could read; the
# landing policy was never written down at all (wamp-cicd#26).
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
# THOSE COPIES ARE GONE AND SO IS THE DRIFT CHECK (#23). While three repositories
# each carried a copy, `just check-workflow-just` compared them on every run and
# earned its keep - it went red, correctly, from both directions during metal#58,
# collection#72 and assurance#17. With one home it can no longer fail anywhere,
# and a check that cannot fail is worse than none (A6): it reports green forever
# and a reader who sees it in a `just check` list concludes something is being
# verified.
#
# NOTHING REPLACES IT, BECAUSE THE PROPERTY IS NOW STRUCTURAL. "Every repository
# runs the same workflow.just" was defended by comparison; it is now true by
# construction. There is one file, in one repository, referenced by pin - and a
# consumer that fails to fetch the submodule does not silently get a stale copy,
# it gets
#
#     error: Could not find source file for import.
#      ——▶ justfile:1:8
#
# and EVERY recipe in that repository stops working, including ones that have
# nothing to do with this file, because `just` resolves imports at parse time.
# That was found the hard way in collection#85, in CI. A fatal parse error is a
# stronger guarantee than a checker, and it needs no maintenance.
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

# -----------------------------------------------------------------------------
# -- how a repository overrides the variables below (#47)
# -----------------------------------------------------------------------------
#
# TO OVERRIDE, ADD ONE LINE TO YOUR OWN JUSTFILE AND NOTHING ELSE:
#
#     import '.cicd/workflow.just'
#
#     WORKFLOW_MAIN := 'master'
#
# *** DO NOT ALSO WRITE `set allow-duplicate-variables := true` YOURSELF. ***
# `just` refuses a setting that is defined twice, and the line below already
# defines it:
#
#     error: Setting `allow-duplicate-variables` first set on line 1
#            is redefined on line 108
#
# Both failures below are at PARSE time, so they take down every recipe in the
# repository, not only the workflow ones.
#
# WHY THE `set` IS HERE AND NOT IN EACH IMPORTER
#
# It has to be somewhere. Without it `just` refuses the override outright -
#
#     error: Variable `WORKFLOW_MAIN` has multiple definitions
#
# - in either order, before or after the `import`. Until #47 this file did not
# say so, so the form it documented did not work and the form that did work was
# written down nowhere. Nothing could have caught that: no repository in the
# estate was both on `master` AND onboarded, so the only route to it was
# someone trying, which is what typedefint-organize#4 did. That is
# system-and-software-assurance's A15 in this file's own tooling - a capability
# described and never exercised, for eight months.
#
# Here rather than in each importer means overriding costs one line instead of
# two, and a justfile read on its own is not missing an invisible prerequisite.
#
# THE COST, STATED: this permits duplicate variables everywhere, including an
# accidental redefinition INSIDE this file, which `just` would now accept
# silently instead of refusing. That is a real loss and it is the price of the
# capability. Two variables exist here; keep it that way.
set allow-duplicate-variables := true

# The integration branch these recipes measure against. A variable rather than a
# literal because it is exactly the kind of thing that differs per repository -
# several of the older repos in this estate use `master`. Override per the block
# above. EXERCISED: typedefint-organize is on `master` (typedefint-organize#4).
WORKFLOW_MAIN := 'main'

# Prefix for dev branch names. `just new-branch 14` produces `fix_14`. Override
# per the block above. NEVER EXERCISED by any repository - a default that
# happens to suit everyone rather than a setting known to work. If you are the
# first to change it, say so on #47 so the claim stops being untested.
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

# Print whether this repository can produce a merge signature the project's own
# verification policy would accept (internal).
#
# Output is `ok|<identity>|<issuer>` or `no|<what is missing>`.
#
# WHY THIS IS A SEPARATE QUESTION FROM "IS THERE A SIGNATURE".
# MERGE-AND-SIGNING-POLICY.md §4: the policy is not "this commit has some valid
# signature", it is "this commit has a valid Sigstore signature whose
# certificate identifies the expected maintainer through the expected OIDC
# issuer". A forge-generated merge commit HAS a valid signature and is exactly
# the object the policy exists to keep out, so anything that checks for mere
# presence passes the one case it was written for.
#
# AND IT IS ASKED BEFORE IT IS NEEDED. `just where` prints it, so "gitsign is
# not configured here" is learned while reading status rather than half way
# through landing a branch. gitsign is configured PER REPOSITORY; a repository
# without it falls through to the OpenPGP backend, where `git commit -S` fails
# with "No secret key" - which reads like a broken key and is not.
_workflow-signing-state:
    #!/usr/bin/env bash
    set -uo pipefail

    if ! command -v gitsign >/dev/null 2>&1; then
        echo "no|gitsign is not installed"
        exit 0
    fi
    if [ "$(git config --get gpg.format || true)" != "x509" ]; then
        echo "no|gpg.format is not x509 (git config gpg.format x509)"
        exit 0
    fi
    case "$(git config --get gpg.x509.program || true)" in
        *gitsign*) : ;;
        *) echo "no|gpg.x509.program is not gitsign (git config gpg.x509.program gitsign)"
           exit 0 ;;
    esac

    identity="$(git config --get workflow.signingIdentity || true)"
    if [ -z "${identity}" ]; then
        echo "no|workflow.signingIdentity is unset - the expected certificate identity"
        exit 0
    fi
    issuer="$(git config --get workflow.oidcIssuer || echo 'https://github.com/login/oauth')"

    # A FOURTH FIELD, BECAUSE THE FIRST THREE DO NOT ANSWER "WILL A COMMIT BE
    # SIGNED" (#36). Everything above establishes that this repository CAN sign;
    # `commit.gpgsign` decides whether an ordinary `git commit` DOES. The two
    # were conflated, and `where` printed "gitsign as <identity>" in three
    # repositories where every audit commit for three weeks was unsigned.
    #
    # Reported rather than required: the recipes that must sign now ask for it
    # explicitly, so this key is only about what the OPERATOR's own `git commit`
    # will do - which is still worth knowing, because hand-typed commits (a pin
    # bump, a fixup) are exactly where it bites.
    case "$(git config --get commit.gpgsign || true)" in
        [Tt]rue|1|[Yy]es|[Oo]n) gpgsign=on ;;
        *)                      gpgsign=off ;;
    esac

    echo "ok|${identity}|${issuer}|${gpgsign}"

# Which of the signing keys are set at GLOBAL scope, and therefore apply to
# repositories that are under no policy at all (#41).
#
# `gpg.format`/`gpg.x509.program` set globally make every repository on the
# machine gitsign-signed - including ones under no policy - and every signature
# needs a live OIDC session, so a commit made offline simply fails.
#
# `commit.gpgsign` set globally is the sharper one: it selects only WHETHER to
# sign, while the other two decide HOW. Set wider than the backend, it asks git
# to sign with a backend those other repositories do not configure, and then a
# PLAIN `git commit` there - no `-S` typed anywhere - is refused:
#
#     error: gpg failed to sign the data:
#     gpg: skipped "...": No secret key
#     fatal: failed to write commit object
#
# Reported from HERE because it cannot be reported from there. A repository
# under no policy has no `just` and nothing to run; the machine-wide mistake is
# visible only from the repositories that are themselves fine. That is also how
# it stayed hidden - MERGE-AND-SIGNING-POLICY.md recommended the global form
# until this issue, and the four policy repositories all kept working.
_workflow-signing-scope:
    #!/usr/bin/env bash
    set -uo pipefail

    offenders=""
    for key in gpg.format gpg.x509.program; do
        if [ -n "$(git config --global --get "${key}" 2>/dev/null || true)" ]; then
            offenders="${offenders}${offenders:+, }${key}"
        fi
    done
    case "$(git config --global --get commit.gpgsign 2>/dev/null || true)" in
        [Tt]rue|1|[Yy]es|[Oo]n) offenders="${offenders}${offenders:+, }commit.gpgsign" ;;
    esac

    echo "${offenders}"

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

    # WHICH COMMIT, SPELLED OUT. `where` answers "where am I", and until now it
    # named the branch but not the object - so the question was finished with a
    # `git log -n1 --oneline` every time. Two lines rather than one because the
    # subject of a merge or an audit commit is long enough to push the sha out
    # of a reader's attention, and the sha is the half that gets copied.
    #
    # An empty repository has no HEAD; say so rather than printing an error.
    if commit_sha="$(git rev-parse --short HEAD 2>/dev/null)"; then
        commit_subject="$(git log -1 --format=%s 2>/dev/null)"
    else
        commit_sha="(none)"
        commit_subject="no commit yet"
    fi

    hooks_state="$(just --justfile "{{justfile()}}" _workflow-hooks-state)"
    subs_state="$(just --justfile "{{justfile()}}" _workflow-submodule-state)"

    # Asked here so it is answered before it is needed, not during a merge.
    sign_state="$(just --justfile "{{justfile()}}" _workflow-signing-state)"
    scope_offenders="$(just --justfile "{{justfile()}}" _workflow-signing-scope)"
    signing_note=""
    case "${sign_state}" in
        ok\|*)
            signing="gitsign as $(echo "${sign_state}" | cut -d'|' -f2)"
            if [ "$(echo "${sign_state}" | cut -d'|' -f4)" = "on" ]; then
                signing="${signing}; commits signed"
            else
                # SAY WHAT IS OFF, NOT JUST THAT SOMETHING IS (#36). This row
                # used to read identically in a repository that signed every
                # commit and one that had never signed any, which is why three
                # weeks of unsigned audit commits went unnoticed.
                signing="${signing}; commit.gpgsign OFF"
                signing_note="your own 'git commit' will not sign here - the recipes sign explicitly"
            fi ;;
        *)  signing="NOT CONFIGURED - $(echo "${sign_state}" | cut -d'|' -f2)" ;;
    esac

    echo ""
    echo "  repository   ${repo}"
    echo "  branch       ${branch}"
    echo "  commit       ${commit_sha}"
    echo "  message      ${commit_subject}"
    echo "  working tree ${tree}"
    # EVERY REMOTE ANSWER BELOW COMES FROM A CACHE, AND THE CACHE HAS A DATE.
    #
    # This recipe deliberately does not fetch - it is read-only and safe to run
    # on a dirty tree mid-work. But `publish` and `land` both fetch every remote
    # before comparing, the second of them with the comment "a remote that was
    # not fetched cannot answer it", and `where` is the recipe whose ENTIRE
    # output is such a comparison. Printing an undated cache in the present
    # tense is the failure A12 is about.
    #
    # So say when. `.git/FETCH_HEAD` is written by `git fetch` and `git pull`
    # and is the closest thing git keeps to "when did I last ask" - it is not
    # per-remote, and the label says so rather than implying more precision
    # than exists.
    fetch_head="$(git rev-parse --git-dir)/FETCH_HEAD"
    if [ -f "${fetch_head}" ]; then
        fetched="$(date -r "${fetch_head}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')"
        age_s=$(( $(date +%s) - $(date -r "${fetch_head}" +%s 2>/dev/null || date +%s) ))
        if   [ "${age_s}" -lt 3600 ]  ; then age="$((age_s / 60)) min ago"
        elif [ "${age_s}" -lt 86400 ] ; then age="$((age_s / 3600)) h ago"
        else                                age="$((age_s / 86400)) DAYS ago"
        fi
        fetched="${fetched} (${age}) - the remote answers below are as fresh as this"
    else
        fetched="NEVER - every remote answer below is a guess"
    fi

    echo "  hooks        ${hooks_state#*|}"
    echo "  submodules   ${subs_state#*|}"
    echo "  signing      ${signing}"
    [ -n "${signing_note}" ] && echo "               ${signing_note}"
    if [ -n "${scope_offenders}" ]; then
        echo "               GLOBAL SCOPE: ${scope_offenders}"
        echo "               other repositories on this machine inherit this and cannot"
        echo "               commit at all ('No secret key'); set these per repository"
    fi
    echo "  last fetch   ${fetched}"
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

            # ON THE INTEGRATION BRANCH THE TWO QUESTIONS COLLAPSE INTO ONE, AND
            # THE ANSWER IS DIRECTIONAL (#28).
            #
            # "DIFFERS from local" and "NOT landed" are about a DEV branch's
            # fate. Standing on {{WORKFLOW_MAIN}}, both compare the same pair of
            # refs, so a remote one commit behind printed both at once and the
            # reader had to reconstruct which of several situations they were
            # in. On 2026-08-22 that output was read as the footprint of a
            # squash merge - a reasonable reading, since squashes do break
            # containment and one had happened in a sibling repository the day
            # before - and the truth was two remotes a single merge behind. Cost:
            # a wrong diagnosis; fix: two pushes.
            #
            # A status line that names no remedy makes the reader invent one.
            if [ "${branch}" = "{{WORKFLOW_MAIN}}" ]; then
                if ! git show-ref --verify --quiet "${main_ref}"; then
                    printf '    %-16s %s\n' "" "no {{WORKFLOW_MAIN}} here"
                else
                    here="$(git rev-parse HEAD)"
                    there="$(git rev-parse "${remote}/{{WORKFLOW_MAIN}}")"
                    if [ "${here}" = "${there}" ]; then
                        printf '    %-16s %s\n' "" "in sync"
                    elif git merge-base --is-ancestor "${there}" "${here}"; then
                        n="$(git rev-list --count "${there}..${here}")"
                        printf '    %-16s %s\n' "" \
                            "BEHIND YOU by ${n} commit(s) - git push ${remote} {{WORKFLOW_MAIN}}"
                    elif git merge-base --is-ancestor "${here}" "${there}"; then
                        n="$(git rev-list --count "${here}..${there}")"
                        printf '    %-16s %s\n' "" \
                            "AHEAD of you by ${n} commit(s) - git pull --ff-only ${remote} {{WORKFLOW_MAIN}}"
                    else
                        printf '    %-16s %s\n' "" \
                            "DIVERGED from your {{WORKFLOW_MAIN}} - neither contains the other"
                    fi
                fi
                continue
            fi

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

    # THE ADVICE BELOW IS ABOUT A DEV BRANCH, so it must not be printed while
    # standing on the integration branch (#28). "This branch adds" and "cut from
    # the wrong parent" are meaningless there - the commits are simply merges
    # not yet pushed - and printing them alongside a remote that is behind was
    # half of what made that state read as something exotic.
    if [ "${branch}" = "{{WORKFLOW_MAIN}}" ]; then
        if [ "${ahead}" != "0" ] && [ "${ahead}" != "?" ]; then
            echo "  your {{WORKFLOW_MAIN}} has ${ahead} commit(s) ${base} does not:"
            git log --oneline --no-decorate "${base}..HEAD" | sed 's/^/    /'
            echo ""
            echo "  Push them, or that remote keeps serving an older tree to"
            echo "  whoever clones from it."
            echo ""
        fi
        if [ "${behind}" != "0" ] && [ "${behind}" != "?" ]; then
            echo "  ${base} has ${behind} commit(s) yours does not."
            echo "  git pull --ff-only ${base_remote} {{WORKFLOW_MAIN}}"
            echo ""
        fi
        exit 0
    fi

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
    # AND WHICH REVISION, because "at their pinned revision" answers the wrong
    # half of the question. That the checkout matches the pin is the cheap half;
    # WHICH pin is what a reader is actually after, and it was reached for by
    # hand often enough - `git submodule status`, then trim the shas - to be
    # worth printing. Order follows `git submodule status`, which is by path, so
    # two repositories can be compared by eye.
    pins="$(echo "${status}" | awk '{printf "%s=>%s, ", $2, substr($1,1,7)}' \
            | sed 's/, $//')"
    echo "ok|${count} at their pinned revision (${pins})"

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

# Print the canonical GitHub repository this checkout belongs to (internal).
#
# ONE HOME FOR "WHICH REPOSITORY DO I ASK" (#39). This rule existed inside
# `just what`, which had it right - the canonical remote is preferred over a
# fork - while `_workflow-merge-preflight` asked `gh` to work it out. Under the
# fork topology `gh` picks `origin`, the maintainer's FORK, and a pull request
# opened against canonical is simply not there. `just land` then refused with
# "no pull request found", about a pull request that was open and mergeable.
#
# `upstream` first, then `origin`, then whatever else carries a github.com URL:
# the same order `_workflow-base-remote` uses, and for the same reason. Prints
# nothing when there is no GitHub remote at all, which is a legitimate state -
# inside an instance there is only the exchange.
_workflow-forge-repo:
    #!/usr/bin/env bash
    set -uo pipefail

    for remote in upstream origin $(git remote); do
        url="$(git remote get-url "${remote}" 2>/dev/null)" || continue
        case "${url}" in *github.com[:/]*) ;; *) continue ;; esac
        printf '%s' "${url}" | sed -E 's|.*github\.com[:/]||; s|\.git$||; s|/$||'
        exit 0
    done

# What is left to do, from the forge (companion to `just where`).
#
# `where` answers "where am I in this workflow" and is deliberately OFFLINE - it
# reads pins, never upstream heads, which is why it works on a machine with no
# credentials. `what` answers "what is left" and cannot be offline: it asks
# GitHub. So it degrades to a sentence rather than an error, because an
# informational recipe that FAILS reads as a broken repository.
#
# The grouping is the point. A flat list of eighteen is why the question keeps
# being asked; "eleven in this epic, six for later, one undecided" is an answer.
# Milestones are what it groups by, so an issue with no milestone shows up as
# exactly that - an issue nobody has decided about.
#
# The repository is DERIVED, never written down: this file is shared, and a
# hard-coded name would be wrong in every repository but one. The canonical
# remote is preferred over a fork, so the count is of the project's issues and
# not of a fork's.
#
# Group this repository's open issues by milestone - what is left, and for when.
what:
    #!/usr/bin/env bash
    set -uo pipefail

    # See _workflow-forge-repo. The rule used to live here; `land` had its own
    # answer and got it wrong (#39), so there is now one.
    slug="$(just --justfile "{{justfile()}}" _workflow-forge-repo)"

    if [ -z "${slug}" ]; then
        echo ""
        echo "  no GitHub remote in this checkout, so there is nothing to ask."
        echo "  \`just what\` runs on the machine that has the forge remotes and"
        echo "  credentials; \`just where\` works everywhere and is the offline half."
        echo ""
        exit 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo ""
        echo "  gh is not installed here, so ${slug} cannot be asked."
        echo "  Same as above: this is the online half of the pair."
        echo ""
        exit 0
    fi

    # number, title and milestone in one call. `gh` exits non-zero when it is
    # unauthenticated or offline, and that is reported rather than swallowed -
    # an empty list and a failed call must not look the same.
    rows="$(gh issue list --repo "${slug}" --state open --limit 200 \
              --json number,title,milestone \
              --jq '.[] | [(.milestone.title // "(no milestone)"), .number, .title] | @tsv' 2>&1)"
    if [ $? -ne 0 ]; then
        echo ""
        echo "  could not ask ${slug}:"
        printf '    %s\n' "${rows}"
        echo ""
        exit 0
    fi

    echo ""
    printf "  repository   %s\n" "${slug}"
    if [ -z "${rows}" ]; then
        printf "  open issues  0 - nothing is left, which is worth checking twice.\n\n"
        exit 0
    fi
    printf "  open issues  %s\n" "$(printf '%s\n' "${rows}" | wc -l)"

    # Milestones first, in name order, with "(no milestone)" LAST - it is the
    # bucket to empty, and putting it at the end is where a reader stops.
    printf '%s\n' "${rows}" | cut -f1 | sort -u | sort -k1,1 \
        | awk '$0 == "(no milestone)" { last = $0; next } { print } END { if (last) print last }' \
        | while IFS= read -r milestone; do
        n="$(printf '%s\n' "${rows}" | awk -F'\t' -v m="${milestone}" '$1 == m' | wc -l)"
        printf "\n  %-28s %s\n" "${milestone}" "${n}"
        printf '%s\n' "${rows}" | awk -F'\t' -v m="${milestone}" '$1 == m { printf "    #%-4s %s\n", $2, $3 }'
    done
    echo ""

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

    # SIGNED IF THIS REPOSITORY CAN SIGN - see _workflow-commit for why the
    # recipe asks rather than leaving it to commit.gpgsign (#36). Inline here
    # rather than via that helper because this message is multi-line and
    # interpolates two recipe parameters; routing it through a `just` argument
    # would be the fragile half of the fix. THIS commit matters more than the
    # audit commit, not less: it goes straight onto the integration branch.
    sign_state="$(just --justfile "{{justfile()}}" _workflow-signing-state)"
    sign_flag=""
    [ "${sign_state%%|*}" = "ok" ] && sign_flag="-S"

    if ! git commit ${sign_flag} -m "{{message}}

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

    if [ -z "${sign_flag}" ]; then
        echo "--> NOTE: this commit on {{WORKFLOW_MAIN}} is NOT SIGNED - ${sign_state#*|}"
        echo "    See MERGE-AND-SIGNING-POLICY.md beside this file."
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

    # WHERE IT WILL BE PUBLISHED, ASKED NOW RATHER THAN AFTER THE COMMIT (#24).
    # See _workflow-publish-remotes. This refusal used to fire after the branch
    # existed and the audit file had been committed onto it, so the recipe's
    # own failure left work behind that the recipe itself had made.
    publish_to="$(just --justfile "{{justfile()}}" _workflow-publish-remotes)"
    if [ -z "${publish_to}" ]; then
        echo "REFUSING: no remote to publish ${branch} to." >&2
        exit 1
    fi

    echo "--> Fetching ${base_remote}"
    git fetch --prune "${base_remote}"

    # DOES THIS BRANCH ALREADY EXIST SOMEWHERE ELSE? (#24)
    #
    # Work had been started on fix_98 on one machine and published to the
    # exchange. On the other machine, `just new-branch 98` cut the branch,
    # generated the audit file, committed it, and only then found out:
    #
    #     ! [rejected]  fix_98 -> fix_98 (non-fast-forward)
    #
    # What is left behind is a local fix_98 that is NOT the fix_98 everyone else
    # has - same name, different history, one commit, no work - and the recipe
    # leaves you STANDING ON IT, so `git branch -d` cannot even be attempted
    # until you check {{WORKFLOW_MAIN}} out again. It then refuses anyway, and
    # correctly, because the branch is merged nowhere: recovery is the
    # destructive `git branch -D`, on a branch a recipe made and named after
    # the user's own issue. It took two rounds of that before the real branch
    # could be fetched.
    #
    # Nothing was lost, and the reason is that the EXCHANGE refused the push.
    # A remote rejecting a non-fast-forward is the last thing standing between
    # this and two divergent histories under one name, and it is not where the
    # check belongs.
    #
    # ls-remote, not the remote-tracking refs: a publish remote is not fetched
    # by this recipe, so its tracking refs can be older than the branch being
    # asked about - which is exactly the case that bit.
    #
    # AND "IT IS NOT THERE" IS NOT "I COULD NOT ASK". A remote that cannot be
    # reached answering the same as a branch that does not exist is how a guard
    # becomes a rubber stamp on the day the network is down. `land` had the same
    # conflation over `gh pr view` (#32); this is the same distinction, made
    # before rather than after.
    existing=""
    found_remote=""
    asked=""
    for remote in ${base_remote} ${publish_to}; do
        case " ${asked} " in *" ${remote} "*) continue ;; esac
        asked="${asked} ${remote}"
        if ! ls_out="$(git ls-remote "${remote}" "refs/heads/${branch}" 2>&1)"; then
            echo "REFUSING: could not ask ${remote} whether ${branch} exists." >&2
            echo "" >&2
            echo "${ls_out}" | sed 's/^/    /' >&2
            echo "" >&2
            echo "  Nothing has been created. A remote that could not answer is" >&2
            echo "  not a remote that answered 'no'." >&2
            exit 1
        fi
        if [ -n "${ls_out}" ]; then
            existing="${existing}    ${remote}  $(echo "${ls_out}" | awk '{print substr($1,1,7)}')"$'\n'
            [ -z "${found_remote}" ] && found_remote="${remote}"
        fi
    done

    if [ -n "${existing}" ]; then
        echo "REFUSING: ${branch} already exists on:" >&2
        echo "" >&2
        printf '%s' "${existing}" >&2
        echo "" >&2
        echo "  Work on issue #{{issue}} was started elsewhere and published." >&2
        echo "  NOTHING has been created here." >&2
        echo "" >&2
        echo "  To continue that work:" >&2
        echo "" >&2
        echo "    git fetch ${found_remote}" >&2
        echo "    git checkout -b ${branch} ${found_remote}/${branch}" >&2
        echo "" >&2
        echo "  If it is finished with and you mean to start again, delete it" >&2
        echo "  on each remote listed above first - deliberately, because on a" >&2
        echo "  dev branch that may be the only copy:" >&2
        echo "" >&2
        echo "    git push <remote> --delete ${branch}" >&2
        exit 1
    fi

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
        just --justfile "{{justfile()}}" _workflow-commit \
            "the audit commit" "start new dev branch; add audit file"
    else
        echo "--> Nothing to commit; ${branch} starts at ${base_sha}."
    fi

    # Published to the PUBLISH remotes, not to the authority (#18). Cutting
    # from `upstream` is right; pushing a dev branch there is not - it bypasses
    # the fork the pull-request gate is built on. See _workflow-publish-remotes.
    # Resolved above, before anything was created.
    for remote in ${publish_to}; do
        git push -q "${remote}" "${branch}"
    done

    echo ""
    echo "--> ${branch} created from ${base_remote}/{{WORKFLOW_MAIN}} at ${base_sha}"
    echo "    and published to:${publish_to}"
    echo ""
    just --justfile "{{justfile()}}" where

# Commit, signed if this repository can sign, and SAY SO when it cannot (internal).
#
# WHY THE RECIPES ASK FOR `-S` RATHER THAN LEAVING IT TO commit.gpgsign (#36).
# MERGE-AND-SIGNING-POLICY.md already makes this argument for the landing merge:
# "whether a merge is signed must not depend on a config key that is easy to
# unset and invisible when it is". It applies with more force here. The audit
# commit is the HUMAN-ONLY act the whole Way A gate is built around - the
# affidavit - and it is the one commit an AI assistant in this estate must not
# be able to produce. It was the last commit that should have depended on an
# invisible config bit, and it did:
#
#     metal       490b239  UNSIGNED      collection  a82dc14  UNSIGNED
#     assurance   a7eb311  SIGNED        campfireos  4186a73  UNSIGNED
#
# Four branches cut within five minutes, one signature, and no signal anywhere
# that the other three were different. Every audit commit in `assurance` had
# been signed since 2026-08-09; none in the other three ever had.
#
# NOT A REFUSAL, THOUGH. This file is shipped to repositories whose contributors
# have no gitsign set up, and a `new-branch` that refuses there would be a guard
# that blocks work everywhere to enforce a policy that is this estate's, not
# theirs. So: sign where signing is configured, and where it is not, make the
# omission LOUD at the moment it happens. Silence was the actual defect.
# ONE-LINE, LITERAL MESSAGES ONLY. `{{message}}` is interpolated into a
# double-quoted `-m`, so a caller with a multi-line body or an embedded quote
# must inline this logic instead - `commit-on-main` does, and says why.
_workflow-commit branch_hint message:
    #!/usr/bin/env bash
    set -uo pipefail

    sign_state="$(just --justfile "{{justfile()}}" _workflow-signing-state)"
    if [ "${sign_state%%|*}" = "ok" ]; then
        git commit -q -S -m "{{message}}"
        exit $?
    fi

    git commit -q -m "{{message}}" || exit $?
    echo "--> NOTE: {{branch_hint}} is NOT SIGNED - ${sign_state#*|}"
    echo "    This commit is the maintainer's own attestation; see"
    echo "    MERGE-AND-SIGNING-POLICY.md beside this file."

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

# Everything that can be refused BEFORE the operator's branch changes (internal).
#
# WHY THIS IS SEPARATE FROM THE MERGE (#32). `land` used to check the branch
# out, fast-forward the integration branch, and only then ask whether it was
# allowed to merge at all - so a refusal for an unset config left the operator
# standing on the integration branch, which is the one branch this whole
# workflow exists to protect. The next `land` then said "not on a dev branch",
# advice that is correct and useless, because `land` is what put them there.
#
# So: three of the five preconditions need nothing but the dev branch and the
# network, and they are asked here, first. The two that genuinely require being
# ON the integration branch - the merge and its verification - stay in
# `_workflow-merge-signed`, behind a trap that restores the branch.
#
# Prints one line on success: what the forge said about the pull request, which
# the merge step then records in the commit message.
_workflow-merge-preflight branch:
    #!/usr/bin/env bash
    set -euo pipefail

    branch="{{branch}}"

    # THE REVIEWED COPY AND THE LOCAL COPY MUST BE THE SAME COMMIT.
    # `_workflow-branch-behind` proves the local branch is not BEHIND any copy.
    # This is the other half, and it is the half that merges unreviewed work: a
    # local branch AHEAD of the copy the pull request was opened against carries
    # commits nobody has seen.
    ahead=""
    for remote in $(just --justfile "{{justfile()}}" _workflow-publish-remotes); do
        git show-ref --verify --quiet "refs/remotes/${remote}/${branch}" || continue
        if [ "$(git rev-parse "${remote}/${branch}")" != "$(git rev-parse "${branch}")" ]; then
            ahead="${ahead} ${remote}"
        fi
    done
    if [ -n "${ahead}" ]; then
        echo "" >&2
        echo "REFUSING: ${branch} differs from the copy on:${ahead}" >&2
        echo "" >&2
        echo "  Those are the copies a reviewer looked at. Merging a local tip" >&2
        echo "  that differs from them lands commits nobody reviewed." >&2
        echo "" >&2
        echo "  Fix with:  just publish ${branch}" >&2
        exit 1
    fi

    sign_state="$(just --justfile "{{justfile()}}" _workflow-signing-state)"
    if [ "${sign_state%%|*}" != "ok" ]; then
        echo "" >&2
        echo "REFUSING: cannot sign a merge here - ${sign_state#*|}." >&2
        echo "" >&2
        echo "  An unsigned merge on {{WORKFLOW_MAIN}} is the object the policy" >&2
        echo "  exists to keep out, so this refuses rather than making one." >&2
        echo "" >&2
        echo "  The IDENTITY is who you are - set it once, for every repository:" >&2
        echo "" >&2
        echo "    git config --global workflow.signingIdentity <your-identity>" >&2
        echo "" >&2
        echo "  HOW a repository signs is per repository, deliberately:" >&2
        echo "" >&2
        echo "    git config gpg.format x509" >&2
        echo "    git config gpg.x509.program gitsign" >&2
        echo "" >&2
        echo "  Forgotten which identity? Any commit you already signed says so:" >&2
        echo "    git verify-commit <sha>   ->  Good signature from [<identity>](<issuer>)" >&2
        echo "" >&2
        exit 1
    fi

    # WHERE THERE IS A FORGE, THE FORGE DECIDES READINESS. This must not become
    # a way around review - that is the whole reason the merge may happen
    # locally at all. Where there is NO forge remote there is no pull request to
    # consult, and this is skipped out loud rather than silently.
    #
    # It checks OPEN and MERGEABLE, and refuses on CHANGES_REQUESTED. It does
    # NOT require an approval: on a single-maintainer repository nothing ever
    # carries one, and a check that cannot pass gets switched off.
    pr_note="no forge remote - no pull request to consult"
    if git remote -v | grep -q 'github\.com'; then
        if ! command -v gh >/dev/null 2>&1; then
            echo "REFUSING: this repository has a forge remote but gh is not" >&2
            echo "  installed, so the pull request's state cannot be read." >&2
            exit 1
        fi
        # WHICH REPOSITORY. Derived, never left to `gh` (#39) - see
        # _workflow-forge-repo. Without this, `gh` resolves to whichever GitHub
        # remote it likes, and under the fork topology that is the fork.
        slug="$(just --justfile "{{justfile()}}" _workflow-forge-repo)"
        if [ -z "${slug}" ]; then
            echo "REFUSING: a github.com remote exists but no owner/repo could" >&2
            echo "  be derived from it, so the pull request cannot be found." >&2
            git remote -v | sed 's/^/    /' >&2
            exit 1
        fi

        # AND `gh` IS NOT ASKED TO RESOLVE THE BRANCH EITHER (#39). Its two
        # rules point in opposite directions, measured against one open
        # cross-repository pull request:
        #
        #   gh pr view  oberstet:fix_158 --repo R    -> #163   needs owner:
        #   gh pr list  --head fix_158    --repo R   -> #163   bare ref
        #   gh pr list  --head oberstet:fix_158 ...  -> []     REJECTS owner:
        #
        # A bare name never matches a fork pull request in `pr view`, and the
        # prefix that fixes `pr view` breaks `pr list`. Depending on either is
        # depending on a rule that surprised this estate twice in one hour, so
        # the repository's open pull requests are listed and matched HERE.
        #
        # The branch name is interpolated into a jq program, so it is checked
        # first: this is the one place in this file where a name from the
        # command line reaches an interpreter.
        case "${branch}" in
            *[!A-Za-z0-9._/-]*)
                echo "REFUSING: refusing to look up a branch whose name has" >&2
                echo "  characters outside [A-Za-z0-9._/-]: ${branch}" >&2
                exit 1 ;;
        esac

        # "THERE IS NO PULL REQUEST" AND "I COULD NOT ASK" ARE DIFFERENT
        # ANSWERS, and an earlier version of this reported both as the first.
        # `2>/dev/null || true` turned an auth failure, an ambiguous repository
        # and a rate limit into "no pull request found for X" - a refusal that
        # names the wrong cause and sends the reader to look at the forge.
        pr_err=""
        if ! rows="$(gh pr list --repo "${slug}" --state open --limit 200 \
                --json number,state,mergeable,reviewDecision,headRefName,headRepositoryOwner \
                --jq ".[] | select(.headRefName == \"${branch}\")
                      | [.number, .state, .mergeable, (.reviewDecision // \"\"),
                         (.headRepositoryOwner.login // \"?\")] | @tsv" 2>&1)"; then
            pr_err="${rows}"
            rows=""
        fi
        if [ -n "${pr_err}" ]; then
            echo "" >&2
            echo "REFUSING: could not ask ${slug} about ${branch}." >&2
            echo "" >&2
            echo "  gh said:" >&2
            echo "${pr_err}" | sed 's/^/    /' >&2
            echo "" >&2
            echo "  This is NOT 'there is no pull request'. Until the" >&2
            echo "  forge can be asked, landing would skip the review" >&2
            echo "  without knowing it." >&2
            exit 1
        fi
        rows="$(printf '%s' "${rows}" | sed '/^$/d')"
        if [ -z "${rows}" ]; then
            echo "" >&2
            echo "REFUSING: no open pull request in ${slug} has ${branch} as" >&2
            echo "  its head branch." >&2
            echo "  The forge hosts the review; landing without one" >&2
            echo "  skips it. Open one, then run this again - nothing" >&2
            echo "  has moved." >&2
            exit 1
        fi
        # MORE THAN ONE IS POSSIBLE, and only visible now that the matching is
        # done here: two forks can each open a pull request from a branch of
        # the same name. Picking the first would land against a review that
        # might belong to the other one.
        if [ "$(printf '%s\n' "${rows}" | wc -l)" -gt 1 ]; then
            echo "" >&2
            echo "REFUSING: ${slug} has more than one open pull request whose" >&2
            echo "  head branch is ${branch}:" >&2
            echo "" >&2
            printf '%s\n' "${rows}" \
                | awk -F'\t' '{printf "    #%s  from %s  (%s, %s)\n", $1, $5, $2, $3}' >&2
            echo "" >&2
            echo "  Which one is being landed is a decision, not a guess." >&2
            exit 1
        fi
        # `cut`, not a heredoc: an unindented terminator would end the recipe
        # body as far as `just` is concerned, and the parse error it produces
        # points at a line several below the real cause.
        pr_number="$(printf '%s' "${rows}" | cut -f1)"
        pr_state="$(printf '%s' "${rows}" | cut -f2)"
        pr_mergeable="$(printf '%s' "${rows}" | cut -f3)"
        pr_review="$(printf '%s' "${rows}" | cut -f4)"
        pr_owner="$(printf '%s' "${rows}" | cut -f5)"

        if [ "${pr_state}" != "OPEN" ]; then
            echo "REFUSING: pull request #${pr_number} is ${pr_state}, not OPEN." >&2
            exit 1
        fi
        if [ "${pr_mergeable}" = "CONFLICTING" ]; then
            echo "REFUSING: pull request #${pr_number} is CONFLICTING." >&2
            exit 1
        fi
        if [ "${pr_review}" = "CHANGES_REQUESTED" ]; then
            echo "REFUSING: pull request #${pr_number} has changes requested." >&2
            exit 1
        fi
        pr_note="pull request ${slug}#${pr_number} from ${pr_owner}, "
        pr_note="${pr_note}${pr_state}, ${pr_mergeable}, review: ${pr_review:-none}"
    fi
    echo "${pr_note}"

# Make the merge that lands a reviewed branch, locally and signed (internal).
#
# MERGE-AND-SIGNING-POLICY.md, made executable. The forge decides that a pull
# request is ready; THIS makes the merge commit that enters protected history,
# so that history is attributable to the maintainer rather than to the forge.
#
# WHY IT IS NOT SIX COMMANDS IN A RUNBOOK. A merge, a signature, a verification
# and three pushes, per landing, forever. Every clerical guard in this file
# replaced a step that had been forgotten at least once, and this is the step
# that decides what enters the branch everyone reads.
#
# ONLY THE STEPS THAT REQUIRE BEING ON THE INTEGRATION BRANCH LIVE HERE (#32).
# Everything answerable earlier is in `_workflow-merge-preflight`, which `land`
# runs BEFORE it changes the operator's branch. `pr_note` is what that step
# learned from the forge, passed in so it is not asked twice.
#
# IT DOES THE CHECKOUT ITSELF, AND THAT IS THE POINT (#32). `land` used to
# check out the integration branch and THEN invoke this recipe - so `just`
# re-read the justfile from a working tree that had just reverted to the
# integration branch's copy. In this repository that copy is an older
# `workflow.just` with a different signature, and the invocation died with
# "Justfile does not contain recipe `pull request #33, OPEN, ...`" - the third
# argument read as a recipe name, because the version on disk took two.
#
# So `just` must finish reading the recipes while the dev branch is still
# checked out. After the checkout below, nothing invokes `just` again.
#
#   1  read the signing configuration - the last sub-invocation, done first
#   2  move to the integration branch and make it current with the authority
#   3  the merge itself, aborted cleanly if a hook refuses it
#   4  the signature verifies against the expected identity AND issuer,
#      BEFORE the object leaves this machine
#   5  push to the authority first
_workflow-merge-signed branch base_remote pr_note:
    #!/usr/bin/env bash
    set -euo pipefail

    branch="{{branch}}"
    base_remote="{{base_remote}}"
    pr_note="{{pr_note}}"

    # 1 --------------------------------------------------------------------
    # THE LAST `just` INVOCATION, AND IT HAPPENS BEFORE THE CHECKOUT. See the
    # header: after the working tree moves, the justfile on disk may not be the
    # one this recipe came from.
    sign_state="$(just --justfile "{{justfile()}}" _workflow-signing-state)"
    identity="$(echo "${sign_state}" | cut -d'|' -f2)"
    issuer="$(echo "${sign_state}" | cut -d'|' -f3)"

    # 2 --------------------------------------------------------------------
    echo "--> Moving to {{WORKFLOW_MAIN}}"
    git checkout {{WORKFLOW_MAIN}}
    # SUBMODULE WORKTREES DO NOT FOLLOW A CHECKOUT, and `land` produced the
    # dirtiness it then refused on because of it (#32): the recorded revisions
    # changed, the checked-out ones did not, and `git status` said modified.
    # Safe here - the clean check in `land` already refused a tree with real
    # local changes, so nothing can be lost.
    git submodule update --init --recursive --quiet 2>/dev/null || true
    git merge --ff-only "${base_remote}/{{WORKFLOW_MAIN}}"

    # 2 --------------------------------------------------------------------
    # The subject carries the issue number the way every other commit here does,
    # derived from the branch name rather than asked for - `new-branch` is what
    # made the name, so the two cannot disagree.
    subject="Merge branch '${branch}'"
    case "${branch}" in
        {{WORKFLOW_BRANCH_PREFIX}}*)
            n="${branch#{{WORKFLOW_BRANCH_PREFIX}}}"
            case "${n}" in
                ''|*[!0-9]*) : ;;
                *) subject="${subject} (#${n})" ;;
            esac ;;
    esac

    before_merge="$(git rev-parse HEAD)"
    # -S EXPLICITLY, not via commit.gpgsign. Whether a merge is signed must not
    # depend on a config key that is easy to unset and invisible when it is:
    # the policy is about this object, so this command asks for it.
    echo "--> Merging ${branch} into {{WORKFLOW_MAIN}}, no fast-forward, signed"
    if ! git merge --no-ff -S -m "${subject}

    Merged on the control node and signed with the maintainer's Sigstore
    identity, per MERGE-AND-SIGNING-POLICY.md - ${pr_note}." "${branch}"; then
        # LEAVE NO HALF-MERGE. A commit-msg hook that refuses a commit on the
        # integration branch stops the merge after the index has been written,
        # and a working tree left mid-merge is worse than a refusal.
        git merge --abort 2>/dev/null || true
        echo "" >&2
        echo "REFUSING: the merge did not complete; the tree has been restored." >&2
        echo "  Read the output above - it names the cause. The two seen so far:" >&2
        echo "" >&2
        echo "  A HOOK REFUSED A COMMIT ON {{WORKFLOW_MAIN}}. Such a hook predates" >&2
        echo "  this policy: it was written when nothing was supposed to be" >&2
        echo "  committed there at all, and it cannot yet tell an ordinary commit" >&2
        echo "  from a maintainer-signed merge. Do NOT disable hooks to get past" >&2
        echo "  it - that is the remedy such hooks print, and taking it leaves" >&2
        echo "  every other guard off too." >&2
        echo "" >&2
        echo "  SIGNING FAILED (\"gpg failed to sign the data\"). gitsign is" >&2
        echo "  configured but could not produce a certificate - usually no" >&2
        echo "  browser for the OIDC flow, or no network to Fulcio." >&2
        exit 1
    fi

    # 3 --------------------------------------------------------------------
    # BEFORE IT LEAVES THIS MACHINE. A merge that was made but not signed must
    # not reach the protected branch, and the check costs one command.
    echo "--> Verifying the merge signature"
    if ! gitsign verify \
            --certificate-identity="${identity}" \
            --certificate-oidc-issuer="${issuer}" HEAD; then
        git reset --hard "${before_merge}"
        echo "" >&2
        echo "REFUSING: the merge commit does not verify as ${identity}" >&2
        echo "  via ${issuer}. The merge has been undone; nothing was pushed." >&2
        exit 1
    fi

    # 4 --------------------------------------------------------------------
    # The authority first, deliberately. Everything else in this file treats
    # the authority's integration branch as the answer to "has this landed",
    # so it is the copy that must exist before any other is told about it.
    echo "--> Pushing {{WORKFLOW_MAIN}} to ${base_remote} (the authority)"
    git push "${base_remote}" {{WORKFLOW_MAIN}}

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

    # HAS THE MERGE ALREADY BEEN MADE? Two worlds, and this recipe serves both.
    #
    # Before MERGE-AND-SIGNING-POLICY.md the forge made the merge and this
    # recipe only tidied up afterwards, so "not contained" could only mean
    # "you have not merged it yet" and refusing was the only safe answer.
    # Under the policy the MAINTAINER makes the merge, so "not contained" is
    # now the ordinary case and this recipe is what makes it - once, locally,
    # signed, and having asked the forge whether it is allowed to.
    #
    # The refusal is not gone. It has moved into _workflow-merge-signed, which
    # refuses on each of that step's own preconditions and names which one -
    # and everything below still runs only if containment holds AFTERWARDS,
    # asserted rather than assumed.
    landed=1
    git merge-base --is-ancestor "${head_sha}" "${base_remote}/{{WORKFLOW_MAIN}}" || landed=0

    pr_note=""
    if [ "${landed}" = 0 ]; then
        # DOES THIS BRANCH CHANGE THE FILE THIS RECIPE COMES FROM? (#32)
        #
        # Checking out {{WORKFLOW_MAIN}} restores the submodule revisions it
        # records, so a branch that bumps `.cicd` swaps `workflow.just` back to
        # the old copy MID-RUN - and the rest of the landing then executes code
        # the operator had already replaced. Observed 2026-08-23: a second
        # attempt printed a refusal in the voice of the version being retired.
        #
        # This is not a defect to fix, it is what bootstrapping means, and it
        # happens exactly once per repository. It is worth SAYING rather than
        # letting someone discover it through three refusals.
        selfmod="$(git diff --name-only \
            "${base_remote}/{{WORKFLOW_MAIN}}...${branch}" -- .cicd .ai 2>/dev/null || true)"
        if [ -n "${selfmod}" ]; then
            echo "" >&2
            echo "REFUSING: ${branch} changes $(echo ${selfmod} | tr '\n' ' ')- where this" >&2
            echo "  recipe and the commit hooks come from." >&2
            echo "" >&2
            echo "  Landing it here would swap them out half way through, and the" >&2
            echo "  copy on {{WORKFLOW_MAIN}} cannot make a signed merge yet -" >&2
            echo "  that is what this branch installs." >&2
            echo "" >&2
            echo "  Land this one through the forge: merge the pull request there," >&2
            echo "  then:" >&2
            echo "" >&2
            echo "    git checkout {{WORKFLOW_MAIN}} && git pull --ff-only ${base_remote} {{WORKFLOW_MAIN}}" >&2
            echo "    git submodule update --init --recursive" >&2
            echo "" >&2
            echo "  Every branch after it can use 'just land'." >&2
            echo "" >&2
            exit 1
        fi

        # ASKED BEFORE ANYTHING MOVES. This is the whole point of #32: a
        # refusal here leaves the operator exactly where they were.
        if ! pr_note="$(just --justfile "{{justfile()}}" _workflow-merge-preflight "${branch}")"; then
            exit 1
        fi
        echo "--> ${pr_note}"
    fi

    # FROM HERE THE OPERATOR'S BRANCH CHANGES, so a failure must put it back.
    # The merge and its verification can only happen on the integration branch;
    # failing there must not leave anyone standing on it.
    start_branch="${branch}"
    trap 'st=$?; if [ ${st} -ne 0 ]; then \
              git merge --abort 2>/dev/null || true; \
              git checkout --quiet "${start_branch}" 2>/dev/null || true; \
              git submodule update --init --recursive --quiet 2>/dev/null || true; \
              echo "--> restored to ${start_branch}" >&2; \
          fi' EXIT

    # WHAT {{WORKFLOW_MAIN}} WAS BEFORE ANY OF THIS. Captured from the
    # authority rather than from the local copy, because the local one may be
    # behind and because `_workflow-merge-signed` is about to move both.
    before="$(git rev-parse --short "${base_remote}/{{WORKFLOW_MAIN}}")"

    if [ "${landed}" = 0 ]; then
        # IT DOES ITS OWN CHECKOUT, DELIBERATELY (#32). Invoking it from the dev
        # branch is what lets `just` finish reading the recipes before the
        # working tree moves - see that recipe's header for the failure this
        # replaces.
        just --justfile "{{justfile()}}" _workflow-merge-signed \
            "${branch}" "${base_remote}" "${pr_note}"
    else
        git checkout {{WORKFLOW_MAIN}}
        git submodule update --init --recursive --quiet 2>/dev/null || true
        git merge --ff-only "${base_remote}/{{WORKFLOW_MAIN}}"
    fi

    if [ "${landed}" = 0 ]; then

        # ASSERT, DO NOT TRUST. Everything after this point deletes the branch
        # on every remote that carries it. The old refusal guarded that; this
        # is the same guard, asked after the step that is now allowed to fix it.
        if ! git merge-base --is-ancestor "${head_sha}" "${base_remote}/{{WORKFLOW_MAIN}}"; then
            echo "" >&2
            echo "REFUSING: the merge ran and ${base_remote}/{{WORKFLOW_MAIN}} still" >&2
            echo "  does not contain ${branch}. Nothing has been deleted." >&2
            echo "" >&2
            echo "  Not yet on {{WORKFLOW_MAIN}}:" >&2
            git log --oneline --no-decorate "${base_remote}/{{WORKFLOW_MAIN}}..${branch}" \
                | sed 's/^/    /' >&2
            exit 1
        fi
    fi

    after="$(git rev-parse --short HEAD)"

    # And once more, because the merge moved the recorded revisions too. Leaving
    # them stale is how the next `just where` reports "NOT at the pinned
    # revision" about a repository that just landed correctly.
    git submodule update --init --recursive --quiet 2>/dev/null || true

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
