#!/usr/bin/env bash
# lag-check.sh - has this repository received every rollout its pinned fleet definition holds?
#
#   bash .cicd/fleet/lag-check.sh [--slug <owner>/<repo>]      (from the repository's root; in CI)
#
# For a member repository's own CI. It reads the PINNED definition (.fleet/): the repository's
# cohorts from .fleet/fleet.toml, each cohort's rollouts from .fleet/rollouts/<cohort>/, and
# requires a marker .waves/<cohort>/<NNNN>-<name>.toml for every one. It FAILS otherwise: a
# repository must not silently fall behind the definition it pins - that drift is what the
# markers exist to prevent.
#
# The slug comes from --slug, else $GITHUB_REPOSITORY, else the upstream/origin forge URL.
# Exit 0 up to date; 1 behind (the missing rollouts are listed); 2 cannot tell.

set -uo pipefail
SLUG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) SLUG="$2"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "${SLUG}" ] || SLUG="${GITHUB_REPOSITORY:-}"
if [ -z "${SLUG}" ]; then
    for r in upstream origin; do
        u="$(git config --get "remote.${r}.url" 2>/dev/null || true)"
        if [[ "${u}" =~ github\.com[:/](.+)$ ]]; then SLUG="${BASH_REMATCH[1]%.git}"; break; fi
    done
fi
[ -n "${SLUG}" ] || { echo "ERROR: cannot tell this repository's slug: pass --slug <owner>/<repo>" >&2; exit 2; }
[ -f .fleet/fleet.toml ] || { echo "ERROR: no .fleet/fleet.toml here - is the .fleet submodule initialised (checkout with submodules)?" >&2; exit 2; }

python3 - "${SLUG}" <<'PY'
import os, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib
slug = sys.argv[1]
fleet = tomllib.load(open(".fleet/fleet.toml", "rb"))
me = next((r for r in fleet.get("repo", []) if str(r.get("slug", "")).lower() == slug.lower()), None)
if me is None:
    print(f"ERROR: {slug} is not in the inventory of the fleet definition it pins (.fleet/fleet.toml)")
    sys.exit(2)
missing, total = [], 0
for cohort in me.get("cohorts", []):
    d = os.path.join(".fleet", "rollouts", cohort)
    for r in sorted(x for x in (os.listdir(d) if os.path.isdir(d) else []) if os.path.isdir(os.path.join(d, x))):
        total += 1
        if not os.path.isfile(os.path.join(".waves", cohort, r + ".toml")):
            missing.append(f"{cohort}/{r}")
if missing:
    print(f"BEHIND: {slug} lacks {len(missing)} of the {total} rollouts of its cohorts ({', '.join(me.get('cohorts', []))}):")
    for m in missing:
        print(f"    {m}    (no .waves/{m}.toml)")
    sys.exit(1)
print(f"OK: {slug} has all {total} rollouts of its cohorts ({', '.join(me.get('cohorts', [])) or 'none'})")
PY
