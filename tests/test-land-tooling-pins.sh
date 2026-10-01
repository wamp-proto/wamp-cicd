#!/usr/bin/env bash
#
# Test that `just land` lands a branch that moves a tooling pin (#51).
#
# `land` used to refuse any branch that changes `.cicd` or `.ai` and send it through the forge's
# merge button. Under rollouts every branch moves a pin (`.fleet`, often `.cicd`), and the forge
# cannot make the maintainer's signed merge - so the one commit MERGE-AND-SIGNING-POLICY.md is
# about could not be made. The refusal folded two reasons into one:
#
#   1. the recipe is swapped mid-run when the integration branch's older `.cicd` comes back.
#      Harmless since #32 - PROVEN here: the integration branch pins a `.cicd` whose workflow.just
#      is a decoy that fails on every recipe, and the landing must still complete.
#   2. the integration branch's hook cannot admit a maintainer merge yet (the bootstrap). Still a
#      reason to refuse - and now the ONLY one, detected from the hook the integration branch pins.
#
# The real `land` end to end (the first test that runs it whole): real submodules, a real hook,
# a stub signer; the exchange is a local bare repository, there is no forge remote. No network.
#
# Run: bash tests/test-land-tooling-pins.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -f "$WORKFLOW_JUST" ] || { echo "FATAL: no $WORKFLOW_JUST" >&2; exit 2; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
git config --global protocol.file.allow always
git config --global init.defaultBranch main

PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -14; FAIL=$((FAIL + 1)); }

# the signer: git invokes gpg.x509.program like gitsign; `gitsign verify` is the same stub
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gitsign" <<'STUB'
#!/usr/bin/env bash
printf -- '-----BEGIN SIGNED MESSAGE-----\nc3R1Yg==\n-----END SIGNED MESSAGE-----\n'
echo "[GNUPG:] SIG_CREATED D 1 8 00 0 0" >&2
STUB
chmod +x "${WORK}/bin/gitsign"
export PATH="${WORK}/bin:${PATH}"
signed() { git -C "$1" cat-file -p "$2" | sed -n '1,12p' | grep -q '^gpgsig '; }

# --- the tooling sources -----------------------------------------------------
# .ai: OLD hook refuses every commit on main; NEW hook admits a merge in progress.
AI="${WORK}/src/ai"; q git init "$AI"; mkdir -p "$AI/.githooks"
cat > "$AI/.githooks/commit-msg" <<'HOOK'
#!/bin/sh
# old: nothing is committed on main
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] && { echo "ERROR: no commits on main" >&2; exit 1; }
exit 0
HOOK
chmod +x "$AI/.githooks/commit-msg"
q git -C "$AI" add -A; q git -C "$AI" commit -m "ai: old hook"; AI_OLD="$(git -C "$AI" rev-parse HEAD)"
cat > "$AI/.githooks/commit-msg" <<'HOOK'
#!/bin/sh
# new: main takes a merge in progress, and nothing else
if [ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ]; then
    [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] || { echo "ERROR: not a merge" >&2; exit 1; }
fi
exit 0
HOOK
q git -C "$AI" commit -am "ai: hook admits a maintainer merge"; AI_NEW="$(git -C "$AI" rev-parse HEAD)"
echo newer > "$AI/NOTES"; q git -C "$AI" add -A; q git -C "$AI" commit -m "ai: newer"; AI_NEWER="$(git -C "$AI" rev-parse HEAD)"

# .cicd: v1 is a DECOY - every recipe the landing could call exists and fails loudly. If anything
# invoked `just` after the integration branch (and its older .cicd) came back, it would hit this.
CICD="${WORK}/src/cicd"; q git init "$CICD"
cat > "$CICD/workflow.just" <<'DECOY'
WORKFLOW_MAIN := 'main'
WORKFLOW_BRANCH_PREFIX := 'fix_'
land branch='':
    @echo "DECOY: the OLD workflow.just ran" >&2; exit 3
_workflow-signing-state:
    @echo "DECOY: the OLD workflow.just ran" >&2; exit 3
_workflow-merge-signed branch base_remote pr_note:
    @echo "DECOY: the OLD workflow.just ran" >&2; exit 3
_workflow-base-remote:
    @echo "DECOY: the OLD workflow.just ran" >&2; exit 3
DECOY
q git -C "$CICD" add -A; q git -C "$CICD" commit -m "cicd v1 (decoy)"; CICD_V1="$(git -C "$CICD" rev-parse HEAD)"
cp "$WORKFLOW_JUST" "$CICD/workflow.just"
q git -C "$CICD" add -A; q git -C "$CICD" commit -m "cicd v2 (the workflow under test)"; CICD_V2="$(git -C "$CICD" rev-parse HEAD)"

# .fleet: a submodule the branch ADDS (what a rollout's first branch does)
FLEET="${WORK}/src/fleet"; q git init "$FLEET"; echo 'schema = 2' > "$FLEET/fleet.toml"
q git -C "$FLEET" add -A; q git -C "$FLEET" commit -m "fleet definition"; FLEET_C="$(git -C "$FLEET" rev-parse HEAD)"

