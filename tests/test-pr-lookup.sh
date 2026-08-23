#!/usr/bin/env bash
#
# Test how `land` finds the pull request (wamp-cicd #39).
#
# `just land fix_158` refused with "no pull request found" while
# typedefint/aaiare-metal-typedefint#163 was open and mergeable. Two defects,
# and the fork topology is what exposed both:
#
#   1. `gh pr view "${branch}"` was given no --repo, so gh resolved the
#      repository itself and picked `origin` - the maintainer's FORK - where
#      the pull request is not.
#   2. Adding --repo is NOT enough. gh's branch matching rules point in
#      opposite directions, measured against that one pull request:
#
#          gh pr view oberstet:fix_158 --repo R   -> #163   NEEDS owner:
#          gh pr list --head fix_158   --repo R   -> #163   bare ref
#          gh pr list --head oberstet:fix_158 ... -> []     REJECTS owner:
#
#      A bare name never matches a fork pull request in `pr view`, and the
#      prefix that fixes `pr view` breaks `pr list`.
#
# So the recipe derives the canonical repository itself and matches
# `headRefName` locally. These tests drive the REAL recipe against a stub `gh`
# that runs the REAL jq over canned API output - so the jq program is exercised,
# not just the shell around it - and a stub signer, so no network, no forge, no
# credentials and no hardware key are involved.
#
# Run: bash tests/test-pr-lookup.sh
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
export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"

PASS=0
FAIL=0
q() { "$@" >/dev/null 2>&1; }
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; sed 's/^/         /' "${WORK}/log" | tail -12; FAIL=$((FAIL + 1)); }

# --- the stubs ---------------------------------------------------------------
#
# `gh` answers from a per-repository JSON file, running the real jq with the
# program the recipe passed. Anything asked about a repository with no file is
# an empty list, which is exactly what the real gh returns for the fork.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Faithful enough that the PRE-FIX recipe fails against it for the REAL reason.
# `pr view <branch>` matches only a pull request whose head is in the queried
# repository's OWN namespace - that is gh's rule, and it is why a bare branch
# name never finds a fork pull request. `pr list` applies the --jq program.
sub="$1 $2"; repo=""; jqprog=""; branch=""; want_repo=0; want_jq=0; n=0
for a in "$@"; do
  n=$((n+1))
  if [ "$want_repo" = 1 ]; then repo="$a"; want_repo=0; continue; fi
  if [ "$want_jq" = 1 ];   then jqprog="$a"; want_jq=0; continue; fi
  case "$a" in
    --repo) want_repo=1 ;;
    --jq)   want_jq=1 ;;
    -*)     ;;
    *)      [ "$n" = 3 ] && branch="$a" ;;
  esac
done
printf '%s\n' "$*" >> "${GH_ARGV_LOG:-/dev/null}"
[ -n "${GH_FAIL:-}" ] && { echo "${GH_FAIL}" >&2; exit 1; }

# No --repo means gh resolves the repository itself, and under this topology it
# picks `origin`: the fork. That IS defect 1, reproduced rather than described.
[ -z "$repo" ] && repo="alice/widget"

file="${GH_FIXTURE_DIR}/$(printf '%s' "$repo" | tr '/' '_').json"
[ -f "$file" ] || file="${GH_FIXTURE_DIR}/empty.json"

case "$sub" in
  "pr view"*)
    owner="${repo%%/*}"
    hit="$(jq -c --arg b "$branch" --arg o "$owner" \
             '[.[] | select(.headRefName == $b and .headRepositoryOwner.login == $o)][0] // empty' \
             < "$file")"
    if [ -z "$hit" ]; then
      echo "no pull requests found for branch \"$branch\"" >&2
      exit 1
    fi
    printf '%s\n' "$hit"
    ;;
  *)
    jq -r "$jqprog" < "$file"
    ;;
esac
EOF
chmod +x "${WORK}/bin/gh"

# The signer, so the preflight's signing precondition passes. See
# tests/test-workflow-signing.sh - git invokes this exactly as it invokes gitsign.
cat > "${WORK}/bin/gitsign" <<'EOF'
#!/usr/bin/env bash
printf -- '-----BEGIN SIGNED MESSAGE-----\nc3R1Yg==\n-----END SIGNED MESSAGE-----\n'
echo "[GNUPG:] SIG_CREATED D 1 8 00 0 0" >&2
EOF
chmod +x "${WORK}/bin/gitsign"
export PATH="${WORK}/bin:${PATH}"
export GH_FIXTURE_DIR="${WORK}/fixtures"
mkdir -p "$GH_FIXTURE_DIR"
echo '[]' > "${GH_FIXTURE_DIR}/empty.json"

# THE FORK TOPOLOGY, which is the whole point: `origin` is the maintainer's
# fork and `upstream` is canonical, exactly as SCM-EXCHANGE-MODEL.md describes.
fixture() {
  local R="$1"
  mkdir -p "$R"
  q git init -b main "$R"
  ( cd "$R"
    cp "$WORKFLOW_JUST" workflow.just
    printf "import 'workflow.just'\n" > justfile
    echo seed > README.md
    q git add -A && q git commit -m seed
    q git config gpg.format x509
    q git config gpg.x509.program "${WORK}/bin/gitsign"
    q git config workflow.signingIdentity test@example.invalid
    # URLs that look like the forge. Nothing is ever fetched - the preflight
    # reads refs, and they are written directly below.
    q git remote add origin   https://github.com/alice/widget.git
    q git remote add upstream https://github.com/acme/widget.git
    local sha; sha="$(git rev-parse HEAD)"
    q git update-ref refs/remotes/origin/main   "$sha"
    q git update-ref refs/remotes/upstream/main "$sha"
    q git checkout -b fix_7
    echo work > work.txt
    q git add -A && q git commit -m work
    sha="$(git rev-parse HEAD)"
    # published, so the "reviewed copy" precondition is satisfied
    q git update-ref refs/remotes/origin/fix_7 "$sha" )
}

