#!/usr/bin/env bash
#
# Test `new-branch` in a repository that does not track `.audit/` yet (#51).
#
# The first Way-A branch of a repository creates `.audit/`. `git status --porcelain` reports an
# untracked DIRECTORY as `?? .audit/`, not the file inside it; the recipe took that for the audit
# file, ran `sed -i` on a directory, and died - leaving the branch created with nothing committed
# and nothing pushed. Seen in the first fleet rollout (the repositories without `.audit/`), and it
# would hit every repository still to be onboarded. The other tests use fixtures that track
# `.audit/` already, which is why none of them saw it.
#
# Run: bash tests/test-new-branch-audit.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -8; FAIL=$((FAIL + 1)); }

# fixture <dir> <audit tracked: yes|no>
fixture() {
  local R="$1"
  mkdir -p "$R"; q git init --bare -b main "$R/exchange.git"; q git init -b main "$R/repo"
  ( cd "$R/repo"
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    mkdir -p .ai
    cat > .ai/justfile <<'AIEOF'
generate-audit-file:
    #!/usr/bin/env bash
    root="$(git rev-parse --show-toplevel)"
    mkdir -p "${root}/.audit"
    printf 'Related issue(s): TBD\n' > "${root}/.audit/oberstet_audit.md"
AIEOF
    echo seed > README.md
    [ "$2" = yes ] && { mkdir -p .audit; printf 'placeholder\n' > .audit/.gitkeep; }
    q git add -A; q git commit -m seed
    q git remote add origin "$R/exchange.git"; q git push origin main )
}

for tracked in no yes; do
  echo "== .audit/ tracked before: ${tracked}"
  R="${WORK}/${tracked}"; fixture "$R" "$tracked"
  ( cd "$R/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "new-branch: exit 0" || bad "new-branch: exit 0" "rc=$rc"
  [ "$(git -C "$R/repo" symbolic-ref --short HEAD)" = fix_7 ] && ok "on fix_7" || bad "on fix_7"
  git -C "$R/repo" show --stat --format= HEAD | grep -q '\.audit/oberstet_audit.md' && ok "the audit file is committed" || bad "the audit file is committed"
  git -C "$R/repo" show HEAD:.audit/oberstet_audit.md 2>/dev/null | grep -qx 'Related issue(s): #7' && ok "it names issue #7" || bad "it names issue #7"
  [ -z "$(git -C "$R/repo" status --porcelain)" ] && ok "working tree clean afterwards" || bad "working tree clean afterwards"
  [ "$(git --git-dir="$R/exchange.git" rev-parse -q --verify refs/heads/fix_7)" = "$(git -C "$R/repo" rev-parse HEAD)" ] && ok "published to the exchange" || bad "published"
done

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
