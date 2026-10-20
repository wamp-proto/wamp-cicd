#!/usr/bin/env bash
# Verify the PyPI provenance (PEP 740 attestations) of every file of a release (wamp-cicd #57).
#
# Usage: verify-pypi-provenance.sh <pypi-project> <version> <github-repository-url>
# Example: verify-pypi-provenance.sh crossbar 26.7.1 https://github.com/crossbario/crossbar
#
# Lists the files of the release from the PyPI simple API (JSON, PEP 691: the project pages may
# serve a JavaScript challenge to scripts, the simple API does not) and verifies each one with
# `pypi-attestations verify pypi --repository <github-repository-url>`. A file passes when PyPI
# holds an attestation for it that was issued to a workflow of that repository.
#
# This proves who uploaded the file (the repository's publish workflow, through Trusted
# Publishing), not how the file was built (build provenance: SLSA.md item 1).
#
# Needs pypi.org, files.pythonhosted.org and the Sigstore trust root (tuf-repo-cdn.sigstore.dev).
#
# Exit codes: 0 every file verified; 1 a file has no attestation, fails verification, or the
# version has no files; 2 wrong usage, a missing tool, or the listing cannot be fetched.

set -uo pipefail

PROJECT="${1:-}"
VERSION="${2:-}"
REPOSITORY="${3:-}"

if [ -z "${PROJECT}" ] || [ -z "${VERSION}" ] || [ -z "${REPOSITORY}" ]; then
    echo "Usage: $0 <pypi-project> <version> <github-repository-url>" >&2
    echo "Example: $0 crossbar 26.7.1 https://github.com/crossbario/crossbar" >&2
    exit 2
fi

for tool in curl python3 pypi-attestations; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: ${tool} not found" >&2
        [ "${tool}" = pypi-attestations ] && echo "   Install: pip install pypi-attestations" >&2
        exit 2
    fi
done

URL="https://pypi.org/simple/${PROJECT}/"
if ! LISTING="$(curl -fsSL -H "Accept: application/vnd.pypi.simple.v1+json" "${URL}")"; then
    echo "ERROR: cannot fetch the file listing from ${URL}" >&2
    exit 2
fi

# One line per file of VERSION: "<filename> <provenance URL or ->". The version is the second
# dash-separated field of a wheel name, and what follows the last dash of an sdist name.
if ! FILES="$(printf '%s' "${LISTING}" | python3 -I -c '
import json, sys

version = sys.argv[1]
for f in json.load(sys.stdin)["files"]:
    name = f["filename"]
    if name.endswith(".whl"):
        file_version = name.split("-")[1]
    elif name.endswith(".tar.gz") or name.endswith(".zip"):
        file_version = name.rsplit(".tar.gz", 1)[0].rsplit(".zip", 1)[0].rsplit("-", 1)[-1]
    else:
        continue
    if file_version == version:
        print(name, f.get("provenance") or "-")
' "${VERSION}")"; then
    echo "ERROR: cannot parse the file listing from ${URL}" >&2
    exit 2
fi

if [ -z "${FILES}" ]; then
    echo "ERROR: no files of ${PROJECT} ${VERSION} on PyPI" >&2
    exit 1
fi

TOTAL=0; VERIFIED=0; MISSING=0; FAILED=0
while read -r FILE PROVENANCE; do
    TOTAL=$((TOTAL + 1))
    if [ "${PROVENANCE}" = "-" ]; then
        echo "MISSING ${FILE}: PyPI has no attestation for this file"
        MISSING=$((MISSING + 1))
        continue
    fi
    if OUTPUT="$(pypi-attestations verify pypi --repository "${REPOSITORY}" "pypi:${FILE}" 2>&1)"; then
        echo "OK      ${FILE}"
        VERIFIED=$((VERIFIED + 1))
    else
        echo "FAILED  ${FILE}: $(printf '%s\n' "${OUTPUT}" | tail -1)"
        FAILED=$((FAILED + 1))
    fi
done <<< "${FILES}"

echo ""
echo "${PROJECT} ${VERSION}: ${TOTAL} files, ${VERIFIED} verified, ${MISSING} missing an attestation, ${FAILED} failed (repository ${REPOSITORY})"
[ "${VERIFIED}" = "${TOTAL}" ]
