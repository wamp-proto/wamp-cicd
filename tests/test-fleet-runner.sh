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
AI_JUSTFILE="${AI_JUSTFILE:-${HERE}/../.deps/wamp-ai/justfile}"
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
# Hermetic: the runner may look for FLEET_DEF_URL in a fleet's <fleet>.env - never in the real one.
export FLEET_CONFIG_DIR="${WORK}/no-config"
PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -8; FAIL=$((FAIL + 1)); }
# The definition here has no forge to be landed on; the refusal of an unlanded one has its own
# section below, which calls the runner without the flag.
run() { "${RUN}" "$@" --allow-unlanded > "${WORK}/log" 2>&1; }
strict() { "${RUN}" "$@" > "${WORK}/log" 2>&1; }
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

echo "== --repo: the inventory name, when the clone's directory is named differently"
q git clone "$B" "${WORK}/some-other-dir"; O="${WORK}/some-other-dir"; q git -C "$O" checkout fix_5
run "$O" "$DEF" core/0003-third --issue 6; rc=$?
[ "$rc" = 14 ] && ok "by directory name it is not a member (exit 14)" || bad "dir name" "rc=$rc"
run "$O" "$DEF" core/0003-third --issue 6 --repo bravo; rc=$?
[ "$rc" = 0 ] && [ -f "$O/.waves/core/0003-third.toml" ] && grep -qx third "$O/THIRD.txt" && ok "--repo bravo: applied" || bad "--repo" "rc=$rc"

echo "== what is next (fleet/lib/rollouts.sh)"
# shellcheck source=/dev/null
. "${HERE}/../fleet/lib/rollouts.sh"
[ "$(rollouts_of "$DEF" core | tr '\n' ' ')" = "0001-first 0002-second 0003-third " ] && ok "a cohort's rollouts, in order" || bad "rollouts_of"
[ -z "$(next_rollout "$A" fix_5 "$DEF" core)" ] && [ "$(applied_count "$A" fix_5 "$DEF" core)" = "3/3" ] && ok "alpha has all three: nothing is next" || bad "next: alpha"
[ "$(next_rollout "$B" fix_5 "$DEF" core)" = "0003-third" ] && [ "$(applied_count "$B" fix_5 "$DEF" core)" = "2/3" ] && ok "bravo: 0003-third is next" || bad "next: bravo"
[ "$(next_rollout "$B" main "$DEF" core)" = "0001-first" ] && ok "on a branch without markers (not landed): the first one is next" || bad "next: unlanded"
[ "$(default_ref "$A" main)" = main ] && ok "default_ref: the local branch when there is no upstream" || bad "default_ref"

echo "== lag check (fleet/lag-check.sh), as a member's CI runs it"
LAG="${HERE}/../fleet/lag-check.sh"
lag() { ( cd "$1" && env -u GITHUB_REPOSITORY bash "${LAG}" "${@:2}" ) > "${WORK}/log" 2>&1; }
lag "$A" --slug acme/alpha; rc=$?
[ "$rc" = 0 ] && grep -q "OK: acme/alpha has all 3 rollouts" "${WORK}/log" && ok "alpha: up to date with the definition it pins" || bad "lag ok" "rc=$rc"
lag "$B" --slug ACME/Bravo; rc=$?
[ "$rc" = 0 ] && grep -q "has all 2 rollouts" "${WORK}/log" && ok "bravo pins an EARLIER definition (2 rollouts) and has both: ok" || bad "lag: bravo at its pin" "rc=$rc"
q git -C "$B/.fleet" fetch "$DEF" HEAD; q git -C "$B/.fleet" checkout "$DEF3"
lag "$B" --slug acme/bravo; rc=$?
[ "$rc" = 1 ] && grep -q "core/0003-third    (no .waves/core/0003-third.toml)" "${WORK}/log" && ok "its pin moved on without the rollout: BEHIND, exit 1, names it" || bad "lag behind" "rc=$rc"
( cd "$B" && GITHUB_REPOSITORY=acme/bravo bash "${LAG}" ) > "${WORK}/log" 2>&1; [ $? = 1 ] && ok "the slug comes from GITHUB_REPOSITORY in CI" || bad "GITHUB_REPOSITORY"
lag "$A" --slug acme/nobody; [ $? = 2 ] && grep -q "not in the inventory" "${WORK}/log" && ok "not in the pinned inventory: exit 2" || bad "lag: unknown slug"
lag "${WORK}/stranger" --slug acme/alpha; [ $? = 2 ] && grep -q "no pinned fleet definition here" "${WORK}/log" && ok "no .fleet/ and nothing under .deps/: exit 2, says how to get one" || bad "lag: no .fleet"

