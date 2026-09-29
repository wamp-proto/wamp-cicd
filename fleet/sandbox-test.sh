#!/usr/bin/env bash
# End-to-end sandbox test for wamp-fleet-rollout.sh - no network, no GitHub, no gitsign.
#
# Two repos mirror the real situation (names per SANDBOX_FLAVOUR: wamp = autobahn-python/txaio,
# neutral = alpha/bravo with another exchange-remote and fleet name):
#   M : master's .ai hook ADMITS maintainer merges  -> lands as a signed merge commit
#   B : master's .ai hook is the OLD one             -> bootstrap: seal + fast-forward
# Each has local bare `upstream`, `origin` (fork) and exchange remotes, a `.ai`
# submodule carrying the REAL wamp-ai justfile (generate-audit-file), and signing via a
# throwaway ssh key standing in for gitsign. `gh` and `file-issue.sh` are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export SANDBOX_DIR="${SANDBOX_DIR:-/tmp/fleet-sandbox}"
SB="${SANDBOX_DIR}"   # throwaway test data; deliberately OUTSIDE the script directory
# The real wamp-ai justfile (its generate-audit-file recipe is what `cut` runs). In CI: a checkout
# of wamp-proto/wamp-ai; locally: the sibling clone.
AI_JUSTFILE="${AI_JUSTFILE:-${HERE}/../../wamp-ai/justfile}"
[ -f "${AI_JUSTFILE}" ] || { echo "FATAL: no wamp-ai justfile at ${AI_JUSTFILE} (set AI_JUSTFILE)" >&2; exit 2; }

# Names. The default is the WAMP shape the tooling was proven on; SANDBOX_FLAVOUR=neutral uses
# other repository names, another exchange-remote name and another fleet name, to prove the
# tools assume nothing WAMP-specific (#58). M = merge-admitting repo, B = bootstrap repo.
if [ "${SANDBOX_FLAVOUR:-wamp}" = neutral ]; then
    M=alpha; B=bravo; EXCH=hub; FLEET_ID=acme; ROLLOUT=rollout-1
else
    M=autobahn-python; B=txaio; EXCH=exchange; FLEET_ID=sbx; ROLLOUT=sbx
fi
rm -rf "${SB}"; mkdir -p "${SB}"/{bin,up,fork,exch,work,src}
export GIT_CONFIG_GLOBAL="${SB}/gitconfig"
git config --global user.name "Sandbox Maintainer"
git config --global user.email "sandbox@example.invalid"
git config --global init.defaultBranch master
git config --global protocol.file.allow always
ssh-keygen -q -t ed25519 -N '' -f "${SB}/signkey"

# -- wamp-ai source: v1 = old hook (no merge admission), v2 = new hook ------------------------
A="${SB}/src/wamp-ai"; git init -q "${A}"; mkdir -p "${A}/.githooks"
cp "${AI_JUSTFILE}" "${A}/justfile"
printf '#!/bin/sh\n# old hook: refuses commits on master\nexit 0\n' > "${A}/.githooks/commit-msg"
chmod +x "${A}/.githooks/commit-msg"
git -C "${A}" add -A; git -C "${A}" commit -qm "ai v1"; AI_OLD="$(git -C "${A}" rev-parse HEAD)"
printf '#!/bin/sh\n# new hook: admits a maintainer-signed merge on master (MERGE_HEAD)\nexit 0\n' > "${A}/.githooks/commit-msg"
git -C "${A}" commit -qam "ai v2"; AI_NEW="$(git -C "${A}" rev-parse HEAD)"

# -- wamp-cicd source: real workflow.just + the canonical CONTRIBUTING.md --------------------
C="${SB}/src/wamp-cicd"; git init -q "${C}"; mkdir -p "${C}/templates"
cp "${HERE}/../workflow.just" "${C}/"
cp "${HERE}/../templates/CONTRIBUTING.md" "${C}/templates/"
git -C "${C}" add -A; git -C "${C}" commit -qm "cicd with templates"; CICD="$(git -C "${C}" rev-parse HEAD)"
git clone -q --bare "${C}" "${SB}/src/wamp-cicd-origin.git"
git -C "${C}" remote add origin "${SB}/src/wamp-cicd-origin.git"

