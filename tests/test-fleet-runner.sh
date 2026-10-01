#!/usr/bin/env bash
#
# Test fleet/apply-rollout.sh - rollouts as migrations (#64).
#
# A rollout is a script applied to each member of a cohort, and a marker in the member that says
# so. apply-rollout.sh is the one credential-free step: it runs the rollout's apply.sh, pins the
# member's .fleet/ submodule to the definition it came from, writes the marker
# .waves/<cohort>/<NNNN>-<name>.toml, and makes one commit. What this pins:
#
#   - the exit codes an orchestration loop relies on to re-run a half-finished wave
#     (0 applied / 10 already applied / 11 dirty tree / 12 apply.sh failed / 13 an earlier rollout
#     is missing / 14 not a member / 2 usage);
#   - nothing is skipped, and what is already in place is ADOPTED (marker without a script hash);
#   - .fleet/ comes from the LOCAL definition clone only - proven with every non-local git
#     transport disabled - while .gitmodules records the canonical forge URL;
#   - the commit passes the real .ai commit-msg hook, and a footer that would not is refused
#     before anything is changed.
#
# Run: bash tests/test-fleet-runner.sh      (AI_JUSTFILE=<wamp-ai>/justfile for the real hook)
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/../fleet/apply-rollout.sh"
AI_JUSTFILE="${AI_JUSTFILE:-${HERE}/../../wamp-ai/justfile}"
HOOKS="$(dirname "${AI_JUSTFILE}")/.githooks"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
git config --global init.defaultBranch main
# NO NETWORK, by construction: only the local file transport is allowed. Any attempt to reach the
# (deliberately unreachable) canonical URL fails the test.
export GIT_ALLOW_PROTOCOL=file
unset FLEET_NAME
PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -8; FAIL=$((FAIL + 1)); }
run() { "${RUN}" "$@" > "${WORK}/log" 2>&1; }
URL="https://github.com/acme/acme-fleet.git"

# --- the definition repository: one cohort, two rollouts (a third added later) ------------------
DEF="${WORK}/acme-fleet"; q git init "$DEF"
cat > "$DEF/fleet.toml" <<'EOF'
schema = 2
[[cohort]]
name = "core"
description = "test cohort"
[[repo]]
name = "alpha"
slug = "acme/alpha"
default_branch = "main"
cohorts = ["core"]
[[repo]]
name = "bravo"
slug = "acme/bravo"
default_branch = "main"
cohorts = ["core"]
[[repo]]
name = "outsider"
slug = "acme/outsider"
default_branch = "main"
cohorts = []
EOF
mkroll() {  # mkroll <NNNN-name> <apply body> [check body]
  local d="$DEF/rollouts/core/$1"; mkdir -p "$d"
  printf 'name = "%s"\ncohort = "core"\ndescription = "test rollout"\n' "$1" > "$d/rollout.toml"
  printf '#!/usr/bin/env bash\nset -e\n%s\n' "$2" > "$d/apply.sh"; chmod +x "$d/apply.sh"
  [ -z "${3:-}" ] || { printf '#!/usr/bin/env bash\n%s\n' "$3" > "$d/check.sh"; chmod +x "$d/check.sh"; }
  echo "issue text" > "$d/issue.md"
}
mkroll 0001-first  'echo "first for ${FLEET_REPO} (${FLEET_SLUG}) in ${FLEET_NAME}/${FLEET_COHORT}" > FIRST.txt' 'test -f FIRST.txt'
mkroll 0002-second 'echo second >> SECOND.txt; git add SECOND.txt'
q git -C "$DEF" add -A; q git -C "$DEF" commit -m "definition: two rollouts"
q git -C "$DEF" remote add upstream "$URL"
DEF1="$(git -C "$DEF" rev-parse HEAD)"

member() {  # member <name>  -> a clone on its rollout branch
  local m="${WORK}/$1"; q git init "$m"; echo "$1" > "$m/README.md"
  q git -C "$m" add -A; q git -C "$m" commit -m seed; q git -C "$m" checkout -b fix_5
}

