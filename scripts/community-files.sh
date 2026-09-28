#!/usr/bin/env bash
# Copyright (c) typedef int GmbH, Germany, 2025. All rights reserved.
# Licensed under the MIT License (see LICENSE file).
#
# Deploy, and check for drift, the community files every WAMP repository shares (#16).
#
#   community-files.sh deploy <repo-root>   copy the shared files in, seed DEVELOPMENT.md
#   community-files.sh check  <repo-root>   exit 1 if anything has drifted
#
# WHY COPIES AND NOT A SYMLINK. GitHub does not follow a symlink into a submodule - a
# submodule is only a commit pointer in the tree - so a CONTRIBUTING.md symlinked into
# `.cicd/` would break exactly where contributors look for it: the "contributing
# guidelines" link on the pull request page and the community profile. So the files are
# COPIED into each repository, and a check that fails in CI when a copy differs from its
# template is what keeps them the same. The copy is what GitHub shows; the check is what
# keeps it true.
#
# WHY THE TEMPLATES COME FROM BESIDE THIS SCRIPT. A repository runs its OWN pinned copy:
#
#     bash .cicd/scripts/community-files.sh check .
#
# so the comparison is against the templates at the wamp-cicd commit that repository
# pins. A composite action referenced as `@main` would compare against main instead, and
# report drift in every repository the moment a template changed here - before any of
# them had bumped its pin.
#
# The three kinds of file:
#
#   MANAGED  byte-identical in every repository; `check` fails on any difference
#   SEEDED   created by `deploy` only when missing and never overwritten - the repository
#            owns it; `check` only requires that it EXISTS (CONTRIBUTING.md links to it)
#   OBSOLETE removed by `deploy`; `check` fails while it is still there

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${HERE}/../templates"

# template (relative to templates/)  ->  destination (relative to the repository root)
MANAGED=(
    "CONTRIBUTING.md:CONTRIBUTING.md"
    "pull_request_template.md:.github/pull_request_template.md"
    "audit-README.md:.audit/README.md"
)
SEEDED=(
    "DEVELOPMENT.md:DEVELOPMENT.md"
)
OBSOLETE=(
    ".github/PULL_REQUEST_TEMPLATE"
)

usage() {
    echo "usage: $(basename "$0") deploy|check <repo-root>" >&2
    exit 2
}

[ $# -eq 2 ] || usage
mode="$1"
root="$2"
[ -d "${root}" ] || { echo "REFUSING: no such directory: ${root}" >&2; exit 2; }
root="$(cd "${root}" && pwd)"
[ -d "${TEMPLATES}" ] || { echo "REFUSING: no templates at ${TEMPLATES}" >&2; exit 2; }

deploy() {
    local pair src dst
    for pair in "${MANAGED[@]}"; do
        src="${TEMPLATES}/${pair%%:*}"; dst="${root}/${pair#*:}"
        mkdir -p "$(dirname "${dst}")"
        if [ -f "${dst}" ] && cmp -s "${src}" "${dst}"; then
            echo "  unchanged  ${pair#*:}"
        else
            cp "${src}" "${dst}"
            echo "  deployed   ${pair#*:}"
        fi
    done
    for pair in "${SEEDED[@]}"; do
        src="${TEMPLATES}/${pair%%:*}"; dst="${root}/${pair#*:}"
        if [ -e "${dst}" ]; then
            echo "  kept       ${pair#*:} (owned by this repository)"
        else
            cp "${src}" "${dst}"
            echo "  seeded     ${pair#*:}"
        fi
    done
    for dst in "${OBSOLETE[@]}"; do
        if [ -e "${root}/${dst}" ]; then
            rm -rf "${root:?}/${dst}"
            echo "  removed    ${dst} (obsolete)"
        fi
    done
    echo "--> Community files deployed into ${root}. Review, then add and commit them there."
}

check() {
    local pair src dst failed=0
    for pair in "${MANAGED[@]}"; do
        src="${TEMPLATES}/${pair%%:*}"; dst="${root}/${pair#*:}"
        if [ ! -f "${dst}" ]; then
            echo "  MISSING    ${pair#*:}"
            failed=1
        elif ! cmp -s "${src}" "${dst}"; then
            echo "  DRIFTED    ${pair#*:}  (differs from .cicd/templates/${pair%%:*})"
            diff -u "${src}" "${dst}" | sed -n '3,20p' | sed 's/^/             /' || true
            failed=1
        else
            echo "  ok         ${pair#*:}"
        fi
    done
    for pair in "${SEEDED[@]}"; do
        dst="${root}/${pair#*:}"
        if [ -f "${dst}" ]; then
            echo "  ok         ${pair#*:} (exists)"
        else
            echo "  MISSING    ${pair#*:} (the shared CONTRIBUTING.md links to it)"
            failed=1
        fi
    done
    for dst in "${OBSOLETE[@]}"; do
        if [ -e "${root}/${dst}" ]; then
            echo "  OBSOLETE   ${dst} (remove it; deploy does)"
            failed=1
        fi
    done
    if [ "${failed}" != 0 ]; then
        echo ""
        echo "Community files have drifted. Do not edit the copies here - change the template in"
        echo "wamp-proto/wamp-cicd, bump .cicd, then run:  bash .cicd/scripts/community-files.sh deploy ."
        return 1
    fi
    echo "--> Community files are in sync with .cicd/templates/."
}

case "${mode}" in
    deploy) deploy ;;
    check)  check ;;
    *)      usage ;;
esac
