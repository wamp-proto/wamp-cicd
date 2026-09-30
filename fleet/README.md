# Fleet tooling: one change across many repositories

Tools for making the **same** change in a set of repositories as one batch — issues filed,
branches cut, work staged through the exchange, CI collected, everything landed with signed
tips — and for keeping those repositories' GitHub settings consistent. They implement
[SCM-EXCHANGE-MODEL.md](../SCM-EXCHANGE-MODEL.md) and
[MERGE-AND-SIGNING-POLICY.md](../MERGE-AND-SIGNING-POLICY.md) for many repositories at once, on top
of the per-repository recipes in [`workflow.just`](../workflow.just).

First used for the WAMP rollout `wave1-2026-09`: 9 repositories, one pin pair, three CI rounds,
all landed; then default-branch protection unified across 16 repositories (#58).

## Concepts

- **Fleet** — a set of repositories managed together, described by an **inventory**
  (`fleet.toml`): name, GitHub slug, default branch, kind, wave, notes. The WAMP inventory is
  [`../fleet.toml`](../fleet.toml); any other fleet keeps its own inventory **with its owner**,
  not here. Slugs are checked against the GitHub API's `full_name`: `git ls-remote` silently
  follows renames and transfers, so a stale slug never fails on its own.
- **Wave** — the subset of the fleet one rollout touches (`wave = N`; `0` = not rolled out).
- **Rollout** — one named, batched change across one wave. `init` freezes its state: the wave's
  rows of the inventory, the ONE `.cicd`/`.ai` pin pair every repository gets, and a manifest
  (repository → issue → branch → PR) that every later phase reads and extends.

**Where things run.** Everything that talks to GitHub with credentials, or signs, runs on the
maintainer's machine. An AI assistant works on its own host with **no** forge credentials: it
commits to the rollout branches and pushes them to the exchange, between `cut` and `sync`.

**Two ways to land.** A repository whose default branch has the `.ai` hook that admits a
maintainer merge lands as a **signed `--no-ff` merge**. One that still has the older hook (the
first Way-A branch there: the "bootstrap") lands by **fast-forward onto a signed tip** — any
maintainer-signed commit, usually an empty "Seal #N" commit. After the first rollout every default
branch carries the new hook.

## Configuration: one file per fleet, one inventory per fleet

A fleet is exactly two files, and nothing else configures the tools:

- `~/.config/fleet/<name>.env` — `KEY=value` lines, `chmod 600`, in a `chmod 700` directory (both
  are refused otherwise: the file is executed). Keys and defaults: [`lib/config.sh`](lib/config.sh);
  `FLEET_INVENTORY` is the only required one.
- the inventory it names — `fleet.toml`, format and rules in
  [`lib/check-inventory.py`](lib/check-inventory.py).

Both may be **generated** from a single source of truth (for example an Ansible inventory). The
generator's output must pass `just fleet-check`: an unknown key (a generator typo) or an entry
breaking the inventory contract fails it, rather than being silently ignored. `rollout.sh init`
refuses an invalid inventory, too. The generator and the source stay with their owner; only the
contract lives here.

## Setup (maintainer's machine)

1. **Configure the fleet:** copy [`examples/wamp.env`](examples/wamp.env) to
   `~/.config/fleet/<name>.env`, `chmod 600`, and adjust. Keys and defaults are listed in
   [`lib/config.sh`](lib/config.sh). With one `*.env` it is selected automatically; with several,
   set `FLEET_NAME`. The environment overrides the file (`EXCHANGE=other just fleet-where`).
2. **Check it:** `just fleet-check` (see below).
3. **Install the personal tools:** `just fleet-install-tools go` puts `file-issue.sh`,
   `file-comment.sh` (copies) and `pr-ci.sh` (a wrapper running it from this checkout) into
   `~/.local/bin` (which should be on `PATH`).
4. **Requirements:** `git`, `just`, `gh` (authenticated; `admin:org` scope for `fleet-org`),
   `python3`, and for signing `gitsign`.

## Recipes

From a wamp-cicd clone, or `just -f <wamp-cicd>/fleet/fleet.just <recipe>` from anywhere (e.g.
`.cicd/fleet/fleet.just` in a repository that pins wamp-cicd).

**Every recipe that changes something is a dry run. The armed call is the same one with `go` as
its last word.** A `go` anywhere else is refused.

| recipe | does |
|---|---|
| `just fleet-check` | is the fleet's configuration valid: only known keys, permissions of file and directory, the inventory against its contract (read-only) |
| `just fleet-where [full]` | read-only health table: branch, clean, default branch = upstream = exchange, hooks, signing, `.cicd`/`.ai` pins, submodules, managed-file drift, `just where` |
| `just fleet-rollout init <name> --wave N` | start a rollout: freeze the wave, the pin pair, the inventory |
| `just fleet-rollout <phase> [go]` | `preflight`, `prune`, `file-issues`, `cut`, `sync`, `seal`, `publish`, `open-prs`, `status`, `land` |
| `just fleet-hygiene [go]` | before a rollout: bundle-backed removal of stale local branches; signing and hooks configuration |
| `just fleet-publish [seal] [go]` | rollout branches from the exchange to the forks (optionally sealing bootstrap repositories first) |
| `just fleet-ci-results` | every rollout PR's checks, runs, jobs and failed-job logs (also of runs still in progress); uploaded if `UPLOAD_TO` is set |
| `just fleet-rulesets [integrity] [go]` | default-branch rulesets per repository from [`rulesets/`](rulesets/), then classic branch protection off |
| `just fleet-org [status \| settings \| rulesets <org> \| transfer <from> <to>] [go]` | organisations you administer: plan, 2FA, member privileges, org-wide rulesets, repository transfers |
| `just fleet-install-tools [go]` | `file-issue.sh`, `file-comment.sh` (copies), `pr-ci.sh` (wrapper) into `~/.local/bin` |

## A rollout, step by step

1. Land the change's shared part in wamp-cicd / wamp-ai first; that commit is what gets pinned.
2. `just fleet-rollout init <name> --wave 1`. Write this rollout's issue template (example:
   [`examples/issue-template-wamp-wave1.md`](examples/issue-template-wamp-wave1.md)) and pass it
   when filing: `ISSUE_TEMPLATE=<file> just fleet-rollout file-issues go`.
