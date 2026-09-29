#!/usr/bin/env bash
#
# Test the fixes to the fleet scripts found in their first real use, rollout wave1-2026-09 (#58):
#
#   A. fleet-rulesets.sh / org-hardening.sh rewrote an unchanged ruleset on every run: GitHub
#      adds fields of its own, so "same?" must be a SUBSET test (lib/ruleset-matches.py).
#   B. org-hardening.sh status printed GitHub's raw 403 JSON for free-plan orgs.
#   C. org-hardening.sh transfer reported a false "already exists" (rfminer/rfminer): exists
#      only if GitHub answers with exactly <to>/<repo> as full_name.
#   D. wave-ci-results.sh saved no logs for failed jobs of a run still in progress.
#   E. wave-publish.sh wanted a "Seal #" commit on top of an already SIGNED tip (crossbar's
#      signed release-key commit), where `land` rightly accepts any signed tip.
#
# The real scripts, a stub `gh` answering from canned JSON, throwaway HOME and config. No network.
#
# Run: bash tests/test-fleet-fixes.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="${HERE}/../fleet"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }

export HOME="${WORK}/home" GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "${HOME}" "${WORK}/bin" "${WORK}/canned"
git config --global user.name T; git config --global user.email t@example.invalid
git config --global init.defaultBranch master

# stub gh: answers are files in $WORK/canned, chosen by the call
cat > "${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
C="${CANNED}"
echo "$*" >> "${C}/calls.log"
args="$*"
case "$args" in
  "auth status"*)                          exit 0 ;;
  "api user/memberships/orgs"*)            echo acme ;;
  "api orgs/acme/rulesets"*)               cat "${C}/org-rulesets.out"; exit "$(cat "${C}/org-rulesets.rc")" ;;
  "api orgs/acme"*)                        cat "${C}/org.json" ;;
  "repo list"*)                            echo r1 ;;
  "api repos/target/r1 --jq .full_name"*)  cat "${C}/full_name" ;;
  "pr view"*)                              cat "${C}/pr.json" ;;
  "pr checks"*)                            echo "unit	fail"; exit 1 ;;
  "run list"*)                             cat "${C}/runs.json" ;;
  "run view --repo "*"--job 11 --log"*)    echo "JOB 11 LOG: assertion failed" ;;
  "run view 7 "*"--json"*)                 cat "${C}/run-7.json" ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
export PATH="${WORK}/bin:${PATH}" CANNED="${WORK}/canned"

