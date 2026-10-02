#!/usr/bin/env bash
#
# Test scripts/deps.sh - dependencies as plain checkouts at pinned commits (#69).
#
# A repository that must not carry submodules (wamp-cicd, wamp-ai: every other repository pins
# THEM) says in deps.toml which commit of which repository it depends on, and `deps.sh sync`
# makes .deps/<name> exactly that. What this pins:
#
#   - sync from nothing, in sync, after the pin moved, and over a checkout at the wrong commit;
#   - check says so without changing anything, and a modified checkout is never overwritten;
#   - --from takes the objects from a local clone while the recorded origin stays the URL -
#     proven with every non-local git transport disabled;
#   - a deps.toml that is not exactly name / url / full commit ID is refused, never guessed;
#   - .deps/ must be ignored, or sync refuses (it would otherwise be committed as a repository).
#
# Run: bash tests/test-deps.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPS="${HERE}/../scripts/deps.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
git config --global init.defaultBranch main
export GIT_ALLOW_PROTOCOL=file    # no network, by construction
PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -6; FAIL=$((FAIL + 1)); }
run() { bash "${DEPS}" "$@" > "${WORK}/log" 2>&1; }

# A dependency with two commits, and the repository that depends on it.
SRC="${WORK}/src/tool"; q git init "$SRC"; echo v1 > "$SRC/v"; q git -C "$SRC" add -A; q git -C "$SRC" commit -m v1; C1="$(git -C "$SRC" rev-parse HEAD)"
echo v2 > "$SRC/v"; q git -C "$SRC" commit -am v2; C2="$(git -C "$SRC" rev-parse HEAD)"
R="${WORK}/repo"; q git init "$R"; echo ".deps/" > "$R/.gitignore"; q git -C "$R" add -A; q git -C "$R" commit -m seed
head_of() { git -C "$R/.deps/$1" rev-parse HEAD 2>/dev/null; }

echo "== no deps.toml"
run sync --root "$R"; [ $? = 0 ] && grep -q "nothing to do" "${WORK}/log" && ok "sync: nothing to do, exit 0" || bad "sync without deps.toml"
run check --root "$R"; [ $? = 0 ] && ok "check: exit 0" || bad "check without deps.toml"

echo "== set, get"
run set --root "$R" tool "$SRC" "$C1"; [ $? = 0 ] && ok "set writes a pin" || bad "set"
[ "$(bash "$DEPS" get --root "$R" tool)" = "$C1 $SRC" ] && ok "get prints <commit> <url>" || bad "get" "$(bash "$DEPS" get --root "$R" tool 2>&1)"
bash "$DEPS" get --root "$R" nope >/dev/null 2>&1; [ $? = 1 ] && ok "get of an unknown name: exit 1" || bad "get unknown"
run set --root "$R" tool "$SRC" abc1234; [ $? = 2 ] && grep -q "full commit ID" "${WORK}/log" && ok "set refuses an abbreviated commit" || bad "set short commit"
run set --root "$R" Tool "$SRC" "$C1"; [ $? = 2 ] && ok "set refuses a name that is not a plain directory name" || bad "set bad name"
run set --root "$R" ../x "$SRC" "$C1"; [ $? = 2 ] && ok "set refuses a name that leaves .deps/" || bad "set traversal"
run set --root "$R" other "$SRC" "$C2"; run set --root "$R" tool "$SRC" "$C1"
[ "$(grep -c '^\[' "$R/deps.toml")" = 2 ] && [ "$(grep '^\[' "$R/deps.toml" | head -1)" = "[other]" ] && ok "set keeps the other pins, sorted" || bad "set keeps others" "$(cat "$R/deps.toml")"
before="$(cat "$R/deps.toml")"; run set --root "$R" tool "$SRC" "$C1"; [ "$(cat "$R/deps.toml")" = "$before" ] && ok "set of the same pin changes nothing" || bad "set idempotent"

