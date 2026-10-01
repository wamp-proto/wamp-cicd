#!/usr/bin/env python3
"""check-rollout.py <rollouts/<cohort>/<NNNN>-<name>> [--quiet]  -  is this a valid rollout?

A rollout is a directory in a fleet's definition repository:

    rollouts/<cohort>/<NNNN>-<name>/
        rollout.toml     name, cohort, description   (requires = [...] is reserved)
        apply.sh         makes the change in a member repository (executable)
        check.sh         optional: exit 0 if the repository already is in the desired state
        issue.md         the text of the rollout issue

`name` and `cohort` must EQUAL the directory's - never guessed, never "close enough": the
directory is what orders a cohort's rollouts and what a repository's marker is named after.
A rollout must be appliable (apply.sh), adoptable (check.sh), or at least a declared record of
something applied by hand (an [applied] table); otherwise the runner could never get past it.

Exit 0 when valid, 1 when not (each failed check is printed), 2 when unreadable.
"""
import os
import re
import sys

try:
    import tomllib
except ImportError:  # Python < 3.11
    import tomli as tomllib

REQUIRED = ("name", "cohort", "description")


def check_rollout(path, quiet=False):
    path = os.path.normpath(path)
    name, cohort = os.path.basename(path), os.path.basename(os.path.dirname(path))
    results = []

    def check(label, cond, detail=""):
        results.append(bool(cond))
        if not cond:
            print(f"  FAIL [{cohort}/{name}: {label}] {detail}")
        elif not quiet:
            print(f"  ok   [{cohort}/{name}: {label}]")

    check("directory is <NNNN>-<name>", bool(re.fullmatch(r"[0-9]{4}-[a-z0-9][a-z0-9-]*", name)), repr(name))
    try:
        meta = tomllib.load(open(os.path.join(path, "rollout.toml"), "rb"))
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"  FAIL [{cohort}/{name}: rollout.toml readable] {e}")
        return None
    for k in REQUIRED:
        check(f"rollout.toml has {k}", isinstance(meta.get(k), str) and meta[k].strip() != "")
    check("name equals the directory", meta.get("name") == name, f"{meta.get('name')!r} != {name!r}")
    check("cohort equals the parent directory", meta.get("cohort") == cohort, f"{meta.get('cohort')!r} != {cohort!r}")
    req = meta.get("requires", [])
    check("requires, if present, is a list of <cohort>/<NNNN>-<name>",
          isinstance(req, list) and all(isinstance(r, str) and re.fullmatch(r"[a-z][a-z0-9-]*/[0-9]{4}-[a-z0-9][a-z0-9-]*", r) for r in req), repr(req))
    apply_sh, check_sh = os.path.join(path, "apply.sh"), os.path.join(path, "check.sh")
    has_apply, has_check = os.path.isfile(apply_sh), os.path.isfile(check_sh)
    check("appliable (apply.sh), adoptable (check.sh), or a declared hand-applied record ([applied])",
          has_apply or has_check or isinstance(meta.get("applied"), dict))
    if has_apply:
        check("apply.sh is executable", os.access(apply_sh, os.X_OK))
        check("issue.md present", os.path.isfile(os.path.join(path, "issue.md")))
    if has_check:
        check("check.sh is executable", os.access(check_sh, os.X_OK))
    return results


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--quiet"]
    if len(args) != 1:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    results = check_rollout(args[0], quiet="--quiet" in sys.argv)
    if results is None:
        return 2
    passed, failed = results.count(True), results.count(False)
    if "--quiet" not in sys.argv or failed:
        print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
