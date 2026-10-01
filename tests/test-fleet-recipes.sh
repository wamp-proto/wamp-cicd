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

# Hermetic: CI runners set XDG_CONFIG_HOME, which the config loader prefers over $HOME/.config.
unset XDG_CONFIG_HOME
unset FLEET_NAME XDG_STATE_HOME
export HOME="${WORK}/home" FLEET_CONFIG_DIR="${WORK}/home/.config/wamp-cicd/fleet"; mkdir -p "${HOME}" "${WORK}/bin"
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
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

echo "== fleet-install-tools: prefixed symlinks into this clone; dry run, then go"
BIN="${HOME}/.local/bin"; TOOLS="$(cd "${HERE}/../fleet" && pwd)"
out="$(fj fleet-install-tools)"
grep -q "\[dry-run\] link ${BIN}/wamp-cicd-file-issue.sh -> ${TOOLS}/file-issue.sh" <<<"$out" && [ ! -e "${BIN}/wamp-cicd-file-issue.sh" ] \
    && ok "dry run links nothing" || fail "dry run: $out"
out="$(fj fleet-install-tools go)"
all=1; for t in file-issue.sh file-comment.sh pr-ci.sh; do
    [ -L "${BIN}/wamp-cicd-${t}" ] && [ "$(readlink "${BIN}/wamp-cicd-${t}")" = "${TOOLS}/${t}" ] || all=0; done
[ "$all" = 1 ] && ok "go: wamp-cicd-{file-issue,file-comment,pr-ci}.sh are symlinks into the clone" || fail "go: $out"
out="$("${BIN}/wamp-cicd-pr-ci.sh" --help 2>&1)"
grep -q "collect ONE pull request's CI results" <<<"$out" && ok "pr-ci.sh runs through its symlink (finds its library)" || fail "symlink run: $out"
out="$(fj fleet-install-tools go)"
[ "$(grep -c '^ok ' <<<"$out")" = 3 ] && ok "re-run: nothing to do" || fail "re-run: $out"
ln -sfn /elsewhere/pr-ci.sh "${BIN}/wamp-cicd-pr-ci.sh"
out="$(fj fleet-install-tools go)"
[ "$(readlink "${BIN}/wamp-cicd-pr-ci.sh")" = "${TOOLS}/pr-ci.sh" ] && ok "a symlink pointing elsewhere is re-pointed" || fail "re-point: $out"
rm -f "${BIN}/wamp-cicd-pr-ci.sh"; echo "mine" > "${BIN}/wamp-cicd-pr-ci.sh"
out="$(fj fleet-install-tools go)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "BLOCKED .*wamp-cicd-pr-ci.sh: exists and is not a symlink" <<<"$out" && [ "$(cat "${BIN}/wamp-cicd-pr-ci.sh")" = mine ] \
    && ok "a regular file is never touched (blocked, exit non-zero)" || fail "regular file: $out"

echo "== refuses to install from inside a .cicd/ submodule"
git config --global user.name T; git config --global user.email t@example.invalid; git config --global protocol.file.allow always
git init -q "${WORK}/tools"; cp -r "${HERE}/../fleet" "${WORK}/tools/fleet"
git -C "${WORK}/tools" add -A; git -C "${WORK}/tools" commit -qm tools
git init -q "${WORK}/member"; git -C "${WORK}/member" submodule add -q "${WORK}/tools" .cicd 2>/dev/null
out="$(cd "${WORK}" && just -f "${WORK}/member/.cicd/fleet/fleet.just" fleet-install-tools go 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "REFUSING: .* is inside a git submodule" <<<"$out" && ok "refused" || fail "submodule: $out"

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