mkrepo() {  # mkrepo <name> <ai-commit> <default-branch>
    local n="$1" ai="$2" br="$3" w="${SB}/work/$1"
    git init -q -b "${br}" "${w}"
    echo "# ${n}" > "${w}/README.md"
    mkdir -p "${w}/.audit"; echo "audit files" > "${w}/.audit/README.md"   # all 6 real repos track .audit/
    git -C "${w}" submodule add -q "${A}" .ai
    git -C "${w}/.ai" checkout -q "${ai}"
    git -C "${w}" add -A; git -C "${w}" commit -qm "initial"
    for kind in up fork exch; do git clone -q --bare "${w}" "${SB}/${kind}/${n}.git"; done
    git -C "${w}" remote add upstream "${SB}/up/${n}.git"
    git -C "${w}" remote add origin   "${SB}/fork/${n}.git"
    git -C "${w}" remote add "${EXCH}" "${SB}/exch/${n}.git"
    for r in upstream origin "${EXCH}"; do git -C "${w}" fetch -q "${r}"; done
    git -C "${w}" config core.hooksPath .ai/.githooks
    git -C "${w}" config gpg.format ssh
    git -C "${w}" config user.signingkey "${SB}/signkey.pub"
    git -C "${w}" config commit.gpgsign true
    git -C "${w}" branch -q stale_merged           # contained in upstream/master -> prune deletes
}
mkrepo "${M}" "${AI_NEW}" master
mkrepo "${B}" "${AI_OLD}" main          # exercises a per-repo default branch

# -- stubs -----------------------------------------------------------------------------------
cat > "${SB}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# stub gh: just enough for the rollout script
repo_of() { for a in "$@"; do case "$prev" in --repo) basename "$a" ;; esac; prev="$a"; done; }
case "$1 $2" in
  "auth status") exit 0 ;;
  "api "*)       exit 1 ;;
  "pr list")     exit 0 ;;
  "pr create")   echo "$*" >> "${SANDBOX_DIR}/pr-create.log"; echo "https://github.com/x/y/pull/77" ;;
  "pr view")     r="$(repo_of "$@")"; git --git-dir="${SANDBOX_DIR}/fork/${r}.git" \
                   for-each-ref --format='%(objectname)' 'refs/heads/fix_*' | head -1 ;;
  "pr checks")   exit 0 ;;
  *) echo "stub gh: unhandled: $*" >&2; exit 2 ;;
esac
EOF
cat > "${SB}/bin/file-issue.sh" <<'EOF'
#!/usr/bin/env bash
repo="$(grep -m1 '^Repo:' "$1" | cut -d: -f2- | xargs)"
echo "--> ${repo}: filed"; echo "https://github.com/${repo}/issues/42"
EOF
chmod +x "${SB}/bin/gh" "${SB}/bin/file-issue.sh"
export PATH="${SB}/bin:${PATH}"

cat > "${SB}/fleet.toml" <<FLEETEOF
schema = 1
[[repo]]
name = "${M}"
slug = "${SB}/up/${M}"
default_branch = "master"
kind = "python"
wave = 1
notes = "sandbox: hook admits merges"
[[repo]]
name = "${B}"
slug = "${SB}/up/${B}"
default_branch = "main"
kind = "python"
wave = 1
notes = "sandbox: bootstrap, default branch main"
[[repo]]
name = "not-cloned"
slug = "nowhere/not-cloned"
default_branch = "master"
kind = "cpp"
wave = 2
notes = "sandbox: must be ignored by a wave-1 rollout"
FLEETEOF
# The fleet's configuration, exactly as a user writes it (fleet/lib/config.sh reads it).
mkdir -p "${SB}/config"
cat > "${SB}/config/${FLEET_ID}.env" <<CFGEOF
FLEET_INVENTORY=${SB}/fleet.toml
FLEET_WORK_DIR=${SB}/work
FLEET_STATE=${SB}/state
EXCHANGE=${EXCH}
CICD_DIR=${C}
ISSUE_TEMPLATE=${HERE}/examples/issue-template-wamp-wave1.md
FILE_ISSUE=${SB}/bin/file-issue.sh
CFGEOF
chmod 600 "${SB}/config/${FLEET_ID}.env"
export FLEET_CONFIG_DIR="${SB}/config"   # the only *.env there: selected without FLEET_NAME
R="${HERE}/wamp-fleet-rollout.sh"
ONLY=()   # the fleet file now selects the repos (wave 1)
step() { echo; echo "################ $* ################"; }

