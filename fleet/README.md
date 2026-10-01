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

- **Fleet** — all the repositories managed together; every repository belongs to exactly one
  fleet. It is described by an **inventory** (`<fleet>.toml`, schema 2), which lives in the
  fleet's own definition repository, **not here**: only the tools and the contract are here.
- **Cohort** — a named, described subset of a fleet; a repository may be in several, or in none
  (then it takes part in nothing).
- **Rollout** — one named, batched change applied to exactly one cohort. `init` freezes its
  state: the cohort's members, the ONE `.cicd`/`.ai` pin pair every repository gets, the issue
  template, and a manifest (repository → issue → branch → PR) that every later phase reads and
  extends. One rollout at a time per fleet: `finish` closes it once every repository has landed.
- **Wave** — one run of a rollout on its cohort.

Slugs are checked against the GitHub API's `full_name`: `git ls-remote` silently follows renames
and transfers, so a stale slug never fails on its own.

**Where things run.** Everything that talks to GitHub with credentials, or signs, runs on the
maintainer's machine. An AI assistant works on its own host with **no** forge credentials: it
commits to the rollout branches and pushes them to the exchange, between `cut` and `sync`.

**Two ways to land.** A repository whose default branch has the `.ai` hook that admits a
maintainer merge lands as a **signed `--no-ff` merge**. One that still has the older hook (the
first Way-A branch there: the "bootstrap") lands by **fast-forward onto a signed tip** — any
maintainer-signed commit, usually an empty "Seal #N" commit. After the first rollout every default
branch carries the new hook.

## Configuration: a fleet is two files, side by side

In `${XDG_CONFIG_HOME:-~/.config}/wamp-cicd/fleet/`, and nothing else configures the tools:

- **`<fleet>.toml`** — the inventory. Usually a symlink to `fleet.toml` in a clone of the fleet's
  definition repository. Contract (schema 2), in [`lib/check-inventory.py`](lib/check-inventory.py):
  ```toml
  schema = 2
  [[cohort]]   name = "way-a"            description = "what its members have in common"
  [[repo]]     name = "autobahn-python"  slug = "crossbario/autobahn-python"
               default_branch = "master" cohorts = ["way-a", "python"]
  ```
  No other keys; `name` is the clone's directory and the last part of `slug`; every cohort a
  repository names must be defined.
- **`<fleet>.env`** — per-host settings, `KEY=value`, **optional**: every key has a default
  ([`lib/config.sh`](lib/config.sh)). Typically just `EXCHANGE=<remote name>` and
  `UPLOAD_TO=<host>:<path>`. Mode 600, in a mode 700 directory (refused otherwise: it is executed).
  The environment overrides it (`EXCHANGE=other just fleet-where`).

By convention the clones live in `~/work/<fleet>/<repo>`, and a rollout's state and logs in
`${XDG_STATE_HOME:-~/.local/state}/wamp-cicd/fleet/<fleet>/`.

Both files may be **generated** from a single source of truth. The output must pass
`just fleet-check`: an unknown key (a generator typo) or an entry breaking the inventory contract
fails it, rather than being silently ignored. `rollout.sh init` refuses an invalid inventory, too.
The generator and its source stay with their owner; only the contract lives here.

## Setup (maintainer's machine)

1. **Configure the fleet:** `ln -s <definition clone>/fleet.toml ~/.config/wamp-cicd/fleet/<fleet>.toml`,
   and write `<fleet>.env` beside it if a default does not fit this host. With one fleet
   configured it is selected automatically; with several, set `FLEET_NAME`.
2. **Check it:** `just fleet-check`.
3. **Link the personal tools:** `just fleet-install-tools go` creates
   `~/.local/bin/wamp-cicd-{file-issue,file-comment,pr-ci}.sh` as symlinks into this clone (type
   `wamp-cicd-` and TAB). Run it from a standalone wamp-cicd clone: it refuses inside a `.cicd/`
   submodule, re-points existing symlinks, and never touches a regular file.
4. **Requirements:** `git`, `just`, `gh` (authenticated; `admin:org` scope for `fleet-org`),
   `python3`, and for signing `gitsign`.

## Recipes

