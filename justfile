# Copyright (c) typedef int GmbH, Germany, 2025. All rights reserved.
# Licensed under the MIT License (see LICENSE file).

# -----------------------------------------------------------------------------
# -- just global configuration
# -----------------------------------------------------------------------------

set unstable := true
set positional-arguments := true
set script-interpreter := ['uv', 'run', '--script']

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

# Deploy GitHub templates from `.cicd/templates/` to target repository `.github/` directory (should be run from `.cicd` dir in target repository).
deploy-github-templates:
    #!/usr/bin/env bash
    set -e

    # Create .github directories if they don't exist
    mkdir -p ../.github/ISSUE_TEMPLATE
    mkdir -p ../.github/PULL_REQUEST_TEMPLATE

    # Copy Issue templates
    cp -v templates/ISSUE_TEMPLATE/*.md ../.github/ISSUE_TEMPLATE/
    cp -v templates/ISSUE_TEMPLATE/*.yml ../.github/ISSUE_TEMPLATE/

    # Copy PR template
    cp -v templates/PULL_REQUEST_TEMPLATE/*.md ../.github/PULL_REQUEST_TEMPLATE/

    echo "✅ GitHub templates deployed to ../.github/"
    echo "   Now add & commit the templates in the target repository."
