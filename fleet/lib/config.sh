# fleet/lib/config.sh - sourced by every fleet script: WHICH fleet, and its configuration.
#
# A fleet is configured by one file, ${FLEET_CONFIG_DIR:-~/.config/fleet}/<name>.env: plain
# KEY=value lines (shell syntax; it is sourced). Which one:
#   FLEET_NAME=<name>   explicitly, or
#   the only *.env in FLEET_CONFIG_DIR, if there is exactly one.
# A variable already set in the environment wins over the file, so a one-off override is
# `EXCHANGE=other ./publish.sh`. See fleet/examples/*.env for every key.
#
# Keys (defaults in brackets):
#   FLEET_INVENTORY   path to the fleet's fleet.toml                       [required]
#   FLEET_WORK_DIR    where the clones live, one directory per repository  [~/work/<name>]
#   FLEET_STATE       rollout state: <rollout>/{fleet.tsv,pins,manifest...} [~/.fleet/<name>]
#   FLEET_CI_DIR      local copy of collected CI results                   [~/fleet-ci/<name>]
#   EXCHANGE          name of the git remote pointing at the exchange      [exchange]
#   UPLOAD_TO         host:path the CI results are uploaded to            [none: stay local]
#   CICD_URL, AI_URL  the Way-A sources pinned into every repository   [wamp-proto/wamp-{cicd,ai}]
#   CICD_DIR          a local wamp-cicd clone                   [$FLEET_WORK_DIR/wamp-cicd]
#   FILE_ISSUE        the issue-filing command                           [file-issue.sh on PATH]
#   ISSUE_TEMPLATE    the rollout's issue template (per rollout; example:          [none]
#                     fleet/examples/issue-template-wamp-wave1.md)
#   FLEET_RULESETS    directory of ruleset JSON files                        [fleet/rulesets]

FLEET_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLEET_CONFIG_DIR="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet}"

_fleet_keys="FLEET_INVENTORY FLEET_WORK_DIR FLEET_STATE FLEET_CI_DIR EXCHANGE UPLOAD_TO CICD_URL AI_URL CICD_DIR FILE_ISSUE ISSUE_TEMPLATE FLEET_RULESETS"

if [ -z "${FLEET_NAME:-}" ]; then
    _cfgs=("${FLEET_CONFIG_DIR}"/*.env)
    if [ "${#_cfgs[@]}" -eq 1 ] && [ -f "${_cfgs[0]}" ]; then
        FLEET_NAME="$(basename "${_cfgs[0]}" .env)"
    else
        echo "ERROR: which fleet? Set FLEET_NAME to one of:" >&2
        for _c in "${_cfgs[@]}"; do [ -f "${_c}" ] && echo "    $(basename "${_c}" .env)" >&2; done
        [ -f "${_cfgs[0]}" ] || echo "    (none: create ${FLEET_CONFIG_DIR}/<name>.env, see ${FLEET_TOOLS_DIR}/examples/)" >&2
        exit 1
    fi
fi
_cfg="${FLEET_CONFIG_DIR}/${FLEET_NAME}.env"
[ -f "${_cfg}" ] || { echo "ERROR: fleet '${FLEET_NAME}': no ${_cfg} (see ${FLEET_TOOLS_DIR}/examples/)" >&2; exit 1; }
# The file is executed: refuse one that others can write.
case "$(stat -c %a "${_cfg}")" in
    *[2367]?|*?[2367]) echo "ERROR: ${_cfg} is writable by group or others; chmod 600 it" >&2; exit 1 ;;
esac

# Source the file, then put back whatever the environment had set (the environment wins).
for _k in ${_fleet_keys}; do
    if [ -n "${!_k+x}" ]; then eval "_env_${_k}=\${${_k}}"; eval "_had_${_k}=1"; fi
done
# shellcheck source=/dev/null
. "${_cfg}"
for _k in ${_fleet_keys}; do
    if [ "$(eval echo "\${_had_${_k}:-}")" = 1 ]; then eval "${_k}=\${_env_${_k}}"; fi
done

: "${FLEET_INVENTORY:?fleet '${FLEET_NAME}': FLEET_INVENTORY is not set in ${_cfg}}"
FLEET_WORK_DIR="${FLEET_WORK_DIR:-$HOME/work/${FLEET_NAME}}"
FLEET_STATE="${FLEET_STATE:-$HOME/.fleet/${FLEET_NAME}}"
FLEET_CI_DIR="${FLEET_CI_DIR:-$HOME/fleet-ci/${FLEET_NAME}}"
EXCHANGE="${EXCHANGE:-exchange}"
UPLOAD_TO="${UPLOAD_TO:-}"
CICD_URL="${CICD_URL:-https://github.com/wamp-proto/wamp-cicd.git}"
AI_URL="${AI_URL:-https://github.com/wamp-proto/wamp-ai.git}"
CICD_DIR="${CICD_DIR:-${FLEET_WORK_DIR}/wamp-cicd}"
FILE_ISSUE="${FILE_ISSUE:-file-issue.sh}"
ISSUE_TEMPLATE="${ISSUE_TEMPLATE:-}"
FLEET_RULESETS="${FLEET_RULESETS:-${FLEET_TOOLS_DIR}/rulesets}"
for _k in ${_fleet_keys}; do unset "_env_${_k}" "_had_${_k}"; done
unset _cfgs _c _cfg _k _fleet_keys
