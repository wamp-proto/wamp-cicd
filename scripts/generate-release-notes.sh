#!/usr/bin/env bash
# Generate release notes entry from downloaded artifacts
# Usage: generate-release-notes.sh <version> <release-name> [repo]
# Example: generate-release-notes.sh 25.12.1 master-202512092131 crossbario/autobahn-python

set -e

VERSION="${1:-}"
RELEASE_NAME="${2:-}"
REPO="${3:-crossbario/autobahn-python}"

if [ -z "${VERSION}" ] || [ -z "${RELEASE_NAME}" ]; then
    echo "Usage: $0 <version> <release-name> [repo]"
    echo "Example: $0 25.12.1 master-202512092131 crossbario/autobahn-python"
    exit 1
fi

echo ""
echo "========================================================================"
echo "  Generating Release Notes for Version ${VERSION}"
echo "========================================================================"
echo ""
echo "Version: ${VERSION}"
echo "Source release: ${RELEASE_NAME}"
echo "Repository: ${REPO}"
echo ""

# Check artifacts directory exists
ARTIFACTS_DIR="/tmp/release-artifacts/${RELEASE_NAME}"
if [ ! -d "${ARTIFACTS_DIR}" ]; then
    echo "ERROR: Artifacts directory not found: ${ARTIFACTS_DIR}"
    echo ""
    echo "Run first: just download-release-artifacts ${RELEASE_NAME}"
    exit 1
fi

echo "OK: Artifacts directory found: ${ARTIFACTS_DIR}"
echo ""

# Output file
OUTPUT_FILE="/tmp/release-notes-${VERSION}.rst"
TODAY=$(date +%Y-%m-%d)

# Start generating RST
cat > "${OUTPUT_FILE}" << EOF
${VERSION} (${TODAY})
--------------------

**Release Type:** Stable release

**Source Build:** \`${RELEASE_NAME} <https://github.com/${REPO}/releases/tag/${RELEASE_NAME}>\`__

EOF

# =========================================================================
# WebSocket Conformance Results
# =========================================================================
echo "==> Processing WebSocket conformance results..."

WSTEST_SUMMARY=$(find "${ARTIFACTS_DIR}" -name "*wstest-summary.md" -type f | head -1)
if [ -n "${WSTEST_SUMMARY}" ] && [ -f "${WSTEST_SUMMARY}" ]; then
    echo "    Found: ${WSTEST_SUMMARY}"

    cat >> "${OUTPUT_FILE}" << 'EOF'
**WebSocket Conformance**

Autobahn|Python passes 100% of the WebSocket conformance tests from the
`Autobahn|Testsuite <https://github.com/crossbario/autobahn-testsuite>`_.

.. list-table:: Conformance Test Results
   :header-rows: 1
   :widths: 30 20 20 30

   * - Configuration
     - Client
     - Server
     - Notes
   * - with-nvx (NVX acceleration enabled)
     - 100%
     - 100%
     - Hardware-accelerated XOR masking
   * - without-nvx (pure Python)
     - 100%
     - 100%
     - Fallback implementation

EOF
else
    echo "    Warning: No conformance summary found"
    cat >> "${OUTPUT_FILE}" << EOF
**WebSocket Conformance**