echo "== a rollout directory's contract (fleet/lib/check-rollout.py)"
CR="${HERE}/../fleet/lib/check-rollout.py"
rd() { local d="${WORK}/rc/rollouts/$1"; rm -rf "${WORK}/rc"; mkdir -p "$d"; echo "$d"; }
d="$(rd core/0001-ok)"; printf 'name = "0001-ok"\ncohort = "core"\ndescription = "d"\n' > "$d/rollout.toml"; printf '#!/bin/sh\n' > "$d/apply.sh"; chmod +x "$d/apply.sh"; echo i > "$d/issue.md"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1 && ok "a valid rollout passes" || bad "valid rollout"
chmod -x "$d/apply.sh"; python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1; [ $? = 1 ] && grep -q "apply.sh is executable" "${WORK}/log" && ok "apply.sh not executable" || bad "not executable"
d="$(rd core/0001-ok)"; printf 'name = "0001-other"\ncohort = "core"\ndescription = "d"\n[applied]\nby = "hand"\n' > "$d/rollout.toml"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1; [ $? = 1 ] && grep -q "name equals the directory" "${WORK}/log" && ok "name differs from the directory: refused, never guessed" || bad "name mismatch"
d="$(rd core/0001-ok)"; printf 'name = "0001-ok"\ncohort = "elsewhere"\ndescription = "d"\n[applied]\nby = "hand"\n' > "$d/rollout.toml"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1; [ $? = 1 ] && grep -q "cohort equals the parent directory" "${WORK}/log" && ok "cohort differs from the directory" || bad "cohort mismatch"
d="$(rd core/0001-ok)"; printf 'name = "0001-ok"\ncohort = "core"\n[applied]\nby = "hand"\n' > "$d/rollout.toml"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1; [ $? = 1 ] && grep -q "rollout.toml has description" "${WORK}/log" && ok "description missing" || bad "description"
d="$(rd core/0001-ok)"; printf 'name = "0001-ok"\ncohort = "core"\ndescription = "d"\n' > "$d/rollout.toml"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1; [ $? = 1 ] && grep -q "appliable (apply.sh), adoptable" "${WORK}/log" && ok "neither apply.sh, check.sh nor an [applied] record" || bad "nothing to do"
printf '[applied]\nby = "hand"\n' >> "$d/rollout.toml"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1 && ok "a declared hand-applied record passes" || bad "record"
d="$(rd core/first)"; printf 'name = "first"\ncohort = "core"\ndescription = "d"\n[applied]\nby = "hand"\n' > "$d/rollout.toml"
python3 "$CR" "$d" --quiet > "${WORK}/log" 2>&1; [ $? = 1 ] && grep -q "directory is <NNNN>-<name>" "${WORK}/log" && ok "a directory without its order number" || bad "no NNNN"

