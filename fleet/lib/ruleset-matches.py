#!/usr/bin/env python3
"""ruleset-matches.py <wanted.json> < live.json  ->  prints "yes" or "no".

Does the live ruleset (as GitHub returns it) already say everything the wanted JSON says?
A SUBSET comparison over the fields that define a ruleset: GitHub adds fields and defaults of
its own when it stores one (ids, links, newer rule parameters), so an exact comparison would
report "differs" forever and every re-run would rewrite an unchanged ruleset.
Lists are compared as lists, element by element (order matters to GitHub for rules too).
"""
import json
import sys

KEYS = ("name", "target", "enforcement", "conditions", "rules", "bypass_actors")


def covers(live, want):
    if isinstance(want, dict):
        return isinstance(live, dict) and all(k in live and covers(live[k], v) for k, v in want.items())
    if isinstance(want, list):
        return isinstance(live, list) and len(live) == len(want) and all(covers(l, w) for l, w in zip(live, want))
    return live == want


def main() -> int:
    want = json.load(open(sys.argv[1]))
    live = json.load(sys.stdin)
    print("yes" if all(covers(live.get(k), want[k]) for k in KEYS if k in want) else "no")
    return 0


if __name__ == "__main__":
    sys.exit(main())