From a wamp-cicd clone, or `just -f <wamp-cicd>/fleet/fleet.just <recipe>` from anywhere (e.g.
`.cicd/fleet/fleet.just` in a repository that pins wamp-cicd).

**Every recipe that changes something is a dry run. The armed call is the same one with `go` as
its last word.** A `go` anywhere else is refused.

| recipe | does |
|---|---|
| `just fleet-check` | is the fleet's configuration valid: only known keys, permissions, the inventory against its contract, its cohorts (read-only) |
| `just fleet-next [--cohort C]` | who is behind: per repository and cohort, how many rollouts it has and which is next (read-only) |
| `just fleet-apply-rollout <member clone> <definition clone> <cohort>/<NNNN>-<name> --issue N` | apply one rollout to one member: `apply.sh`, the `.fleet/` pin, the `.waves/` marker, one commit (no credentials; see below) |
| `just fleet-where [full] [--cohort C]` | read-only health table: branch, clean, default branch = upstream = exchange, hooks, signing, `.cicd`/`.ai` pins, submodules, managed-file drift, `just where` |
| `just fleet-rollout init <name> --cohort C --rollout <NNNN>-<name>` | start a wave of a rollout from the definition: freeze the members whose NEXT rollout it is, the pin pair, its issue text (`--issue-template F` for a rollout that is not a migration) |
| `just fleet-rollout <phase> [go]` | `preflight`, `prune`, `file-issues`, `cut`, `sync`, `seal`, `publish`, `open-prs`, `status`, `land`, `finish` |
| `just fleet-hygiene [go]` | before a rollout: bundle-backed removal of stale local branches; signing and hooks configuration |
| `just fleet-publish [seal] [go]` | rollout branches from the exchange to the forks (optionally sealing bootstrap repositories first) |
| `just fleet-ci-results` | every rollout PR's checks, runs, jobs and failed-job logs (also of runs still in progress); uploaded if `UPLOAD_TO` is set |
| `just fleet-rulesets [integrity] [--cohort C] [go]` | default-branch rulesets per repository from [`rulesets/`](rulesets/), then classic branch protection off |
| `just fleet-org [status \| settings \| rulesets <org> \| transfer <from> <to>] [go]` | organisations you administer: plan, 2FA, member privileges, org-wide rulesets, repository transfers |
| `just fleet-install-tools [go]` | `~/.local/bin/wamp-cicd-{file-issue,file-comment,pr-ci}.sh`, symlinks into this clone |

## Rollouts as migrations

A rollout lives in the fleet's definition repository, and every member records which ones it has:

```
<definition>/rollouts/<cohort>/<NNNN>-<name>/        <member>/.fleet/                 (submodule: the definition, pinned)
    rollout.toml   name, cohort, description         <member>/.waves/<cohort>/<NNNN>-<name>.toml   (one marker per applied rollout)
    apply.sh       makes the change
    check.sh       optional: already in the desired state?
    issue.md       the issue text
```

- A cohort's rollouts are applied **in order, and none is skipped**. What is next for a member is
  the first one without a marker on its default branch (`just fleet-next`). A wave of a rollout is
  the members for which it is next.
- **`apply.sh`** runs in the member's root, on the rollout branch, with `FLEET_NAME`,
  `FLEET_COHORT`, `FLEET_ROLLOUT`, `FLEET_REPO`, `FLEET_SLUG`, `FLEET_DEFAULT_BRANCH`,
  `FLEET_DEF_DIR` and `FLEET_TOOLS_DIR` set. It changes files; it does not commit, push or talk to
  a forge; it needs no credentials; a second run changes nothing.
- **`apply-rollout.sh`** is the one step that applies it: it adopts earlier rollouts that are
  already in place (`check.sh` passes: a marker without a script hash), runs `apply.sh` **from the
  definition clone**, sets `.fleet/` to that clone's commit, writes the marker (rollout, definition
  commit, sha256 of `apply.sh`, the `.cicd` pin, issue, time) and makes one commit. It never
  pushes. Exit codes: `0` applied, `10` already applied, `11` dirty tree, `12` `apply.sh` failed,
  `13` an earlier rollout is missing, `14` not a member, `15` the commit was refused, `2` usage
  or a definition that is not committed or not landed.
