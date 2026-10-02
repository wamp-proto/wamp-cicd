#!/usr/bin/env bash
#
# Test the audit file through the workflow (#63).
#
# Every branch carries its AI-assistance disclosure, `.audit/<user>_<branch>.md`. `new-branch`
# generates it through the `.ai` submodule - and in a repository WITHOUT `.ai` (this one, wamp-ai,
# anything not yet onboarded) it printed one line saying it had not, which scrolled by: the file
# was forgotten on four branches in a row and added by hand after the work was done. Nothing
# later noticed. Now:
#
#   - `new-branch` generates the file without `.ai` too - the SAME file the `.ai` generator
#     writes (compared here against the real one, so the two cannot drift apart);
#   - `where` shows it, or says MISSING;
#   - `publish` warns, and `land` refuses, a branch without one.
#
# Run: bash tests/test-audit-file.sh       (AI_JUSTFILE=<wamp-ai>/justfile for the comparison)
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
AI_JUSTFILE="${AI_JUSTFILE:-${HERE}/../.deps/wamp-ai/justfile}"
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

# fixture <dir> <ai: none|real>   - the exchange path names the user, as on the AI host
fixture() {
  local R="$1"
  mkdir -p "$R/scm/repos/alice"; q git init --bare -b main "$R/scm/repos/alice/widget.git"; q git init -b main "$R/repo"
  ( cd "$R/repo"
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    [ "$2" = real ] && { mkdir -p .ai; cp "$AI_JUSTFILE" .ai/justfile; }
    echo seed > README.md
    q git add -A; q git commit -m seed
    q git remote add origin "$R/scm/repos/alice/widget.git"; q git push origin main )
}

echo "== new-branch WITHOUT .ai generates the audit file"
R="${WORK}/noai"; fixture "$R" none
( cd "$R/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "new-branch: exit 0" || bad "new-branch: exit 0" "rc=$rc"
f=".audit/alice_fix_7.md"
git -C "$R/repo" show --stat --format= HEAD | grep -q "$f" && ok "$f is committed in the branch's first commit" || bad "committed"
c="$(git -C "$R/repo" show "HEAD:$f" 2>/dev/null)"
grep -qx 'Related issue(s): #7' <<<"$c" && grep -qx 'Submitted by: @alice' <<<"$c" && grep -qx 'Branch: alice:fix_7' <<<"$c" \
    && grep -qx "Date: $(date -u +%Y-%m-%d)" <<<"$c" && ok "it names the user, the date, the issue and the branch" || bad "content" "$c"
grep -q "Audit file $f (issue #7)" "${WORK}/log" && ! grep -q "no audit file was generated" "${WORK}/log" && ok "and says so (the old NOTE is gone)" || bad "message"
[ "$(git --git-dir="$R/scm/repos/alice/widget.git" rev-parse fix_7)" = "$(git -C "$R/repo" rev-parse HEAD)" ] && ok "published" || bad "published"

echo "== ...and it is the file the .ai generator writes"
if [ -f "$AI_JUSTFILE" ]; then
  R2="${WORK}/ai"; fixture "$R2" real
  ( cd "$R2/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1
  if [ -f "$R2/repo/$f" ] && diff -u "$R2/repo/$f" "$R/repo/$f" > "${WORK}/log" 2>&1; then
    ok "same name, byte-identical content"
  else
    bad "same name, byte-identical content" "$(ls "$R2/repo/.audit" 2>&1)"
  fi
else
  echo "  skip [no wamp-ai justfile at ${AI_JUSTFILE}; set AI_JUSTFILE]"
fi

echo "== where: shows the audit file, or MISSING"
( cd "$R/repo" && just where ) > "${WORK}/log" 2>&1
grep -q "audit file   $f" "${WORK}/log" && ok "on the branch with one" || bad "where shows it"
( cd "$R/repo" && q git checkout main && just where ) > "${WORK}/log" 2>&1
grep -q "audit file" "${WORK}/log" && bad "no audit line on the integration branch" || ok "no audit line on the integration branch"
( cd "$R/repo" && q git checkout -b fix_8 && just where ) > "${WORK}/log" 2>&1
grep -q "audit file   MISSING for this branch - expected .audit/alice_fix_8.md" "${WORK}/log" && ok "MISSING, with the expected path, on a branch without" || bad "where MISSING"

echo "== publish warns, land refuses, a branch without an audit file"
( cd "$R/repo" && echo x > x && q git add -A && q git commit -m work && just publish ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "WARNING: fix_8 has no audit file yet" "${WORK}/log" && ok "publish: warns, still publishes" || bad "publish warns" "rc=$rc"
before="$(git -C "$R/repo" rev-parse main)"
( cd "$R/repo" && just land ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q "REFUSING: fix_8 has no audit file" "${WORK}/log" && grep -q ".audit/alice_fix_8.md" "${WORK}/log" \
    && ok "land: refuses, naming the file to add" || bad "land refuses" "rc=$rc"
[ "$(git -C "$R/repo" rev-parse main)" = "$before" ] && [ "$(git -C "$R/repo" symbolic-ref --short HEAD)" = fix_8 ] && ok "nothing moved" || bad "nothing moved"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
