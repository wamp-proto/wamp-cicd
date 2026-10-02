# fleet/lib/config.sh - sourced by every fleet script: WHICH fleet, and its configuration.
#
# A fleet is two files side by side in ${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/wamp-cicd/fleet}:
#   <fleet>.toml   the inventory (schema 2: cohorts + repositories; fleet/lib/check-inventory.py).
#                  Usually a symlink to fleet.toml in a clone of the fleet's definition repository.
#   <fleet>.env    per-host settings, KEY=value (shell syntax; it is sourced). OPTIONAL: every key
#                  has a default. Mode 600, in a mode 700 directory (refused otherwise).
# Which fleet: FLEET_NAME=<fleet>, or the only fleet configured there.
# A variable already set in the environment wins over the file (`EXCHANGE=other just fleet-where`).
#
# Keys of <fleet>.env (defaults in brackets):
#   EXCHANGE          name of the git remote pointing at the exchange            [exchange]
#   UPLOAD_TO         host:path collected CI results are uploaded to      [none: stay local]
#   FLEET_WORK_DIR    where the clones live, one directory per repository   [~/work/<fleet>]
#   FLEET_STATE       rollout state and logs   [${XDG_STATE_HOME:-~/.local/state}/wamp-cicd/fleet/<fleet>]
#   FLEET_CI_DIR      local copy of collected CI results                [~/fleet-ci/<fleet>]
#   CICD_URL, AI_URL  the Way-A sources pinned into every repository  [wamp-proto/wamp-{cicd,ai}]
#   CICD_DIR          a local wamp-cicd clone             [the clone these tools run from]
#   FILE_ISSUE        the issue-filing command             [file-issue.sh beside these tools]
#   FLEET_RULESETS    directory of ruleset JSON files                    [fleet/rulesets]
#   FLEET_DEF_URL     forge URL of the fleet's definition repository: what members record for
#                     .fleet/ (or in deps.toml). Needed where the definition clone has no forge
#                     remote (a host without forge credentials)   [none: derived from the clone]
# Set by this file, not configurable: FLEET_INVENTORY (= <fleet>.toml beside the .env).

FLEET_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET_CONFIG_DIR="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/wamp-cicd/fleet}"

FLEET_CONFIG_KEYS="EXCHANGE UPLOAD_TO FLEET_WORK_DIR FLEET_STATE FLEET_CI_DIR CICD_URL AI_URL CICD_DIR FILE_ISSUE FLEET_RULESETS FLEET_DEF_URL"

# The fleets configured here: every <name>.toml (and a lone <name>.env counts too, so its
# missing inventory is reported rather than the fleet being invisible).
_fleet_names() {
    local f
    for f in "${FLEET_CONFIG_DIR}"/*.toml "${FLEET_CONFIG_DIR}"/*.env; do
        [ -e "${f}" ] && basename "${f}" | sed -E 's/\.(toml|env)$//'
    done | sort -u
}

if [ -z "${FLEET_NAME:-}" ]; then
    mapfile -t _names < <(_fleet_names)
    if [ "${#_names[@]}" -eq 1 ]; then
        FLEET_NAME="${_names[0]}"
    else
        echo "ERROR: which fleet? Set FLEET_NAME to one of:" >&2
        for _n in "${_names[@]}"; do echo "    ${_n}" >&2; done
        [ "${#_names[@]}" -gt 0 ] || echo "    (none configured in ${FLEET_CONFIG_DIR}: see ${FLEET_TOOLS_DIR}/README.md, Configuration)" >&2
        exit 1
    fi
fi
FLEET_INVENTORY="${FLEET_CONFIG_DIR}/${FLEET_NAME}.toml"
_cfg="${FLEET_CONFIG_DIR}/${FLEET_NAME}.env"
[ -e "${FLEET_INVENTORY}" ] || {
    echo "ERROR: fleet '${FLEET_NAME}': no inventory ${FLEET_INVENTORY}" >&2
    echo "       (link it: ln -s <definition clone>/fleet.toml ${FLEET_INVENTORY})" >&2; exit 1; }

# Source the .env if there is one, then put back whatever the environment had set (it wins).
_fleet_keys="${FLEET_CONFIG_KEYS}"
if [ -f "${_cfg}" ]; then
    # The file is executed: refuse one that others can write - or that others can REPLACE, through
    # a directory they can write (a 600 file in a 775 directory can be swapped for another file).
    case "$(stat -L -c %a "${_cfg}")" in
        *[2367]?|*?[2367]) echo "ERROR: ${_cfg} is writable by group or others; chmod 600 it" >&2; exit 1 ;;
    esac
    case "$(stat -c %a "${FLEET_CONFIG_DIR}")" in
        *[2367]?|*?[2367]) echo "ERROR: ${FLEET_CONFIG_DIR} is writable by group or others (its .env files are executed); chmod 700 it" >&2; exit 1 ;;
    esac
    for _k in ${_fleet_keys}; do
        if [ -n "${!_k+x}" ]; then eval "_env_${_k}=\${${_k}}"; eval "_had_${_k}=1"; fi
    done
    # shellcheck source=/dev/null
    . "${_cfg}"
    for _k in ${_fleet_keys}; do
        if [ "$(eval echo "\${_had_${_k}:-}")" = 1 ]; then eval "${_k}=\${_env_${_k}}"; fi
    done
fi

EXCHANGE="${EXCHANGE:-exchange}"
UPLOAD_TO="${UPLOAD_TO:-}"
FLEET_WORK_DIR="${FLEET_WORK_DIR:-$HOME/work/${FLEET_NAME}}"
FLEET_STATE="${FLEET_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wamp-cicd/fleet/${FLEET_NAME}}"
FLEET_CI_DIR="${FLEET_CI_DIR:-$HOME/fleet-ci/${FLEET_NAME}}"
CICD_URL="${CICD_URL:-https://github.com/wamp-proto/wamp-cicd.git}"
AI_URL="${AI_URL:-https://github.com/wamp-proto/wamp-ai.git}"
CICD_DIR="${CICD_DIR:-$(dirname "${FLEET_TOOLS_DIR}")}"
FILE_ISSUE="${FILE_ISSUE:-${FLEET_TOOLS_DIR}/file-issue.sh}"
FLEET_RULESETS="${FLEET_RULESETS:-${FLEET_TOOLS_DIR}/rulesets}"
FLEET_DEF_URL="${FLEET_DEF_URL:-}"
for _k in ${_fleet_keys}; do unset "_env_${_k}" "_had_${_k}"; done
unset _names _n _cfg _k _fleet_keys
