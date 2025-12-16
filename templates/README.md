# GitHub Templates for WAMP Repositories

This directory contains reusable GitHub Issue and Pull Request templates for all WAMP-related repositories.

## Contents

```
templates/
├── ISSUE_TEMPLATE/
│   ├── bug_report.md          # Bug report template
│   ├── feature_request.md     # Feature request template
│   └── config.yml             # Issue template configuration
├── pull_request_template.md   # PR template (auto-populated)
└── README.md                  # This file
```

## GitHub Template Behavior

**Important**: GitHub has specific rules for how templates are loaded:

### Pull Request Templates

| Location | Behavior |
|----------|----------|
| `.github/pull_request_template.md` | **Auto-populated** when opening a new PR |
| `.github/PULL_REQUEST_TEMPLATE/` directory | Multiple templates, requires manual URL selection |

**Recommendation**: Use `.github/pull_request_template.md` for a single default template that auto-populates. The `PULL_REQUEST_TEMPLATE/` directory approach is only useful when you need multiple different PR templates that users select manually.

### Issue Templates

| Location | Behavior |
|----------|----------|
| `.github/ISSUE_TEMPLATE/` directory | Multiple templates shown in issue creation UI |
| `.github/ISSUE_TEMPLATE/config.yml` | Controls blank issues and adds external links |

Issue templates work differently - the directory approach with multiple `.md` files is the standard way to offer template choices.

## Usage

### Quick Deploy (Recommended)

From a repository that has `wamp-cicd` as a `.cicd` submodule:

```bash
cd .cicd
just deploy-github-templates
```

This copies all templates to the correct locations in `.github/`.

### Manual Setup

1. **Copy templates to `.github/` directory**:
   ```bash
   # From project root
   mkdir -p .github/ISSUE_TEMPLATE

   # Copy issue templates
   cp path/to/wamp-cicd/templates/ISSUE_TEMPLATE/* .github/ISSUE_TEMPLATE/

   # Copy PR template (must be at .github/ root, NOT in subdirectory!)
   cp path/to/wamp-cicd/templates/pull_request_template.md .github/
   ```

2. **Customize if needed**:
   - Update URLs in `config.yml` to point to correct repo
   - Adjust checklists for project-specific requirements

3. **Commit templates**:
   ```bash
   git add .github/
   git commit -m "Add GitHub Issue and PR templates from wamp-cicd"
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
- ✅ Can automate copying via `just deploy-github-templates`

## Maintenance

- Templates are maintained in `wamp-cicd` repository
- Updates should be made here and then deployed to dependent repos
- Use `just deploy-github-templates` to sync templates

## References

- [GitHub Issue Templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository)
- [GitHub PR Templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository)
- [AI_POLICY.md](https://github.com/wamp-proto/wamp-ai/blob/main/AI_POLICY.md)
