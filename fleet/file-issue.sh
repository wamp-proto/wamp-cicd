#!/usr/bin/env bash
# Usage: file-issue.sh <draft.md>
#
# File a GitHub issue from a draft whose header carries `Repo:` and `Title:` lines, with the
# body being everything after the first `---`. Refuses a duplicate title. Runs where `gh` is
# authenticated (the maintainer's machine); install with `just fleet-install-tools`.
#
# Draft header shape:
#
#     Repo:  <owner>/<repo>
#     Title: short but complete statement
#
#     ---
#     ## Why
#     ...
#
# On success the draft is ARCHIVED (never deleted) to
#     ${FLEET_ARCHIVE:-~/gh-issues/_filed}/<owner>/<repo>/<UTC stamp>-#<number>-<draft name>
# with the resulting URL appended, so the archive answers "where did this go?" by its path
# (repository), its name (number) and its last line (URL). If archiving fails after a
# successful filing, the script WARNS instead of failing: re-running would file twice.

set -euo pipefail

f="${1:?usage: file-issue.sh <draft.md>}"
ARCHIVE="${FLEET_ARCHIVE:-$HOME/gh-issues/_filed}"

[ -f "$f" ] || { echo "REFUSING: no such draft: $f" >&2; exit 1; }
# `|| true`: with `set -euo pipefail`, a header line that is missing would otherwise end
# the script right here, silently, before the refusal below could say why.
repo="$(grep -m1 '^Repo:'  "$f" | cut -d: -f2- | xargs || true)"
title="$(grep -m1 '^Title:' "$f" | cut -d: -f2- | sed 's/^ *//' || true)"
body="$(awk 'x{print} /^---$/{x=1}' "$f")"
[ -n "${repo}" ] && [ -n "${title}" ] || {
    echo "REFUSING: draft needs '^Repo:' and '^Title:' header lines." >&2; exit 1; }
[[ "${repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    echo "REFUSING: 'Repo:' must be a bare owner/name slug, got '${repo}'." >&2; exit 1; }

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
url="$(gh issue create --repo "$repo" --title "$title" --body "$body")"
echo "${url}"
number="${url##*/}"

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
