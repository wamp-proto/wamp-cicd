# Validate Audit File Action

A GitHub Action to validate AI-assisted work audit logs for format and completeness.

## Purpose

This action validates audit files created using the `AUDIT.md` template from `wamp-ai`. It ensures:
- Audit file has required structure
- All entries have required fields
- Human review status is tracked
- Compliance with `AI_POLICY.md` requirements

## Usage

### Basic Usage

```yaml
- name: Validate Audit File
  uses: ./.cicd/actions/validate-audit-file
```

### With Custom Path

```yaml
- name: Validate Audit File
  uses: ./.cicd/actions/validate-audit-file
  with:
    audit-file-path: '.audit/DEVELOPMENT.md'
```

### Require Human Review

```yaml
- name: Validate Audit File
  uses: ./.cicd/actions/validate-audit-file
  with:
    require-human-review: 'true'
    fail-on-pending: 'true'
```

### Complete Workflow Example

```yaml
name: Validate AI Work

on:
  pull_request:
    paths:
      - '.audit/**'
  push:
    paths:
      - '.audit/**'

jobs:
  validate-audit:
    name: Validate Audit Log
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Validate audit file
        uses: ./.cicd/actions/validate-audit-file
        with:
          audit-file-path: '.audit/WORK.md'
          require-human-review: 'false'
          fail-on-pending: 'false'

      - name: Comment on PR with results
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const entries = '${{ steps.validate.outputs.entries-count }}';
            const pending = '${{ steps.validate.outputs.pending-count }}';

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.name,
              body: `## Audit File Validation\\n\\n✅ Total entries: ${entries}\\n⏳ Pending review: ${pending}`
            });
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `audit-file-path` | Path to the audit file | No | `.audit/WORK.md` |
| `require-human-review` | Require all entries to have human review | No | `false` |
| `fail-on-pending` | Fail if any entries are pending review | No | `false` |

## Outputs

| Output | Description |
|--------|-------------|
| `valid` | Whether the audit file is valid (`true`/`false`) |
| `entries-count` | Number of audit entries found |
| `pending-count` | Number of entries pending human review |

## Validation Rules

### Required Sections

The action checks for these required sections:
- `# AI-Assisted Work Audit Log` (main heading)
- `## Purpose`
- `## Audit Entries`

### Required Entry Fields

Each audit entry must have:
- `**AI Assistant**:` field
- `**Scope of Work**:` field
- `**Files Modified**:` field
- `**Testing**:` field
- `**Human Review**:` field with status

### Review Status

Valid review statuses:
- `Pending` - Awaiting human review
- `Approved` - Reviewed and approved
- `Changes Requested` - Requires modifications

## Examples

### Example 1: CI/CD Validation

Use in CI/CD to ensure audit logs are properly maintained:

```yaml
- name: Validate audit file
  uses: ./.cicd/actions/validate-audit-file
  with:
    fail-on-pending: 'false'  # Don't block CI on pending reviews
```

### Example 2: Pre-Merge Check

Require human review before merging:

```yaml
- name: Validate audit file
  uses: ./.cicd/actions/validate-audit-file
  with:
    require-human-review: 'true'
    fail-on-pending: 'true'  # Block merge if reviews pending
```

### Example 3: Custom Audit Location

For projects with multiple audit files:

```yaml
- name: Validate development audit
  uses: ./.cicd/actions/validate-audit-file
  with:
    audit-file-path: '.audit/DEVELOPMENT.md'

- name: Validate security audit
  uses: ./.cicd/actions/validate-audit-file
  with:
    audit-file-path: '.audit/SECURITY.md'
```

## Exit Codes

- `0` - Validation passed (or no audit file present)
- `1` - Validation failed (errors found or pending reviews when `fail-on-pending=true`)

## Notes

### No Audit File

If the audit file doesn't exist, the action:
- Logs a warning message
- Exits successfully (code 0)
- Sets `valid=true`, `entries-count=0`, `pending-count=0`

This allows repos without AI-assisted work to pass validation.

### Error Handling

The action reports but doesn't fail on:
- Missing `## Purpose` section (warning only)
- Unknown review status (warning only)

The action fails on:
- Missing main heading
- Missing `## Audit Entries` section
- Missing required fields in entries
- Pending reviews (if `fail-on-pending=true`)

### Integration with wamp-ai

This action is designed to work with the audit template from `wamp-ai`:
- Template: `wamp-ai/templates/AUDIT.md`
- Policy: `wamp-ai/AI_POLICY.md`
- Guidelines: `wamp-ai/AI_GUIDELINES.md`

## Related Actions

- [check-release-fileset](../check-release-fileset/) - Validates PyPI release artifacts
- [upload-artifact-verified](../upload-artifact-verified/) - Uploads artifacts with verification
- [download-artifact-verified](../download-artifact-verified/) - Downloads artifacts with verification

## Maintenance

- Maintained in `wamp-cicd` repository
- Used via `.cicd` submodule in dependent repos
- Update by bumping submodule version