# fixture <dir> <.ai on main: old|new|none> <branch changes: cicd|ai|fleet ...>
# main pins .cicd v1 (the decoy); the dev branch fix_7 moves the named pins and is published.
fixture() {
  local R="$1" ai_main="$2"; shift 2
  mkdir -p "$R"; q git init --bare "$R/exchange.git"; q git init "$R/repo"
  ( cd "$R/repo"
    q git submodule add "$CICD" .cicd; q git -C .cicd checkout "$CICD_V1"
    if [ "$ai_main" != none ]; then
      q git submodule add "$AI" .ai
      [ "$ai_main" = old ] && q git -C .ai checkout "$AI_OLD" || q git -C .ai checkout "$AI_NEW"
    fi
    printf "import '.cicd/workflow.just'\n" > justfile
    echo seed > README.md
    q git add -A; q git commit -m seed
    q git remote add origin "$R/exchange.git"; q git push origin main
    q git config gpg.format x509
    q git config gpg.x509.program "${WORK}/bin/gitsign"
    q git config workflow.signingIdentity test@example.invalid
    q git checkout -b fix_7
    # every dev branch needs the workflow under test to run `land` at all
    q git -C .cicd checkout "$CICD_V2"
    for c in "$@"; do
      case "$c" in
        ai)    q git -C .ai checkout "$AI_NEWER" ;;
        ainew) q git -C .ai checkout "$AI_NEW" ;;
        fleet) q git submodule add "$FLEET" .fleet ;;
      esac
    done
    echo work > work.txt
    q git add -A; q git commit -m "work, moving tooling pins"
    q git push origin fix_7
    [ "$ai_main" != none ] && q git config core.hooksPath .ai/.githooks
    : )
}
land() { ( cd "$1/repo" && just land ) > "${WORK}/log" 2>&1; }
pin() { git -C "$1/repo" ls-tree "$2" "$3" | awk '{print $3}'; }

echo "== a branch that bumps .cicd lands as a signed merge (the decoy never runs)"
R="${WORK}/cicd"; fixture "$R" new
land "$R"; rc=$?
[ "$rc" = 0 ] && ok "just land: exit 0" || bad "just land: exit 0" "rc=$rc"
grep -q "DECOY" "${WORK}/log" && bad "the old workflow.just was not invoked after the checkout" || ok "the old workflow.just was not invoked after the checkout"
[ "$(git -C "$R/repo" log -1 --format=%p main | wc -w)" = 2 ] && ok "main's tip is a merge commit" || bad "main's tip is a merge commit"
signed "$R/repo" main && ok "the merge is signed" || bad "the merge is signed"
[ "$(git -C "$R/repo" log -1 --format=%s main)" = "Merge branch 'fix_7' (#7)" ] && ok "subject names the branch and issue" || bad "subject"
[ "$(pin "$R" main .cicd)" = "$CICD_V2" ] && ok "main now pins the branch's .cicd" || bad "main pins .cicd v2"
[ -z "$(git -C "$R/repo" submodule status | grep -E '^[-+U]')" ] && ok "submodules are at their pinned revisions" || bad "submodules at pins"
[ "$(git --git-dir="$R/exchange.git" rev-parse main)" = "$(git -C "$R/repo" rev-parse main)" ] && ok "pushed to the exchange" || bad "pushed"
! git -C "$R/repo" show-ref -q --verify refs/heads/fix_7 && ! git --git-dir="$R/exchange.git" show-ref -q --verify refs/heads/fix_7 \
    && ok "fix_7 deleted locally and on the exchange" || bad "branch cleanup"

echo "== a branch that ADDS a submodule (.fleet) and bumps .ai lands too"
R="${WORK}/fleet"; fixture "$R" new fleet ai
land "$R"; rc=$?
[ "$rc" = 0 ] && signed "$R/repo" main && ok "landed, signed" || bad "landed, signed" "rc=$rc"
[ "$(pin "$R" main .fleet)" = "$FLEET_C" ] && [ -f "$R/repo/.fleet/fleet.toml" ] && ok ".fleet is on main and populated" || bad ".fleet on main"
[ "$(pin "$R" main .ai)" = "$AI_NEWER" ] && ok "main pins the branch's .ai" || bad ".ai pin"

echo "== a repository without .ai (like wamp-cicd itself): a .cicd bump lands"
R="${WORK}/noai"; fixture "$R" none
land "$R"; rc=$?
[ "$rc" = 0 ] && signed "$R/repo" main && [ "$(pin "$R" main .cicd)" = "$CICD_V2" ] && ok "landed, signed, pinned" || bad "no .ai" "rc=$rc"

echo "== the bootstrap is still refused - and named as the reason"
R="${WORK}/boot"; fixture "$R" old ainew
before="$(git -C "$R/repo" rev-parse main)"
land "$R"; rc=$?
[ "$rc" != 0 ] && ok "refused" || bad "refused" "rc=$rc"
grep -q "REFUSING: main cannot take a maintainer's merge yet" "${WORK}/log" && grep -q "This is the bootstrap" "${WORK}/log" \
    && ok "says main's hook is the reason, not the pin change" || bad "names the bootstrap"
grep -q "changes .cicd\|changes .ai" "${WORK}/log" && bad "no longer blames the pin change" || ok "no longer blames the pin change"
[ "$(git -C "$R/repo" rev-parse main)" = "$before" ] && [ "$(git -C "$R/repo" symbolic-ref --short HEAD)" = fix_7 ] \
    && ok "nothing moved: main unchanged, still on fix_7" || bad "nothing moved"
git --git-dir="$R/exchange.git" show-ref -q --verify refs/heads/fix_7 && ok "the branch is still published" || bad "branch kept"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
