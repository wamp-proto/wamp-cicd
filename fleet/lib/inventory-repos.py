#!/usr/bin/env python3
"""inventory-repos.py <fleet.toml> [--cohort NAME]  -  list an inventory's repositories.

One line per repository, tab-separated:  name  slug  default_branch  cohort,cohort,...
With --cohort, only the members of that cohort. Exit 3 if the cohort is not defined
(an undefined cohort must not look like an empty one).
"""
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib


def main() -> int:
    args = sys.argv[1:]
    cohort = None
    if "--cohort" in args:
        i = args.index("--cohort")
        cohort = args[i + 1]
        del args[i:i + 2]
    fleet = tomllib.load(open(args[0], "rb"))
    if cohort is not None and cohort not in [c.get("name") for c in fleet.get("cohort", [])]:
        print(f"cohort '{cohort}' is not defined in {args[0]} "
              f"(defined: {', '.join(c.get('name', '?') for c in fleet.get('cohort', [])) or 'none'})", file=sys.stderr)
        return 3
    for r in fleet.get("repo", []):
        if cohort is None or cohort in r.get("cohorts", []):
            print("\t".join((r["name"], r["slug"], r["default_branch"], ",".join(r.get("cohorts", [])))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