step init;             "${R}" init "${ROLLOUT}" --wave 1 --cicd "${CICD}" --ai "${AI_NEW}"
step "prune (go)";     "${R}" prune "${ONLY[@]}" --go
step preflight;        "${R}" preflight "${ONLY[@]}" || echo "(preflight exit $? - expected: gitsign x509 not configured in sandbox)"
step "file-issues";    "${R}" file-issues "${ONLY[@]}" --go
step "rendered draft (${B})"; sed -n "1,22p" "${SB}/state/${ROLLOUT}/drafts/${B}.md"
step "cut (go)";       "${R}" cut "${ONLY[@]}" --go

step "AI work on the exchange (simulated AI-host commits)"
for n in "${M}" "${B}"; do
    t="${SB}/aiwork-${n}"; git clone -q "${SB}/exch/${n}.git" "${t}" -b fix_42
    git -C "${t}" config commit.gpgsign false
    echo "shared" > "${t}/CONTRIBUTING.md"; git -C "${t}" add -A
    git -C "${t}" commit -qm "Deploy shared CONTRIBUTING.md (#42)"; git -C "${t}" push -q origin fix_42
done

step "sync (go)";      "${R}" sync  "${ONLY[@]}" --go
step "seal (go)";      "${R}" seal  "${ONLY[@]}" --go
step "publish (go)";   "${R}" publish "${ONLY[@]}" --go
step "open-prs (go)";  "${R}" open-prs "${ONLY[@]}" --go
step status;           "${R}" status "${ONLY[@]}"
step "land (dry)";     "${R}" land "${ONLY[@]}"
step "land (go)";      "${R}" land "${ONLY[@]}" --go

step "VERIFY upstream master"
for n in "${M}" "${B}"; do
    echo "== ${n}"
    br="$(git --git-dir="${SB}/up/${n}.git" symbolic-ref --short HEAD)"; echo "   default branch: ${br}"
    git --git-dir="${SB}/up/${n}.git" log --format='   %h parents=%p  %s' -4 "${br}"
    git --git-dir="${SB}/up/${n}.git" cat-file commit "${br}" | grep -q '^gpgsig' && echo "   tip SIGNED" || echo "   tip UNSIGNED"
    for kind in up fork exch; do
        printf '   fix_42 on %-5s: %s\n' "${kind}" \
            "$(git --git-dir="${SB}/${kind}/${n}.git" rev-parse -q --verify refs/heads/fix_42 >/dev/null && echo PRESENT || echo deleted)"
    done
    printf '   local branches: %s\n' "$(git -C "${SB}/work/${n}" branch --format='%(refname:short)' | tr '\n' ' ')"
done

# -- assertions: the run above only printed; these decide pass/fail -------------------------
step "ASSERT"
nfail=0
check() { if eval "$2"; then echo "   ok   $1"; else echo "   FAIL $1"; nfail=$((nfail+1)); fi; }
for n in "${M}" "${B}"; do
    br="$(git --git-dir="${SB}/up/${n}.git" symbolic-ref --short HEAD)"
    check "${n}: upstream ${br} tip is signed" "git --git-dir='${SB}/up/${n}.git' cat-file commit '${br}' | grep -q '^gpgsig'"
    check "${n}: AI commit landed" "git --git-dir='${SB}/up/${n}.git' log --format=%s '${br}' | grep -q 'Deploy shared CONTRIBUTING.md'"
    for kind in up fork exch; do
        check "${n}: fix_42 deleted on ${kind}" "! git --git-dir='${SB}/${kind}/${n}.git' rev-parse -q --verify refs/heads/fix_42 >/dev/null"
    done
done
check "${M}: landed as a merge commit (2 parents)" \
    "[ \$(git --git-dir='${SB}/up/${M}.git' log -1 --format=%p master | wc -w) -eq 2 ]"
check "${B}: landed by fast-forward onto the seal" \
    "git --git-dir='${SB}/up/${B}.git' log -1 --format=%s main | grep -q '^Seal #42'"
check "PR titled like its issue" "grep -q -- '--title .*(#42)' '${SB}/pr-create.log' && ! grep -q -- '--title Fleet rollout' '${SB}/pr-create.log'"
check "exchange remote is '${EXCH}'" "git -C '${SB}/work/${M}' remote | grep -qx '${EXCH}'"
echo ""
[ "${nfail}" -eq 0 ] && echo "SANDBOX (${SANDBOX_FLAVOUR:-wamp}): all assertions passed" || { echo "SANDBOX (${SANDBOX_FLAVOUR:-wamp}): ${nfail} FAILED"; exit 1; }
