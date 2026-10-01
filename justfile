# Copyright (c) typedef int GmbH, Germany, 2025. All rights reserved.
# Licensed under the MIT License (see LICENSE file).

# -----------------------------------------------------------------------------
# -- just global configuration
# -----------------------------------------------------------------------------

set unstable := true
set positional-arguments := true
set script-interpreter := ['uv', 'run', '--script']

# The branch workflow this repository ships to nine others - and, until now, did
# not run against itself (#20). `workflow.just` is the file beside this one;
# SCM-EXCHANGE-MODEL.md and MERGE-AND-SIGNING-POLICY.md decide what it does.
#
# One line, and it is the only way #27's recipe can be exercised in the
# repository that owns it: a recipe that cannot run where it is written cannot
# be watched failing.
import 'workflow.just'

# The fleet tooling (fleet/, #58): `just fleet-where`, `just fleet-rollout <phase> [go]`, ...
import 'fleet/fleet.just'

# Project base directory = directory of this justfile
PROJECT_DIR := justfile_directory()

# List all recipes.
default:
    @echo ""
    @echo "The Web Application Messaging Protocol: CI/CD Support Module"
    @echo ""
    @just --list
    @echo ""

# Add CI/CD submodule from `wamp-cicd` to dir `.cicd` in target repository (should be run from root dir in target repository).
add-repo-submodule:
    #!/usr/bin/env bash
    set -e

    git submodule add https://github.com/wamp-proto/wamp-cicd.git .cicd
    git submodule update --init --recursive
    echo "✅ Workspace CI/CD submodule added."

# Update CI/CD submodule following `wamp-cicd` in dir `.cicd` in this repository (should be run from `.cicd` dir after adding submodule in target repository).
update-repo-submodule:
    #!/usr/bin/env bash
    set -e

    git submodule update --remote --merge
    echo "✅ Workspace AI submodule updated. Now add & commit the change (to `.cicd`) in this repository."

# Deploy the shared GitHub and community files from `.cicd/templates/` into the target repository: issue templates, the PR template, CONTRIBUTING.md, `.audit/README.md`, and a DEVELOPMENT.md seed if it has none (should be run from `.cicd` dir in target repository).
deploy-github-templates:
    #!/usr/bin/env bash
    set -e

    # Issue templates: copied, but NOT drift-checked yet - `config.yml` carries a
    # Discussions URL that differs per repository, so it cannot be byte-identical.
    mkdir -p ../.github/ISSUE_TEMPLATE
    cp -v templates/ISSUE_TEMPLATE/*.md ../.github/ISSUE_TEMPLATE/
    cp -v templates/ISSUE_TEMPLATE/*.yml ../.github/ISSUE_TEMPLATE/

    # CONTRIBUTING.md, the PR template, `.audit/README.md` (byte-identical, drift-checked),
    # DEVELOPMENT.md (seeded once, then owned by the repository), and removal of the
    # obsolete `.github/PULL_REQUEST_TEMPLATE/` directory (#16).
    bash scripts/community-files.sh deploy ..

# Check the shared community files in the target repository against `.cicd/templates/`, failing on any drift (should be run from `.cicd` dir in target repository; in CI, run `bash .cicd/scripts/community-files.sh check .` from the repository root).
check-community-files:
    bash scripts/community-files.sh check ..

# Run the unit tests: composite-action shell logic, and the workflow recipes
# themselves, both against crafted fixtures rather than against this checkout.
test:
    #!/usr/bin/env bash
    # pipefail: the sandboxes are piped through `tail -1`, which must not hide their failure.
    set -eo pipefail
    bash tests/test-check-release-fileset.sh
    bash tests/test-new-branch-collision.sh
    bash tests/test-new-branch-audit.sh
    bash tests/test-audit-file.sh
    bash tests/test-workflow-signing.sh
    bash tests/test-land-tooling-pins.sh
    bash tests/test-where-output.sh
    bash tests/test-pr-lookup.sh
    bash tests/test-signing-scope.sh
    bash tests/test-variable-override.sh
    bash tests/test-community-files.sh
    bash tests/test-fleet.sh
    bash tests/test-file-issue.sh
    bash tests/test-fleet-config.sh
    bash tests/test-fleet-fixes.sh
    bash tests/test-fleet-recipes.sh
    bash tests/test-fleet-runner.sh
    bash tests/test-pr-ci.sh
    bash fleet/sandbox-test.sh | tail -1
    SANDBOX_FLAVOUR=neutral bash fleet/sandbox-test.sh | tail -1
