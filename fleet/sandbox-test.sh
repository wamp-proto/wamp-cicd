#!/usr/bin/env bash
# End-to-end sandbox test for rollout.sh - no network, no GitHub, no gitsign.
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
    M=alpha; B=bravo; EXCH=hub; FLEET_ID=acme; ROLLOUT=rollout-1; COHORT=core
else
    M=autobahn-python; B=txaio; EXCH=exchange; FLEET_ID=sbx; ROLLOUT=sbx; COHORT=way-a
fi
rm -rf "${SB}"; mkdir -p "${SB}"/{bin,up,fork,exch,work,src}
export GIT_CONFIG_GLOBAL="${SB}/gitconfig"
git config --global user.name "Sandbox Maintainer"
git config --global user.email "sandbox@example.invalid"
git config --global init.defaultBranch master
git config --global protocol.file.allow always
# Remotes look like GitHub, as in real clones (the tools derive owner/repo from remote URLs, and
# the inventory's slugs must be owner/repo); git rewrites them to the local bare repositories.
git config --global url."${SB}/up/".insteadOf "https://github.com/sandbox/"
git config --global url."${SB}/fork/".insteadOf "https://github.com/sandbox-fork/"
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
    git -C "${w}" remote add upstream "https://github.com/sandbox/${n}.git"
    git -C "${w}" remote add origin   "https://github.com/sandbox-fork/${n}.git"
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

# The inventory, schema 2: the rollout's cohort has M and B; a third repository is in ANOTHER
# cohort only (and not even cloned), so it must not be touched; a fourth is in no cohort.
mkdir -p "${SB}/config"; chmod 700 "${SB}/config"
DEFD="${SB}/def/${FLEET_ID}-fleet"; mkdir -p "${DEFD}"; git init -q "${DEFD}"
cat > "${DEFD}/fleet.toml" <<FLEETEOF
# GENERATED - do not edit; regenerate from the private inventory.
schema = 2
[[cohort]]
name = "${COHORT}"
description = "sandbox: the repositories this rollout applies to"
[[cohort]]
name = "other"
description = "sandbox: a cohort the rollout does not select"
[[repo]]
name = "${M}"
slug = "sandbox/${M}"
default_branch = "master"
cohorts = ["${COHORT}", "other"]
[[repo]]
name = "${B}"
slug = "sandbox/${B}"
default_branch = "main"
cohorts = ["${COHORT}"]
[[repo]]
name = "not-cloned"
slug = "sandbox/not-cloned"
default_branch = "master"
cohorts = ["other"]
[[repo]]
name = "takes-no-part"
slug = "sandbox/takes-no-part"
default_branch = "master"
cohorts = []
FLEETEOF
# The fleet's configuration, exactly as on a real host (fleet/lib/config.sh reads it): the
# inventory as a symlink beside an .env holding only what differs from the defaults.
# ... and its first rollout: a migration (apply.sh), with the issue text and an adoption check.
MIG="0001-shared-contributing"
RD="${DEFD}/rollouts/${COHORT}/${MIG}"; mkdir -p "${RD}"
printf 'name = "%s"\ncohort = "%s"\ndescription = "sandbox: deploy the shared CONTRIBUTING.md"\n' "${MIG}" "${COHORT}" > "${RD}/rollout.toml"
printf '#!/usr/bin/env bash\nset -e\necho "shared, for ${FLEET_REPO}" > CONTRIBUTING.md\n' > "${RD}/apply.sh"
printf '#!/usr/bin/env bash\ntest -f CONTRIBUTING.md\n' > "${RD}/check.sh"
chmod +x "${RD}/apply.sh" "${RD}/check.sh"
cp "${HERE}/../tests/fixtures/rollout-issue-template.md" "${RD}/issue.md"
git -C "${DEFD}" add -A; git -C "${DEFD}" commit -qm "the ${FLEET_ID} fleet: inventory and its first rollout"
# its canonical forge URL resolves locally too (the landing updates submodules)
DEFURL="https://github.com/sandbox/${FLEET_ID}-fleet.git"
git clone -q --bare "${DEFD}" "${SB}/up/${FLEET_ID}-fleet.git"
ln -s "${DEFD}/fleet.toml" "${SB}/config/${FLEET_ID}.toml"
cat > "${SB}/config/${FLEET_ID}.env" <<CFGEOF
FLEET_WORK_DIR=${SB}/work
FLEET_STATE=${SB}/state
EXCHANGE=${EXCH}
CICD_DIR=${C}
FILE_ISSUE=${SB}/bin/file-issue.sh
CFGEOF
chmod 600 "${SB}/config/${FLEET_ID}.env"
unset XDG_CONFIG_HOME XDG_STATE_HOME FLEET_NAME
export FLEET_CONFIG_DIR="${SB}/config"   # the only fleet there: selected without FLEET_NAME
R="${HERE}/rollout.sh"
ONLY=()   # the rollout's cohort selects the repositories
step() { echo; echo "################ $* ################"; }

step "next (before)";  "${HERE}/next.sh"
step init;             "${R}" init "${ROLLOUT}" --cohort "${COHORT}" --rollout "${MIG}" --cicd "${CICD}" --ai "${AI_NEW}"
step "prune (go)";     "${R}" prune "${ONLY[@]}" --go
step preflight;        "${R}" preflight "${ONLY[@]}" || echo "(preflight exit $? - expected: gitsign x509 not configured in sandbox)"
step "file-issues";    "${R}" file-issues "${ONLY[@]}" --go
step "rendered draft (${B})"; sed -n "1,22p" "${SB}/state/${ROLLOUT}/drafts/${B}.md"
step "cut (go)";       "${R}" cut "${ONLY[@]}" --go

