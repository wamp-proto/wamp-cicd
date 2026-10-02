# fleet/lib/aidir.sh - sourced: where a repository has the AI policy tooling (the commit hooks).
#
# The same three layouts workflow.just knows (`_workflow-ai-dir`; TOOLING-STRUCTURE.md):
#   .ai             the wamp-ai submodule: every ordinary repository
#   .deps/wamp-ai   a pinned checkout (deps.toml): a tooling source, which carries no submodules
#   .               wamp-ai itself: the hooks are its own .githooks/

# ai_dir <clone>: the directory, relative to the clone; nothing when the repository has none.
# Answered from what the repository RECORDS (.gitmodules, deps.toml) as well as from what is
# checked out, so "recorded but not there" is not mistaken for "has none".
ai_dir() {
    local d="$1"
    if [ -d "${d}/.ai/.githooks" ] || git -C "${d}" config -f .gitmodules --get submodule..ai.url >/dev/null 2>&1; then echo ".ai"
    elif [ -d "${d}/.deps/wamp-ai/.githooks" ] || grep -q '^\[wamp-ai\]' "${d}/deps.toml" 2>/dev/null; then echo ".deps/wamp-ai"
    elif [ -f "${d}/.githooks/commit-msg" ] && [ -f "${d}/AI_POLICY.md" ] && [ ! -L "${d}/AI_POLICY.md" ]; then echo "."
    fi
}

# ai_hooks_path <clone>: the value core.hooksPath must have for the hooks to be enforced.
# A repository without any of the three is held to the ordinary layout: it is missing .ai.
ai_hooks_path() {
    case "$(ai_dir "$1")" in
        .deps/wamp-ai) echo ".deps/wamp-ai/.githooks" ;;
        .)             echo ".githooks" ;;
        *)             echo ".ai/.githooks" ;;
    esac
}

# ai_admits_merge <clone> <integration branch ref>: can a maintainer's merge commit be made on the
# integration branch - does the commit-msg hook that runs there know about merges? No (or no hook
# to be found) means the bootstrap: fast-forward onto a signed tip.
#   .ai            the hook at the revision the integration branch pins
#   .              the hook as the integration branch has it
#   .deps/wamp-ai  the hook as checked out: no checkout of the integration branch moves it
ai_admits_merge() {
    local d="$1" ref="$2" sha
    case "$(ai_dir "${d}")" in
        .ai)
            sha="$(git -C "${d}" ls-tree "${ref}" .ai 2>/dev/null | awk '{print $3}')"
            [ -n "${sha}" ] || return 1
            git -C "${d}/.ai" cat-file -e "${sha}" 2>/dev/null || git -C "${d}/.ai" fetch -q origin 2>/dev/null || true
            git -C "${d}/.ai" show "${sha}:.githooks/commit-msg" 2>/dev/null | grep -qi 'merge' ;;
        .)  git -C "${d}" show "${ref}:.githooks/commit-msg" 2>/dev/null | grep -qi 'merge' ;;
        .deps/wamp-ai) grep -qi 'merge' "${d}/.deps/wamp-ai/.githooks/commit-msg" 2>/dev/null ;;
        *)  return 1 ;;
    esac
}
