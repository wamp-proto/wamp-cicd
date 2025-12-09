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

# Start generating RST - main section heading
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

    # Add subsection heading (Sphinx will create anchor)
    cat >> "${OUTPUT_FILE}" << 'EOF'
WebSocket Conformance
^^^^^^^^^^^^^^^^^^^^^

Autobahn|Python passes 100% of the WebSocket conformance tests from the
`Autobahn|Testsuite <https://github.com/crossbario/autobahn-testsuite>`_.

EOF

    # Convert the wstest-summary.md to RST format
    # The markdown file has tables like:
    # | Testee | Cases OK / Total | Status |
    # We convert these to RST list-tables

    # Process each configuration section
    for nvx_config in "with-nvx" "without-nvx"; do
        if grep -q "Configuration: ${nvx_config}" "${WSTEST_SUMMARY}"; then
            # Add configuration subheading
            if [ "${nvx_config}" = "with-nvx" ]; then
                echo "Configuration: with-nvx (NVX acceleration)" >> "${OUTPUT_FILE}"
                echo '""""""""""""""""""""""""""""""""""""""""""' >> "${OUTPUT_FILE}"
            else
                echo "Configuration: without-nvx (pure Python)" >> "${OUTPUT_FILE}"
                echo '""""""""""""""""""""""""""""""""""""""""""' >> "${OUTPUT_FILE}"
            fi
            echo "" >> "${OUTPUT_FILE}"

            # Extract and convert Client table
            if grep -q "Client Conformance (${nvx_config})" "${WSTEST_SUMMARY}"; then
                echo "**Client Conformance**" >> "${OUTPUT_FILE}"
                echo "" >> "${OUTPUT_FILE}"
                echo ".. list-table::" >> "${OUTPUT_FILE}"
                echo "   :header-rows: 1" >> "${OUTPUT_FILE}"
                echo "   :widths: 60 20 10" >> "${OUTPUT_FILE}"
                echo "" >> "${OUTPUT_FILE}"
                echo "   * - Testee" >> "${OUTPUT_FILE}"
                echo "     - Cases" >> "${OUTPUT_FILE}"
                echo "     - Status" >> "${OUTPUT_FILE}"

                # Extract table rows using awk - get lines between "Client Conformance" and next "##" or "---"
                awk "/Client Conformance \(${nvx_config}\)/,/^(##|---)/" "${WSTEST_SUMMARY}" | \
                    grep "^|" | grep -v "^| *Testee" | grep -v "^|.*---" | \
                    while IFS='|' read -r _ testee cases status _; do
                        testee=$(echo "$testee" | xargs)
                        cases=$(echo "$cases" | xargs)
                        status=$(echo "$status" | xargs)
                        if [ -n "$testee" ] && [ "$testee" != "Testee" ]; then
                            echo "   * - \`\`${testee}\`\`" >> "${OUTPUT_FILE}"
                            echo "     - ${cases}" >> "${OUTPUT_FILE}"
                            echo "     - ${status}" >> "${OUTPUT_FILE}"
                        fi
                    done
                echo "" >> "${OUTPUT_FILE}"
            fi

            # Extract and convert Server table
            if grep -q "Server Conformance (${nvx_config})" "${WSTEST_SUMMARY}"; then
                echo "**Server Conformance**" >> "${OUTPUT_FILE}"
                echo "" >> "${OUTPUT_FILE}"
                echo ".. list-table::" >> "${OUTPUT_FILE}"
                echo "   :header-rows: 1" >> "${OUTPUT_FILE}"
                echo "   :widths: 60 20 10" >> "${OUTPUT_FILE}"
                echo "" >> "${OUTPUT_FILE}"
                echo "   * - Testee" >> "${OUTPUT_FILE}"
                echo "     - Cases" >> "${OUTPUT_FILE}"
                echo "     - Status" >> "${OUTPUT_FILE}"

                # Extract table rows
                awk "/Server Conformance \(${nvx_config}\)/,/^(##|---)/" "${WSTEST_SUMMARY}" | \
                    grep "^|" | grep -v "^| *Testee" | grep -v "^|.*---" | \
                    while IFS='|' read -r _ testee cases status _; do
                        testee=$(echo "$testee" | xargs)
                        cases=$(echo "$cases" | xargs)
                        status=$(echo "$status" | xargs)
                        if [ -n "$testee" ] && [ "$testee" != "Testee" ]; then
                            echo "   * - \`\`${testee}\`\`" >> "${OUTPUT_FILE}"
                            echo "     - ${cases}" >> "${OUTPUT_FILE}"
                            echo "     - ${status}" >> "${OUTPUT_FILE}"
                        fi
                    done
                echo "" >> "${OUTPUT_FILE}"
            fi
        fi
    done
else
    echo "    Warning: No conformance summary found"
    cat >> "${OUTPUT_FILE}" << EOF
WebSocket Conformance
^^^^^^^^^^^^^^^^^^^^^