step "apply (the AI host: fetch the cut branch from the exchange, apply the rollout, push)"
mkdir -p "${SB}/aihost"
for n in "${M}" "${B}"; do
    t="${SB}/aihost/${n}"; git clone -q "${SB}/exch/${n}.git" "${t}" -b fix_42
    git -C "${t}" config commit.gpgsign false
    "${HERE}/apply-rollout.sh" "${t}" "${DEFD}" "${COHORT}/${MIG}" --issue 42 --fleet-url "${DEFURL}" \
        --footer "Note: This work was completed with AI assistance (Claude Code)."
    git -C "${t}" push -q origin fix_42
done
step "apply again (a re-run of the wave: exit 10, nothing to do)"
rc=0; "${HERE}/apply-rollout.sh" "${SB}/aihost/${M}" "${DEFD}" "${COHORT}/${MIG}" --issue 42 --fleet-url "${DEFURL}" || rc=$?
REAPPLY_RC="${rc}"

step "sync (go)";      "${R}" sync  "${ONLY[@]}" --go
step "seal (go)";      "${R}" seal  "${ONLY[@]}" --go
step "publish (go)";   "${R}" publish "${ONLY[@]}" --go
step "open-prs (go)";  "${R}" open-prs "${ONLY[@]}" --go
step status;           "${R}" status "${ONLY[@]}"
step "land (dry)";     "${R}" land "${ONLY[@]}"
step "land (go)";      "${R}" land "${ONLY[@]}" --go

step "a second rollout is refused while this one is open"
if out="$("${R}" init next-one --cohort "${COHORT}" --issue-template "${HERE}/../tests/fixtures/rollout-issue-template.md" --cicd "${CICD}" --ai "${AI_NEW}" 2>&1)"; then
    echo "${out}"; SECOND_REFUSED=no
else
    echo "${out}" | tail -1; SECOND_REFUSED=yes
fi
step "finish (dry)";   "${R}" finish
step "finish (go)";    "${R}" finish --go
for n in "${M}" "${B}"; do git -C "${SB}/work/${n}" fetch -q upstream; done
step "next (after)";   "${HERE}/next.sh"; NEXT_AFTER="$("${HERE}/next.sh" | tail -1)"

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
    check "${n}: the rollout's commit landed" "git --git-dir='${SB}/up/${n}.git' log --format=%s '${br}' | grep -q 'Apply rollout ${COHORT}/${MIG} (#42)'"
    check "${n}: apply.sh's change is on ${br}" "git --git-dir='${SB}/up/${n}.git' show '${br}:CONTRIBUTING.md' | grep -qx 'shared, for ${n}'"
    check "${n}: the marker is on ${br}" "git --git-dir='${SB}/up/${n}.git' cat-file -e '${br}:.waves/${COHORT}/${MIG}.toml'"
    check "${n}: .fleet/ is pinned to the definition's commit" "[ \"\$(git --git-dir='${SB}/up/${n}.git' ls-tree '${br}' .fleet | awk '{print \$3}')\" = \"\$(git -C '${DEFD}' rev-parse HEAD)\" ]"
    for kind in up fork exch; do
        check "${n}: fix_42 deleted on ${kind}" "! git --git-dir='${SB}/${kind}/${n}.git' rev-parse -q --verify refs/heads/fix_42 >/dev/null"
    done
done
check "${M}: landed as a merge commit (2 parents)" \
    "[ \$(git --git-dir='${SB}/up/${M}.git' log -1 --format=%p master | wc -w) -eq 2 ]"
check "re-applying the rollout exits 10" "[ '${REAPPLY_RC}' = 10 ]"
check "after the wave nobody is behind" "grep -q '^0 repository/cohort pair(s) behind' <<<'${NEXT_AFTER}'"
check "${B}: landed by fast-forward onto the seal" \
    "git --git-dir='${SB}/up/${B}.git' log -1 --format=%s main | grep -q '^Seal #42'"
check "PR titled like its issue" "grep -q -- '--title .*(#42)' '${SB}/pr-create.log' && ! grep -q -- '--title Fleet rollout' '${SB}/pr-create.log'"
check "the rollout froze exactly its cohort's members" "[ \"\$(cut -f1 '${SB}/state/${ROLLOUT}/fleet.tsv' | tr '\n' ' ')\" = '${M} ${B} ' ]"
check "a second rollout was refused while this one was open" "[ '${SECOND_REFUSED}' = yes ]"
check "finish closed the rollout (no current rollout; its state kept)" "[ ! -e '${SB}/state/current' ] && [ -f '${SB}/state/${ROLLOUT}/landed.tsv' ]"
check "the issue names the cohort" "grep -q 'cohort \*\*${COHORT}\*\*' '${SB}/state/${ROLLOUT}/drafts/${B}.md' 2>/dev/null || grep -rq '${COHORT}' '${SB}/state/${ROLLOUT}/drafts/'"
check "exchange remote is '${EXCH}'" "git -C '${SB}/work/${M}' remote | grep -qx '${EXCH}'"
echo ""
[ "${nfail}" -eq 0 ] && echo "SANDBOX (${SANDBOX_FLAVOUR:-wamp}): all assertions passed" || { echo "SANDBOX (${SANDBOX_FLAVOUR:-wamp}): ${nfail} FAILED"; exit 1; }
