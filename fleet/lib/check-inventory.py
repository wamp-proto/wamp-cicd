#!/usr/bin/env python3
"""check-inventory.py <fleet.toml> [--quiet]  -  is this a valid fleet inventory (schema 2)?

The contract every fleet's inventory must meet, whether hand-written or GENERATED from a single
source of truth. A malformed entry does not fail loudly later: it silently drops a repository
from a rollout, or aims one at the wrong slug or branch. So it is checked here, by
`just fleet-check`, and by `rollout.sh init` before a rollout freezes the inventory.

    schema = 2

    [[cohort]]                                  # a named subset of the fleet
    name        = "<lowercase word>"            # unique
    description = "<what its members have in common>"

    [[repo]]
    name           = "<directory name of the clone>"
    slug           = "<owner>/<name>"           # GitHub owner/repository; ends in name
    default_branch = "<branch>"
    cohorts        = ["<cohort>", ...]          # defined cohorts; empty = takes part in nothing

No other keys, anywhere. Comments are fine (a generated file carries a header).
Exit 0 when valid, 1 when not (each failed check is printed), 2 when unreadable.
"""
import re
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib

REPO_KEYS = {"name", "slug", "default_branch", "cohorts"}
COHORT_KEYS = {"name", "description"}
WORD = r"[a-z][a-z0-9-]*"


def load(path):
    return tomllib.load(open(path, "rb"))


def check_inventory(path, quiet=False):
    try:
        fleet = load(path)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"  FAIL [readable TOML] {e}")
        return None
    results = []

    def check(label, cond, detail=""):
        results.append(bool(cond))
        if not cond:
            print(f"  FAIL [{label}] {detail}")
        elif not quiet:
            print(f"  ok   [{label}]")

    if fleet.get("schema") == 1:
        check("schema is 2", False, "this is a schema-1 inventory (per-repository wave/kind/notes); "
              "schema 2 has [[cohort]] entries and `cohorts = [...]` per repository")
        return results
    check("schema is 2", fleet.get("schema") == 2, f"got {fleet.get('schema')!r}")
    top = {"schema", "cohort", "repo"}
    check("only schema, cohort and repo at the top", set(fleet) <= top, f"unknown {sorted(set(fleet) - top)}")

    cohorts = fleet.get("cohort", [])
    cohorts = cohorts if isinstance(cohorts, list) else []
    cnames = [c.get("name") for c in cohorts if isinstance(c, dict)]
    dupes = sorted({str(n) for n in cnames if cnames.count(n) > 1})
    check("cohort names are unique", not dupes, f"duplicates: {dupes}")
    for c in cohorts:
        n = c.get("name", "<unnamed>")
        check(f"cohort {n}: exactly name and description", set(c) == COHORT_KEYS,
              f"missing {sorted(COHORT_KEYS - set(c))}, unknown {sorted(set(c) - COHORT_KEYS)}")
        check(f"cohort {n}: name is a lowercase word", bool(re.fullmatch(WORD, str(n))), repr(n))
        check(f"cohort {n}: description says what its members share", bool(str(c.get("description", "")).strip()))

    repos = fleet.get("repo", [])
    check("has repositories", isinstance(repos, list) and len(repos) > 0)
    repos = repos if isinstance(repos, list) else []
    names = [r.get("name") for r in repos]
    dupes = sorted({str(n) for n in names if names.count(n) > 1})
    check("names are unique", not dupes, f"duplicates: {dupes}")
    slugs = [str(r.get("slug", "")).lower() for r in repos]
    dupes = sorted({s for s in slugs if slugs.count(s) > 1})
    check("slugs are unique", not dupes, f"duplicates: {dupes}")
    for r in repos:
        n = r.get("name", "<unnamed>")
        check(f"{n}: exactly the known keys", set(r) == REPO_KEYS,
              f"missing {sorted(REPO_KEYS - set(r))}, unknown {sorted(set(r) - REPO_KEYS)}")
        check(f"{n}: name is a plain directory name", bool(re.fullmatch(r"[A-Za-z0-9._-]+", str(n))) and n not in (".", ".."), repr(n))
        check(f"{n}: slug is owner/repo", bool(re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", str(r.get("slug", "")))), repr(r.get("slug")))
        check(f"{n}: slug ends in the name", str(r.get("slug", "")).split("/")[-1] == n, repr(r.get("slug")))
        check(f"{n}: default_branch set", bool(re.fullmatch(r"[A-Za-z0-9._/-]+", str(r.get("default_branch", "")))), repr(r.get("default_branch")))
        rc = r.get("cohorts")
        is_list = isinstance(rc, list) and all(isinstance(x, str) for x in rc)
        check(f"{n}: cohorts is a list of names", is_list, repr(rc))
        if is_list:
            undefined = sorted(set(rc) - set(cnames))
            check(f"{n}: every cohort is defined", not undefined, f"undefined: {undefined}")
            check(f"{n}: no cohort listed twice", len(rc) == len(set(rc)), repr(rc))
    return results


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    if len(args) != 1:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    results = check_inventory(args[0], quiet="--quiet" in sys.argv)
    if results is None:
        return 2
    passed, failed = results.count(True), results.count(False)
    if "--quiet" not in sys.argv or failed:
        print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
