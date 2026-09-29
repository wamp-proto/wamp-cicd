#!/usr/bin/env bash
#
# Test fleet/fleet.just - the `just` face of the fleet tooling (#58).
#
# The maintainer's rule: every recipe that changes something is a dry run, and the armed call
# is the same one with `go` as its LAST word. A `go` anywhere else must be refused, not
# silently honoured or ignored. Words map to flags (go/seal/integrity/full); everything else
# passes through. Runs the real recipes, standalone via `just -f`, with a stub gh and a
# throwaway HOME.
#
# Run: bash tests/test-fleet-recipes.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FJ="${HERE}/../fleet/fleet.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }
command -v just >/dev/null || { echo "FATAL: needs just" >&2; exit 2; }

export HOME="${WORK}/home"; mkdir -p "${HOME}" "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GH_LOG}"
case "$*" in
  "auth status"*)               exit 0 ;;
  "api user/memberships/orgs"*) echo acme ;;
  "api orgs/acme/rulesets"*)    echo "[]" ;;
  "api -X PATCH orgs/acme"*)    exit 0 ;;
  "api orgs/acme"*)             echo '{"plan":{"name":"team"},"two_factor_requirement_enabled":true,"members_can_change_repo_visibility":true,"members_can_delete_repositories":true}' ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
export PATH="${WORK}/bin:${PATH}" GH_LOG="${WORK}/gh.log"
fj() { (cd "${WORK}" && just -f "${FJ}" "$@" 2>&1); }

echo "== fleet-install-tools: dry run, then go"
out="$(fj fleet-install-tools)"
grep -q '\[dry-run\] install .*file-issue.sh' <<<"$out" && [ ! -e "${HOME}/.local/bin/file-issue.sh" ] \
    && ok "dry run installs nothing" || fail "dry run: $out"
out="$(fj fleet-install-tools go)"
[ -x "${HOME}/.local/bin/file-issue.sh" ] && [ -x "${HOME}/.local/bin/file-comment.sh" ] && ok "go installs both" || fail "go: $out"
cmp -s "${HOME}/.local/bin/file-issue.sh" "${HERE}/../fleet/file-issue.sh" && ok "installed copy is the tool" || fail "copy differs"

echo "== 'go' only as the LAST word"
out="$(fj fleet-org go settings)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "must be the LAST word" <<<"$out" && ok "fleet-org go settings: refused" || fail "go first: $out"
: > "${GH_LOG}"
out="$(fj fleet-org settings)"
grep -q 'dry-run' <<<"$out" && ! grep -q 'PATCH' "${GH_LOG}" && ok "fleet-org settings: dry run, no PATCH" || fail "dry: $out"
out="$(fj fleet-org settings go)"
grep -q 'api -X PATCH orgs/acme' "${GH_LOG}" && ok "fleet-org settings go: PATCH sent" || fail "armed: $out"

echo "== words pass through"
out="$(fj fleet-org status)"
grep -q '^acme ' <<<"$out" && ok "fleet-org status reaches org.sh" || fail "status: $out"

echo "== a fleet script without configuration says so (recipe exits non-zero)"
out="$(fj fleet-where)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "which fleet" <<<"$out" && ok "fleet-where: asks which fleet" || fail "no config: $out"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
