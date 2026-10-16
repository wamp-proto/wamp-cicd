#!/usr/bin/env bash
#
# Test that `new-branch` freezes the issue into the branch, and that `land` reports a
# specification that moved since (wamp-cicd #91).
#
# The issue is the specification of the work, and it lived only on the forge: editable after
# the cut with no trace in the repository, unreadable from the branch alone. `new-branch` now
# writes it next to the audit file, in the maintainer's signed first commit; `land` renders it
# again and compares.
#
# These tests drive the REAL recipes against a stub `gh` that runs the REAL jq over canned API
# output (as tests/test-pr-lookup.sh does), so the jq program that renders the issue is
# exercised, not just the shell around it. No network, no forge, no credentials.
#
# Run: bash tests/test-new-branch-freeze.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JUST="${HERE}/../workflow.just"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$WORKFLOW_JUST" ] || { echo "FATAL: no $WORKFLOW_JUST" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: these tests need jq" >&2; exit 2; }

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
PASS=0; FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -12; FAIL=$((FAIL + 1)); }

# --- the stub ---------------------------------------------------------------------------
#
# `gh issue view N --repo R --json ... --jq PROG` answers from $GH_ISSUE_JSON with the real jq
# and the program the recipe passed; GH_FAIL makes it fail like an unauthenticated gh.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_ARGV_LOG:-/dev/null}"
[ -n "${GH_FAIL:-}" ] && { echo "${GH_FAIL}" >&2; exit 1; }
prog=""; want=0
for a in "$@"; do
  if [ "$want" = 1 ]; then prog="$a"; want=0; continue; fi
  [ "$a" = "--jq" ] && want=1
done
jq -r "$prog" < "${GH_ISSUE_JSON}"
EOF
chmod +x "${WORK}/bin/gh"
export PATH="${WORK}/bin:${PATH}"
export GH_ARGV_LOG="${WORK}/argv"

# A PATH with everything except gh, for "gh is not installed here".
mkdir -p "${WORK}/nogh"
IFS=: read -ra dirs <<< "${PATH}"
for d in "${dirs[@]}"; do
  [ "$d" = "${WORK}/bin" ] && continue
  for f in "$d"/*; do
    n="$(basename "$f")"
    [ "$n" = gh ] && continue
    [ -e "${WORK}/nogh/$n" ] || ln -s "$f" "${WORK}/nogh/$n" 2>/dev/null
  done
done

# The issue, with the shapes that break naive rendering: a line that is exactly `---`, just's
# `{{ }}`, backticks, a trailing blank line, and two comments whose order matters.
issue_json() {   # $1 = body, $2 = number of comments (0..2)
  jq -n --arg body "$1" --argjson n "$2" '{
    number: 7, title: "make `widget` frobnicate", url: "https://github.com/acme/widget/issues/7",
    state: "OPEN", author: {login: "alice"}, createdAt: "2026-10-01T10:00:00Z",
    updatedAt: "2026-10-02T11:00:00Z", body: $body,
    comments: ([{author: {login: "bob"}, createdAt: "2026-10-01T12:00:00Z", body: "first comment"},
                {author: null, createdAt: "2026-10-01T13:00:00Z", body: "second comment"}][0:$n])
  }' > "${WORK}/issue.json"
}
BODY=$'## Why\n\nIt does not frobnicate.\n\n---\n\nUse `{{ x }}` here.\n'
export GH_ISSUE_JSON="${WORK}/issue.json"

# The fork topology as far as new-branch needs it: `origin` is the exchange it fetches from
# and publishes to; `upstream` is the canonical GitHub repository, never fetched here.
fixture() {   # $1 = dir, $2 = with upstream: yes|no
  local R="$1"
  mkdir -p "$R"; q git init --bare -b main "$R/exchange.git"; q git init -b main "$R/repo"
  ( cd "$R/repo"
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    echo seed > README.md
    q git config user.name Test   # the audit file's user, as on a machine without a fork URL
    q git add -A; q git commit -m seed
    q git remote add origin "$R/exchange.git"; q git push origin main
    [ "$2" = yes ] && q git remote add upstream https://github.com/acme/widget.git )
}

FROZEN=.audit/test_fix_7.issue.md
AUDIT=.audit/test_fix_7.md

echo "== new-branch freezes the issue =="
issue_json "$BODY" 2
R="${WORK}/a"; fixture "$R" yes; : > "$GH_ARGV_LOG"
( cd "$R/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit 0" "rc=$rc"
files="$(git -C "$R/repo" show --name-only --format= HEAD)"
grep -qx "$FROZEN" <<< "$files" && grep -qx "$AUDIT" <<< "$files" \
  && ok "the frozen issue and the audit file are in the one audit commit" \
  || bad "the frozen issue and the audit file are in the one audit commit" "$files"
git -C "$R/repo" log -1 --format=%s | grep -qx "start new dev branch; add audit file and frozen issue" \
  && ok "the commit message says so" || bad "the commit message says so"
text="$(git -C "$R/repo" show "HEAD:$FROZEN" 2>/dev/null)"
grep -qx 'Issue:    acme/widget#7' <<< "$text" && grep -qx 'Title:    make `widget` frobnicate' <<< "$text" \
  && ok "header: repository, number and title" || bad "header: repository, number and title"
# the content: everything after the first `---` line and the blank line after it
git -C "$R/repo" show "HEAD:$FROZEN" | awk 'f { print; next } $0 == "---" { getline; f = 1 }' > "${WORK}/content"
printf '%s' "$BODY" | cmp -s - <(head -c "${#BODY}" "${WORK}/content") \
  && ok "the body is byte-identical, \`---\` and {{ }} included" || bad "the body is byte-identical"
want="$(sed -n 's/^SHA-256:  \([0-9a-f]\{64\}\).*/\1/p' <<< "$text")"
[ -n "$want" ] && [ "$(sha256sum < "${WORK}/content" | cut -d' ' -f1)" = "$want" ] \
  && ok "the recorded SHA-256 is that of the content" || bad "the recorded SHA-256 is that of the content" "$want"
