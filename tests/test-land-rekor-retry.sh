#!/usr/bin/env bash
#
# Test that `land` retries the merge-signature check while Rekor has not yet indexed the new
# entry, and only then (wamp-cicd #86).
#
# gitsign's online mode looks the signature up in the transparency log, and right after signing
# that lookup can fail although the entry exists ("could not find matching tlog entry"). Three
# lands in a row were undone for it on 2026-10-14; the undone merge verified minutes later.
#
# The real `land`, end to end, against a stub signer whose `verify` answers from a script; the
# exchange is a local bare repository, there is no forge remote. No network.
#
# Run: bash tests/test-land-rekor-retry.sh
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
export WORKFLOW_REKOR_RETRY_DELAYS="0 0 0 0"

PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -14; FAIL=$((FAIL + 1)); }

# The signer. Signing (git's gpg.x509.program call) always works. `gitsign verify` answers from
# VERIFY_SCRIPT, one word per call, the last word repeating: ok | lag | identity.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gitsign" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = verify ]; then
  n="$(cat "${VERIFY_COUNT}" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "${VERIFY_COUNT}"
  read -r -a words <<< "${VERIFY_SCRIPT}"
  i=$((n - 1)); [ "$i" -ge "${#words[@]}" ] && i=$((${#words[@]} - 1))
  case "${words[$i]}" in
    ok)       echo "Validated Git signature: true"; exit 0 ;;
    lag)      echo "Error: no signer could be verified online: signer 0: looking up rekor entry: could not find matching tlog entry"; exit 1 ;;
    identity) echo "Error: none of the expected identities matched what was in the certificate"; exit 1 ;;
  esac
fi
printf -- '-----BEGIN SIGNED MESSAGE-----\nc3R1Yg==\n-----END SIGNED MESSAGE-----\n'
echo "[GNUPG:] SIG_CREATED D 1 8 00 0 0" >&2
STUB
chmod +x "${WORK}/bin/gitsign"
export PATH="${WORK}/bin:${PATH}"
export VERIFY_COUNT="${WORK}/count"

# A repository on main, the exchange as origin, a published dev branch fix_7 with its audit file.
fixture() {
  local R="$1"
  mkdir -p "$R"; q git init --bare -b main "$R/exchange.git"; q git init -b main "$R/repo"
  ( cd "$R/repo"
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    echo seed > README.md
    q git add -A; q git commit -m seed
    q git remote add origin "$R/exchange.git"; q git push origin main
    q git config gpg.format x509
    q git config gpg.x509.program "${WORK}/bin/gitsign"
    q git config workflow.signingIdentity test@example.invalid
    q git checkout -b fix_7
    echo work > work.txt
    mkdir -p .audit; echo "Related issue(s): #7" > .audit/test_fix_7.md
    q git add -A; q git commit -m work
    q git push origin fix_7 )
}
land() {   # $1 = dir, $2 = VERIFY_SCRIPT
  : > "${VERIFY_COUNT}"
  ( cd "$1/repo" && VERIFY_SCRIPT="$2" just land ) > "${WORK}/log" 2>&1
}
calls() { cat "${VERIFY_COUNT}"; }
merged() { [ "$(git -C "$1/repo" log -1 --format=%p main | wc -w)" = 2 ]; }

echo "== not indexed twice, then indexed: the land goes ahead"
R="${WORK}/a"; fixture "$R"
land "$R" "lag lag ok"; rc=$?
[ "$rc" = 0 ] && merged "$R" && ok "exit 0, main's tip is the merge" || bad "exit 0, main's tip is the merge" "rc=$rc"
[ "$(grep -c 'Rekor has not indexed the entry yet; retrying in 0 s' "${WORK}/log")" = 2 ] \
  && grep -q "(attempt 2/5)" "${WORK}/log" && grep -q "(attempt 3/5)" "${WORK}/log" \
  && ok "two retry lines, numbered" || bad "two retry lines, numbered"
[ "$(calls)" = 3 ] && ok "verify asked three times" || bad "verify asked three times" "$(calls)"
[ "$(git --git-dir="$R/exchange.git" rev-parse main)" = "$(git -C "$R/repo" rev-parse main)" ] \
  && ok "pushed" || bad "pushed"

echo "== never indexed: refused after the last attempt, merge undone, the reflog hint"
R="${WORK}/b"; fixture "$R"
seed="$(git -C "$R/repo" rev-parse main)"
land "$R" "lag"; rc=$?
[ "$rc" = 1 ] && [ "$(git -C "$R/repo" rev-parse main)" = "$seed" ] \
  && ok "exit 1, main back where it was" || bad "exit 1, main back where it was" "rc=$rc"
[ "$(calls)" = 5 ] && ok "five attempts in all" || bad "five attempts in all" "$(calls)"
grep -q "still in the reflog" "${WORK}/log" && grep -q "gitsign verify --certificate-identity=test@example.invalid" "${WORK}/log" \
  && ok "the reflog hint, with the command to verify it later" || bad "the reflog hint"
[ "$(git --git-dir="$R/exchange.git" rev-parse main)" = "$seed" ] && ok "nothing pushed" || bad "nothing pushed"

echo "== any other failure: refused at once, no retry"
R="${WORK}/c"; fixture "$R"
seed="$(git -C "$R/repo" rev-parse main)"
land "$R" "identity ok"; rc=$?
[ "$rc" = 1 ] && [ "$(git -C "$R/repo" rev-parse main)" = "$seed" ] \
  && ok "exit 1, merge undone" || bad "exit 1, merge undone" "rc=$rc"
[ "$(calls)" = 1 ] && ! grep -q "retrying" "${WORK}/log" && ! grep -q "reflog" "${WORK}/log" \
  && ok "one attempt, no retry line, no Rekor hint" || bad "one attempt, no retry" "$(calls)"

echo "== indexed at once: unchanged behaviour"
R="${WORK}/d"; fixture "$R"
land "$R" "ok"; rc=$?
[ "$rc" = 0 ] && merged "$R" && [ "$(calls)" = 1 ] && ! grep -q "retrying" "${WORK}/log" \
  && ok "one verify, no retry line, landed" || bad "one verify, no retry line, landed" "rc=$rc"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
