#!/usr/bin/env python3
# Copyright (c) typedef int GmbH, Germany, 2025. All rights reserved.
# Licensed under the MIT License (see LICENSE file).
"""aspects.py - list a repository's aspects, and run each one's check (wamp-cicd#78).

    aspects.py list                 one row per declared aspect: provider, path, pin, state
    aspects.py check [<aspect>]     run the aspect's scripts/check.py (all aspects if none given)
    aspects.py summary              one line for `just where`

Run from inside the repository. Called by `just list-aspect` / `just check-aspect` in workflow.just,
with the interpreter the recipe chose; standard library only (Python 3.11+, for tomllib).

A repository declares its aspects in `aspects.toml`:

    aspects = ["way-a", "python-package"]

    [provider.python-package]
    repo = "crossbario/autobahn-crossbar-ai"
    path = ".autobahn-crossbar-ai"

Each implemented aspect is `<path>/aspects/<aspect>/scripts/check.py` in its provider. The check runs
from the repository's OWN pin of the provider - the submodule gitlink, or the `deps.toml` entry for a
provider under `.deps/` - never from a newer revision: whether the pin is behind is the rollout
tooling's question, not this one's. A provider whose checkout is missing, or is not at the pin, cannot
be checked, and that is a failure: a check that silently does not run is worse than none.

States:
    ok / FAIL             the check ran and passed / failed
    not implemented       declared, but the provider has no such aspect at the pin (or no provider
                          is declared) - reported, not failed: a not-yet-built aspect is normal
    CANNOT CHECK          the provider is not checked out, or not at the pin - failed
"""

from __future__ import annotations

import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

CANNOT = "CANNOT CHECK"
NOT_IMPLEMENTED = "not implemented"


@dataclass
class Aspect:
    name: str
    repo: str  # provider repository slug, "(this repository)" or "-"
    path: str  # provider path relative to the root, "." for self-hosting, "" for none
    pin: str  # pinned commit (short), or "-"
    state: str  # NOT_IMPLEMENTED, CANNOT, or "implemented"
    why: str = ""

    @property
    def check_py(self) -> Path:
        return Path(self.path) / "aspects" / self.name / "scripts" / "check.py"


def _git(root: Path, *args: str) -> str:
    proc = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _gitlink(root: Path, path: str) -> str:
    """The commit a submodule at `path` is pinned to in HEAD, or ''."""
    out = _git(root, "ls-tree", "HEAD", "--", path)
    parts = out.split()
    return parts[2] if len(parts) >= 3 and parts[0] == "160000" else ""


def _deps_pin(root: Path, path: str) -> str:
    """The deps.toml commit for a provider checked out at `.deps/<name>`, or ''."""
    deps = root / "deps.toml"
    if not path.startswith(".deps/") or not deps.is_file():
        return ""
    name = path.split("/", 2)[1]
    entry = tomllib.loads(deps.read_text(encoding="utf-8")).get(name) or {}
    return str(entry.get("commit", ""))


def resolve(root: Path) -> list[Aspect] | None:
    """The declared aspects and where each is implemented; None without aspects.toml."""
    toml = root / "aspects.toml"
    if not toml.is_file():
        return None
    data = tomllib.loads(toml.read_text(encoding="utf-8"))
    providers = data.get("provider") or {}
    out = []
    for name in data.get("aspects") or []:
        prov = providers.get(name)
        if prov is None:
            if (root / "aspects" / name / "scripts" / "check.py").is_file():
                head = _git(root, "rev-parse", "HEAD")
                out.append(Aspect(name, "(this repository)", ".", head[:7] or "-", "implemented"))
            else:
                out.append(Aspect(name, "-", "", "-", NOT_IMPLEMENTED, "no provider declared"))
            continue
        path = str(prov.get("path", ""))
        repo = str(prov.get("repo", "?"))
        pin = _gitlink(root, path) or _deps_pin(root, path)
        a = Aspect(name, repo, path, pin[:7] or "-", "implemented")
        checkout = root / path
        if not pin:
            a.state, a.why = CANNOT, f"{path} is neither a submodule nor a deps.toml entry"
        elif not checkout.is_dir() or not any(checkout.iterdir()):
            hint = "just deps" if path.startswith(".deps/") else f"git submodule update --init {path}"
            a.state, a.why = CANNOT, f"{path} is not checked out - run: {hint}"
        elif (head := _git(checkout, "rev-parse", "HEAD")) != pin:
            a.state, a.why = CANNOT, f"{path} is checked out at {head[:7] or '?'}, its pin is {pin[:7]}"
        elif not (root / a.check_py).is_file():
            a.state, a.why = NOT_IMPLEMENTED, f"{repo} has no aspects/{name}/ at {pin[:7]}"
        out.append(a)
    return out


def _table(rows: list[list[str]]) -> str:
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  " + "  ".join(c.ljust(w) for c, w in zip(r, widths, strict=True)).rstrip() for r in rows)


def cmd_list(root: Path) -> int:
    aspects = resolve(root)
    if aspects is None:
        print("no aspects.toml - this repository declares no aspects")
        return 0
    rows = [["aspect", "provider", "path", "pin", "state"]]
    for a in aspects:
        state = a.state if not a.why else f"{a.state} ({a.why})"
        rows.append([a.name, a.repo, a.path or "-", a.pin, state])
    print(_table(rows))
    return 0


def _run(root: Path, a: Aspect) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(root / a.check_py), str(root)], capture_output=True, text=True, check=False
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def cmd_check(root: Path, only: str | None, *, quiet: bool = False) -> tuple[int, list[str]]:
    """Run the checks; returns (exit status, one verdict line per aspect)."""
    aspects = resolve(root)
    if aspects is None:
        return 0, []
    if only:
        aspects = [a for a in aspects if a.name == only]
        if not aspects:
            return 2, [f"{only}: not declared in aspects.toml"]
    status, verdicts = 0, []
    for a in aspects:
        if a.state == NOT_IMPLEMENTED:
            verdicts.append(f"{a.name}: {NOT_IMPLEMENTED} ({a.why})")
        elif a.state == CANNOT:
            status = 1
            verdicts.append(f"{a.name}: {CANNOT} - {a.why}")
        else:
            rc, output = _run(root, a)
            verdicts.append(f"{a.name}: {'ok' if rc == 0 else 'FAIL'} ({a.repo} @ {a.pin})")
            if rc != 0:
                status = 1
            if not quiet and output:
                verdicts.append("\n".join("    " + line for line in output.splitlines()))
    return status, verdicts


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("list", "check", "summary"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    root = Path(_git(Path.cwd(), "rev-parse", "--show-toplevel") or ".").resolve()
    if argv[0] == "list":
        return cmd_list(root)
    if argv[0] == "summary":
        aspects = resolve(root)
        if aspects is None:
            print("none declared")
            return 0
        _, verdicts = cmd_check(root, None, quiet=True)
        kinds = {"ok": [], "FAIL": [], CANNOT: [], NOT_IMPLEMENTED: []}
        for v in verdicts:
            name, rest = v.split(": ", 1)
            kinds[next(k for k in kinds if rest.startswith(k))].append(name)
        parts = [f"{len(v)} {k}" for k, v in kinds.items() if v]
        bad = kinds["FAIL"] + kinds[CANNOT]
        hint = f" - failing: {', '.join(bad)}; run: just check-aspect" if bad else ""
        print(f"{len(aspects)} declared: {', '.join(parts)}{hint}")
        return 0
    status, verdicts = cmd_check(root, argv[1] if len(argv) > 1 and argv[1] else None)
    print("\n".join(verdicts) or "no aspects.toml - this repository declares no aspects")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