echo "== applying a rollout: one commit, the change, the pin, the marker"
member alpha; A="${WORK}/alpha"
run "$A" "$DEF" core/0001-first --issue 5; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit 0" "rc=$rc"
[ "$(git -C "$A" rev-list --count main..fix_5)" = 1 ] && ok "exactly one commit" || bad "one commit"
[ "$(git -C "$A" log -1 --format=%s)" = "Apply rollout core/0001-first (#5)" ] && ok "subject" || bad "subject" "$(git -C "$A" log -1 --format=%s)"
grep -qx "first for alpha (acme/alpha) in acme/core" "$A/FIRST.txt" && ok "apply.sh ran with its environment" || bad "apply.sh environment" "$(cat "$A/FIRST.txt" 2>&1)"
[ "$(git -C "$A" ls-tree HEAD .fleet | awk '{print $3}')" = "$DEF1" ] && ok ".fleet/ pinned to the definition's commit" || bad ".fleet pin"
[ "$(git -C "$A" config -f .gitmodules --get submodule..fleet.url)" = "$URL" ] && ok ".gitmodules records the canonical forge URL" || bad ".gitmodules url"
[ -f "$A/.fleet/fleet.toml" ] && ok ".fleet/ is populated (from the local clone: no other transport is allowed here)" || bad ".fleet populated"
mk="$A/.waves/core/0001-first.toml"
python3 - "$mk" "$DEF1" "$DEF" <<'PY' > "${WORK}/log" 2>&1 && ok "marker: rollout, fleet@commit, script hash, issue, time" || bad "marker" "$(cat "$mk" 2>&1)"
import sys, tomllib, hashlib, datetime
m = tomllib.load(open(sys.argv[1], "rb"))
h = "sha256:" + hashlib.sha256(open(sys.argv[3] + "/rollouts/core/0001-first/apply.sh", "rb").read()).hexdigest()
assert m["rollout"] == "core/0001-first", m
assert m["fleet"] == "https://github.com/acme/acme-fleet@" + sys.argv[2], m
assert m["script"] == h, m
assert m["issue"] == 5 and isinstance(m["applied"], datetime.datetime), m
assert "adopted" not in m, m
PY
[ -z "$(git -C "$A" status --porcelain)" ] && ok "tree clean afterwards" || bad "tree clean"

echo "== re-running is a no-op with its own exit code"
before="$(git -C "$A" rev-parse HEAD)"
run "$A" "$DEF" core/0001-first --issue 5; rc=$?
[ "$rc" = 10 ] && [ "$(git -C "$A" rev-parse HEAD)" = "$before" ] && ok "exit 10, nothing changed" || bad "exit 10" "rc=$rc"

echo "== a dirty tree"
echo x > "$A/stray"; run "$A" "$DEF" core/0002-second --issue 5; rc=$?
[ "$rc" = 11 ] && [ "$(git -C "$A" rev-parse HEAD)" = "$before" ] && ok "exit 11, nothing changed" || bad "exit 11" "rc=$rc"
rm -f "$A/stray"

echo "== nothing is skipped: an earlier rollout must be there, or be adoptable"
member bravo; B="${WORK}/bravo"; b0="$(git -C "$B" rev-parse HEAD)"
run "$B" "$DEF" core/0002-second --issue 6; rc=$?
[ "$rc" = 13 ] && [ "$(git -C "$B" rev-parse HEAD)" = "$b0" ] && [ -z "$(git -C "$B" status --porcelain)" ] && ok "0002 without 0001: exit 13, nothing changed" || bad "exit 13" "rc=$rc"
echo "by hand" > "$B/FIRST.txt"; q git -C "$B" add -A; q git -C "$B" commit -m "0001, applied by hand before markers existed"
run "$B" "$DEF" core/0002-second --issue 6; rc=$?
[ "$rc" = 0 ] && [ -f "$B/.waves/core/0002-second.toml" ] && ok "0001 in place by hand: 0002 applies" || bad "adopt + apply" "rc=$rc"
grep -q '^adopted = true' "$B/.waves/core/0001-first.toml" 2>/dev/null && ! grep -q '^script' "$B/.waves/core/0001-first.toml" \
    && ok "0001 is adopted: a marker without a script hash" || bad "adopted marker"
git -C "$B" log -1 --format=%B | grep -q "Adopted, already in place: core/0001-first" && ok "the commit says what was adopted" || bad "commit body"
grep -qx second "$B/SECOND.txt" && ok "0002's apply.sh ran" || bad "0002 ran"

echo "== membership"
member outsider; run "${WORK}/outsider" "$DEF" core/0001-first --issue 7; rc=$?
[ "$rc" = 14 ] && ok "a repository in the fleet but not in the cohort: exit 14" || bad "exit 14" "rc=$rc"
member stranger; run "${WORK}/stranger" "$DEF" core/0001-first --issue 7; rc=$?
[ "$rc" = 14 ] && ok "a repository not in the inventory: exit 14" || bad "exit 14 (stranger)" "rc=$rc"

