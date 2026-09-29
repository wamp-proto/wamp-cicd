#!/usr/bin/env bash
# Usage: file-issue.sh <draft.md>
#
# File a GitHub issue from a draft whose header carries `Repo:` and `Title:` lines,
# with the body being everything after the first `---`. On success the draft is
# ARCHIVED to the cross-repo trashcan (never deleted) and its path + sha256 printed,
# so the digested->landed record is kept without a manual `mv` (metal#266).
#
# Runs on the control node (needs `gh` authenticated). The estate keeps this file
# versioned here; the control node uses ~/file-issue.sh as a symlink to it.
#
# Override the trashcan with AAIARE_TRASHCAN. Draft header shape:
#
#     Repo:  typedefint/<repo>
#     Title: [FEATURE] short but complete statement
#
#     ---
#     ## Why
#     ...
set -euo pipefail

f="${1:?usage: file-issue.sh <draft.md>}"
TRASHCAN="${AAIARE_TRASHCAN:-$HOME/work/typedefint/_trashcan}"

repo="$(grep -m1 '^Repo:'  "$f" | cut -d: -f2- | xargs)"
title="$(grep -m1 '^Title:' "$f" | cut -d: -f2- | sed 's/^ *//')"
body="$(awk 'x{print} /^---$/{x=1}' "$f")"
[ -n "${repo}" ] && [ -n "${title}" ] || {
    echo "REFUSING: draft needs '^Repo:' and '^Title:' header lines." >&2; exit 1; }

# REFUSE A DUPLICATE TITLE. Filed #98/#100 and #99/#101 as identical pairs on
# 2026-08-10 by running this script twice - the forge accepts that happily, and the
# duplicates are only visible later. Cheaper to refuse here than to close two after.
existing="$(gh issue list --repo "$repo" --state all --limit 200 \
              --search "$title" --json number,title \
              --jq ".[] | select(.title == \"${title//\"/\\\"}\") | .number" 2>/dev/null || true)"
if [ -n "${existing}" ]; then
    echo "REFUSING: ${repo} already has an issue with this exact title:" >&2
    for n in ${existing}; do echo "    #${n}" >&2; done
    echo "  Close it, or change the title if this is genuinely a second issue." >&2
    exit 1
fi

echo "--> ${repo}: ${title:0:70}..."
gh issue create --repo "$repo" --title "$title" --body "$body"

# Archive the digested draft (never delete): move to the trashcan under a timestamped
# name so nothing is overwritten, and print path + sha256 to record digested->landed.
mkdir -p "${TRASHCAN}"
archived="${TRASHCAN}/$(date +%Y%m%d-%H%M%S)-$(basename "$f")"
mv "$f" "${archived}"
echo "--> archived draft -> ${archived}"
echo "    sha256: $(openssl sha256 "${archived}" | awk '{print $NF}')"
