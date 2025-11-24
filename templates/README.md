# GitHub Templates for WAMP Repositories

This directory contains reusable GitHub Issue and Pull Request templates for all WAMP-related repositories.

## Contents

```
templates/
├── ISSUE_TEMPLATE/
│   ├── bug_report.md          # Bug report template
│   ├── feature_request.md     # Feature request template
│   └── config.yml             # Issue template configuration
├── PULL_REQUEST_TEMPLATE/
│   └── pull_request_template.md  # PR template
└── README.md                  # This file
```

## Usage

### For New Repositories

When setting up a new WAMP repository:

1. **Copy templates to `.github/` directory**:
   ```bash
   # From project root
   mkdir -p .github
   cp -r path/to/wamp-cicd/templates/ISSUE_TEMPLATE .github/
   cp -r path/to/wamp-cicd/templates/PULL_REQUEST_TEMPLATE .github/
   ```

2. **Customize if needed**:
   - Update URLs in `config.yml` to point to correct repo
   - Adjust checklists for project-specific requirements
   - Add project-specific sections if needed

3. **Commit templates**:
   ```bash
   git add .github/ISSUE_TEMPLATE .github/PULL_REQUEST_TEMPLATE
   git commit -m "Add GitHub Issue and PR templates from wamp-cicd"
   ```

### For Existing Repositories

1. **Review current templates**:
   ```bash
   ls -la .github/ISSUE_TEMPLATE/
   ls -la .github/PULL_REQUEST_TEMPLATE/
   ```

2. **Backup existing templates** (if any):
   ```bash
   mv .github/ISSUE_TEMPLATE .github/ISSUE_TEMPLATE.bak
   mv .github/PULL_REQUEST_TEMPLATE .github/PULL_REQUEST_TEMPLATE.bak
   ```

3. **Copy new templates and customize** (as above)

4. **Test templates**:
   - Create a new issue and verify templates appear
   - Create a new PR and verify template loads
   - Adjust URLs and project-specific content

### Updating Templates Across Repositories

When templates are updated in `wamp-cicd`:

1. **Review changes**:
   ```bash
   cd path/to/wamp-cicd
   git log -p templates/
   ```

2. **Copy updated templates to each repo**:
   ```bash
   # For each WAMP repository
   cd path/to/project
   cp -r path/to/wamp-cicd/templates/ISSUE_TEMPLATE .github/
   cp -r path/to/wamp-cicd/templates/PULL_REQUEST_TEMPLATE .github/
   ```

3. **Review and commit**:
   ```bash
   git diff .github/
   git add .github/
   git commit -m "Update GitHub templates from wamp-cicd"
   ```

## Template Features

### Bug Report Template

- Structured format for bug reports
- Environment information checklist
- Minimal reproducible example section
- Related issues and logs

### Feature Request Template

- Problem statement and proposed solution
- Use cases and examples
- Alternatives considered
- Impact assessment (breaking changes, affected components)
- Complexity estimation

### PR Template

- Comprehensive change description
- Type of change classification
- Testing checklist (Python versions, frameworks, OS)
- Code quality checklist
- Performance impact section
- Breaking changes and migration guide
- **AI Assistance Disclosure** section (per AI_POLICY.md)

### Issue Template Config

- Disables blank issues (enforces structured templates)
- Provides links to:
  - GitHub Discussions (for questions)
  - Documentation (for learning)
  - WAMP Community (for protocol info)

## Customization Guidelines

### Per-Repository Customization

While these templates are designed to be reusable, some repos may need customization:

1. **Update URLs**:
   - In `config.yml`, update discussion/docs URLs for the specific repo
   - In PR template, update any repo-specific links

2. **Adjust Test Checklists**:
   - Remove irrelevant OS/Python version combinations
   - Add framework-specific testing steps (e.g., Twisted-only repos)

3. **Add Project-Specific Sections**:
   - Add security checklist for security-sensitive repos
   - Add database migration section for repos with persistence
   - Add protocol compliance section for WAMP client/router repos

### Keep Templates in Sync

- Avoid diverging too much from base templates
- When making improvements, consider updating base templates in `wamp-cicd`
- Periodically sync with latest version from `wamp-cicd`

## GitHub Limitations

**Important**: GitHub does NOT follow symlinks or submodules for `.github/` content.

- ❌ Cannot symlink templates from `wamp-cicd` submodule
- ❌ GitHub ignores `.github/` content in submodules
- ✅ Must copy templates into each repository's `.github/` directory
- ✅ Can automate copying via scripts or workflows

## Maintenance

- Templates are maintained in `wamp-cicd` repository
- Updates should be made here and then copied to dependent repos
- Consider creating a script/workflow to automate template synchronization

## References

- [GitHub Issue Templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository)
- [GitHub PR Templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository)
- [AI_POLICY.md](https://github.com/wamp-proto/wamp-ai/blob/main/AI_POLICY.md)