echo "== the marker's .cicd pin: what THIS commit sets; an adopted marker keeps the pin it was found with (#67)"
TOOLS="${WORK}/tools"; q git init "$TOOLS"; echo v1 > "$TOOLS/v"; q git -C "$TOOLS" add -A; q git -C "$TOOLS" commit -m v1; T1="$(git -C "$TOOLS" rev-parse HEAD)"
echo v2 > "$TOOLS/v"; q git -C "$TOOLS" commit -am v2; T2="$(git -C "$TOOLS" rev-parse HEAD)"
PIN="${WORK}/pin-fleet"; q git init "$PIN"; mkdir -p "$PIN/rollouts/core"
printf 'schema = 2\n[[cohort]]\nname = "core"\ndescription = "c"\n[[repo]]\nname = "delta"\nslug = "acme/delta"\ndefault_branch = "main"\ncohorts = ["core"]\n[[repo]]\nname = "echo"\nslug = "acme/echo"\ndefault_branch = "main"\ncohorts = ["core"]\n' > "$PIN/fleet.toml"
pinroll() {  # pinroll <NNNN-name> <apply body> [check body]
  local d="$PIN/rollouts/core/$1"; mkdir -p "$d"
  printf 'name = "%s"\ncohort = "core"\ndescription = "test rollout"\n' "$1" > "$d/rollout.toml"
  printf '#!/usr/bin/env bash\nset -e\n%s\n' "$2" > "$d/apply.sh"; chmod +x "$d/apply.sh"
  [ -z "${3:-}" ] || { printf '#!/usr/bin/env bash\n%s\n' "$3" > "$d/check.sh"; chmod +x "$d/check.sh"; }
  echo "issue text" > "$d/issue.md"
}
pinroll 0001-tools "git -c protocol.file.allow=always submodule add --quiet '$TOOLS' .cicd >/dev/null 2>&1; git -C .cicd checkout --quiet $T1; git add .cicd" 'test -e .cicd/v'
pinroll 0002-bump  "git -C .cicd checkout --quiet $T2"
q git -C "$PIN" add -A; q git -C "$PIN" commit -m "definition: add the tools, then move them"
cicd_of() { python3 -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb")).get("cicd", "<absent>"))' "$1" 2>&1; }
member delta; D="${WORK}/delta"
run "$D" "$PIN" core/0001-tools --issue 8 --fleet-url "$URL"; rc=$?
[ "$rc" = 0 ] && [ "$(cicd_of "$D/.waves/core/0001-tools.toml")" = "$T1" ] && ok "a rollout that ADDS .cicd: the marker names the pin it added, not an empty one" || bad "marker pin (added)" "rc=$rc $(cicd_of "$D/.waves/core/0001-tools.toml")"
run "$D" "$PIN" core/0002-bump --issue 8 --fleet-url "$URL"; rc=$?
[ "$rc" = 0 ] && [ "$(cicd_of "$D/.waves/core/0002-bump.toml")" = "$T2" ] && ok "a rollout that MOVES .cicd (unstaged by apply.sh): the marker names the new pin" || bad "marker pin (moved)" "rc=$rc $(cicd_of "$D/.waves/core/0002-bump.toml")"
[ "$(git -C "$D" ls-tree HEAD .cicd | awk '{print $3}')" = "$T2" ] && ok "and that is the pin the commit sets" || bad "commit pin"
member echo; E="${WORK}/echo"
q git -C "$E" -c protocol.file.allow=always submodule add "$TOOLS" .cicd; q git -C "$E" -C .cicd checkout "$T1"; q git -C "$E" add -A; q git -C "$E" commit -m "tools, by hand"
run "$E" "$PIN" core/0002-bump --issue 9 --fleet-url "$URL"; rc=$?
[ "$rc" = 0 ] && [ "$(cicd_of "$E/.waves/core/0001-tools.toml")" = "$T1" ] && [ "$(cicd_of "$E/.waves/core/0002-bump.toml")" = "$T2" ] \
    && ok "adopted and applied in ONE commit: the adopted marker names the old pin, the applied one the new" || bad "adopted vs applied pin" "rc=$rc"
[ "$(cicd_of "$A/.waves/core/0001-first.toml")" = "<absent>" ] && ok "a repository without .cicd: no cicd key (not an empty one)" || bad "no .cicd" "$(cicd_of "$A/.waves/core/0001-first.toml")"

echo "== the definition must be landed: its HEAD in the default branch of one of its remotes (#67)"
FORGE="${WORK}/forge.git"; q git clone --bare "$PIN" "$FORGE"
LD="${WORK}/landed-fleet"; q git -c protocol.file.allow=always clone "$FORGE" "$LD"
member delta2; D2="${WORK}/delta2"; d20="$(git -C "$D2" rev-parse HEAD)"
strict "$D2" "$LD" core/0001-tools --issue 10 --repo delta --fleet-url "$URL"; rc=$?
[ "$rc" = 0 ] && ok "HEAD is the remote's default branch: applied" || bad "landed definition" "rc=$rc"
q git -C "$LD" checkout -b fix_1; echo more >> "$LD/rollouts/core/0002-bump/issue.md"; q git -C "$LD" commit -am "an unlanded change"
strict "$D2" "$LD" core/0002-bump --issue 10 --repo delta --fleet-url "$URL"; rc=$?
[ "$rc" = 2 ] && grep -q "is not landed" "${WORK}/log" && [ -z "$(git -C "$D2" status --porcelain)" ] && [ ! -e "$D2/.waves/core/0002-bump.toml" ] \
    && ok "HEAD on a branch the default branch does not contain: refused, exit 2, nothing changed" || bad "unlanded refused" "rc=$rc"
run "$D2" "$LD" core/0002-bump --issue 10 --repo delta --fleet-url "$URL"; rc=$?
[ "$rc" = 0 ] && ok "--allow-unlanded: applied" || bad "--allow-unlanded" "rc=$rc"
member delta3
strict "${WORK}/delta3" "$PIN" core/0001-tools --issue 11 --repo delta --fleet-url "$URL"; rc=$?
[ "$rc" = 2 ] && grep -q "is not landed" "${WORK}/log" && ok "a definition clone without any remote default branch: refused (cannot tell)" || bad "no remote" "rc=$rc"

echo "== a tooling source: no submodules - the definition's pin in deps.toml, its checkout in .deps/ (#69)"
# The definition pins acme/tools as .cicd and acme/policy as .ai: those two members are the
# tooling sources. Only .gitmodules is read for that, so the file alone is enough here.
DEPS="${HERE}/../scripts/deps.sh"
TSURL="https://github.com/acme/ts-fleet.git"
TS="${WORK}/ts-fleet"; q git init "$TS"; mkdir -p "$TS/rollouts/core/0001-probe"
printf '[submodule ".cicd"]\n\tpath = .cicd\n\turl = https://github.com/acme/tools.git\n[submodule ".ai"]\n\tpath = .ai\n\turl = git@github.com:ACME/Policy.git\n' > "$TS/.gitmodules"
{ echo 'schema = 2'; printf '[[cohort]]\nname = "core"\ndescription = "c"\n'
  for n in tools policy plain; do printf '[[repo]]\nname = "%s"\nslug = "acme/%s"\ndefault_branch = "main"\ncohorts = ["core"]\n' "$n" "$n"; done; } > "$TS/fleet.toml"
printf 'name = "0001-probe"\ncohort = "core"\ndescription = "test rollout"\n' > "$TS/rollouts/core/0001-probe/rollout.toml"
# apply.sh: records what it was told; a tooling source other than the tools themselves pins the
# tools in deps.toml, as a real rollout would.
{ echo '#!/usr/bin/env bash'; echo 'set -e'; echo 'echo "[${FLEET_TOOLING_SOURCE}]" > TS.txt'
  echo 'echo "${FLEET_DEF_URL} [${FLEET_DEF_DEP:-}]" > DEF.txt'
  echo 'if [ "${FLEET_TOOLING_SOURCE}" = .ai ]; then'
  echo "    bash \"\${FLEET_TOOLS_DIR}/../scripts/deps.sh\" set tools https://github.com/acme/tools.git ${T2}"
  echo 'fi'; } > "$TS/rollouts/core/0001-probe/apply.sh"
chmod +x "$TS/rollouts/core/0001-probe/apply.sh"; echo "issue text" > "$TS/rollouts/core/0001-probe/issue.md"
q git -C "$TS" add -A; q git -C "$TS" commit -m "definition: pins its tools"; TS1="$(git -C "$TS" rev-parse HEAD)"
member tsrc; TL="${WORK}/tsrc"
run "$TL" "$TS" core/0001-probe --issue 12 --repo tools --fleet-url "$TSURL"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$TL" rev-list --count main..fix_5)" = 1 ] && ok "exit 0, one commit" || bad "tooling source applies" "rc=$rc"
[ ! -e "$TL/.fleet" ] && [ ! -e "$TL/.gitmodules" ] && [ -z "$(git -C "$TL" ls-tree -r HEAD | awk '$1=="160000"')" ] && ok "no .fleet/, no .gitmodules, no submodule at all" || bad "no submodules"
[ "$(bash "$DEPS" get --root "$TL" ts-fleet)" = "$TS1 $TSURL" ] && ok "deps.toml pins the definition: its forge URL at the definition's commit" || bad "deps.toml" "$(cat "$TL/deps.toml" 2>&1)"
[ -f "$TL/.deps/ts-fleet/fleet.toml" ] && [ "$(git -C "$TL/.deps/ts-fleet" rev-parse HEAD)" = "$TS1" ] && ok ".deps/ts-fleet is populated at that commit (local objects: no other transport is allowed here)" || bad ".deps populated"
grep -qx ".deps/" "$TL/.gitignore" && [ -z "$(git -C "$TL" ls-files .deps)" ] && [ -z "$(git -C "$TL" status --porcelain)" ] && ok ".deps/ is ignored, not committed; tree clean" || bad ".deps ignored" "$(git -C "$TL" status --porcelain)"
grep -qx '\[.cicd\]' "$TL/TS.txt" && ok "apply.sh sees FLEET_TOOLING_SOURCE=.cicd (the path the others pin it under)" || bad "FLEET_TOOLING_SOURCE" "$(cat "$TL/TS.txt" 2>&1)"
[ "$(cicd_of "$TL/.waves/core/0001-probe.toml")" = "<absent>" ] && grep -q "^fleet   = \"https://github.com/acme/ts-fleet@${TS1}\"" "$TL/.waves/core/0001-probe.toml" \
    && grep -q '^script  = "sha256:' "$TL/.waves/core/0001-probe.toml" && ok "marker as for any member; no cicd key (it IS the tools)" || bad "tooling marker" "$(cat "$TL/.waves/core/0001-probe.toml" 2>&1)"
