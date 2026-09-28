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

python3 - "$FLEET" <<'PY'
import re, sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

fleet = tomllib.load(open(sys.argv[1], "rb"))
passed = failed = 0

def check(label, cond, detail=""):
    global passed, failed
    if cond:
        print(f"  ok   [{label}]"); passed += 1
    else:
        print(f"  FAIL [{label}] {detail}"); failed += 1

KEYS = {"name", "slug", "default_branch", "kind", "wave", "notes"}
KINDS = {"python", "javascript", "spec", "tool", "site", "cpp", "java", "tooling-source"}

check("schema is 1", fleet.get("schema") == 1, f"got {fleet.get('schema')!r}")
repos = fleet.get("repo", [])
check("has repositories", len(repos) > 0)

names = [r.get("name") for r in repos]
dupes = sorted({n for n in names if names.count(n) > 1})
check("names are unique", not dupes, f"duplicates: {dupes}")
slugs = [r.get("slug") for r in repos]
dupes = sorted({s for s in slugs if slugs.count(s) > 1})
check("slugs are unique", not dupes, f"duplicates: {dupes}")

for r in repos:
    n = r.get("name", "<unnamed>")
    check(f"{n}: exactly the known keys", set(r) == KEYS, f"missing {sorted(KEYS - set(r))}, unknown {sorted(set(r) - KEYS)}")
    check(f"{n}: slug is owner/repo", bool(re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", str(r.get("slug", "")))), repr(r.get("slug")))
    check(f"{n}: slug ends in the name", str(r.get("slug", "")).split("/")[-1] == n, repr(r.get("slug")))
    check(f"{n}: default_branch set", bool(re.fullmatch(r"[A-Za-z0-9._/-]+", str(r.get("default_branch", "")))), repr(r.get("default_branch")))
    check(f"{n}: kind known", r.get("kind") in KINDS, repr(r.get("kind")))
    check(f"{n}: wave is a non-negative int", isinstance(r.get("wave"), int) and r["wave"] >= 0, repr(r.get("wave")))
    check(f"{n}: notes say why", bool(str(r.get("notes", "")).strip()))

check("wave 1 is not empty", any(r.get("wave") == 1 for r in repos))
check("this repository is in the fleet", "wamp-cicd" in names)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
