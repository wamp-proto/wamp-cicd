#!/usr/bin/env bash
#
# Test where a repository has the AI policy hooks - in all three layouts (#69).
#
#   .ai             the wamp-ai submodule: every ordinary repository
#   .deps/wamp-ai   a pinned checkout (deps.toml): a tooling source, which carries no submodules
#   .               wamp-ai itself: its own .githooks/
#
# Until #69 only the first existed, so a tooling source was "a repository without hooks": nothing
# enforced, nothing reported. What this pins:
#
#   - workflow.just (`_workflow-ai-dir`, `_workflow-hooks-state`, `_workflow-hooks-fix`) and
#     fleet/lib/aidir.sh give the same answer for the same layout;
#   - "pinned in deps.toml but not checked out" is reported as hooks MISSING, never as
#     "this repository has none";
#   - `just land` in a tooling source: the bootstrap question is asked of the hook that will
#     actually run there, and the answer says what to do about it.
#
# Run: bash tests/test-ai-dir.sh
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
git config --global protocol.file.allow always
git config --global init.defaultBranch main
# shellcheck source=/dev/null
. "${HERE}/../fleet/lib/aidir.sh"

PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; [ ! -f "${WORK}/log" ] || sed 's/^/         /' "${WORK}/log" | tail -12; FAIL=$((FAIL + 1)); }

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gitsign" <<'STUB'
#!/usr/bin/env bash
printf -- '-----BEGIN SIGNED MESSAGE-----\nc3R1Yg==\n-----END SIGNED MESSAGE-----\n'
echo "[GNUPG:] SIG_CREATED D 1 8 00 0 0" >&2
STUB
chmod +x "${WORK}/bin/gitsign"
export PATH="${WORK}/bin:${PATH}"
signed() { git -C "$1" cat-file -p "$2" | sed -n '1,12p' | grep -q '^gpgsig '; }

OLD_HOOK='#!/bin/sh
# old: nothing is committed on main
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] && { echo "ERROR: no commits on main" >&2; exit 1; }
exit 0'
NEW_HOOK='#!/bin/sh
# new: main takes a merge in progress, and nothing else
if [ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ]; then
    [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] || { echo "ERROR: not a merge" >&2; exit 1; }
fi
exit 0'
hook_into() { mkdir -p "$1/.githooks"; printf '%s\n' "$2" > "$1/.githooks/commit-msg"; chmod +x "$1/.githooks/commit-msg"; }

# The policy repository, with an old and a new hook.
AI="${WORK}/src/ai"; q git init "$AI"; hook_into "$AI" "$OLD_HOOK"; echo policy > "$AI/AI_POLICY.md"
q git -C "$AI" add -A; q git -C "$AI" commit -m "old hook"; AI_OLD="$(git -C "$AI" rev-parse HEAD)"
hook_into "$AI" "$NEW_HOOK"; q git -C "$AI" commit -am "hook admits a maintainer merge"; AI_NEW="$(git -C "$AI" rev-parse HEAD)"

# repo <dir>: a repository that runs workflow.just as its own file (as wamp-cicd does).
repo() {
  q git init "$1"; cp "$WORKFLOW_JUST" "$1/workflow.just"; printf "import 'workflow.just'\n" > "$1/justfile"
  echo ".deps/" > "$1/.gitignore"; echo seed > "$1/README.md"
}
wf() { ( cd "$1" && just "${@:2}" ) 2>"${WORK}/log"; }
deps_toml() { printf '[wamp-ai]\nurl = "%s"\ncommit = "%s"\n' "$AI" "$2" > "$1/deps.toml"; }

echo "== no AI tooling at all"
N="${WORK}/none"; repo "$N"; q git -C "$N" add -A; q git -C "$N" commit -m seed
[ -z "$(wf "$N" _workflow-ai-dir)" ] && [ -z "$(ai_dir "$N")" ] && ok "no directory, by both" || bad "none: dir"
[ "$(wf "$N" _workflow-hooks-state)" = "na|no .ai/.githooks in this repository" ] && ok "hooks state: not applicable" || bad "none: state" "$(wf "$N" _workflow-hooks-state)"

