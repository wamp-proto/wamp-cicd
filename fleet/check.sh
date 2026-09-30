#!/usr/bin/env bash
# check.sh - is this fleet's configuration valid?  (read-only; `just fleet-check`)
#
# The check a GENERATED configuration must pass, as much as a hand-written one: a fleet is its
# configuration file (~/.config/fleet/<name>.env) plus the repository list it points to
# (FLEET_INVENTORY). Checked:
#   - the file and its directory: not writable by others (fleet/lib/config.sh refuses otherwise);
#   - only KNOWN keys in the file: an unknown one (a typo, a generator bug) would silently do
#     nothing, and the default would win without anyone noticing;
#   - the resolved settings, printed;
#   - the inventory against the contract (fleet/lib/check-inventory.py);
#   - UPLOAD_TO looks like host:path; ISSUE_TEMPLATE, if set, exists;
#   - which repositories of the inventory are cloned under FLEET_WORK_DIR (information only).
# Exit 0 when valid, 1 otherwise.

set -uo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "$(readlink -f "$0")")/lib/config.sh"

cfg="${FLEET_CONFIG_DIR}/${FLEET_NAME}.env"
fails=0
bad() { echo "  FAIL $*"; fails=$((fails+1)); }
good() { echo "  ok   $*"; }

echo "fleet '${FLEET_NAME}': ${cfg}"
good "file $(stat -c %a "${cfg}"), directory $(stat -c %a "${FLEET_CONFIG_DIR}"): not writable by others"

unknown="$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "${cfg}" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' | sort -u \
    | grep -vxF -f <(tr ' ' '\n' <<<"${FLEET_CONFIG_KEYS}") || true)"
if [ -n "${unknown}" ]; then bad "unknown key(s) in the file: $(echo ${unknown}) (known: ${FLEET_CONFIG_KEYS})"
else good "only known keys"; fi

echo ""
echo "resolved settings:"
for k in ${FLEET_CONFIG_KEYS}; do printf '    %-16s %s\n' "${k}" "${!k:-(unset)}"; done
echo ""

if [ ! -f "${FLEET_INVENTORY}" ]; then
    bad "FLEET_INVENTORY: no file at ${FLEET_INVENTORY}"
elif python3 "${FLEET_TOOLS_DIR}/lib/check-inventory.py" "${FLEET_INVENTORY}" --quiet; then
    good "inventory valid: ${FLEET_INVENTORY}"
else
    bad "inventory invalid: ${FLEET_INVENTORY} (failed checks above)"
fi

if [ -n "${UPLOAD_TO}" ] && [[ ! "${UPLOAD_TO}" =~ ^[A-Za-z0-9._@-]+:.+ ]]; then
    bad "UPLOAD_TO is not host:path: ${UPLOAD_TO}"
fi
if [ -n "${ISSUE_TEMPLATE}" ] && [ ! -f "${ISSUE_TEMPLATE}" ]; then
    bad "ISSUE_TEMPLATE: no file at ${ISSUE_TEMPLATE}"
fi

if [ -f "${FLEET_INVENTORY}" ]; then
    cloned=0; missing=()
    while read -r n; do
        if [ -d "${FLEET_WORK_DIR}/${n}/.git" ] || [ -f "${FLEET_WORK_DIR}/${n}/.git" ]; then cloned=$((cloned+1)); else missing+=("${n}"); fi
    done < <(python3 -c 'import sys,tomllib; [print(r["name"]) for r in tomllib.load(open(sys.argv[1],"rb")).get("repo",[]) if isinstance(r,dict) and "name" in r]' "${FLEET_INVENTORY}" 2>/dev/null)
    echo "  info ${cloned} cloned under ${FLEET_WORK_DIR}${missing:+; not cloned: ${missing[*]}}"
fi

echo ""
if [ "${fails}" -eq 0 ]; then echo "OK: fleet '${FLEET_NAME}' is valid"; else echo "INVALID: ${fails} problem(s)"; exit 1; fi
