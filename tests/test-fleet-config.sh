#!/usr/bin/env bash
#
# Test fleet/lib/config.sh and fleet/check.sh - how every fleet script learns WHICH fleet and its
# settings (#58, #60).
#
# A fleet is two files side by side in ~/.config/wamp-cicd/fleet/: <fleet>.toml (the inventory,
# usually a symlink into the definition repository's clone) and <fleet>.env (per-host settings,
# optional). A mistake here silently points a rollout at the wrong clones or state, so the
# selection, the defaults and the precedence are pinned - and `fleet-check`, the check a
# GENERATED configuration must pass.
#
# Run: bash tests/test-fleet-config.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../fleet/lib/config.sh"
CHK="${HERE}/../fleet/check.sh"
GOOD="${HERE}/fixtures/fleet.toml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }

CFG="${WORK}/home/.config/wamp-cicd/fleet"
mkdir -p "${CFG}"; chmod 700 "${CFG}"   # explicit: not the umask's choice
# load [VAR=value ...] -> print the resolved settings (or the error), from a clean environment
load() {
    env -i HOME="${WORK}/home" PATH="${PATH}" "$@" bash -c '
        . "$0" || exit 1
        for k in FLEET_NAME FLEET_INVENTORY FLEET_WORK_DIR FLEET_STATE FLEET_CI_DIR EXCHANGE UPLOAD_TO FILE_ISSUE CICD_DIR; do
            echo "${k}=${!k}"
        done' "${LIB}" 2>&1
}
chk() { env -i HOME="${WORK}/home" PATH="${PATH}" FLEET_NAME="$1" bash "${CHK}" 2>&1; }
inv() { ln -sfn "${2:-${GOOD}}" "${CFG}/$1.toml"; }                       # the inventory: a symlink
envf() { printf '%s\n' "${@:2}" > "${CFG}/$1.env"; chmod 600 "${CFG}/$1.env"; }
TOOLS="$(cd "${HERE}/../fleet" && pwd)"

echo "== nothing configured: says so, and where"
out="$(load)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "which fleet" <<<"$out" && grep -q "none configured in ${CFG}" <<<"$out" && ok "refused with a pointer" || fail "refused: $out"

echo "== one fleet, inventory only (no .env): selected, every default"
inv alpha
out="$(load)"
grep -qx "FLEET_NAME=alpha" <<<"$out" && ok "auto-selected" || fail "auto-selected: $out"
grep -qx "FLEET_INVENTORY=${CFG}/alpha.toml" <<<"$out" && ok "inventory = <fleet>.toml beside the .env" || fail "inventory: $out"
grep -qx "FLEET_WORK_DIR=${WORK}/home/work/alpha" <<<"$out" && ok "work dir ~/work/<fleet>" || fail "work dir: $out"
grep -qx "FLEET_STATE=${WORK}/home/.local/state/wamp-cicd/fleet/alpha" <<<"$out" && ok "state under XDG_STATE_HOME" || fail "state: $out"
grep -qx "FLEET_CI_DIR=${WORK}/home/fleet-ci/alpha" <<<"$out" && ok "CI results ~/fleet-ci/<fleet>" || fail "ci dir: $out"
grep -qx "EXCHANGE=exchange" <<<"$out" && grep -qx "UPLOAD_TO=" <<<"$out" && ok "neutral exchange, no upload" || fail "exchange/upload: $out"
grep -qx "FILE_ISSUE=${TOOLS}/file-issue.sh" <<<"$out" && ok "file-issue.sh beside the tools" || fail "file-issue: $out"
grep -qx "CICD_DIR=$(dirname "${TOOLS}")" <<<"$out" && ok "CICD_DIR = the clone the tools run from" || fail "cicd dir: $out"
out="$(load XDG_STATE_HOME=/xdg/state XDG_CONFIG_HOME="${WORK}/home/.config")"
grep -qx "FLEET_STATE=/xdg/state/wamp-cicd/fleet/alpha" <<<"$out" && ok "XDG_STATE_HOME and XDG_CONFIG_HOME honoured" || fail "xdg: $out"

echo "== two fleets: FLEET_NAME required, both listed; the .env supplies host settings"
inv beta; envf beta "EXCHANGE=jx" "UPLOAD_TO=aihost:/srv/ci/beta"
out="$(load)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "alpha" <<<"$out" && grep -q "beta" <<<"$out" && ok "refused, lists alpha and beta" || fail "refused: $out"
out="$(load FLEET_NAME=beta)"
grep -qx "EXCHANGE=jx" <<<"$out" && grep -qx "UPLOAD_TO=aihost:/srv/ci/beta" <<<"$out" && ok "FLEET_NAME=beta reads beta.env" || fail "beta: $out"
out="$(load FLEET_NAME=beta EXCHANGE=override)"
grep -qx "EXCHANGE=override" <<<"$out" && grep -qx "UPLOAD_TO=aihost:/srv/ci/beta" <<<"$out" && ok "the environment wins over the file, key by key" || fail "precedence: $out"

