# fleet/fleet.just - the fleet tooling as `just` recipes (#58).
#
# Imported by wamp-cicd's justfile; from anywhere else: `just -f <wamp-cicd>/fleet/fleet.just ...`
# (e.g. `just -f .cicd/fleet/fleet.just fleet-where` in a repository that pins wamp-cicd).
#
# EVERY recipe that changes something is a DRY RUN. The armed variant is the same call with
# `go` as the LAST word:   just fleet-org settings        (shows what would change)
#                          just fleet-org settings go     (does it)
# Other words: `seal` (publish), `integrity` (rulesets), `full` (where); anything else is
# passed through (repository names, org names, --only a,b, --wave N, ...).
# Which fleet: FLEET_NAME, or the only ~/.config/fleet/*.env (see fleet/lib/config.sh).

FLEET_TOOLS := source_directory()

# Is the fleet's configuration valid? File, keys, permissions, inventory (read-only; the check for generated configurations)
fleet-check *args: (_fleet "check.sh" args)

# Who is behind: per repository and cohort, the next rollout to apply (read-only; [--cohort C])
fleet-next *args: (_fleet "next.sh" args)

# Apply one rollout to one member clone (the credential-free step; see fleet/apply-rollout.sh)
fleet-apply-rollout *args: (_fleet "apply-rollout.sh" args)

# Health table across the fleet: sync, hooks, signing, pins, drift, `just where` (read-only; `full` adds every `just where`)
fleet-where *args: (_fleet "where.sh" args)

# One rollout phase: init <name> --wave N | preflight | prune | file-issues | cut | sync | seal | publish | open-prs | status | land  [go]
fleet-rollout phase *args: (_fleet "rollout.sh" phase + " " + args)

# One-time cleanup before a rollout: bundle-backed removal of stale branches, signing + hooks config [go]
fleet-hygiene *args: (_fleet "hygiene.sh" args)

# Bring the rollout branches from the exchange to the forks: [seal] [go]
fleet-publish *args: (_fleet "publish.sh" args)

# Collect every rollout PR's CI results and failed-job logs (and upload them if UPLOAD_TO is set)
fleet-ci-results *args: (_fleet "ci-results.sh" args)

# Default-branch rulesets per repository, then classic protection off: [integrity] [go]
fleet-rulesets *args: (_fleet "rulesets.sh" args)

# Organisations you administer: status | settings [go] | rulesets <org> [go] | transfer <from> <to> [go]
fleet-org *args: (_fleet "org.sh" args)

# Link the personal tools as ~/.local/bin/wamp-cicd-{file-issue,file-comment,pr-ci}.sh (symlinks into this clone) [go]
fleet-install-tools *args:
    #!/usr/bin/env bash
    set -euo pipefail
    set -- {{args}}; go=0
    while [ $# -gt 0 ]; do
        case "$1" in
            go) [ $# -eq 1 ] || { echo "ERROR: 'go' must be the LAST word (it arms the whole call)" >&2; exit 2; }; go=1 ;;
            *)  echo "ERROR: unexpected word '$1'" >&2; exit 2 ;;
        esac; shift
    done
    # Symlinks must point into a STANDALONE wamp-cicd clone: a link into some repository's .cicd/
    # submodule would change with that repository's pin and checked-out branch.
    if [ -n "$(git -C "{{FLEET_TOOLS}}" rev-parse --show-superproject-working-tree 2>/dev/null)" ]; then
        echo "REFUSING: {{FLEET_TOOLS}} is inside a git submodule; run this from a standalone wamp-cicd clone" >&2; exit 1
    fi
    dest="${HOME}/.local/bin"; blocked=0
    for t in file-issue.sh file-comment.sh pr-ci.sh; do
        link="${dest}/wamp-cicd-${t}"; target="{{FLEET_TOOLS}}/${t}"
        if [ -e "${link}" ] && [ ! -L "${link}" ]; then
            # Never touch a regular file: it is not ours to replace.
            echo "BLOCKED ${link}: exists and is not a symlink - remove it yourself, then re-run"; blocked=1; continue
        fi
        if [ -L "${link}" ] && [ "$(readlink "${link}")" = "${target}" ]; then echo "ok      ${link} -> ${target}"; continue; fi
        if [ "${go}" = 1 ]; then
            mkdir -p "${dest}" && ln -sfn "${target}" "${link}" && echo "linked  ${link} -> ${target}"
        else
            echo "[dry-run] link ${link} -> ${target}$([ -L "${link}" ] && echo "  (re-point from $(readlink "${link}"))")"
        fi
    done
    [ "${go}" = 1 ] || echo "(dry run - nothing changed; add 'go' as the last word)"
    [ "${blocked}" = 0 ] || exit 1
    case ":${PATH}:" in *":${dest}:"*) ;; *) echo "note: ${dest} is not on your PATH" ;; esac

# Translate the words and run a script from this directory. `go` is only valid LAST.
_fleet script args:
    #!/usr/bin/env bash
    set -euo pipefail
    set -- {{args}}
    out=()
    while [ $# -gt 0 ]; do
        case "$1" in
            go)        [ $# -eq 1 ] || { echo "ERROR: 'go' must be the LAST word (it arms the whole call)" >&2; exit 2; }
                       out+=(--go) ;;
            seal)      out+=(--seal) ;;
            integrity) out+=(--integrity) ;;
            full)      out+=(--where) ;;
            *)         out+=("$1") ;;
        esac
        shift
    done
    exec bash "{{FLEET_TOOLS}}/{{script}}" "${out[@]}"