grep -q '## Comments at freeze (2)' "${WORK}/content" \
  && [ "$(grep -n 'first comment' "${WORK}/content" | cut -d: -f1)" -lt "$(grep -n 'second comment' "${WORK}/content" | cut -d: -f1)" ] \
  && grep -q '### @ghost, 2026-10-01T13:00:00Z' "${WORK}/content" \
  && ok "comments at freeze, in order, a deleted author as @ghost" || bad "comments at freeze, in order"
grep -q -- "--repo acme/widget" "$GH_ARGV_LOG" \
  && ok "the issue is asked of the canonical repository (upstream)" || bad "the issue is asked of upstream" "$(cat "$GH_ARGV_LOG")"
[ "$(git --git-dir="$R/exchange.git" rev-parse -q --verify refs/heads/fix_7)" = "$(git -C "$R/repo" rev-parse HEAD)" ] \
  && ok "published" || bad "published"

echo ""
echo "== gh present but the fetch fails: refused, nothing created =="
R="${WORK}/b"; fixture "$R" yes
( cd "$R/repo" && GH_FAIL="gh: authentication required" just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q "could not fetch issue acme/widget#7" "${WORK}/log" \
  && grep -q "authentication required" "${WORK}/log" \
  && ok "exit 1, and gh's own message is shown" || bad "exit 1, and gh's own message is shown" "rc=$rc"
! git -C "$R/repo" rev-parse -q --verify refs/heads/fix_7 >/dev/null \
  && [ "$(git -C "$R/repo" symbolic-ref --short HEAD)" = main ] \
  && ok "no local branch, still on main" || bad "no local branch, still on main"
! git --git-dir="$R/exchange.git" rev-parse -q --verify refs/heads/fix_7 >/dev/null \
  && ok "nothing pushed" || bad "nothing pushed"

echo ""
echo "== no gh, or no GitHub remote: cut anyway, and said loudly =="
R="${WORK}/c"; fixture "$R" yes
( cd "$R/repo" && PATH="${WORK}/nogh" just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "NOTE: issue #7 was NOT frozen into the branch - gh is not installed here" "${WORK}/log" \
  && ok "no gh: exit 0 with the NOTE" || bad "no gh: exit 0 with the NOTE" "rc=$rc"
git -C "$R/repo" show --name-only --format= HEAD | grep -qx "$AUDIT" \
  && ! git -C "$R/repo" show --name-only --format= HEAD | grep -q "issue.md" \
  && ok "...the audit file is committed, no frozen issue" || bad "...the audit file is committed, no frozen issue"
R="${WORK}/d"; fixture "$R" no
( cd "$R/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "NOT frozen into the branch - no GitHub remote in this checkout" "${WORK}/log" \
  && ok "no GitHub remote: exit 0 with the NOTE" || bad "no GitHub remote: exit 0 with the NOTE" "rc=$rc"

echo ""
echo "== land: the specification against the frozen copy =="
R="${WORK}/a"
drift() { ( cd "$R/repo" && just _workflow-issue-drift fix_7 ) > "${WORK}/log" 2>&1; }
issue_json "$BODY" 2; drift
grep -q "issue acme/widget#7: unchanged since this branch was cut" "${WORK}/log" \
  && ok "unchanged: said so" || bad "unchanged: said so"
issue_json "${BODY}A late edit.\n" 2; drift
grep -q "NOTE: issue acme/widget#7 changed after this branch was cut (body or a comment edited)" "${WORK}/log" \
  && grep -q "worked against $FROZEN" "${WORK}/log" \
  && ok "body edited: the NOTE, naming the frozen file" || bad "body edited: the NOTE"
# one comment fewer at the cut is the same as one more now
R2="${WORK}/e"; fixture "$R2" yes; issue_json "$BODY" 1
( cd "$R2/repo" && just new-branch 7 ) > "${WORK}/log" 2>&1
issue_json "$BODY" 2
( cd "$R2/repo" && just _workflow-issue-drift fix_7 ) > "${WORK}/log" 2>&1
grep -q "changed after this branch was cut (1 new comment(s))" "${WORK}/log" \
  && ok "a new comment: counted" || bad "a new comment: counted"
( cd "$R/repo" && GH_FAIL="gh: offline" just _workflow-issue-drift fix_7 ) > "${WORK}/log" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q "could not be re-checked" "${WORK}/log" && ! grep -q "unchanged" "${WORK}/log" \
  && ok "could not re-check: a note, not 'unchanged', not a refusal" || bad "could not re-check" "rc=$rc"
R="${WORK}/d"   # cut without a frozen issue
drift; rc=$?
[ "$rc" = 0 ] && [ ! -s "${WORK}/log" ] && ok "no frozen issue on the branch: silent" || bad "no frozen issue: silent"
grep -q '_workflow-issue-drift "${branch}"' "$WORKFLOW_JUST" \
  && [ "$(grep -n '_workflow-issue-drift "${branch}"' "$WORKFLOW_JUST" | cut -d: -f1)" -lt "$(grep -n '_workflow-merge-signed \\$' "$WORKFLOW_JUST" | head -1 | cut -d: -f1)" ] \
  && ok "land asks before it merges" || bad "land asks before it merges"

echo ""
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