echo "== .ai: the submodule"
S="${WORK}/sub"; repo "$S"; q git -C "$S" submodule add "$AI" .ai; q git -C "$S" add -A; q git -C "$S" commit -m seed
[ "$(wf "$S" _workflow-ai-dir)" = .ai ] && [ "$(ai_dir "$S")" = .ai ] && ok "directory: .ai, by both" || bad "sub: dir"
[ "$(ai_hooks_path "$S")" = .ai/.githooks ] && [ "$(wf "$S" _workflow-hooks-fix)" = "just --justfile .ai/justfile setup-repo" ] && ok "hooks path and the fix, as before" || bad "sub: path/fix"
[ "$(wf "$S" _workflow-hooks-state)" = "bad|NOT ENFORCED - core.hooksPath is unset" ] && ok "unset: not enforced" || bad "sub: unset"
q git -C "$S" config core.hooksPath .ai/.githooks
[ "$(wf "$S" _workflow-hooks-state)" = "ok|ENFORCED (.ai/.githooks)" ] && ok "set: enforced" || bad "sub: set" "$(wf "$S" _workflow-hooks-state)"

echo "== .deps/wamp-ai: a tooling source's pinned checkout"
D="${WORK}/deps"; repo "$D"; deps_toml "$D" "$AI_NEW"; q git -C "$D" add -A; q git -C "$D" commit -m seed
[ "$(wf "$D" _workflow-ai-dir)" = .deps/wamp-ai ] && [ "$(ai_dir "$D")" = .deps/wamp-ai ] && ok "pinned in deps.toml, not checked out: the directory is still .deps/wamp-ai" || bad "deps: dir (unpopulated)"
case "$(wf "$D" _workflow-hooks-state)" in "bad|NOT ENFORCED - .deps/wamp-ai is pinned in deps.toml but not checked out"*) ok "...and that is reported as hooks MISSING, not as 'has none'" ;; *) bad "deps: unpopulated state" "$(wf "$D" _workflow-hooks-state)" ;; esac
[ "$(wf "$D" _workflow-hooks-fix)" = "just deps && git config core.hooksPath .deps/wamp-ai/.githooks" ] && ok "the fix: just deps, then core.hooksPath" || bad "deps: fix" "$(wf "$D" _workflow-hooks-fix)"
q bash "${HERE}/../scripts/deps.sh" sync --root "$D"
[ "$(wf "$D" _workflow-hooks-state)" = "bad|NOT ENFORCED - core.hooksPath is unset" ] && ok "checked out, core.hooksPath unset: not enforced" || bad "deps: unset" "$(wf "$D" _workflow-hooks-state)"
q git -C "$D" config core.hooksPath .ai/.githooks
case "$(wf "$D" _workflow-hooks-state)" in "bad|NOT ENFORCED - core.hooksPath is .ai/.githooks") ok "core.hooksPath pointing at .ai/ here: not enforced" ;; *) bad "deps: wrong path" ;; esac
q git -C "$D" config core.hooksPath "$(ai_hooks_path "$D")"
[ "$(wf "$D" _workflow-hooks-state)" = "ok|ENFORCED (.deps/wamp-ai/.githooks)" ] && ok "set to .deps/wamp-ai/.githooks: enforced" || bad "deps: set" "$(wf "$D" _workflow-hooks-state)"
( cd "$D" && just where ) > "${WORK}/log" 2>&1; grep -q "hooks        ENFORCED (.deps/wamp-ai/.githooks)" "${WORK}/log" && ok "just where shows it" || bad "deps: where"

echo "== .: wamp-ai itself"
W="${WORK}/self"; repo "$W"; hook_into "$W" "$NEW_HOOK"; echo policy > "$W/AI_POLICY.md"; q git -C "$W" add -A; q git -C "$W" commit -m seed
[ "$(wf "$W" _workflow-ai-dir)" = . ] && [ "$(ai_dir "$W")" = . ] && ok "directory: the repository itself, by both" || bad "self: dir" "$(wf "$W" _workflow-ai-dir)"
[ "$(ai_hooks_path "$W")" = .githooks ] && [ "$(wf "$W" _workflow-hooks-fix)" = "git config core.hooksPath .githooks" ] && ok "hooks path .githooks, and the fix" || bad "self: path/fix"
q git -C "$W" config core.hooksPath .githooks
[ "$(wf "$W" _workflow-hooks-state)" = "ok|ENFORCED (.githooks)" ] && ok "enforced" || bad "self: state" "$(wf "$W" _workflow-hooks-state)"
# An ordinary repository has AI_POLICY.md as a SYMLINK into .ai/ and may have hooks of its own:
# that must not make it "wamp-ai itself".
L="${WORK}/link"; repo "$L"; hook_into "$L" "$NEW_HOOK"; ln -s .ai/AI_POLICY.md "$L/AI_POLICY.md"
[ -z "$(ai_dir "$L")" ] && [ -z "$(wf "$L" _workflow-ai-dir)" ] && ok "a symlinked AI_POLICY.md does not make a repository 'wamp-ai itself'" || bad "symlink"