echo "== sync"
run check --root "$R"; [ $? = 1 ] && grep -q "MISSING" "${WORK}/log" && ok "check before sync: missing, exit 1" || bad "check missing"
run sync --root "$R"; rc=$?
[ "$rc" = 0 ] && [ "$(head_of tool)" = "$C1" ] && [ "$(head_of other)" = "$C2" ] && ok "sync from nothing: both checkouts at their pins" || bad "sync fresh" "rc=$rc"
[ "$(git -C "$R/.deps/tool" config --get remote.origin.url)" = "$SRC" ] && ok "origin of the checkout is the URL" || bad "origin url"
[ -z "$(git -C "$R" status --porcelain)" ] || [ "$(git -C "$R" status --porcelain)" = "?? deps.toml" ] && ok ".deps/ does not show up in the repository's status" || bad "status" "$(git -C "$R" status --porcelain)"
run check --root "$R"; [ $? = 0 ] && ok "check after sync: exit 0" || bad "check ok"
run sync --root "$R"; [ $? = 0 ] && [ "$(grep -c '  ok ' "${WORK}/log")" = 2 ] && ok "sync again: nothing to do" || bad "sync idempotent"
run set --root "$R" tool "$SRC" "$C2"; run check --root "$R"; [ $? = 1 ] && grep -q "AT ${C1^^}" "${WORK}/log" && ok "the pin moved: check says which commit is there" || bad "check moved"
run sync --root "$R"; [ $? = 0 ] && [ "$(head_of tool)" = "$C2" ] && ok "sync moves the checkout to the new pin" || bad "sync moved"
q git -C "$R/.deps/tool" checkout "$C1"; run sync --root "$R"; [ $? = 0 ] && [ "$(head_of tool)" = "$C2" ] && ok "a checkout at the wrong commit is put back" || bad "sync wrong commit"

echo "== a modified checkout is never overwritten"
echo local > "$R/.deps/tool/v"
run check --root "$R"; [ $? = 1 ] && grep -q "MODIFIED" "${WORK}/log" && ok "check: modified, exit 1" || bad "check modified"
run sync --root "$R"; [ $? = 1 ] && grep -qx local "$R/.deps/tool/v" && ok "sync: refuses, the change is still there" || bad "sync modified"
q git -C "$R/.deps/tool" checkout -- v

echo "== --from: objects from a local clone, origin stays the URL"
R2="${WORK}/repo2"; q git init "$R2"; echo ".deps/" > "$R2/.gitignore"
URL="https://forge.invalid/acme/tool.git"
run set --root "$R2" tool "$URL" "$C2"
run sync --root "$R2"; [ $? = 1 ] && grep -q "FAILED" "${WORK}/log" && ok "without --from the (unreachable) URL fails, exit 1" || bad "unreachable"
run sync --root "$R2" --from "tool=$SRC"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$R2/.deps/tool" rev-parse HEAD)" = "$C2" ] && ok "with --from: synced without the network" || bad "--from" "rc=$rc"
[ "$(git -C "$R2/.deps/tool" config --get remote.origin.url)" = "$URL" ] && ok "and origin is the canonical URL" || bad "--from origin"
# a detached checkout as the source (a submodule checkout is one): the commit is HEAD, on no branch
DET="${WORK}/det"; q git clone "$SRC" "$DET"; q git -C "$DET" checkout --detach "$C1"; q git -C "$DET" branch -D main
R3="${WORK}/repo3"; q git init "$R3"; echo ".deps/" > "$R3/.gitignore"; run set --root "$R3" tool "$URL" "$C1"
run sync --root "$R3" --from "tool=$DET"; [ $? = 0 ] && [ "$(git -C "$R3/.deps/tool" rev-parse HEAD)" = "$C1" ] && ok "--from a detached checkout" || bad "--from detached"

echo "== .deps/ must be ignored"
R4="${WORK}/repo4"; q git init "$R4"; run set --root "$R4" tool "$SRC" "$C1"
run sync --root "$R4"; [ $? = 2 ] && grep -q "not ignored" "${WORK}/log" && [ ! -e "$R4/.deps" ] && ok "sync refuses, nothing created" || bad "not ignored"

echo "== a deps.toml that is not exactly name / url / commit"
tomlcase() {  # tomlcase <label> <expected message> <<< content
  cat > "$R4/deps.toml"; run check --root "$R4"; rc=$?
  [ "$rc" = 2 ] && grep -q "$2" "${WORK}/log" && ok "$1" || bad "$1" "rc=$rc"
}
tomlcase "a branch name instead of a commit" "full commit ID" <<EOF2
[tool]
url = "$SRC"
commit = "main"
EOF2
tomlcase "no url" "needs url" <<EOF2
[tool]
commit = "$C1"
EOF2
tomlcase "an unknown key" "unknown key" <<EOF2
[tool]
url = "$SRC"
commit = "$C1"
branch = "main"
EOF2
tomlcase "not TOML" "deps.toml" <<EOF2
[tool
EOF2

echo "== usage"
run frobnicate; [ $? = 2 ] && ok "an unknown mode" || bad "unknown mode"
run sync --root "$R" nope; [ $? = 2 ] && grep -q "no \[nope\]" "${WORK}/log" && ok "sync of a name deps.toml does not have" || bad "sync unknown name"
q git -C "$R/.deps/tool" checkout "$C1"; q git -C "$R/.deps/other" checkout "$C1"
run sync --root "$R" other; [ $? = 0 ] && [ "$(head_of other)" = "$C2" ] && [ "$(head_of tool)" = "$C1" ] && ok "sync <name>: only that one" || bad "sync one name"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
