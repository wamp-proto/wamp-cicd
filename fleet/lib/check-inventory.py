#!/usr/bin/env python3
"""check-inventory.py <fleet.toml> [--quiet]  -  is this a valid fleet inventory?

The contract every fleet's repository list must meet, whether hand-written or GENERATED from a
single source of truth. A malformed entry does not fail loudly later: it silently drops a
repository from a rollout, or aims one at the wrong slug or branch. So it is checked here, and
by `rollout.sh init` before a rollout freezes the inventory.

    schema = 1
    [[repo]]
    name           = "<directory name of the clone>"
    slug           = "<owner>/<name>"          # GitHub owner/repository; ends in name
    default_branch = "<branch>"
    kind           = "<lowercase word>"        # informational (python, cpp, ansible, ...)
    wave           = <int >= 0>                # 0 = not rolled out
    notes          = "<why it is in the fleet>"

Exit 0 when valid, 1 when not (each failed check is printed), 2 when unreadable.
"""
import re
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib

KEYS = {"name", "slug", "default_branch", "kind", "wave", "notes"}


def check_inventory(path, quiet=False):
    try:
        fleet = tomllib.load(open(path, "rb"))
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

    check("schema is 1", fleet.get("schema") == 1, f"got {fleet.get('schema')!r}")
    check("only schema and repo at the top", set(fleet) <= {"schema", "repo"}, f"unknown {sorted(set(fleet) - {'schema', 'repo'})}")
    repos = fleet.get("repo", [])
    check("has repositories", isinstance(repos, list) and len(repos) > 0)
    names = [r.get("name") for r in repos]
    dupes = sorted({n for n in names if names.count(n) > 1})
    check("names are unique", not dupes, f"duplicates: {dupes}")
    slugs = [str(r.get("slug", "")).lower() for r in repos]
    dupes = sorted({s for s in slugs if slugs.count(s) > 1})
    check("slugs are unique", not dupes, f"duplicates: {dupes}")
    for r in repos:
        n = r.get("name", "<unnamed>")
        check(f"{n}: exactly the known keys", set(r) == KEYS, f"missing {sorted(KEYS - set(r))}, unknown {sorted(set(r) - KEYS)}")
        check(f"{n}: name is a plain directory name", bool(re.fullmatch(r"[A-Za-z0-9._-]+", str(n))) and n not in (".", ".."), repr(n))
        check(f"{n}: slug is owner/repo", bool(re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", str(r.get("slug", "")))), repr(r.get("slug")))
        check(f"{n}: slug ends in the name", str(r.get("slug", "")).split("/")[-1] == n, repr(r.get("slug")))
        check(f"{n}: default_branch set", bool(re.fullmatch(r"[A-Za-z0-9._/-]+", str(r.get("default_branch", "")))), repr(r.get("default_branch")))
        check(f"{n}: kind is a lowercase word", bool(re.fullmatch(r"[a-z][a-z0-9-]*", str(r.get("kind", "")))), repr(r.get("kind")))
        check(f"{n}: wave is a non-negative int", isinstance(r.get("wave"), int) and not isinstance(r.get("wave"), bool) and r["wave"] >= 0, repr(r.get("wave")))
        check(f"{n}: notes say why", bool(str(r.get("notes", "")).strip()))
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