echo "== a later definition commit: .fleet/ moves to it, again from local objects"
mkroll 0003-broken 'echo half > HALF.txt; exit 7'
q git -C "$DEF" add -A; q git -C "$DEF" commit -m "definition: a third rollout"; DEF2="$(git -C "$DEF" rev-parse HEAD)"
run "$A" "$DEF" core/0002-second --issue 5; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$A" ls-tree HEAD .fleet | awk '{print $3}')" = "$DEF2" ] && ok "0002 applied; .fleet/ at the new commit" || bad ".fleet updated" "rc=$rc"
grep -q "@${DEF2}\"" "$A/.waves/core/0002-second.toml" && grep -q "@${DEF1}\"" "$A/.waves/core/0001-first.toml" \
    && ok "each marker names the definition commit ITS rollout came from" || bad "markers' commits"

echo "== a failing apply.sh"
a0="$(git -C "$A" rev-parse HEAD)"
run "$A" "$DEF" core/0003-broken --issue 5; rc=$?
[ "$rc" = 12 ] && [ "$(git -C "$A" rev-parse HEAD)" = "$a0" ] && ok "exit 12, nothing committed" || bad "exit 12" "rc=$rc"
[ -f "$A/HALF.txt" ] && [ ! -e "$A/.waves/core/0003-broken.toml" ] && ok "the tree is left for inspection; no marker" || bad "tree left, no marker"
rm -f "$A/HALF.txt"

echo "== a fresh clone of a member: .fleet/ recorded but not initialised"
q git clone "$A" "${WORK}/fresh/alpha" 2>/dev/null || { mkdir -p "${WORK}/fresh"; q git clone "$A" "${WORK}/fresh/alpha"; }
F="${WORK}/fresh/alpha"; q git -C "$F" checkout fix_5
rm -rf "$DEF/rollouts/core/0003-broken"; mkroll 0003-third 'echo third > THIRD.txt'
q git -C "$DEF" add -A; q git -C "$DEF" commit -m "definition: replace the broken rollout"; DEF3="$(git -C "$DEF" rev-parse HEAD)"
run "$F" "$DEF" core/0003-third --issue 5; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$F" ls-tree HEAD .fleet | awk '{print $3}')" = "$DEF3" ] && [ -f "$F/.fleet/fleet.toml" ] \
    && ok "initialised from the local definition clone, pinned, applied" || bad "uninitialised .fleet" "rc=$rc"

echo "== the definition must be in a committed state"
echo "# edit" >> "$DEF/rollouts/core/0003-third/apply.sh"
member charlie 2>/dev/null; run "$A" "$DEF" core/0003-third --issue 5; rc=$?
[ "$rc" = 2 ] && grep -q "uncommitted changes" "${WORK}/log" && ok "uncommitted rollout: refused (exit 2)" || bad "uncommitted definition" "rc=$rc"
q git -C "$DEF" checkout -- rollouts

echo "== the commit and the .ai commit-msg hook"
a1="$(git -C "$A" rev-parse HEAD)"
run "$A" "$DEF" core/0003-third --issue 5 --footer "Generated by the maintainers' tooling"; rc=$?
[ "$rc" = 2 ] && [ "$(git -C "$A" rev-parse HEAD)" = "$a1" ] && [ -z "$(git -C "$A" status --porcelain)" ] \
    && ok "a footer the hook would reject is refused BEFORE anything changes" || bad "bad footer" "rc=$rc"
if [ -x "${HOOKS}/commit-msg" ]; then
  q git -C "$A" config core.hooksPath "${HOOKS}"
  run "$A" "$DEF" core/0003-third --issue 5 --footer "Note: This work was completed with AI assistance (Claude Code)."; rc=$?
  [ "$rc" = 0 ] && git -C "$A" log -1 --format=%B | grep -qx "Note: This work was completed with AI assistance (Claude Code)." \
      && ok "the runner's commit passes the REAL hook, with the sanctioned footer" || bad "real hook" "rc=$rc"
else
  echo "  skip [no .ai hook at ${HOOKS}; set AI_JUSTFILE]"
fi

echo "== usage"
run "$A" "$DEF" core/0001-first; [ $? = 2 ] && ok "--issue is required" || bad "--issue required"
run "$A" "$DEF" nonsense --issue 5; [ $? = 2 ] && ok "a malformed rollout id" || bad "malformed id"
run "$A" "$DEF" core/0009-nope --issue 5; [ $? = 2 ] && ok "an unknown rollout" || bad "unknown rollout"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
