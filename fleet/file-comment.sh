#!/usr/bin/env bash
# Usage: file-comment.sh <draft.md>
#
# Append a comment to an EXISTING GitHub issue from a draft whose header carries `Repo:` and
# `Issue:` (the issue number), with the body being everything after the first `---`. The
# sibling of file-issue.sh. Runs where `gh` is authenticated.
#
# Draft header shape:
#
#     Repo:  <owner>/<repo>
#     Issue: 188
#
#     ---
#     Scope update: ...
#
# On success the draft is ARCHIVED (never deleted) to
#     ${FLEET_ARCHIVE:-~/gh-issues/_filed}/<owner>/<repo>/<UTC stamp>-#<number>-<draft name>
# with the resulting URL appended, so the archive answers "where did this go?" by its path
# (repository), its name (number) and its last line (URL). If archiving fails after a
# successful filing, the script WARNS instead of failing: re-running would file twice.

set -euo pipefail

f="${1:?usage: file-comment.sh <draft.md>}"
ARCHIVE="${FLEET_ARCHIVE:-$HOME/gh-issues/_filed}"

[ -f "$f" ] || { echo "REFUSING: no such draft: $f" >&2; exit 1; }
# `|| true`: with `set -euo pipefail`, a header line that is missing would otherwise end
# the script right here, silently, before the refusal below could say why.
repo="$(grep -m1 '^Repo:'  "$f" | cut -d: -f2- | xargs || true)"
issue="$(grep -m1 '^Issue:' "$f" | cut -d: -f2- | xargs || true)"
body="$(awk 'x{print} /^---$/{x=1}' "$f")"
[ -n "${repo}" ] && [ -n "${issue}" ] || {
    echo "REFUSING: draft needs '^Repo:' and '^Issue:' header lines." >&2; exit 1; }
[[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    echo "REFUSING: 'Repo:' must be a bare owner/name slug, got '${repo}'." >&2; exit 1; }
[[ "${issue}" =~ ^[0-9]+$ ]] || {
    echo "REFUSING: 'Issue:' must be an issue number, got '${issue}'." >&2; exit 1; }

echo "--> ${repo}#${issue}: adding a comment..."
url="$(gh issue comment "$issue" --repo "$repo" --body "$body")"
echo "${url}"
number="${issue}"

# Archive the filed draft (never delete; see the header). A failure here is a WARNING:
# the forge already has the issue/comment, and a re-run would file it a second time.
dir="${ARCHIVE}/${repo}"
archived="${dir}/$(date -u +%Y%m%d-%H%M%S)-#${number}-$(basename "$f")"
if mkdir -p "${dir}" && mv "$f" "${archived}" \
   && printf '\n---\nFiled: %s (%s)\n' "${url}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${archived}"; then
    echo "--> archived draft -> ${archived}"
    echo "    sha256: $(openssl sha256 "${archived}" | awk '{print $NF}')"
else
    echo "WARNING: filed as ${url}, but archiving the draft failed - move $f by hand; do NOT re-run." >&2
fi
