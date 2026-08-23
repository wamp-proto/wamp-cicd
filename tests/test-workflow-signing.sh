#!/usr/bin/env bash
#
# Test that the recipes which make commits SIGN them (wamp-cicd #36).
#
# `_workflow-merge-signed` passes `-S` explicitly, with the reason written in
# MERGE-AND-SIGNING-POLICY.md: whether an object is signed must not depend on a
# config key that is easy to unset and invisible when it is. `new-branch` and
# `commit-on-main` did not, so on 2026-08-23 four dev branches were cut within
# five minutes and exactly one audit commit was signed - with no signal anywhere
# that the other three differed.
#
# Signing is exercised with a STUB `gpg.x509.program`. git calls it exactly as
# it calls gitsign, so this proves the recipe asked for a signature, needs no
# network, no Fulcio, no OIDC and no hardware key - and cannot be satisfied by a
# test that merely reads the config back.
#
# Assertions read the OBJECT for a `gpgsig` header. Never `git log %G?`: it
# prints `N` ("cannot verify") for perfectly good gitsign objects, which is how
# this went unnoticed for three weeks in the first place.
#
# Run: bash tests/test-workflow-signing.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$WORKFLOW_JUST" ] || { echo "FATAL: no $WORKFLOW_JUST" >&2; exit 2; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"

# The stand-in for gitsign. git invokes gpg.x509.program the same way for both.
STUB="${WORK}/fake-gitsign"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf -- '-----BEGIN SIGNED MESSAGE-----\nc3R1Yg==\n-----END SIGNED MESSAGE-----\n'
echo "[GNUPG:] SIG_CREATED D 1 8 00 0 0" >&2
EOF
chmod +x "$STUB"

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }

ok()   { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log" | tail -10; FAIL=$((FAIL + 1)); }

# signed <repo> <rev> -> 0 if the object carries a gpgsig header
signed() { git -C "$1" cat-file -p "$2" | sed -n '1,12p' | grep -q '^gpgsig '; }

# fixture <dir> <signing: yes|no> [gpgsign]
#
# A repository with a stub `.ai` whose generate-audit-file produces something to
# commit - without it `new-branch` has nothing to sign and the case is vacuous.
fixture() {
  local R="$1" signing="$2" gpgsign="${3:-}"
  mkdir -p "$R"
  q git init --bare -b main "$R/exchange.git"
  q git init -b main "$R/repo"
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
    # `.audit/` tracked, as it is in every real consumer: `git status
    # --porcelain` reports an untracked DIRECTORY, not the file inside it, so a
    # fixture without this would exercise a path the estate never takes.
    mkdir -p .audit && printf 'placeholder\n' > .audit/.gitkeep
    q git add -A && q git commit -m seed
    q git remote add origin "$R/exchange.git"
    q git push origin main
    if [ "$signing" = yes ]; then
      q git config gpg.format x509
      q git config gpg.x509.program "$STUB"
      q git config workflow.signingIdentity test@example.invalid
    fi
    [ -n "$gpgsign" ] && q git config commit.gpgsign "$gpgsign"
    : )
}

# The recipes ask `command -v gitsign`, so it must exist on PATH for the
# configured cases. The stub on PATH under that name satisfies the lookup; the
# signature itself still comes from gpg.x509.program.
mkdir -p "${WORK}/bin" && cp "$STUB" "${WORK}/bin/gitsign"
export PATH="${WORK}/bin:${PATH}"

echo "== the audit commit: new-branch (#36) =="

R="${WORK}/nb-signed"; fixture "$R" yes
( cd "$R/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1
if signed "$R/repo" HEAD; then
  ok "signing configured, commit.gpgsign UNSET: the audit commit is signed"
else
  bad "signing configured, commit.gpgsign UNSET: the audit commit is signed" "no gpgsig header"
fi

R="${WORK}/nb-unsigned"; fixture "$R" no
( cd "$R/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! signed "$R/repo" HEAD && grep -q "NOT SIGNED" "${WORK}/log"; then
  ok "no signing configured: still succeeds, and says the commit is NOT SIGNED"
else
  bad "no signing configured: still succeeds, and says the commit is NOT SIGNED" "rc=$rc"
fi

echo ""
echo "== the commit that goes straight onto main: commit-on-main (#36) =="

R="${WORK}/com-signed"; fixture "$R" yes
( cd "$R/repo" && echo change >> README.md && git add README.md \
  && just commit-on-main "a reason" "a message" ) > "${WORK}/log" 2>&1
if signed "$R/repo" main; then
  ok "signing configured: the commit on main is signed"
else
  bad "signing configured: the commit on main is signed" "no gpgsig header"
fi

R="${WORK}/com-unsigned"; fixture "$R" no
( cd "$R/repo" && echo change >> README.md && git add README.md \
  && just commit-on-main "a reason" "a message" ) > "${WORK}/log" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! signed "$R/repo" main && grep -q "NOT SIGNED" "${WORK}/log"; then
  ok "no signing configured: still succeeds, and says so"
else
  bad "no signing configured: still succeeds, and says so" "rc=$rc"
fi

echo ""
echo "== what 'just where' claims about signing (#36) =="

R="${WORK}/w-on"; fixture "$R" yes true
( cd "$R/repo" && just where ) > "${WORK}/log" 2>&1
if grep -q "commits signed" "${WORK}/log"; then
  ok "commit.gpgsign true: 'commits signed'"
else
  bad "commit.gpgsign true: 'commits signed'" "row missing"
fi

R="${WORK}/w-off"; fixture "$R" yes
( cd "$R/repo" && just where ) > "${WORK}/log" 2>&1
if grep -q "commit.gpgsign OFF" "${WORK}/log" \
   && grep -q "will not sign here" "${WORK}/log"; then
  ok "commit.gpgsign unset: says OFF, and what that means for your own commits"
else
  bad "commit.gpgsign unset: says OFF, and what that means for your own commits" "row missing"
fi

R="${WORK}/w-none"; fixture "$R" no
( cd "$R/repo" && just where ) > "${WORK}/log" 2>&1
if grep -q "NOT CONFIGURED" "${WORK}/log"; then
  ok "no signing at all: still reports NOT CONFIGURED, unchanged"
else
  bad "no signing at all: still reports NOT CONFIGURED, unchanged" "row missing"
fi

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
