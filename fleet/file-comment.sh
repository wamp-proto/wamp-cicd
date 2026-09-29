#!/usr/bin/env bash
# Usage: file-comment.sh <draft.md>
#
# Append a comment to an EXISTING GitHub issue from a draft whose header carries
# `Repo:` and `Issue:` (the issue number), with the body being everything after the
# first `---`. The sibling of file-issue.sh for the "comment on an existing issue"
# case (e.g. a scope-update). On success the draft is ARCHIVED to the cross-repo
# trashcan and its path + sha256 printed (metal#266).
#
# Runs on the control node (needs `gh` authenticated). Draft header shape:
#
#     Repo:  typedefint/<repo>
#     Issue: 188
#
#     ---
#     Scope update: ...
set -euo pipefail

f="${1:?usage: file-comment.sh <draft.md>}"
TRASHCAN="${AAIARE_TRASHCAN:-$HOME/work/typedefint/_trashcan}"

repo="$(grep -m1 '^Repo:'  "$f" | cut -d: -f2- | xargs)"
issue="$(grep -m1 '^Issue:' "$f" | cut -d: -f2- | xargs)"
body="$(awk 'x{print} /^---$/{x=1}' "$f")"
[ -n "${repo}" ] && [ -n "${issue}" ] || {
    echo "REFUSING: draft needs '^Repo:' and '^Issue:' header lines." >&2; exit 1; }

echo "--> ${repo}#${issue}: adding a comment..."
gh issue comment "$issue" --repo "$repo" --body "$body"

# Archive the digested draft (never delete); print path + sha256 (digested->landed).
mkdir -p "${TRASHCAN}"
archived="${TRASHCAN}/$(date +%Y%m%d-%H%M%S)-$(basename "$f")"
mv "$f" "${archived}"
echo "--> archived draft -> ${archived}"
echo "    sha256: $(openssl sha256 "${archived}" | awk '{print $NF}')"