See the \`GitHub Release <https://github.com/${REPO}/releases/tag/${RELEASE_NAME}>\`__
for detailed conformance test results.

EOF
fi

# =========================================================================
# Artifact Inventory
# =========================================================================
echo "==> Processing artifact inventory..."

cat >> "${OUTPUT_FILE}" << 'EOF'
Release Artifacts
^^^^^^^^^^^^^^^^^

EOF

# Count wheels by platform
WHEELS=$(find "${ARTIFACTS_DIR}" -name "*.whl" -type f 2>/dev/null || true)
WHEEL_COUNT=$(echo "${WHEELS}" | grep -c ".whl" 2>/dev/null || echo "0")

if [ "${WHEEL_COUNT}" -gt 0 ]; then
    cat >> "${OUTPUT_FILE}" << 'EOF'
Binary wheels are available for the following platforms:

.. list-table:: Platform Support Matrix
   :header-rows: 1
   :widths: 20 15 15 50

   * - Platform
     - Python
     - Arch
     - Wheel
EOF

    # Create temp file for sorting
    WHEEL_TEMP=$(mktemp)

    # Parse wheel filenames and create sortable entries
    for wheel in ${WHEELS}; do
        WHEEL_NAME=$(basename "${wheel}")

        # Extract platform (sort key 1)
        if echo "${WHEEL_NAME}" | grep -q "manylinux"; then
            PLATFORM="Linux"
            SORT_PLATFORM="1"
        elif echo "${WHEEL_NAME}" | grep -q "macosx"; then
            PLATFORM="macOS"
            SORT_PLATFORM="2"
        elif echo "${WHEEL_NAME}" | grep -q "win"; then
            PLATFORM="Windows"
            SORT_PLATFORM="3"
        else
            PLATFORM="Other"
            SORT_PLATFORM="9"
        fi

        # Extract Python version with proper formatting (sort key 2)
        if echo "${WHEEL_NAME}" | grep -q "cp3"; then
            PY_NUM=$(echo "${WHEEL_NAME}" | grep -oE "cp3[0-9]+" | head -1 | sed 's/cp//')
            # Insert dot: 311 -> 3.11, 314 -> 3.14
            PY_MAJOR="${PY_NUM:0:1}"
            PY_MINOR="${PY_NUM:1}"
            PY_VER="CPython ${PY_MAJOR}.${PY_MINOR}"
            SORT_PY="1${PY_NUM}"
        elif echo "${WHEEL_NAME}" | grep -q "pp3"; then
            PY_NUM=$(echo "${WHEEL_NAME}" | grep -oE "pp3[0-9]+" | head -1 | sed 's/pp//')
            PY_MAJOR="${PY_NUM:0:1}"
            PY_MINOR="${PY_NUM:1}"
            PY_VER="PyPy ${PY_MAJOR}.${PY_MINOR}"
            SORT_PY="2${PY_NUM}"
        else
            PY_VER="Unknown"
            SORT_PY="9999"
        fi

        # Extract architecture (sort key 3)
        if echo "${WHEEL_NAME}" | grep -qE "x86_64|amd64"; then
            ARCH="x86_64"
            SORT_ARCH="1"
        elif echo "${WHEEL_NAME}" | grep -qE "aarch64|arm64"; then
            ARCH="ARM64"
            SORT_ARCH="2"
        else
            ARCH="Other"
            SORT_ARCH="9"
        fi

        # Write sortable line: SORT_KEY|PLATFORM|PY_VER|ARCH|WHEEL_NAME
        echo "${SORT_PLATFORM}${SORT_PY}${SORT_ARCH}|${PLATFORM}|${PY_VER}|${ARCH}|${WHEEL_NAME}" >> "${WHEEL_TEMP}"
    done

    # Sort and output
    sort "${WHEEL_TEMP}" | while IFS='|' read -r _ platform py_ver arch wheel_name; do
        cat >> "${OUTPUT_FILE}" << EOF
   * - ${platform}
     - ${py_ver}
     - ${arch}
     - \`\`${wheel_name}\`\`
EOF
    done
    rm -f "${WHEEL_TEMP}"
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
    cat >> "${OUTPUT_FILE}" << EOF
Artifact Verification
^^^^^^^^^^^^^^^^^^^^^

All release artifacts include SHA256 checksums for integrity verification.

* \`CHECKSUMS.sha256 <https://github.com/${REPO}/releases/download/${RELEASE_NAME}/CHECKSUMS.sha256>\`__

To verify a downloaded artifact:

.. code-block:: bash

   # Download checksum file
   curl -LO https://github.com/${REPO}/releases/download/${RELEASE_NAME}/CHECKSUMS.sha256

   # Verify a wheel (example)
   openssl sha256 autobahn-${VERSION}-cp311-cp311-manylinux_2_28_x86_64.whl
   # Compare output with corresponding line in CHECKSUMS.sha256

EOF
fi

# =========================================================================
# Links
# =========================================================================
cat >> "${OUTPUT_FILE}" << EOF
Release Links
^^^^^^^^^^^^^

* \`GitHub Release <https://github.com/${REPO}/releases/tag/v${VERSION}>\`__
* \`PyPI Package <https://pypi.org/project/autobahn/${VERSION}/>\`__
* \`Documentation <https://autobahn.readthedocs.io/en/v${VERSION}/>\`__

**Detailed Changes:** See :ref:\`changelog\` (${VERSION} section)

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
