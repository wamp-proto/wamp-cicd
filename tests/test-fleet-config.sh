#!/usr/bin/env bash
#
# Test fleet/lib/config.sh - how every fleet script learns WHICH fleet and its settings (#58).
#
# The rollout scripts first ran with WAMP constants (~/work/wamp, ~/.wamp-fleet, the maintainer's
# exchange-remote name). Now one file per fleet configures them; a mistake here silently points
# a rollout at the wrong clones or state, so the selection and precedence rules are pinned.
#
# Run: bash tests/test-fleet-config.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../fleet/lib/config.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }

# load [VAR=value ...] -> print the resolved settings (or the error), from a clean environment
load() {
    env -i HOME="${WORK}/home" PATH="${PATH}" FLEET_CONFIG_DIR="${WORK}/cfg" "$@" bash -c '
        . "$0" || exit 1
        for k in FLEET_NAME FLEET_INVENTORY FLEET_WORK_DIR FLEET_STATE FLEET_CI_DIR EXCHANGE UPLOAD_TO FILE_ISSUE; do
            echo "${k}=${!k}"
        done' "${LIB}" 2>&1
}
cfg() { printf '%s\n' "${@:2}" > "${WORK}/cfg/$1.env"; chmod 600 "${WORK}/cfg/$1.env"; }
mkdir -p "${WORK}/cfg" "${WORK}/home"

echo "== no configuration at all: says so, and where"
out="$(load)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "which fleet" <<<"$out" && grep -q "examples/" <<<"$out" && ok "refused with a pointer" || fail "refused: $out"

echo "== exactly one configuration: selected without FLEET_NAME, defaults filled in"
cfg alpha "FLEET_INVENTORY=/inv/alpha.toml"
out="$(load)"
grep -qx "FLEET_NAME=alpha" <<<"$out" && ok "auto-selected" || fail "auto-selected: $out"
grep -qx "FLEET_WORK_DIR=${WORK}/home/work/alpha" <<<"$out" && ok "default work dir per fleet" || fail "work dir: $out"
grep -qx "FLEET_STATE=${WORK}/home/.fleet/alpha" <<<"$out" && ok "default state per fleet" || fail "state: $out"
grep -qx "FLEET_CI_DIR=${WORK}/home/fleet-ci/alpha" <<<"$out" && ok "default CI dir per fleet" || fail "ci dir: $out"
grep -qx "EXCHANGE=exchange" <<<"$out" && grep -qx "UPLOAD_TO=" <<<"$out" && ok "neutral exchange, no upload" || fail "exchange/upload: $out"
grep -qx "FILE_ISSUE=file-issue.sh" <<<"$out" && ok "file-issue.sh from PATH" || fail "file-issue: $out"

echo "== two configurations: FLEET_NAME required, both listed"
cfg beta "FLEET_INVENTORY=/inv/beta.toml" "EXCHANGE=jx" "FLEET_WORK_DIR=/w/beta"
out="$(load)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "alpha" <<<"$out" && grep -q "beta" <<<"$out" && ok "refused, lists alpha and beta" || fail "refused: $out"
out="$(load FLEET_NAME=beta)"
grep -qx "EXCHANGE=jx" <<<"$out" && grep -qx "FLEET_WORK_DIR=/w/beta" <<<"$out" && ok "FLEET_NAME=beta reads beta.env" || fail "beta: $out"

echo "== the environment wins over the file"
out="$(load FLEET_NAME=beta EXCHANGE=override)"
grep -qx "EXCHANGE=override" <<<"$out" && grep -qx "FLEET_WORK_DIR=/w/beta" <<<"$out" && ok "env overrides one key, file keeps the rest" || fail "precedence: $out"

echo "== unknown fleet name"
out="$(load FLEET_NAME=gamma)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "no .*gamma.env" <<<"$out" && ok "refused" || fail "refused: $out"

echo "== FLEET_INVENTORY is required"
cfg delta "EXCHANGE=x"
out="$(load FLEET_NAME=delta)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FLEET_INVENTORY is not set" <<<"$out" && ok "refused" || fail "refused: $out"

echo "== a configuration others can write is refused (it is executed)"
cfg epsilon "FLEET_INVENTORY=/inv/e.toml"; chmod 620 "${WORK}/cfg/epsilon.env"
out="$(load FLEET_NAME=epsilon)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "writable by group or others" <<<"$out" && ok "group-writable refused" || fail "group-writable: $out"
chmod 602 "${WORK}/cfg/epsilon.env"
out="$(load FLEET_NAME=epsilon)"; rc=$?
[ "$rc" -ne 0 ] && ok "world-writable refused" || fail "world-writable: $out"

echo "== the shipped example parses and names the WAMP inventory"
cp "${HERE}/../fleet/examples/wamp.env" "${WORK}/cfg/wamp.env"; chmod 600 "${WORK}/cfg/wamp.env"
out="$(load FLEET_NAME=wamp)"
grep -qx "FLEET_INVENTORY=${WORK}/home/work/wamp/wamp-cicd/fleet.toml" <<<"$out" && ok "examples/wamp.env" || fail "example: $out"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