- **The marker's `.cicd` pin** is the pin the commit sets (after `apply.sh`); an adopted rollout's
  marker names the pin the repository was found with. A repository without `.cicd` has no such key.
- **The definition must be landed.** The runner refuses a definition clone whose `HEAD` is not
  contained in the default branch of one of its remotes (`refs/remotes/<remote>/HEAD`): members
  pin `.fleet/` to that commit, and their CI must be able to fetch it from the forge's default
  branch. So: land the definition branch, fetch, check out the default branch, then apply.
  `--allow-unlanded` is for sandboxes and dry runs.
- A rollout is **immutable once a marker names it**; a change is a new rollout.
- **Who runs what.** `init`, `file-issues`, `cut`, `publish`, `open-prs`, `land`, `finish`: the
  maintainer's machine (forge credentials; the maintainer signs each branch's first commit, with
  its audit file, and the landing merge). `apply-rollout.sh`: anywhere, typically the AI host, on
  the branches already cut - between `cut` and `publish`.
- **`.fleet/` without network.** The runner fills `.fleet/` from the local definition clone;
  `.gitmodules` records the canonical forge URL. On a host that cannot fetch that URL (a private
  definition, no forge credentials), a plain `git submodule update` additionally needs
  `git config --global url.<exchange or local clone>.insteadOf <forge URL>`.
- **Lag check.** In a member's CI (checkout with submodules):
  `bash .cicd/fleet/lag-check.sh` fails if a rollout of the member's cohorts in its pinned
  `.fleet/` has no marker.

## A rollout, step by step

1. Land the change's shared part in wamp-cicd / wamp-ai first; that commit is what gets pinned.
2. Write the rollout in the definition repository (`rollouts/<cohort>/<NNNN>-<name>/`; issue text
   with placeholders such as `@@SLUG@@`, `@@ROLLOUT@@`, `@@COHORT@@`, see
   [`../tests/fixtures/rollout-issue-template.md`](../tests/fixtures/rollout-issue-template.md)),
   land it there, and check: `just fleet-check`, `just fleet-next`. Then
   `just fleet-rollout init <name> --cohort <cohort> --rollout <NNNN>-<name>`.
3. `just fleet-rollout preflight` until it reports no blockers (extra remotes, wrong slugs or
   default branches, missing hooks or signing).
4. `just fleet-hygiene go` once; `just fleet-rollout file-issues go`; `just fleet-rollout cut go`.
5. On each `fix_<N>` (fetched from the exchange): `apply-rollout.sh`, the repository's own
   checks, any follow-up commits that need judgement, push to the exchange.
6. `just fleet-publish seal go`, then `just fleet-rollout open-prs go`.
7. CI loop: `just fleet-ci-results` → analysis → fixes pushed to the exchange →
   `just fleet-publish seal go`. Separate what the rollout **caused** from pre-existing drift it
   merely **surfaced**; file issues for the latter.
8. `just fleet-rollout land` (dry), then `just fleet-rollout land go`: local tip = PR head = fork
   = exchange, checks pass, signed tip or signed merge, verified push, branches deleted
   everywhere.
9. `just fleet-rollout finish go` closes the rollout (it refuses while a repository has not
   landed, or its marker is not on the default branch); only then can the next one be started.
10. `just fleet-where`: every repository in sync, pinned, signed.

Every phase is re-runnable: finished work is detected and skipped.

## Issue and comment drafts

`wamp-cicd-file-issue.sh <draft.md>` and `wamp-cicd-file-comment.sh <draft.md>` file a reviewed draft:

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

`wamp-cicd-pr-ci.sh <PR URL>` (or `<owner>/<repo>#<n>`) collects one pull request's checks, runs and
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
[`test-file-issue.sh`](../tests/test-file-issue.sh),
[`test-fleet-runner.sh`](../tests/test-fleet-runner.sh) (`apply-rollout.sh`: every exit code,
adoption, `.fleet/` with the network disabled, the real commit hook; next; the lag check; the
rollout contract), and [`sandbox-test.sh`](sandbox-test.sh) twice: a whole wave of a migration
(init → cut → apply-rollout → land in both landing modes → finish) against local bare
repositories, once in the WAMP shape and once with neutral names (`SANDBOX_FLAVOUR=neutral`),
asserting the result.
