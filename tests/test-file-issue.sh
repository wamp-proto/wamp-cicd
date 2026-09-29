#!/usr/bin/env bash
#
# Test fleet/file-issue.sh and fleet/file-comment.sh (#58).
#
# Two defects of the versions that filed the wave1-2026-09 issues, and the new archive:
#
#   1. A draft without its `Issue:` (or `Repo:`) line made the script exit SILENTLY:
#      `set -euo pipefail` ended it at the failing `grep`, before the refusal message.
#   2. Filed drafts went to one flat trashcan under a timestamped name that did not say
#      which repository or which issue they became.
#   3. Now: <archive>/<owner>/<repo>/<stamp>-#<number>-<name>, with the URL appended.
#
# Drives the REAL scripts against a stub `gh` that records its arguments and prints the
# URL the forge would print. No network, no credentials.
#
# Run: bash tests/test-file-issue.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUE="${HERE}/../fleet/file-issue.sh"
COMMENT="${HERE}/../fleet/file-comment.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0
ok()   { echo "  ok   $1"; passed=$((passed+1)); }
fail() { echo "  FAIL $1"; failed=$((failed+1)); }

# stub gh: `issue list` -> the titles in $WORK/existing; `issue create` -> a new issue URL;
# `issue comment` -> a comment URL. Every call is logged.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG}"
case "$1 $2" in
  "issue list")    [ -s "${STUB_EXISTING}" ] && echo 17 ; exit 0 ;;
  "issue create")  for a; do [ "$p" = "--repo" ] && r="$a"; p="$a"; done
                   echo "https://github.com/${r}/issues/42" ;;
  "issue comment") for a; do [ "$p" = "--repo" ] && r="$a"; p="$a"; done
                   echo "https://github.com/${r}/issues/$3#issuecomment-99" ;;
esac
STUB
chmod +x "${WORK}/bin/gh"
export PATH="${WORK}/bin:${PATH}" STUB_LOG="${WORK}/gh.log" STUB_EXISTING="${WORK}/existing"
# A throwaway HOME too: a script version with a HOME-relative default archive (the old one
# had ~/work/typedefint/_trashcan) must never write into the real home while under test.
export HOME="${WORK}/home" FLEET_ARCHIVE="${WORK}/filed"
mkdir -p "${HOME}"
: > "${STUB_EXISTING}"

draft() { printf '%s\n' "$@" > "${WORK}/d.md"; }

echo "== file-comment: missing Issue: line refuses LOUDLY (defect 1)"
draft "Repo:  acme/widget" "" "---" "body"
out="$(bash "${COMMENT}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "exits non-zero" || fail "exits non-zero (rc=$rc)"
grep -q "REFUSING: draft needs '^Repo:' and '^Issue:'" <<<"$out" && ok "says why" || fail "says why: '$out'"
[ ! -s "${STUB_LOG}" ] && ok "nothing sent to the forge" || fail "nothing sent to the forge"

echo "== file-issue: missing Title: line refuses loudly"
draft "Repo:  acme/widget" "" "---" "body"
out="$(bash "${ISSUE}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "REFUSING" <<<"$out" && ok "refused with a message" || fail "refused with a message: '$out'"

echo "== file-issue: a slug with trailing text is refused"
draft "Repo:  acme/widget PR #3" "Title: t" "" "---" "body"
out="$(bash "${ISSUE}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "bare owner/name slug" <<<"$out" && ok "refused" || fail "refused: '$out'"

echo "== file-issue: files, archives per repository with number and URL (2, 3)"
: > "${STUB_LOG}"
draft "Repo:  acme/widget" "Title: Make it so" "" "---" "## Why" "because"
out="$(bash "${ISSUE}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || fail "exit 0 (rc=$rc): $out"
grep -q -- "issue create --repo acme/widget --title Make it so" "${STUB_LOG}" && ok "gh issue create called" || fail "gh issue create called"
a="$(ls "${FLEET_ARCHIVE}/acme/widget/" 2>/dev/null)"
[[ "$a" =~ ^[0-9]{8}-[0-9]{6}-#42-d\.md$ ]] && ok "archived as <stamp>-#42-d.md under acme/widget/" || fail "archive name: '$a'"
tail -1 "${FLEET_ARCHIVE}/acme/widget/$a" 2>/dev/null | grep -q '^Filed: https://github.com/acme/widget/issues/42 (' \
    && ok "URL appended" || fail "URL appended"
[ ! -e "${WORK}/d.md" ] && ok "draft moved, not copied" || fail "draft moved, not copied"

echo "== file-issue: duplicate title refused"
echo 17 > "${STUB_EXISTING}"
draft "Repo:  acme/widget" "Title: Make it so" "" "---" "body"
out="$(bash "${ISSUE}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "#17" <<<"$out" && ok "refused, names #17" || fail "refused, names #17: '$out'"
: > "${STUB_EXISTING}"

echo "== file-comment: files and archives with the comment URL"
draft "Repo:  acme/widget" "Issue: 7" "" "---" "Scope update"
out="$(bash "${COMMENT}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0" || fail "exit 0 (rc=$rc): $out"
a="$(ls "${FLEET_ARCHIVE}/acme/widget/" | grep -- '-#7-')"
[ -n "$a" ] && tail -1 "${FLEET_ARCHIVE}/acme/widget/$a" | grep -q 'issues/7#issuecomment-99' \
    && ok "archived as -#7- with the comment URL" || fail "comment archive: '$a'"

echo "== archiving failure after filing WARNS, does not fail (a re-run would file twice)"
draft "Repo:  acme/widget" "Title: Another" "" "---" "body"
export FLEET_ARCHIVE="/proc/cannot-create-here"
out="$(bash "${ISSUE}" "${WORK}/d.md" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "WARNING: filed as .*do NOT re-run" <<<"$out" && ok "warned, exit 0" || fail "warned, exit 0 (rc=$rc): $out"

echo ""
echo "${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