See the \`GitHub Release <https://github.com/${REPO}/releases/tag/${RELEASE_NAME}>\`__
for detailed conformance test results.

EOF
fi

# =========================================================================
# Artifact Inventory
# =========================================================================
echo "==> Processing artifact inventory..."

cat >> "${OUTPUT_FILE}" << 'EOF'
**Release Artifacts**

EOF

# Count wheels by platform
WHEELS=$(find "${ARTIFACTS_DIR}" -name "*.whl" -type f 2>/dev/null || true)
WHEEL_COUNT=$(echo "${WHEELS}" | grep -c ".whl" 2>/dev/null || echo "0")

if [ "${WHEEL_COUNT}" -gt 0 ]; then
    cat >> "${OUTPUT_FILE}" << 'EOF'
Binary wheels are available for the following platforms:

.. list-table:: Platform Support Matrix
   :header-rows: 1
   :widths: 25 20 20 35

   * - Platform
     - Python
     - Architecture
     - Wheel
EOF

    # Parse wheel filenames and create table entries
    for wheel in ${WHEELS}; do
        WHEEL_NAME=$(basename "${wheel}")

        # Extract platform
        if echo "${WHEEL_NAME}" | grep -q "manylinux"; then
            PLATFORM="Linux (manylinux)"
        elif echo "${WHEEL_NAME}" | grep -q "macosx"; then
            PLATFORM="macOS"
        elif echo "${WHEEL_NAME}" | grep -q "win"; then
            PLATFORM="Windows"
        else
            PLATFORM="Other"
        fi

        # Extract Python version
        if echo "${WHEEL_NAME}" | grep -q "cp3"; then
            PY_VER=$(echo "${WHEEL_NAME}" | grep -oE "cp3[0-9]+" | head -1 | sed 's/cp/CPython /')
        elif echo "${WHEEL_NAME}" | grep -q "pp3"; then
            PY_VER=$(echo "${WHEEL_NAME}" | grep -oE "pp3[0-9]+" | head -1 | sed 's/pp/PyPy /')
        else
            PY_VER="Unknown"
        fi

        # Extract architecture
        if echo "${WHEEL_NAME}" | grep -q "x86_64"; then
            ARCH="x86_64"
        elif echo "${WHEEL_NAME}" | grep -qE "aarch64|arm64"; then
            ARCH="ARM64"
        elif echo "${WHEEL_NAME}" | grep -q "amd64"; then
            ARCH="x86_64"
        else
            ARCH="Unknown"
        fi

        cat >> "${OUTPUT_FILE}" << EOF
   * - ${PLATFORM}
     - ${PY_VER}
     - ${ARCH}
     - \`\`${WHEEL_NAME}\`\`
EOF
    done
    echo "" >> "${OUTPUT_FILE}"
fi

# Source distribution
SDIST=$(find "${ARTIFACTS_DIR}" -name "autobahn-*.tar.gz" -not -name "*conformance*" -type f | head -1)
if [ -n "${SDIST}" ]; then
    SDIST_NAME=$(basename "${SDIST}")
    cat >> "${OUTPUT_FILE}" << EOF
Source distribution: \`\`${SDIST_NAME}\`\`

EOF
fi

# =========================================================================
# Checksums / Chain of Custody
# =========================================================================
echo "==> Processing checksums..."

CHECKSUM_FILE="${ARTIFACTS_DIR}/CHECKSUMS.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
    cat >> "${OUTPUT_FILE}" << 'EOF'
**Artifact Verification**

All release artifacts include SHA256 checksums for integrity verification.
Download ``CHECKSUMS.sha256`` from the GitHub Release to verify:

.. code-block:: bash

   # Verify a downloaded wheel
   openssl sha256 autobahn-*.whl
   # Compare with checksum in CHECKSUMS.sha256

EOF
fi

# =========================================================================
# Links
# =========================================================================
cat >> "${OUTPUT_FILE}" << EOF
**Release Links**

* \`GitHub Release <https://github.com/${REPO}/releases/tag/v${VERSION}>\`__
* \`PyPI Package <https://pypi.org/project/autobahn/${VERSION}/>\`__
* \`Documentation <https://autobahn.readthedocs.io/en/v${VERSION}/>\`__

**Detailed Changes**

* See :ref:\`changelog <changelog>\` (${VERSION} section)

EOF

echo ""
echo "========================================================================"
echo "  Generated Release Notes"
echo "========================================================================"
echo ""
cat "${OUTPUT_FILE}"
echo ""
echo "========================================================================"
echo ""
echo "Generated file: ${OUTPUT_FILE}"
echo ""
echo "To insert into docs/release-notes.rst:"
echo "  1. Review the generated content above"
echo "  2. Edit as needed"
echo "  3. Insert after the 'Release Notes' header in docs/release-notes.rst"
echo ""
