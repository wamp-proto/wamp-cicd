# The Web Application Messaging Protocol: CI/CD Support Module

Centralized reusable CI/CD (GitHub) helpers and workflows, and the SCM,
merge and signing policy they implement.
This is intended to be added to WAMP target (using) repositories as a Git submodule.

See also: [AI Support Module](https://github.com/wamp-proto/wamp-ai)

## What this module decides

Three documents, and the recipes that implement them. A using repository gets
all of them by carrying this submodule, which is the point: a rule that lives
one `git clone` away from the repositories that must follow it is a rule those
repositories cannot check themselves against.

| document | decides |
|---|---|
| [SCM-EXCHANGE-MODEL.md](SCM-EXCHANGE-MODEL.md) | how work is staged between a control node, a private exchange, AI assistants and the forge — and what every remote is called |
| [MERGE-AND-SIGNING-POLICY.md](MERGE-AND-SIGNING-POLICY.md) | how an approved branch becomes protected history: merge commits only, made and signed by the maintainer rather than by the forge |
| [SLSA.md](SLSA.md) | the build-provenance target and what is still missing for it |

[`workflow.just`](workflow.just) implements the first two — `just where`,
`just new-branch`, `just publish`, `just land`. It implements; they decide.

**These are patterns, not inventories.** Which repositories, hosts and people
fill their parameters is deployment-specific and is not recorded here.

## Benefits of Centralized wamp-ai and wamp-cicd

1. Single Source of Truth - Update once in `wamp-cicd` or `wamp-ai`, versioned and evolvable over time, propagate everywhere via git submodule update
2. Consistency - Issue templates, PR templates, CI actions, and scripts behave identically across projects
3. Reduced Maintenance - Bug fixes in shared scripts benefit all projects
4. Onboarding - New contributors see the same patterns everywhere
5. Standard Git Mechanisms - Git submodules (standard practice), Symlinks (filesystem-level solution), Automated setup via justfile
6. Dual-Level Coverage - Project-level (single using repo) and Workspace-level (multi-repo)
7. AI Policy Enforcement - Centralized `AI_GUIDELINES.md` ensures consistent AI assistant behavior
8. Multi-AI Support - Claude (`CLAUDE.md`), Gemini (`.gemini/GEMINI.md`), extensible for future AI assistants

The Architecture - *reused repos*, and *using repos*:

```
wamp-proto/wamp-ai          wamp-proto/wamp-cicd
       │                            │
       │ .ai submodule              │ .cicd submodule
       ▼                            ▼
┌──────────────────────────────────────────────┐
│  crossbario/zlmdb                            │
│  crossbario/autobahn-python                  │
│  crossbario/crossbar                         │
│  crossbario/txaio                            │
│  (future: cfxdb, autobahn-js, etc.)          │
└──────────────────────────────────────────────┘
```

## Installation

Add this repo as a submodule to a WAMP related repo:

```console
cd ~/scm/crossbario/autobahn-python
git submodule add https://github.com/wamp-proto/wamp-cicd.git .cicd
cd .cicd
just deploy-github-templates
```

Clone a WAMP related repo including submodules:

```console
git clone --recursive git@github.com:crossbario/autobahn-python.git
```

Initialize a WAMP related repo including submodules:

```console
git submodule update --init --recursive
```

Update a WAMP related repo submodules:

```console
git submodule update --remote --merge
```

## Usage

In your `.github/workflows/<workflow>.yml`:

```yaml
jobs:
  identifiers:
    uses: ./.cicd/workflows/identifiers.yml

  test:
    needs: identifiers
    runs-on: ubuntu-latest
    env:
      BASE_REPO: ${{ needs.identifiers.outputs.base_repo }}
      BASE_BRANCH: ${{ needs.identifiers.outputs.base_branch }}
      PR_NUMBER: ${{ needs.identifiers.outputs.pr_number }}
      PR_REPO: ${{ needs.identifiers.outputs.pr_repo }}
      PR_BRANCH: ${{ needs.identifiers.outputs.pr_branch }}
    steps:
      - name: Use identifiers
        run: |
          echo "Identifier: ${PR_NUMBER}-${PR_REPO}-${PR_BRANCH}"
```
