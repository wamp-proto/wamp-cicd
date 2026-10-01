#!/usr/bin/env bash
# check.sh - is this fleet's configuration valid?  (read-only; `just fleet-check`)
#
# The check a GENERATED configuration must pass, as much as a hand-written one. A fleet is two
# files side by side in the fleet configuration directory: <fleet>.toml (the inventory) and
# <fleet>.env (per-host settings, optional). Checked:
#   - the .env, if present: not writable by others, nor its directory (fleet/lib/config.sh refuses
#     otherwise); only KNOWN keys - an unknown one (a typo, a generator bug) would silently do
#     nothing, and the default would win without anyone noticing;
#   - the resolved settings, printed;
#   - the inventory against the schema-2 contract (fleet/lib/check-inventory.py), where it points
#     (it is usually a symlink into the definition repository's clone), and its cohorts;
#   - UPLOAD_TO looks like host:path;
#   - which repositories of the inventory are cloned under FLEET_WORK_DIR (information only).
# Exit 0 when valid, 1 otherwise.

set -uo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"

cfg="${FLEET_CONFIG_DIR}/${FLEET_NAME}.env"
fails=0
bad() { echo "  FAIL $*"; fails=$((fails+1)); }
good() { echo "  ok   $*"; }

echo "fleet '${FLEET_NAME}' in ${FLEET_CONFIG_DIR}"
if [ -f "${cfg}" ]; then
    good "${FLEET_NAME}.env: mode $(stat -L -c %a "${cfg}"), directory $(stat -c %a "${FLEET_CONFIG_DIR}") - not writable by others"
    unknown="$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "${cfg}" \
        | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | sort -u \
        | grep -vxF -f <(tr ' ' '\n' <<<"${FLEET_CONFIG_KEYS}") || true)"
    if [ -n "${unknown}" ]; then bad "unknown key(s) in ${FLEET_NAME}.env: $(echo ${unknown}) (known: ${FLEET_CONFIG_KEYS})"
    else good "${FLEET_NAME}.env: only known keys"; fi
else
    good "no ${FLEET_NAME}.env: every setting at its default"
fi

echo ""
echo "resolved settings:"
for k in ${FLEET_CONFIG_KEYS}; do printf '    %-16s %s\n' "${k}" "${!k:-(unset)}"; done
echo ""

target="$(readlink -f "${FLEET_INVENTORY}")"
[ "${target}" = "${FLEET_INVENTORY}" ] || echo "  info ${FLEET_NAME}.toml -> ${target}"
if [ ! -f "${target}" ]; then
    bad "inventory: ${FLEET_INVENTORY} points at nothing"
elif python3 "${FLEET_TOOLS_DIR}/lib/check-inventory.py" "${FLEET_INVENTORY}" --quiet; then
    good "inventory valid (schema 2)"
    python3 - "${FLEET_INVENTORY}" <<'PY'
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
f = tomllib.load(open(sys.argv[1], "rb"))
for c in f.get("cohort", []):
    n = sum(1 for r in f.get("repo", []) if c["name"] in r.get("cohorts", []))
    print(f"  info cohort {c['name']}: {n} repositories - {c['description']}")
none = [r["name"] for r in f.get("repo", []) if not r.get("cohorts")]
if none:
    print(f"  info in no cohort (take part in nothing): {' '.join(none)}")
PY
else
    bad "inventory invalid (failed checks above)"
fi

if [ -n "${UPLOAD_TO}" ] && [[ ! "${UPLOAD_TO}" =~ ^[A-Za-z0-9._@-]+:.+ ]]; then
    bad "UPLOAD_TO is not host:path: ${UPLOAD_TO}"
fi

if [ -f "${target}" ]; then
    cloned=0; missing=()
    while IFS=$'\t' read -r n _rest; do
        [ -n "${n}" ] || continue
        if [ -e "${FLEET_WORK_DIR}/${n}/.git" ]; then cloned=$((cloned+1)); else missing+=("${n}"); fi
    done < <(python3 "${FLEET_TOOLS_DIR}/lib/inventory-repos.py" "${FLEET_INVENTORY}" 2>/dev/null)
    echo "  info ${cloned} cloned under ${FLEET_WORK_DIR}${missing:+; not cloned: ${missing[*]}}"
fi

echo ""
if [ "${fails}" -eq 0 ]; then echo "OK: fleet '${FLEET_NAME}' is valid"; else echo "INVALID: ${fails} problem(s)"; exit 1; fi
