# Shared GitHub and community files for WAMP repositories

This directory is the single source for the files every using repository carries (#16): the
contribution guide, the pull request template, the AI-assistance disclosure README, a seed for the
repository's own development notes, and the issue templates.

## Contents

```
templates/
├── CONTRIBUTING.md            # -> CONTRIBUTING.md                   MANAGED  (byte-identical)
├── pull_request_template.md   # -> .github/pull_request_template.md  MANAGED  (byte-identical)
├── audit-README.md            # -> .audit/README.md                  MANAGED  (byte-identical)
├── DEVELOPMENT.md             # -> DEVELOPMENT.md                    SEEDED   (repository-owned)
├── ISSUE_TEMPLATE/            # -> .github/ISSUE_TEMPLATE/           copied, not yet drift-checked
│   ├── bug_report.md
│   ├── feature_request.md
│   └── config.yml
└── README.md                  # this file
```

The kinds, handled by [`../scripts/community-files.sh`](../scripts/community-files.sh):

| Kind | `deploy` | `check` |
|---|---|---|
| **MANAGED** | copies the template in | fails unless the copy is byte-identical |
| **SEEDED** | creates it only if missing, and never overwrites it | fails only if it is missing |
| **OBSOLETE** (`.github/PULL_REQUEST_TEMPLATE/`) | removes it | fails while it exists |

## One workflow, one text: CONTRIBUTING.md vs DEVELOPMENT.md

`CONTRIBUTING.md` states the workflow shared by all WAMP projects, and is **identical** everywhere:
GitHub issue first, red → green tests, and the AI-assistance disclosure. It is deliberately neutral:
it names no project, says "the default branch" (most repositories use `master`, a few use `main`), and
defers anything project-specific to `DEVELOPMENT.md`.

`DEVELOPMENT.md` belongs to the repository: development setup, running the tests, supported
platforms and runtimes, and additional agreements or license notes (for example Crossbar.io's
contributor assignment agreement, or the IETF text of the specification repository). wamp-cicd only
seeds it; the drift check requires that it exists, because the shared CONTRIBUTING.md links to it.

**Do not customize a MANAGED file in a using repository** - the drift check fails, by design. If the
shared text is wrong for a repository, either the text should be neutral enough to fit (change it
here), or the difference belongs in that repository's `DEVELOPMENT.md`.

The four places that state the audit-file format must agree: `CONTRIBUTING.md`,
`pull_request_template.md`, `audit-README.md` here, and the generator in wamp-ai
(`generate-audit-file`). Change them together.

## Usage

From a repository that has `wamp-cicd` as its `.cicd` submodule:

```bash
cd .cicd
just deploy-github-templates   # issue templates + community files; seeds DEVELOPMENT.md if missing
just check-community-files     # fails on any drift
```

In CI, run the repository's own pinned copy from the repository root (checkout with
`submodules: recursive`):

```yaml
      - name: Community files in sync with .cicd/templates/
        run: bash .cicd/scripts/community-files.sh check .
```

The check compares against the templates beside the script, i.e. at the wamp-cicd commit the
repository pins. A template changed here therefore never fails a repository that has not bumped its
pin - and the drift shows up exactly when it does, which is when `deploy` should be run.

## Why copies

GitHub does NOT follow symlinks into submodules, nor read `.github/` content from a submodule:

- ❌ a `CONTRIBUTING.md` symlinked into `.cicd/` breaks the "contributing guidelines" link on the pull
  request page and the repository's community profile;
- ❌ `.github/` content inside a submodule is ignored;
- ✅ so the files are copied, and the drift check keeps the copies true.

## GitHub template behavior

| Location | Behavior |
|---|---|
| `.github/pull_request_template.md` | **Auto-populated** when opening a new pull request |
| `.github/PULL_REQUEST_TEMPLATE/` directory | Multiple templates, manual URL selection only - obsolete here, removed by `deploy` |
| `.github/ISSUE_TEMPLATE/` directory | Template choices shown in the issue creation UI |
| `.github/ISSUE_TEMPLATE/config.yml` | Controls blank issues and adds external links |

## Known issue: the issue templates are not yet shared correctly

The issue templates are copied by `deploy-github-templates` but are not MANAGED, because they are
not yet neutral: `ISSUE_TEMPLATE/config.yml` points every repository's "Discussions" link at
autobahn-python's discussions, and `bug_report.md` asks for Python- and Twisted-specific versions.
Making them MANAGED needs a per-repository rendering step (the repository slug is in
[`../fleet.toml`](../fleet.toml)) and a language-neutral bug report. Tracked as a follow-up to #16.

## References

- [GitHub issue templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository)
- [GitHub pull request templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository)
- [AI_POLICY.md](https://github.com/wamp-proto/wamp-ai/blob/main/AI_POLICY.md)
