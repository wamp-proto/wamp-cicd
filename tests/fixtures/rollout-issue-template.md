Repo:  @@SLUG@@
Title: [CI/CD] Fleet rollout @@ROLLOUT@@: pin wamp-cicd @@CICD7@@ + wamp-ai @@AI7@@, shared CONTRIBUTING.md + repo DEVELOPMENT.md, Way-A workflow
Type:  CI/CD

---

## Summary

This repository's part of a **batched fleet rollout** across cohort **@@COHORT@@** of the WAMP fleet:
@@FLEET_LIST@@. All repositories in the cohort get **the same** shared-tooling pins and the same
contribution workflow in one rollout, tracked by one issue per repository. The fleet membership is
defined in the fleet's inventory.

- **@@CICD_VERB@@ `.cicd` → wamp-proto/wamp-cicd @ `@@CICD@@`**
- **Pin `.ai` → wamp-proto/wamp-ai @ `@@AI@@`**

## Changes

1. **Shared contribution guide (wamp-proto/wamp-cicd#16).**
   - Deploy the canonical, byte-identical `CONTRIBUTING.md` from `.cicd/templates/`. It makes
     "**GitHub issue first**" explicit, and covers the red→green test-driven workflow and the
     AI-assistance disclosure.
   - Deploy the canonical PR template and `.audit/README.md` the same way.
   - Add a CI drift check that fails when any deployed copy differs from `.cicd/templates/`, or when
     `DEVELOPMENT.md` is missing.
   - Remove stale duplicate templates (e.g. `.github/PULL_REQUEST_TEMPLATE/`).
2. **Repository-owned `DEVELOPMENT.md`.** Move everything specific to this repository out of the old
   CONTRIBUTING.md into `DEVELOPMENT.md`: development setup, running the tests, supported
   platforms/runtimes, and any additional agreements or license notes. Legal text moves verbatim. If
   there is nothing project-specific yet, add a short stub pointing to CONTRIBUTING.md. Where the docs
   include CONTRIBUTING.md (`docs/contributing.rst`), include DEVELOPMENT.md the same way.
3. **Way-A developer workflow.** `WORKFLOW_MAIN := '@@MAIN@@'` plus `import '.cicd/workflow.just'`,
   so the repository gets `just where / what / new-branch / publish / land`. Check for recipe-name
   collisions before importing (autobahn-python had to rename `publish` → `publish-release`).
   @@WAYA_NOTE@@
4. A changelog entry referencing this issue, where the repository keeps a changelog.

No behaviour change in the software itself.

## Acceptance criteria

- [ ] `.cicd` and `.ai` are pinned to exactly the commits above, the same across the wave.
- [ ] `CONTRIBUTING.md`, the PR template and `.audit/README.md` are byte-identical to `.cicd/templates/`,
      and the drift check passes.
- [ ] `DEVELOPMENT.md` exists; any previous repo-specific CONTRIBUTING content is preserved there.
- [ ] `just where` works, and `just --evaluate WORKFLOW_MAIN` prints `@@MAIN@@`.
- [ ] CI green; landed as a maintainer-signed change.