lag "$TL" --slug acme/tools --fleet-dir .deps/ts-fleet; [ $? = 0 ] && grep -q "OK: acme/tools has all 1 rollouts" "${WORK}/log" && ok "lag check --fleet-dir .deps/ts-fleet: up to date" || bad "lag --fleet-dir"
lag "$TL" --slug acme/tools; [ $? = 0 ] && grep -q "OK: acme/tools has all 1 rollouts" "${WORK}/log" && ok "lag check WITHOUT --fleet-dir finds the one definition under .deps/ (#71)" || bad "lag finds .deps"
grep -qx "$TSURL \[ts-fleet\]" "$TL/DEF.txt" && ok "apply.sh sees FLEET_DEF_URL and FLEET_DEF_DEP (#71)" || bad "FLEET_DEF_URL/DEP" "$(cat "$TL/DEF.txt" 2>&1)"
mkdir -p "$TL/.deps/second"; cp "$TL/.deps/ts-fleet/fleet.toml" "$TL/.deps/second/fleet.toml"
lag "$TL" --slug acme/tools; [ $? = 2 ] && grep -q "more than one fleet definition" "${WORK}/log" && ok "two definitions under .deps/: exit 2, pass --fleet-dir" || bad "lag two defs"
rm -rf "$TL/.deps/second"
lag "$TL" --slug acme/tools --fleet-dir .deps/nope; [ $? = 2 ] && grep -q "is .deps/ populated" "${WORK}/log" && ok "lag check on an unpopulated --fleet-dir says so" || bad "lag unpopulated"
member policy; PO="${WORK}/policy"
run "$PO" "$TS" core/0001-probe --issue 12 --fleet-url "$TSURL"; rc=$?
[ "$rc" = 0 ] && grep -qx '\[.ai\]' "$PO/TS.txt" && ok "the other tooling source (URL in another spelling and case): FLEET_TOOLING_SOURCE=.ai" || bad "policy" "rc=$rc"
[ "$(cicd_of "$PO/.waves/core/0001-probe.toml")" = "$T2" ] && ok "its marker's cicd is the tools pin from deps.toml" || bad "policy marker cicd" "$(cicd_of "$PO/.waves/core/0001-probe.toml")"
member plain; PL="${WORK}/plain"
run "$PL" "$TS" core/0001-probe --issue 12 --fleet-url "$TSURL"; rc=$?
[ "$rc" = 0 ] && grep -qx '\[\]' "$PL/TS.txt" && [ "$(git -C "$PL" ls-tree HEAD .fleet | awk '{print $3}')" = "$TS1" ] && [ ! -e "$PL/deps.toml" ] \
    && ok "an ordinary member of the same fleet: .fleet/ submodule as before, no deps.toml, FLEET_TOOLING_SOURCE empty" || bad "plain member" "rc=$rc"
