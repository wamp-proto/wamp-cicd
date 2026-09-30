#!/usr/bin/env bash
#
# Test fleet/pr-ci.sh - one pull request's CI results, collected where `gh` is authenticated and
# handed to the AI host (#58). For private repositories the AI host cannot read the logs itself.
#
#   - only for a repository in a fleet: the fleet whose inventory lists it (or FLEET_NAME); a
#     repository in no fleet, or in several, is refused;
#   - the PR can be named as a URL (pasted from the browser), owner/repo#n, or owner/repo n;
#   - results go to the fleet's FLEET_CI_DIR/<repo>/pr<n>-<stamp>/ and are uploaded to its
#     UPLOAD_TO/<repo>/, staged inside the destination - never in the target's /tmp;
#   - UPLOAD_TO unset: the results stay local and the script says so.
#
# Real script, stub gh and stub ssh (runs the remote command locally), throwaway HOME. No network.
#
# Run: bash tests/test-pr-ci.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${HERE}/../fleet/pr-ci.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }

unset XDG_CONFIG_HOME FLEET_NAME FLEET_CONFIG_DIR
export HOME="${WORK}/home"; mkdir -p "${HOME}" "${WORK}/bin"
# Two fleets: "tools" lists acme/tool (and uploads), "other" lists something else.
mkdir -p "${HOME}/.config/fleet" "${WORK}/aihost"; chmod 700 "${HOME}/.config/fleet"
inv() { printf 'schema = 1\n[[repo]]\nname = "%s"\nslug = "%s"\ndefault_branch = "main"\nkind = "python"\nwave = 1\nnotes = "test"\n' "${2##*/}" "$2" > "${WORK}/$1.toml"; }
fleet() { printf '%s\n' "FLEET_INVENTORY=${WORK}/$1.toml" "${@:2}" > "${HOME}/.config/fleet/$1.env"; chmod 600 "${HOME}/.config/fleet/$1.env"; }
inv tools acme/tool;   fleet tools "UPLOAD_TO=aihost:${WORK}/aihost/fleet-ci/tools"
inv other acme/else;   fleet other
cat > "${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG}"
case "$*" in
  "auth status"*)  exit 0 ;;
  "pr view 59 --repo acme/"*) echo '{"headRefOid":"feedbeef1234","number":59}' ;;
  "pr view"*)      echo "no such PR" >&2; exit 1 ;;
  "pr checks"*)    echo "just test	fail"; exit 1 ;;
  "run list"*)     echo '[{"databaseId":5,"workflowName":"test","status":"completed","conclusion":"failure"}]' ;;
  "run view 5 --repo acme/"*"--json"*) echo '{"status":"completed","jobs":[{"databaseId":50,"name":"just test","status":"completed","conclusion":"failure"}]}' ;;
  "run view 5 --repo acme/"*"--log-failed"*) echo "just test FAILED: 3 of 13" ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 2 ;;
esac
STUB
cat > "${WORK}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# stub ssh: `ssh <host> <command>` runs <command> locally
echo "$1" >> "${SSH_LOG}"; shift; exec bash -c "$*"
STUB
chmod +x "${WORK}/bin/gh" "${WORK}/bin/ssh"
export PATH="${WORK}/bin:${PATH}" GH_LOG="${WORK}/gh.log" SSH_LOG="${WORK}/ssh.log"

echo "== the PR, three ways; the fleet found from the inventories"
for arg in "https://github.com/acme/tool/pull/59" "https://github.com/acme/tool/pull/59/checks" "acme/tool#59" "acme/tool 59"; do
    out="$(bash "$S" $arg --no-upload 2>&1)"
    grep -q "== acme/tool PR #59  (fleet 'tools')" <<<"$out" && ok "'${arg}'" || fail "'${arg}': $out"
done
out="$(bash "$S" acme 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q usage <<<"$out" && ok "nonsense refused with usage" || fail "usage: $out"

echo "== only fleet repositories"
out="$(bash "$S" acme/stranger#3 --no-upload 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "acme/stranger is in no fleet" <<<"$out" && ok "repository in no fleet: refused" || fail "no fleet: $out"
inv third acme/tool; fleet third
out="$(bash "$S" acme/tool#59 --no-upload 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "in several fleets (.*third.*tools.*\|.*tools.*third.*); set FLEET_NAME" <<<"$out" && ok "in two fleets: refused" || fail "two fleets: $out"
out="$(FLEET_NAME=tools bash "$S" acme/tool#59 --no-upload 2>&1)"
grep -q "(fleet 'tools')" <<<"$out" && ok "FLEET_NAME decides" || fail "FLEET_NAME: $out"
out="$(FLEET_NAME=other bash "$S" acme/tool#59 --no-upload 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "is not in fleet 'other'" <<<"$out" && ok "FLEET_NAME of a fleet without it: refused" || fail "wrong fleet: $out"
rm -f "${HOME}/.config/fleet/third.env"
out="$(bash "$S" acme/tool#1 --no-upload 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'could not read acme/tool PR #1' <<<"$out" && ok "unreadable PR: error" || fail "bad PR: $out"

echo "== collected locally under the fleet's FLEET_CI_DIR/<repo>/pr<n>-<stamp>/"
d="$(ls -d "${HOME}"/fleet-ci/tools/tool/pr59-* | head -1)"
[ -f "$d/pr.json" ] && [ -f "$d/checks.txt" ] && [ -f "$d/runs.json" ] && ok "pr.json, checks.txt, runs.json" || fail "files in $d"
grep -q '3 of 13' "$d"/run-5-*.failed.log 2>/dev/null && ok "failed-run log" || fail "failed log"
grep -q '| FAIL | 1 | test: just test<br> |' "$d/SUMMARY.md" && ok "SUMMARY.md row" || fail "summary: $(cat "$d/SUMMARY.md" 2>/dev/null)"

echo "== uploaded to the fleet's UPLOAD_TO/<repo>/"
ls /tmp > "${WORK}/tmp-before"
out="$(bash "$S" acme/tool#59 2>&1)"
up="$(ls -d "${WORK}"/aihost/fleet-ci/tools/tool/pr59-* 2>/dev/null | head -1)"
[ -n "$up" ] && [ -f "$up/SUMMARY.md" ] && ok "arrived under UPLOAD_TO/tool/pr59-*/" || fail "upload: $out"
grep -qx aihost "${SSH_LOG}" && ok "ssh to the fleet's host" || fail "ssh host"
[ -z "$(ls -A "${WORK}"/aihost/fleet-ci/tools/tool/ | grep '^\.')" ] && ok "staging tarball removed" || fail "staging left behind"
ls /tmp > "${WORK}/tmp-after"
! diff "${WORK}/tmp-before" "${WORK}/tmp-after" | grep -q 'pr59' && ok "nothing staged in /tmp" || fail "used /tmp"

echo "== a fleet without UPLOAD_TO: local only, and says so"
inv solo acme/solo; fleet solo; : > "${SSH_LOG}"
out="$(bash "$S" acme/solo#59 2>&1)"
grep -q "not uploaded: UPLOAD_TO is not set in fleet 'solo'" <<<"$out" && [ ! -s "${SSH_LOG}" ] && ok "told, no ssh" || fail "no UPLOAD_TO: $out"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