3. `just fleet-rollout preflight` until it reports no blockers (extra remotes, wrong slugs or
   default branches, missing hooks or signing).
4. `just fleet-hygiene go` once; file the issues (step 2); `just fleet-rollout cut go`.
5. The AI assistant implements on each `fix_<N>` and pushes to the exchange.
6. `just fleet-publish seal go`, then `just fleet-rollout open-prs go`.
7. CI loop: `just fleet-ci-results` → analysis → fixes pushed to the exchange →
   `just fleet-publish seal go`. Separate what the rollout **caused** from pre-existing drift it
   merely **surfaced**; file issues for the latter.
8. `just fleet-rollout land` (dry), then `just fleet-rollout land go`: local tip = PR head = fork
   = exchange, checks pass, signed tip or signed merge, verified push, branches deleted
   everywhere.
9. `just fleet-where`: every repository in sync, pinned, signed.

Every phase is re-runnable: finished work is detected and skipped.

## Issue and comment drafts

`file-issue.sh <draft.md>` and `file-comment.sh <draft.md>` file a reviewed draft:

```
Repo:  <owner>/<repo>            Repo:  <owner>/<repo>
Title: short, complete           Issue: <number>
                                 
---                              ---
<body>                           <body>
```

`file-issue.sh` refuses a duplicate title. A missing or malformed header line is refused
loudly. A filed draft is archived, never deleted, to
`${FLEET_ARCHIVE:-~/gh-issues/_filed}/<owner>/<repo>/<stamp>-#<number>-<draft>` with the resulting
URL appended: the path says which repository, the name which issue, the last line where. Keep
drafts, CI results and the archive under your home directory, not `/tmp`: they may contain
sensitive material, and `/tmp` does not survive a reboot.

## One pull request's CI, for the AI host

`pr-ci.sh <PR URL>` (or `<owner>/<repo>#<n>`) collects one pull request's checks, runs and
failed-job logs — also of runs still in progress. It works for **fleet repositories only**: the
fleet is the one whose inventory lists the repository (or `FLEET_NAME`), and that fleet's
configuration decides where the results go — `${FLEET_CI_DIR}/<repo>/pr<n>-<stamp>/` locally,
uploaded to `${UPLOAD_TO}/<repo>/`, staged inside the destination, never in the target's `/tmp`.
It is the way to show an AI assistant without forge credentials a failing CI run of a private
repository. `--full-logs` adds the full logs, `--rerun-failed` re-runs the failed jobs.
`just fleet-ci-results` does the same for every pull request of a rollout, with the same code.

## Branch protection

Two rulesets per default branch, because GitHub grants bypass per ruleset, not per rule:

- [`master`](rulesets/master.json) — pull request required for everyone but admins (admin bypass:
  the maintainer's local landing pushes directly).
- [`master-integrity`](rulesets/master-integrity.json) — no deletion, no force-push, **no bypass
  for anyone**.

The same pair as organisation rulesets ([`org-master*.json`](rulesets/)) where the plan allows
it; free-plan organisations use the per-repository pair. `fleet-rulesets` creates the ruleset
first and removes classic protection only afterwards, so a branch is never unprotected; rulesets
and classic protection stack (the stricter wins). Member privileges ("repository visibility
change", "deletion and transfer": admins only) and the 2FA requirement can only be set in the
web UI; `fleet-org` checks them.

## Lessons (all hit for real)

- A justfile that imports `.cicd/workflow.just` needs every CI job that runs `just` to check out
  with `submodules: recursive`.
- A rollout surfaces unrelated drift (new linter rules, a runtime's new ABI, a CI tool's
  install path); budget CI rounds for it.
- `set -euo pipefail` plus a `grep` that finds nothing ends a script silently: check, then fail
  loudly.
- `git status --porcelain` collapses an untracked directory: use `-uall`.
- `refname:short` gives `heads/x` when a branch and a tag share a name: use `refname:lstrip=2`.
- `just ... --justfile X` runs sub-calls in X's directory.
- `uv run` inside a project creates `.venv` and `uv.lock` there: use `uv run --no-project` / `uvx`.
- GitHub adds fields to a stored ruleset: compare as a subset, or every run "changes" it.
- Verify a pushed branch in a **fresh clone**: an ignored file in the working copy once hid a
  missing file from every local test.

## Tests

`just test` runs, without network: [`../tests/test-fleet-config.sh`](../tests/test-fleet-config.sh)
(configuration), [`test-fleet-fixes.sh`](../tests/test-fleet-fixes.sh) (the fixes from the first
use), [`test-fleet-recipes.sh`](../tests/test-fleet-recipes.sh) (the recipes and the `go` rule),
[`test-file-issue.sh`](../tests/test-file-issue.sh), and [`sandbox-test.sh`](sandbox-test.sh) twice:
a whole rollout (init → land, both landing modes) against local bare repositories, once in the
WAMP shape and once with neutral names (`SANDBOX_FLAVOUR=neutral`), asserting the result.
