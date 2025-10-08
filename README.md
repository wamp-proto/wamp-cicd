# The Web Application Messaging Protocol: CI/CD Support Module

Centralized reusable CI/CD (GitHub) helpers and workflows.
This is intended to be added to WAMP target repositories
as a Git submodule.

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