grep -qx "$TSURL \[\]" "$PL/DEF.txt" && ok "...and FLEET_DEF_URL set, FLEET_DEF_DEP not (#71)" || bad "plain FLEET_DEF_URL" "$(cat "$PL/DEF.txt" 2>&1)"
lag "$PL" --slug acme/plain; [ $? = 0 ] && ok "...and its lag check uses .fleet/" || bad "plain lag"
mkdir -p "$TS/rollouts/core/0002-more"; printf 'name = "0002-more"\ncohort = "core"\ndescription = "test rollout"\n' > "$TS/rollouts/core/0002-more/rollout.toml"
printf '#!/usr/bin/env bash\necho more > MORE.txt\n' > "$TS/rollouts/core/0002-more/apply.sh"; chmod +x "$TS/rollouts/core/0002-more/apply.sh"; echo i > "$TS/rollouts/core/0002-more/issue.md"
q git -C "$TS" add -A; q git -C "$TS" commit -m "definition: a second rollout"; TS2="$(git -C "$TS" rev-parse HEAD)"
run "$TL" "$TS" core/0002-more --issue 13 --repo tools; rc=$?
[ "$rc" = 0 ] && [ "$(bash "$DEPS" get --root "$TL" ts-fleet)" = "$TS2 $TSURL" ] && [ "$(git -C "$TL/.deps/ts-fleet" rev-parse HEAD)" = "$TS2" ] \
    && ok "the next rollout moves the pin and the checkout; the URL comes from deps.toml (no --fleet-url)" || bad "tooling second rollout" "rc=$rc"
