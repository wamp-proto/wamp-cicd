#!/usr/bin/env bash
# Generate changelog entry from git history, audit files, and GitHub issues
# Usage: prepare-changelog.sh <version> [repo]
# Example: prepare-changelog.sh 25.12.1 crossbario/autobahn-python

set -e

VERSION="${1:-}"
REPO="${2:-crossbario/autobahn-python}"

if [ -z "${VERSION}" ]; then
    echo "Usage: $0 <version> [repo]"
    echo "Example: $0 25.12.1 crossbario/autobahn-python"
    exit 1
fi

echo ""
echo "========================================================================"
echo "  Generating Changelog for Version ${VERSION}"
echo "========================================================================"
echo ""
echo "Version: ${VERSION}"
echo "Repository: ${REPO}"
echo ""

# Find the previous version in changelog.rst
PREV_VERSION=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" docs/changelog.rst 2>/dev/null | head -1 || echo "")
if [ -z "${PREV_VERSION}" ]; then
    echo "Warning: No previous version found in changelog.rst"
    PREV_TAG=""
else
    echo "Previous version in changelog: ${PREV_VERSION}"
    PREV_TAG="v${PREV_VERSION}"
fi

# Check if previous tag exists in git
if [ -n "${PREV_TAG}" ] && ! git rev-parse "${PREV_TAG}" &>/dev/null; then
    echo "Warning: Tag ${PREV_TAG} not found in git, falling back to git describe"
    PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
fi

echo ""
echo "==> Collecting commits since ${PREV_TAG:-beginning}..."
echo ""

# Get commits with PR numbers
if [ -z "${PREV_TAG}" ]; then
    COMMITS=$(git log --oneline --no-decorate HEAD | head -100)
else
    COMMITS=$(git log --oneline --no-decorate "${PREV_TAG}..HEAD")
fi

COMMIT_COUNT=$(echo "$COMMITS" | wc -l)
echo "Found ${COMMIT_COUNT} commits"
echo ""

# Extract PR numbers from commits
PR_NUMBERS=$(echo "$COMMITS" | grep -oE '#[0-9]+' | tr -d '#' | sort -u || true)

# Prepare output file
OUTPUT_FILE="/tmp/changelog-${VERSION}.rst"

cat > "${OUTPUT_FILE}" << EOF
${VERSION}
-------

EOF

# Check if gh is available for fetching issue details
HAS_GH=false
if command -v gh &> /dev/null && gh auth status &> /dev/null 2>&1; then
    HAS_GH=true
    echo "OK: GitHub CLI available - will fetch issue details"
else
    echo "Warning: GitHub CLI not available - using commit messages only"
fi

echo ""
echo "==> Processing commits and audit files..."
echo ""

# Collect changes by category using temp files (more portable than arrays)
NEW_FILE=$(mktemp)
FIX_FILE=$(mktemp)
OTHER_FILE=$(mktemp)

# Cleanup on exit
trap "rm -f ${NEW_FILE} ${FIX_FILE} ${OTHER_FILE}" EXIT

# Process each PR
for PR_NUM in ${PR_NUMBERS}; do
    echo "  Processing PR #${PR_NUM}..."

    # Look for matching audit file
    AUDIT_FILE=""
    if [ -d ".audit" ]; then
        AUDIT_FILE=$(find .audit -name "*.md" -exec grep -l "Related issue.*#${PR_NUM}" {} \; 2>/dev/null | head -1 || true)
    fi

    ISSUE_NUM=""
    ISSUE_TITLE=""

    if [ -n "${AUDIT_FILE}" ]; then
        echo "    Found audit file: ${AUDIT_FILE}"
        # Extract related issue from audit file
        ISSUE_NUM=$(grep "Related issue" "${AUDIT_FILE}" | grep -oE '#[0-9]+' | tr -d '#' | head -1 || true)
        if [ -n "${ISSUE_NUM}" ]; then
            echo "    Related issue: #${ISSUE_NUM}"
        fi
    fi

    # Fetch issue/PR title from GitHub
    if [ "${HAS_GH}" = true ]; then
        # Try to get issue title first (issues have better descriptions)
        if [ -n "${ISSUE_NUM}" ]; then
            ISSUE_TITLE=$(gh issue view "${ISSUE_NUM}" --repo "${REPO}" --json title -q '.title' 2>/dev/null || echo "")
        fi
        # Fall back to PR title
        if [ -z "${ISSUE_TITLE}" ]; then
            ISSUE_TITLE=$(gh pr view "${PR_NUM}" --repo "${REPO}" --json title -q '.title' 2>/dev/null || echo "")
        fi
    fi

    # Fall back to commit message
    if [ -z "${ISSUE_TITLE}" ]; then
        ISSUE_TITLE=$(echo "$COMMITS" | grep "#${PR_NUM}" | head -1 | sed "s/^[a-f0-9]* //" | sed "s/ (#${PR_NUM})//" || true)
    fi

    if [ -n "${ISSUE_TITLE}" ]; then
        # Categorize based on title/commit message
        ITEM="* ${ISSUE_TITLE} (#${PR_NUM})"
        if echo "${ISSUE_TITLE}" | grep -qiE "^(fix|bug|patch|repair|correct)"; then
            echo "${ITEM}" >> "${FIX_FILE}"
        elif echo "${ISSUE_TITLE}" | grep -qiE "^(new|add|feat|implement|support)"; then
            echo "${ITEM}" >> "${NEW_FILE}"
        else
            echo "${ITEM}" >> "${OTHER_FILE}"
        fi
        echo "    Title: ${ISSUE_TITLE}"
    fi
done

# Also process commits without PR numbers (direct commits)
DIRECT_COMMITS=$(echo "$COMMITS" | grep -v '#[0-9]' || true)
if [ -n "${DIRECT_COMMITS}" ]; then
    echo ""
    echo "  Processing direct commits (no PR)..."
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            COMMIT_MSG=$(echo "$line" | sed 's/^[a-f0-9]* //')
            # Skip merge commits and version bumps
            if ! echo "${COMMIT_MSG}" | grep -qiE "^(Merge|Bump version|Release)"; then
                echo "* ${COMMIT_MSG}" >> "${OTHER_FILE}"
            fi
        fi
    done <<< "${DIRECT_COMMITS}"
fi

# Write categorized items to output
if [ -s "${NEW_FILE}" ]; then
    echo "**New**" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    cat "${NEW_FILE}" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
fi

if [ -s "${FIX_FILE}" ]; then
    echo "**Fix**" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    cat "${FIX_FILE}" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
fi

if [ -s "${OTHER_FILE}" ]; then
    echo "**Other**" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    cat "${OTHER_FILE}" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
fi

# If no items found, add placeholder
if [ ! -s "${NEW_FILE}" ] && [ ! -s "${FIX_FILE}" ] && [ ! -s "${OTHER_FILE}" ]; then
    echo "**Changes**" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    echo "* (No categorized changes found - please fill in manually)" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
fi

echo ""
echo "========================================================================"
echo "  Generated Changelog Entry"
echo "========================================================================"
echo ""
cat "${OUTPUT_FILE}"
echo ""
echo "========================================================================"
echo ""
echo "Generated file: ${OUTPUT_FILE}"
echo ""
echo "To insert into docs/changelog.rst:"
echo "  1. Review the generated content above"
echo "  2. Edit as needed (categorize, improve descriptions)"
echo "  3. Insert after the 'Changelog' header in docs/changelog.rst"
echo ""
