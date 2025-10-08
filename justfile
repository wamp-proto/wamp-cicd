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