member tools2; q git -C "${WORK}/tools2" -c protocol.file.allow=always submodule add "$TS" .fleet; q git -C "${WORK}/tools2" commit -am "a .fleet submodule, by mistake"
t20="$(git -C "${WORK}/tools2" rev-parse HEAD)"
run "${WORK}/tools2" "$TS" core/0001-probe --issue 12 --repo tools --fleet-url "$TSURL"; rc=$?
[ "$rc" = 12 ] && grep -q "carries a .fleet submodule" "${WORK}/log" && [ "$(git -C "${WORK}/tools2" rev-parse HEAD)" = "$t20" ] && ok "a tooling source that carries .fleet/: refused, nothing committed" || bad "tooling with .fleet" "rc=$rc"

echo "== FLEET_DEF_URL: the definition's forge URL where its clone has no forge remote (#69)"
member plain2
run "${WORK}/plain2" "$TS" core/0001-probe --issue 14 --repo plain; rc=$?
[ "$rc" = 2 ] && grep -q "FLEET_DEF_URL" "${WORK}/log" && ok "no --fleet-url, no forge remote, no FLEET_DEF_URL: exit 2, and says how" || bad "no url" "rc=$rc"
FLEET_DEF_URL="$TSURL" run "${WORK}/plain2" "$TS" core/0001-probe --issue 14 --repo plain; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "${WORK}/plain2" config -f .gitmodules --get submodule..fleet.url)" = "$TSURL" ] && ok "FLEET_DEF_URL in the environment is what .gitmodules records" || bad "FLEET_DEF_URL env" "rc=$rc"
CFG="${WORK}/cfg"; mkdir -p "$CFG"; chmod 700 "$CFG"; ln -s "$TS/fleet.toml" "$CFG/ts.toml"; echo "FLEET_DEF_URL=$TSURL" > "$CFG/ts.env"; chmod 600 "$CFG/ts.env"
member plain3
FLEET_CONFIG_DIR="$CFG" run "${WORK}/plain3" "$TS" core/0001-probe --issue 14 --repo plain; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "${WORK}/plain3" config -f .gitmodules --get submodule..fleet.url)" = "$TSURL" ] && ok "...and so is FLEET_DEF_URL from the fleet's <fleet>.env" || bad "FLEET_DEF_URL config" "rc=$rc"

echo "== usage"
run "$A" "$DEF" core/0001-first; [ $? = 2 ] && ok "--issue is required" || bad "--issue required"
run "$A" "$DEF" nonsense --issue 5; [ $? = 2 ] && ok "a malformed rollout id" || bad "malformed id"
run "$A" "$DEF" core/0009-nope --issue 5; [ $? = 2 ] && ok "an unknown rollout" || bad "unknown rollout"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
