# The Web Application Messaging Protocol: CI/CD Support Module

Centralized reusable CI/CD (GitHub) helpers and workflows.
This is intended to be added to WAMP target (using) repositories as a Git submodule.

See also: [AI Support Module](https://github.com/wamp-proto/wamp-ai)

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