echo "== can the integration branch take a maintainer's merge? (fleet/lib/aidir.sh)"
ai_admits_merge "$N" main; [ $? != 0 ] && ok "no hooks to be found: no (as before)" || bad "admits: none"
q git -C "$S/.ai" checkout "$AI_OLD"; q git -C "$S" -c core.hooksPath=/dev/null commit -am "old hook pinned"   # (the fixture itself must get past the hook)
ai_admits_merge "$S" main; [ $? != 0 ] && ok ".ai pinned at the old hook: no" || bad "admits: sub old"
q git -C "$S/.ai" checkout "$AI_NEW"; q git -C "$S" -c core.hooksPath=/dev/null commit -am "new hook pinned"
ai_admits_merge "$S" main && ok ".ai pinned at the new hook: yes" || bad "admits: sub new"
ai_admits_merge "$D" main && ok ".deps/wamp-ai checked out with the new hook: yes" || bad "admits: deps new"
ai_admits_merge "$W" main && ok "wamp-ai itself, new hook on the branch: yes" || bad "admits: self new"

echo "== just land in a tooling source"
# landable <dir>: an exchange, a signer, and a published dev branch fix_7 with its audit file.
landable() {
  q git init --bare "$1.exchange.git"
  ( cd "$1"; q git remote add origin "$1.exchange.git"; q git push origin main
    q git config gpg.format x509; q git config gpg.x509.program "${WORK}/bin/gitsign"; q git config workflow.signingIdentity test@example.invalid
    q git checkout -b fix_7; echo work > work.txt; mkdir -p .audit; echo "Related issue(s): #7" > .audit/test_fix_7.md
    q git add -A; q git commit -m work; q git push origin fix_7 )
}
land() { ( cd "$1" && just land ) > "${WORK}/log" 2>&1; }
landable "$D"
land "$D"; rc=$?
[ "$rc" = 0 ] && signed "$D" main && [ "$(git -C "$D" log -1 --format=%p main | wc -w)" = 2 ] && ok ".deps/wamp-ai with a hook that admits a merge: lands as a signed merge" || bad "land: deps new" "rc=$rc"
D2="${WORK}/deps-old"; repo "$D2"; deps_toml "$D2" "$AI_OLD"; q git -C "$D2" add -A; q git -C "$D2" commit -m seed
q bash "${HERE}/../scripts/deps.sh" sync --root "$D2"; landable "$D2"; q git -C "$D2" config core.hooksPath .deps/wamp-ai/.githooks
before="$(git -C "$D2" rev-parse main)"
land "$D2"; rc=$?
[ "$rc" != 0 ] && grep -q "REFUSING: main cannot take a maintainer's merge yet" "${WORK}/log" && [ "$(git -C "$D2" rev-parse main)" = "$before" ] \
    && ok ".deps/wamp-ai with the old hook: refused, nothing moved" || bad "land: deps old" "rc=$rc"
grep -q "(.deps/wamp-ai at ${AI_OLD:0:7})" "${WORK}/log" && grep -q "Move the wamp-ai pin in deps.toml" "${WORK}/log" && grep -q "just deps" "${WORK}/log" \
    && ok "...naming the checkout, and the fix: move the pin, just deps" || bad "land: deps old message"
landable "$W"
land "$W"; rc=$?
[ "$rc" = 0 ] && signed "$W" main && ok "wamp-ai itself, the hook on main admits a merge: lands" || bad "land: self new" "rc=$rc"
W2="${WORK}/self-old"; repo "$W2"; hook_into "$W2" "$OLD_HOOK"; echo policy > "$W2/AI_POLICY.md"; q git -C "$W2" add -A; q git -C "$W2" commit -m seed
landable "$W2"; q git -C "$W2" config core.hooksPath .githooks
land "$W2"; rc=$?
[ "$rc" != 0 ] && grep -q "(.githooks/ on main)" "${WORK}/log" && grep -q "through the forge" "${WORK}/log" && ok "wamp-ai itself with the old hook on main: refused - the bootstrap, through the forge" || bad "land: self old" "rc=$rc"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