pr_row() {   # number owner [state] [mergeable] [review]
  cat <<EOF
{"number": $1, "state": "${3:-OPEN}", "mergeable": "${4:-MERGEABLE}",
 "reviewDecision": "${5:-}", "headRefName": "fix_7",
 "headRepositoryOwner": {"login": "$2"}}
EOF
}

preflight() {   # $1 = fixture dir
  ( cd "$1" && just _workflow-merge-preflight fix_7 ) > "${WORK}/log" 2>&1
}

echo "== which repository is asked (#39, defect 1) =="

R="${WORK}/a"; fixture "$R"
export GH_ARGV_LOG="${WORK}/argv"; : > "$GH_ARGV_LOG"
printf '[%s]' "$(pr_row 163 alice)" > "${GH_FIXTURE_DIR}/acme_widget.json"
# The FORK answers with nothing, as the real one did.
echo '[]' > "${GH_FIXTURE_DIR}/alice_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 0 ] && grep -q "acme/widget#163" "${WORK}/log"; then
  ok "the canonical repository is asked, not the fork"
else
  bad "the canonical repository is asked, not the fork" "rc=$rc"
fi
if grep -q -- "--repo acme/widget" "$GH_ARGV_LOG"; then
  ok "...and --repo is passed explicitly, never left to gh"
else
  bad "...and --repo is passed explicitly, never left to gh" "$(cat "$GH_ARGV_LOG")"
fi
if grep -q "upstream" <(cd "$R" && git remote) && ! grep -q -- "--repo alice/widget" "$GH_ARGV_LOG"; then
  ok "...upstream is preferred over origin"
else
  bad "...upstream is preferred over origin" "$(cat "$GH_ARGV_LOG")"
fi

echo ""
echo "== a fork pull request is found (#39, defect 2) =="

if grep -q "from alice" "${WORK}/log"; then
  ok "a head branch in ANOTHER owner's repository still matches"
else
  bad "a head branch in ANOTHER owner's repository still matches" "see log"
fi
if grep -q "OPEN, MERGEABLE" "${WORK}/log"; then
  ok "...and its state comes back in the same call"
else
  bad "...and its state comes back in the same call" "see log"
fi

# The same-repo shape, which works today and must not regress.
printf '[%s]' "$(pr_row 44 acme)" > "${GH_FIXTURE_DIR}/acme_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 0 ] && grep -q "acme/widget#44 from acme" "${WORK}/log"; then
  ok "a same-repository pull request still resolves"
else
  bad "a same-repository pull request still resolves" "rc=$rc"
fi

echo ""
echo "== the three answers stay distinct =="

echo '[]' > "${GH_FIXTURE_DIR}/acme_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 1 ] && grep -q "no open pull request in acme/widget" "${WORK}/log"; then
  ok "no pull request: refused, and it names the repository it asked"
else
  bad "no pull request: refused, and it names the repository it asked" "rc=$rc"
fi

GH_FAIL="gh: authentication required" preflight "$R"; rc=$?
if [ "$rc" = 1 ] && grep -q "could not ask" "${WORK}/log" \
   && grep -q "NOT 'there is no pull request'" "${WORK}/log"; then
  ok "could not ask: refused, and it says so IS NOT 'there is none'"
else
  bad "could not ask: refused, and it says so IS NOT 'there is none'" "rc=$rc"
fi

# ONLY VISIBLE NOW THAT THE MATCHING IS DONE HERE: two forks, one branch name.
printf '[%s,%s]' "$(pr_row 163 alice)" "$(pr_row 200 bob)" \
  > "${GH_FIXTURE_DIR}/acme_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 1 ] && grep -q "more than one open pull request" "${WORK}/log"; then
  ok "two pull requests from one branch name: refused, not guessed"
else
  bad "two pull requests from one branch name: refused, not guessed" "rc=$rc"
fi
if grep -q "#163  from alice" "${WORK}/log" && grep -q "#200  from bob" "${WORK}/log"; then
  ok "...and both are named"
else
  bad "...and both are named" "see log"
fi

echo ""
echo "== state is still enforced =="

printf '[%s]' "$(pr_row 163 alice CLOSED MERGEABLE)" > "${GH_FIXTURE_DIR}/acme_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 1 ] && grep -q "is CLOSED, not OPEN" "${WORK}/log"; then
  ok "a CLOSED pull request is refused"
else
  bad "a CLOSED pull request is refused" "rc=$rc"
fi

printf '[%s]' "$(pr_row 163 alice OPEN CONFLICTING)" > "${GH_FIXTURE_DIR}/acme_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 1 ] && grep -q "CONFLICTING" "${WORK}/log"; then
  ok "a CONFLICTING pull request is refused"
else
  bad "a CONFLICTING pull request is refused" "rc=$rc"
fi

printf '[%s]' "$(pr_row 163 alice OPEN MERGEABLE CHANGES_REQUESTED)" \
  > "${GH_FIXTURE_DIR}/acme_widget.json"
preflight "$R"; rc=$?
if [ "$rc" = 1 ] && grep -q "changes requested" "${WORK}/log"; then
  ok "changes requested is refused"
else
  bad "changes requested is refused" "rc=$rc"
fi

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
