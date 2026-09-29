#!/usr/bin/env bash
#
# Test fleet/pr-ci.sh - one pull request's CI results, collected where `gh` is authenticated and
# handed to the AI host (#58). For private repositories the AI host cannot read the logs itself.
#
#   - the PR can be named as a URL (pasted from the browser), owner/repo#n, or owner/repo n;
#   - failed-job logs are collected, also of runs still in progress (shared with ci-results.sh);
#   - the upload goes to <PR_CI_UPLOAD_TO>/<owner>/<repo>/pr<n>-<stamp>/, from the environment or
#     ~/.config/fleet/pr-ci.conf, staged inside the destination - never in the target's /tmp;
#   - without an upload target the results stay local and the script says so.
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

unset XDG_CONFIG_HOME PR_CI_UPLOAD_TO PR_CI_DIR
export HOME="${WORK}/home"; mkdir -p "${HOME}" "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG}"
case "$*" in
  "auth status"*)  exit 0 ;;
  "pr view 59 --repo acme/tool"*) echo '{"headRefOid":"feedbeef1234","number":59}' ;;
  "pr view"*)      echo "no such PR" >&2; exit 1 ;;
  "pr checks"*)    echo "just test	fail"; exit 1 ;;
  "run list"*)     echo '[{"databaseId":5,"workflowName":"test","status":"completed","conclusion":"failure"}]' ;;
  "run view 5 --repo acme/tool --json"*) echo '{"status":"completed","jobs":[{"databaseId":50,"name":"just test","status":"completed","conclusion":"failure"}]}' ;;
  "run view 5 --repo acme/tool --log-failed"*) echo "just test FAILED: 3 of 13" ;;
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

echo "== the PR, three ways"
for arg in "https://github.com/acme/tool/pull/59" "https://github.com/acme/tool/pull/59/checks" "acme/tool#59" "acme/tool 59"; do
    out="$(bash "$S" $arg --no-upload 2>&1)"
    grep -q '== acme/tool PR #59' <<<"$out" && ok "'${arg}'" || fail "'${arg}': $out"
done
out="$(bash "$S" acme 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q usage <<<"$out" && ok "nonsense refused with usage" || fail "usage: $out"
out="$(bash "$S" acme/tool#1 --no-upload 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'could not read acme/tool PR #1' <<<"$out" && ok "unreadable PR: error" || fail "bad PR: $out"

echo "== collected locally under ~/fleet-ci/<owner>/<repo>/pr<n>-<stamp>/"
d="$(ls -d "${HOME}"/fleet-ci/acme/tool/pr59-* | head -1)"
[ -f "$d/pr.json" ] && [ -f "$d/checks.txt" ] && [ -f "$d/runs.json" ] && ok "pr.json, checks.txt, runs.json" || fail "files in $d"
grep -q '3 of 13' "$d"/run-5-*.failed.log 2>/dev/null && ok "failed-run log" || fail "failed log"
grep -q '| FAIL | 1 | test: just test<br> |' "$d/SUMMARY.md" && ok "SUMMARY.md row" || fail "summary: $(cat "$d/SUMMARY.md")"

echo "== no upload target: says so"
out="$(bash "$S" acme/tool#59 2>&1)"
grep -q 'not uploaded: set PR_CI_UPLOAD_TO' <<<"$out" && [ ! -s "${SSH_LOG}" ] && ok "local only, told" || fail "no target: $out"

echo "== upload target from ~/.config/fleet/pr-ci.conf"
mkdir -p "${HOME}/.config/fleet" "${WORK}/aihost"
echo "PR_CI_UPLOAD_TO=aihost:${WORK}/aihost/fleet-ci" > "${HOME}/.config/fleet/pr-ci.conf"
ls /tmp > "${WORK}/tmp-before"
out="$(bash "$S" acme/tool#59 2>&1)"
up="$(ls -d "${WORK}"/aihost/fleet-ci/acme/tool/pr59-* 2>/dev/null | head -1)"
[ -n "$up" ] && [ -f "$up/SUMMARY.md" ] && ok "arrived under <target>/acme/tool/pr59-*/" || fail "upload: $out"
grep -qx aihost "${SSH_LOG}" && ok "ssh to the configured host" || fail "ssh host"
[ -z "$(ls -A "${WORK}"/aihost/fleet-ci/acme/tool/ | grep '^\.')" ] && ok "staging tarball removed" || fail "staging left behind"
ls /tmp > "${WORK}/tmp-after"
! diff "${WORK}/tmp-before" "${WORK}/tmp-after" | grep -q 'pr59' && ok "nothing staged in /tmp" || fail "used /tmp"

echo "== the environment wins over the conf file"
: > "${SSH_LOG}"
PR_CI_UPLOAD_TO="otherhost:${WORK}/other" bash "$S" acme/tool#59 >/dev/null 2>&1
grep -qx otherhost "${SSH_LOG}" && [ -n "$(ls -d "${WORK}"/other/acme/tool/pr59-* 2>/dev/null)" ] && ok "PR_CI_UPLOAD_TO from env" || fail "env precedence"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
