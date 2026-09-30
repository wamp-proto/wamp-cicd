#!/usr/bin/env bash
#
# Test fleet.toml - the one versioned answer to "which repositories are aligned, and how
# far" (#16).
#
# Rollout tooling reads this file and acts on every entry of a wave: files issues, cuts
# branches, lands them. A malformed entry does not fail loudly there - it silently drops a
# repository from a rollout, or aims one at the wrong slug or branch. So the structure is
# asserted here, where a mistake costs one red test run.
#
# Offline by design: whether a slug and default branch are TRUE is checked against the live
# remotes by the rollout tool's preflight. This test checks that they are well-formed.
#
# Run: bash tests/test-fleet.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="${HERE}/../fleet.toml"
[ -f "$FLEET" ] || { echo "FATAL: no $FLEET" >&2; exit 2; }

python3 - "$FLEET" "${HERE}/../fleet/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
import importlib.util
spec = importlib.util.spec_from_file_location("ci", sys.argv[2] + "/check-inventory.py")
ci = importlib.util.module_from_spec(spec); spec.loader.exec_module(ci)
try:
    import tomllib
except ImportError:
    import tomli as tomllib

# 1. The contract every fleet inventory meets (fleet/lib/check-inventory.py).
results = ci.check_inventory(sys.argv[1]) or [False]

# 2. What only the WAMP inventory must additionally be.
fleet = tomllib.load(open(sys.argv[1], "rb"))
repos = fleet.get("repo", [])
def check(label, cond, detail=""):
    results.append(bool(cond))
    print(f"  {'ok  ' if cond else 'FAIL'} [{label}] {'' if cond else detail}")
KINDS = {"python", "javascript", "spec", "tool", "site", "cpp", "java", "tooling-source"}
for r in repos:
    check(f"{r.get('name')}: kind is one of WAMP's", r.get("kind") in KINDS, repr(r.get("kind")))
check("wave 1 is not empty", any(r.get("wave") == 1 for r in repos))
check("this repository is in the fleet", "wamp-cicd" in [r.get("name") for r in repos])

print(f"\n{results.count(True)} passed, {results.count(False)} failed")
sys.exit(1 if results.count(False) else 0)
PY