echo "== refusals"
out="$(load FLEET_NAME=gamma)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "no inventory .*gamma.toml" <<<"$out" && ok "unknown fleet: no inventory" || fail "unknown: $out"
envf delta "EXCHANGE=x"
out="$(load FLEET_NAME=delta)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "no inventory .*delta.toml" <<<"$out" && ok "a .env without its inventory" || fail "env only: $out"
rm -f "${CFG}/delta.env"
inv eps; envf eps "EXCHANGE=x"; chmod 620 "${CFG}/eps.env"
out="$(load FLEET_NAME=eps)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "writable by group or others; chmod 600" <<<"$out" && ok "group-writable .env" || fail "group-writable: $out"
chmod 600 "${CFG}/eps.env"; chmod 775 "${CFG}"
out="$(load FLEET_NAME=eps)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "its .env files are executed" <<<"$out" && ok "group-writable directory (the .env could be replaced)" || fail "dir: $out"
out="$(load FLEET_NAME=alpha)"; rc=$?
[ "$rc" -eq 0 ] && ok "...but a fleet WITHOUT an .env is not affected (nothing is executed)" || fail "no-env fleet in 775 dir: $out"
chmod 700 "${CFG}"

echo "== fleet-check (fleet/check.sh): the check for generated configurations"
out="$(chk beta)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "OK: fleet 'beta' is valid" <<<"$out" && ok "a valid fleet passes" || fail "valid: $out"
grep -q "cohort way-a: 2 repositories" <<<"$out" && grep -q "in no cohort (take part in nothing): dormant" <<<"$out" && ok "shows the cohorts and their sizes" || fail "cohorts: $out"
grep -q "beta.toml -> ${GOOD}" <<<"$out" && ok "shows where the inventory symlink points" || fail "symlink info: $out"
out="$(chk alpha)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "no alpha.env: every setting at its default" <<<"$out" && ok "a fleet without .env passes" || fail "no env: $out"
inv typo; envf typo "UPLOADTO=aihost:/srv/ci"
out="$(chk typo)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "unknown key(s) in typo.env: UPLOADTO" <<<"$out" && ok "an unknown key (typo) fails" || fail "typo: $out"
envf typo "FLEET_INVENTORY=/somewhere/fleet.toml"
out="$(chk typo)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "unknown key(s) in typo.env: FLEET_INVENTORY" <<<"$out" && ok "FLEET_INVENTORY is no longer a key" || fail "FLEET_INVENTORY: $out"
envf typo "FLEET_DEF_URL=https://github.com/acme/acme-fleet.git"
out="$(chk typo)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "FLEET_DEF_URL *https://github.com/acme/acme-fleet.git" <<<"$out" && ok "FLEET_DEF_URL is a known key (#69)" || fail "FLEET_DEF_URL: $out"
sed 's|"acme/alpha"|"acme/other"|' "${GOOD}" > "${WORK}/bad.toml"; inv badinv "${WORK}/bad.toml"
out="$(chk badinv)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "slug ends in the name" <<<"$out" && ok "an invalid inventory fails, naming the check" || fail "bad inventory: $out"
sed 's/^schema = 2/schema = 1/' "${GOOD}" > "${WORK}/s1.toml"; inv old "${WORK}/s1.toml"
out="$(chk old)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "schema-1 inventory" <<<"$out" && ok "a schema-1 inventory is refused" || fail "schema 1: $out"
inv badup; envf badup "UPLOAD_TO=/just/a/path"
out="$(chk badup)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "UPLOAD_TO is not host:path" <<<"$out" && ok "UPLOAD_TO without a host fails" || fail "upload: $out"
# a definition repository: the inventory with rollouts beside it
mkdir -p "${WORK}/def/rollouts/way-a/0001-first" "${WORK}/def/rollouts/nosuch/0001-x"
cp "${GOOD}" "${WORK}/def/fleet.toml"; inv withdef "${WORK}/def/fleet.toml"
printf 'name = "0001-first"\ncohort = "way-a"\ndescription = "d"\n[applied]\nby = "hand"\n' > "${WORK}/def/rollouts/way-a/0001-first/rollout.toml"
printf 'name = "0001-x"\ncohort = "nosuch"\ndescription = "d"\n[applied]\nby = "hand"\n' > "${WORK}/def/rollouts/nosuch/0001-x/rollout.toml"
out="$(chk withdef)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "its cohort 'nosuch' is not defined in the inventory" <<<"$out" && ok "a rollout for an undefined cohort fails" || fail "rollout cohort: $out"
rm -rf "${WORK}/def/rollouts/nosuch"
out="$(chk withdef)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "1 rollout(s) valid" <<<"$out" && ok "the definition's rollouts are checked too" || fail "rollouts valid: $out"
sed -i 's/^name = .*/name = "0001-renamed"/' "${WORK}/def/rollouts/way-a/0001-first/rollout.toml"
out="$(chk withdef)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "name equals the directory" <<<"$out" && ok "an invalid rollout fails fleet-check" || fail "invalid rollout: $out"
ln -sfn "${WORK}/gone.toml" "${CFG}/dangling.toml"
out="$(chk dangling)"; rc=$?
[ "$rc" -ne 0 ] && grep -qE "no inventory|points at nothing" <<<"$out" && ok "a dangling inventory symlink fails" || fail "dangling: $out"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
