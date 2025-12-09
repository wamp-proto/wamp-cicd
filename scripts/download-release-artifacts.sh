#!/usr/bin/env bash
# Download ALL artifacts from a GitHub release for release preparation
# Usage: download-release-artifacts.sh <release-name> <repo>
# Example: download-release-artifacts.sh master-202512092131 crossbario/autobahn-python

set -euo pipefail

RELEASE_NAME="${1:-}"
REPO="${2:-crossbario/autobahn-python}"

if [ -z "${RELEASE_NAME}" ]; then
    echo "Usage: $0 <release-name> [repo]"
    echo "Example: $0 master-202512092131 crossbario/autobahn-python"
    exit 1
fi

echo ""
echo "========================================================================"
echo "  Downloading ALL Release Artifacts"
echo "========================================================================"
echo ""
echo "Release: ${RELEASE_NAME}"
echo "Repository: ${REPO}"
echo ""

# Destination directory
DEST_DIR="/tmp/release-artifacts/${RELEASE_NAME}"

# Check if gh is available and authenticated
if ! command -v gh &> /dev/null; then
    echo "ERROR: GitHub CLI (gh) is not installed"
    echo "   Install: https://cli.github.com/"
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "ERROR: GitHub CLI is not authenticated"
    echo "   Run: gh auth login"
    exit 1
fi

# Verify release exists
echo "==> Verifying release exists..."
if ! gh release view "${RELEASE_NAME}" --repo "${REPO}" &> /dev/null; then
    echo "ERROR: Release '${RELEASE_NAME}' not found"
    echo ""
    echo "Available releases:"
    gh release list --repo "${REPO}" --limit 10
    exit 1
fi
echo "OK: Release found"
echo ""

# Create/clean destination directory
if [ -d "${DEST_DIR}" ]; then
    echo "==> Cleaning existing directory: ${DEST_DIR}"
    rm -rf "${DEST_DIR}"
fi
mkdir -p "${DEST_DIR}"

# Download all assets
echo "==> Downloading all release assets to: ${DEST_DIR}"
echo ""
cd "${DEST_DIR}"

gh release download "${RELEASE_NAME}" \
    --repo "${REPO}" \
    --pattern "*" \
    --clobber

echo ""
echo "==> Downloaded assets:"
ls -la

# Count different types of files
WHEEL_COUNT=$(ls -1 *.whl 2>/dev/null | wc -l || echo "0")
TARBALL_COUNT=$(ls -1 *.tar.gz 2>/dev/null | wc -l || echo "0")
CHECKSUM_COUNT=$(ls -1 *CHECKSUMS* 2>/dev/null | wc -l || echo "0")
AUDIT_COUNT=$(ls -1 *.md 2>/dev/null | wc -l || echo "0")

echo ""
echo "==> Asset summary:"
echo "    Wheels:     ${WHEEL_COUNT}"
echo "    Tarballs:   ${TARBALL_COUNT}"
echo "    Checksums:  ${CHECKSUM_COUNT}"
echo "    Audit/MD:   ${AUDIT_COUNT}"

# Verify checksums if available
if [ -f "CHECKSUMS.sha256" ]; then
    echo ""
    echo "==> Verifying checksums..."
    # Count lines that look like checksums (SHA256 or SHA2-256 format)
    EXPECTED=$(grep -cE "^SHA2?-?256\(" CHECKSUMS.sha256 || echo "0")
    echo "    Files to verify: ${EXPECTED}"

    VERIFIED=0
    FAILED=0
    SKIPPED=0
    while IFS= read -r line; do
        # Skip empty lines
        [ -z "$line" ] && continue

        # Parse: SHA256(filename)= checksum  or  SHA2-256(filename)= checksum
        # Extract filename between parentheses
        FILE_PATH=$(echo "$line" | sed -E 's/^SHA2?-?256\(([^)]+)\)=.*/\1/')
        EXPECTED_CHECKSUM=$(echo "$line" | awk -F'= ' '{print $2}')

        # Handle ./prefix
        FILE_PATH="${FILE_PATH#./}"

        if [ -f "$FILE_PATH" ]; then
            ACTUAL_CHECKSUM=$(openssl sha256 "$FILE_PATH" | awk '{print $2}')
            if [ "$ACTUAL_CHECKSUM" = "$EXPECTED_CHECKSUM" ]; then
                VERIFIED=$((VERIFIED + 1))
            else
                echo "    MISMATCH: $FILE_PATH"
                echo "      Expected: $EXPECTED_CHECKSUM"
                echo "      Actual:   $ACTUAL_CHECKSUM"
                FAILED=$((FAILED + 1))
            fi
        else
            # File not in this directory (might be in sub-checksum file)
            SKIPPED=$((SKIPPED + 1))
        fi
    done < CHECKSUMS.sha256

    if [ $FAILED -gt 0 ]; then
        echo "    ERROR: ${FAILED} file(s) failed verification!"
        exit 1
    else
        echo "    OK: ${VERIFIED} file(s) verified successfully"
        if [ $SKIPPED -gt 0 ]; then
            echo "    (${SKIPPED} files skipped - referenced in sub-checksum files)"
        fi
    fi
fi

echo ""
echo "========================================================================"
echo "  Download Complete"
echo "========================================================================"
echo ""
echo "Artifacts location: ${DEST_DIR}"
echo ""
echo "Next steps:"
echo "  1. just generate-release-notes <version> ${RELEASE_NAME}"
echo "  2. just prepare-changelog <version>"
echo ""