echo "== A. ruleset-matches.py: subset, not equality"
M="${F}/lib/ruleset-matches.py"
want='{"name":"m","enforcement":"active","rules":[{"type":"deletion"},{"type":"pull_request","parameters":{"required_approving_review_count":0}}]}'
echo "$want" > "${WORK}/want.json"
live='{"id":9,"name":"m","enforcement":"active","_links":{},"rules":[{"type":"deletion"},{"type":"pull_request","parameters":{"required_approving_review_count":0,"automatic_copilot_code_review_enabled":false}}]}'
[ "$(echo "$live" | python3 "$M" "${WORK}/want.json")" = yes ] && ok "extra server-side fields -> same" || fail "extra fields"
[ "$(echo "${live/\"deletion\"/\"creation\"}" | python3 "$M" "${WORK}/want.json")" = no ] && ok "a different rule -> differs" || fail "different rule"
[ "$(echo "${live/\"active\"/\"disabled\"}" | python3 "$M" "${WORK}/want.json")" = no ] && ok "disabled vs active -> differs" || fail "enforcement"
[ "$(echo '{"name":"m","enforcement":"active","rules":[{"type":"deletion"}]}' | python3 "$M" "${WORK}/want.json")" = no ] \
    && ok "a missing rule -> differs" || fail "missing rule"

echo "== B. org-hardening status: free plan shown as such, no raw 403 JSON"
echo '{"plan":{"name":"free"},"public_repos":3,"total_private_repos":0,"two_factor_requirement_enabled":true,"members_can_change_repo_visibility":false,"members_can_delete_repositories":false}' > "${CANNED}/org.json"
echo '{"message":"Upgrade to GitHub Team to enable this feature.","status":"403"}' > "${CANNED}/org-rulesets.out"; echo 1 > "${CANNED}/org-rulesets.rc"
out="$(bash "${F}/org-hardening.sh" status 2>&1)"
grep -q 'n/a (free plan)' <<<"$out" && ok "n/a (free plan)" || fail "n/a (free plan): $out"
grep -q 'Upgrade to GitHub Team' <<<"$out" && fail "raw 403 JSON still printed" || ok "no raw 403 JSON"

echo "== C. org-hardening transfer: exists only on an exact full_name"
echo "other/r1" > "${CANNED}/full_name"
out="$(bash "${F}/org-hardening.sh" transfer acme target 2>&1)"
grep -q 'acme/r1: \[dry-run\] transfer to target/r1' <<<"$out" && ok "lookup resolving elsewhere -> not 'exists'" || fail "false exists: $out"
echo "Target/R1" > "${CANNED}/full_name"
out="$(bash "${F}/org-hardening.sh" transfer acme target 2>&1)"
grep -q 'SKIP - target/r1 already exists' <<<"$out" && ok "exact full_name (any case) -> SKIP" || fail "real exists: $out"

# a fleet with one repository, configured like a user would, and a rollout state
mkdir -p "${HOME}/.config/fleet" "${WORK}/state/r1" "${WORK}/work"
cat > "${HOME}/.config/fleet/t.env" <<EOF
FLEET_INVENTORY=${WORK}/fleet.toml
FLEET_WORK_DIR=${WORK}/work
FLEET_STATE=${WORK}/state
FLEET_CI_DIR=${WORK}/ci
EXCHANGE=exch
EOF
chmod 600 "${HOME}/.config/fleet/t.env"
echo r1 > "${WORK}/state/current"; echo 1 > "${WORK}/state/r1/wave"
printf 'widget\tacme/widget\tmaster\tpython\t1\n' > "${WORK}/state/r1/fleet.tsv"
printf 'widget\tacme/widget\t5\t8\n' > "${WORK}/state/r1/manifest.tsv"

echo "== D. wave-ci-results: failed job of an IN-PROGRESS run gets its log"
echo '{"headRefOid":"abc1234def","number":8}' > "${CANNED}/pr.json"
echo '[{"databaseId":7,"workflowName":"main","status":"in_progress","conclusion":""}]' > "${CANNED}/runs.json"
echo '{"status":"in_progress","jobs":[{"databaseId":11,"name":"unit (3.14)","status":"completed","conclusion":"failure"},{"databaseId":12,"name":"docs","status":"in_progress","conclusion":null}]}' > "${CANNED}/run-7.json"
out="$(bash "${F}/wave-ci-results.sh" --no-upload 2>&1)"
log="$(find "${WORK}/ci" -name 'run-7-job-11.failed.log' 2>/dev/null)"
[ -n "$log" ] && grep -q 'JOB 11 LOG' "$log" && ok "job 11 log saved" || fail "job 11 log: $out"
[ -z "$(find "${WORK}/ci" -name 'run-7-job-12*' 2>/dev/null)" ] && ok "running job 12 left alone" || fail "job 12 fetched"
grep -q 'main (in progress): unit (3.14)' "$(find "${WORK}/ci" -name SUMMARY.md)" && ok "summary names the job" || fail "summary"

echo "== E. wave-publish: a signed tip that is not a 'Seal #' commit counts as signed"
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/key"
git init -q --bare "${WORK}/exch.git"; git init -q --bare "${WORK}/fork.git"
w="${WORK}/work/widget"; git init -q "$w"
git -C "$w" config gpg.format ssh; git -C "$w" config user.signingkey "${WORK}/key"
echo a > "$w/a"; git -C "$w" add a; git -C "$w" commit -qm init
git -C "$w" checkout -q -b fix_5
echo k > "$w/release.pub"; git -C "$w" add release.pub; git -C "$w" commit -q -S -m "add release key"
git -C "$w" remote add exch "${WORK}/exch.git"; git -C "$w" remote add origin "${WORK}/fork.git"
git -C "$w" push -q exch fix_5
out="$(bash "${F}/wave-publish.sh" 2>&1)"
grep -E '^widget +fix_5 +signed ' <<<"$out" >/dev/null && ok "shown as signed" || fail "signed tip: $out"
grep -q 'NEEDS SEAL' <<<"$out" && fail "asked for a seal on a signed tip" || ok "no seal requested"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
