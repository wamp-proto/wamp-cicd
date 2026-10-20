# SLSA Level 3 Implementation Plan

This document tracks the technical implementation of SLSA Level 3 provenance across the WAMP project CI/CD infrastructure.

---

## Current State

### Existing Infrastructure

| Component | Status | Location |
|-----------|--------|----------|
| `upload-artifact-verified` | ✅ Done | `actions/upload-artifact-verified/` |
| `download-artifact-verified` | ✅ Done | `actions/download-artifact-verified/` |
| `check-release-fileset` | ✅ Done | `actions/check-release-fileset/` |
| `validate-audit-file` | ✅ Done | `actions/validate-audit-file/` |
| SHA-256 chain-of-custody | ✅ Done | Via verified artifact actions |
| Meta-checksum in artifact name | ✅ Done | Self-verification capability |
| Retry on corruption | ✅ Done | Configurable attempts/delay |

### What's Missing for SLSA L3

| Component | Status | Priority |
|-----------|--------|----------|
| SLSA provenance generation | ❌ TODO | High |
| PyPI Trusted Publishing attestations | ❌ TODO | High |
| SBOM signing | ❌ TODO | Medium |
| Lockfile signing | ❌ TODO | Medium |
| VEX document generation | ❌ TODO | Medium |
| VERIFICATION.md template | ❌ TODO | Low |

---

## Implementation Tasks

### 1. SLSA Provenance Generation

**Goal:** Generate signed SLSA Level 3 provenance for wheel artifacts.

**Implementation:**

Add to release workflows in each project (crossbar, autobahn, etc.):

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      hashes: ${{ steps.hash.outputs.hashes }}
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install uv
        uses: astral-sh/setup-uv@v4

      - name: Build wheel
        run: uv build --wheel

      - name: Generate hashes for provenance
        id: hash
        run: |
          cd dist
          sha256sum *.whl | base64 -w0 > ../hashes.b64
          echo "hashes=$(cat ../hashes.b64)" >> $GITHUB_OUTPUT

      - uses: wamp-proto/wamp-cicd/actions/upload-artifact-verified@main
        with:
          name: dist
          path: dist/

  provenance:
    needs: build
    permissions:
      actions: read
      id-token: write
      contents: write
    uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.0.0
    with:
      base64-subjects: "${{ needs.build.outputs.hashes }}"
      upload-assets: true
      provenance-name: "${{ github.event.repository.name }}-provenance.intoto.jsonl"
```

**Files to modify:**

- [ ] `crossbar/.github/workflows/release.yml`
- [ ] `autobahn-python/.github/workflows/release.yml`
- [ ] `zlmdb/.github/workflows/release.yml`
- [ ] `cfxdb/.github/workflows/release.yml`
- [ ] `xbr/.github/workflows/release.yml`
- [ ] `txaio/.github/workflows/release.yml`

**Testing:**

1. Create test release on a feature branch
2. Verify provenance file is generated
3. Verify provenance can be validated with `slsa-verifier`

---

### 2. PyPI Trusted Publishing with Attestations

**Goal:** Enable PEP 740 attestations when publishing to PyPI.

**Implementation:**

Update publish job in release workflows:

```yaml
  publish:
    needs: [build, test, provenance]
    runs-on: ubuntu-latest
    permissions:
      id-token: write  # Required for Trusted Publishing
    environment:
      name: pypi
      url: https://pypi.org/project/${{ github.event.repository.name }}
    steps:
      - uses: wamp-proto/wamp-cicd/actions/download-artifact-verified@main
        with:
          name: dist
          path: dist/

      - name: Publish to PyPI
        uses: pypa/gh-action-pypi-publish@release/v1
        with:
          attestations: true  # Enable PEP 740 attestations
```

**Prerequisites:**

- [ ] Configure Trusted Publishing on PyPI for each project
  - Go to PyPI project → Settings → Publishing
  - Add GitHub Actions as trusted publisher
  - Specify workflow file path

**Projects to configure:**

- [ ] https://pypi.org/manage/project/crossbar/settings/publishing/
- [ ] https://pypi.org/manage/project/autobahn/settings/publishing/
- [ ] https://pypi.org/manage/project/zlmdb/settings/publishing/
- [ ] https://pypi.org/manage/project/cfxdb/settings/publishing/
- [ ] https://pypi.org/manage/project/xbr/settings/publishing/
- [ ] https://pypi.org/manage/project/txaio/settings/publishing/

**Verifying the attestations (#57):**

`scripts/verify-pypi-provenance.sh <pypi-project> <version> <github-repository-url>` checks every
file of a release: it lists the files from the PyPI simple API (JSON, PEP 691) and runs
`pypi-attestations verify pypi --repository <github-repository-url> pypi:<file>` for each one.
It prints one line per file (`OK`, `MISSING`: PyPI has no attestation, `FAILED`: with the
verifier's reason) and a summary, and exits with 0 only if every file verified (1 if a file is
missing or failed, or the version has no files; 2 for wrong usage, a missing tool or an
unreachable listing).

```
$ bash .cicd/scripts/verify-pypi-provenance.sh crossbar 26.7.1 https://github.com/crossbario/crossbar
OK      crossbar-26.7.1-py3-none-any.whl
OK      crossbar-26.7.1.tar.gz

crossbar 26.7.1: 2 files, 2 verified, 0 missing an attestation, 0 failed (repository https://github.com/crossbario/crossbar)
```

It needs `pypi-attestations` (installed by each repository's `just install-tools`), and network
access to `pypi.org`, `files.pythonhosted.org` and the Sigstore trust root
(`tuf-repo-cdn.sigstore.dev`). The Rekor inclusion proof is part of the attestation, so
`rekor.sigstore.dev` is not queried.

Recipe pattern for each repository's justfile (`<project>`, `<org>/<repo>` filled in):

```
# Verify the PyPI provenance (PEP 740 attestations) of every file of a release (default: the current version)
verify-pypi version="":
    #!/usr/bin/env bash
    set -e
    VERSION="{{ version }}"
    if [ -z "${VERSION}" ]; then
        VERSION=$(grep '^version' pyproject.toml | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    fi
    bash .cicd/scripts/verify-pypi-provenance.sh <project> "${VERSION}" https://github.com/<org>/<repo>
```

Docs snippet for each repository's `docs/installation.rst`:

```rst
Verifying a release
-------------------

Every file of a release on PyPI carries a `PEP 740 <https://peps.python.org/pep-0740/>`__
attestation. To check that a file was uploaded by this project's release workflow:

.. code-block:: console

    $ pip install pypi-attestations
    $ pypi-attestations verify pypi --repository https://github.com/<org>/<repo> \
          pypi:<project>-<version>-py3-none-any.whl
    OK: <project>-<version>-py3-none-any.whl

This proves that the file was uploaded to PyPI through Trusted Publishing by a GitHub Actions
workflow of ``github.com/<org>/<repo>``. It does not prove how the file was built.
```

---

### 3. SBOM Signing

**Goal:** Sign CycloneDX SBOMs with Sigstore for independent verification.

**Implementation:**

Create new composite action `actions/sign-sbom/action.yml`:

```yaml
name: 'Sign SBOM with Sigstore'
description: 'Generate and sign CycloneDX SBOM'

inputs:
  sbom-path:
    description: 'Path to SBOM file'
    required: true

outputs:
  bundle-path:
    description: 'Path to Sigstore bundle'
    value: ${{ steps.sign.outputs.bundle-path }}

runs:
  using: 'composite'
  steps:
    - name: Install cosign
      uses: sigstore/cosign-installer@v3

    - name: Sign SBOM
      id: sign
      shell: bash
      run: |
        BUNDLE_PATH="${{ inputs.sbom-path }}.bundle"
        cosign sign-blob "${{ inputs.sbom-path }}" \
          --bundle "$BUNDLE_PATH" \
          --yes
        echo "bundle-path=$BUNDLE_PATH" >> $GITHUB_OUTPUT
```

**Usage in workflows:**

```yaml
- name: Generate SBOM
  run: |
    syft dir:. -o cyclonedx-json > sbom.cdx.json

- uses: wamp-proto/wamp-cicd/actions/sign-sbom@main
  with:
    sbom-path: sbom.cdx.json
```

**Tasks:**

- [ ] Create `actions/sign-sbom/action.yml`
- [ ] Add SBOM generation + signing to release workflows
- [ ] Upload signed SBOM to GitHub Release assets

---

### 4. Lockfile Signing

**Goal:** Sign `uv.lock` files so customers can verify authenticity.

**Implementation:**

Add to release workflows:

```yaml
- name: Sign lockfile
  run: |
    cosign sign-blob uv.lock \
      --bundle uv.lock.bundle \
      --yes

- name: Upload signed lockfile
  uses: wamp-proto/wamp-cicd/actions/upload-artifact-verified@main
  with:
    name: lockfile
    path: |
      uv.lock
      uv.lock.bundle
      pyproject.toml
```

**Tasks:**

- [ ] Add lockfile signing to release workflows
- [ ] Include `uv.lock` + signature in GitHub Release assets
- [ ] Document verification in customer-facing docs

---

### 5. VEX Document Generation

**Goal:** Generate VEX (Vulnerability Exploitability eXchange) documents for each release.

**Implementation:**

Create new action `actions/generate-vex/action.yml`:

```yaml
name: 'Generate VEX Document'
description: 'Generate VEX document from Trivy scan'

inputs:
  image:
    description: 'Image or directory to scan'
    required: true
  output:
    description: 'Output VEX file path'
    required: false
    default: 'vex.json'

runs:
  using: 'composite'
  steps:
    - name: Install Trivy
      uses: aquasecurity/trivy-action@master
      with:
        scan-type: 'image'
        image-ref: ${{ inputs.image }}
        format: 'cosign-vuln'
        output: ${{ inputs.output }}
```

**Note:** VEX generation often requires manual curation to mark CVEs as "not affected" with justification. Consider:

1. Auto-generate baseline VEX from Trivy
2. Maintain manual overrides in repo (e.g., `vex-overrides.json`)
3. Merge during release

**Tasks:**

- [ ] Create `actions/generate-vex/action.yml`
- [ ] Define VEX curation process
- [ ] Add to release workflows

---

### 6. VERIFICATION.md Template

**Goal:** Provide customers with copy-paste verification commands.

**Implementation:**

Create template at `templates/VERIFICATION.md.template`:

```markdown
# Verification Guide for {{PROJECT}} v{{VERSION}}

## Prerequisites

\`\`\`bash
pip install sigstore slsa-verifier
\`\`\`

## Verify Wheel Attestation

\`\`\`bash
python -m sigstore verify identity {{PROJECT}}-{{VERSION}}-py3-none-any.whl \
  --cert-oidc-issuer https://token.actions.githubusercontent.com \
  --cert-identity https://github.com/crossbario/{{PROJECT}}/.github/workflows/release.yml@refs/tags/v{{VERSION}}
\`\`\`

## Verify SLSA Provenance

\`\`\`bash
slsa-verifier verify-artifact {{PROJECT}}-{{VERSION}}-py3-none-any.whl \
  --provenance-path {{PROJECT}}-provenance.intoto.jsonl \
  --source-uri github.com/crossbario/{{PROJECT}} \
  --source-tag v{{VERSION}}
\`\`\`

## Verify SBOM Signature

\`\`\`bash
cosign verify-blob {{PROJECT}}-sbom.cdx.json \
  --bundle {{PROJECT}}-sbom.cdx.json.bundle \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'https://github.com/crossbario/{{PROJECT}}/.*'
\`\`\`
```

**Tasks:**

- [ ] Create template
- [ ] Add generation step to release workflows
- [ ] Include in GitHub Release assets

---

## Workflow Architecture (Target State)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RELEASE WORKFLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌────────┐│
│  │  BUILD   │───▶│   TEST   │───▶│PROVENANCE│───▶│  PUBLISH │───▶│RELEASE ││
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘    └────────┘│
│       │               │               │               │              │      │
│       ▼               ▼               ▼               ▼              ▼      │
│  • Build wheel   • Verify       • Generate      • PyPI +       • GitHub    │
│  • Generate        artifacts      SLSA L3         attestation    Release   │
│    SBOM          • Run tests    • Sign          • Trusted      • Attach:  │
│  • Generate      • Upload         provenance      Publishing     - wheels │
│    hashes          results                                       - SBOM   │
│  • Upload                                                        - prov.  │
│    verified                                                      - VEX    │
│                                                                  - lock   │
│                                                                  - VERIFY │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Rollout Plan

### Phase 1: Foundation (Current)

- [x] Verified artifact upload/download
- [x] SHA-256 chain-of-custody
- [x] Self-verification via artifact names

### Phase 2: Provenance (Next)

- [ ] SLSA provenance generation
- [ ] PyPI Trusted Publishing attestations
- [ ] Update all project workflows

### Phase 3: Signing

- [ ] SBOM signing action
- [ ] Lockfile signing
- [ ] VEX document generation

### Phase 4: Documentation

- [ ] VERIFICATION.md template
- [ ] Customer documentation updates
- [ ] Audit evidence package definition

---

## Testing Checklist

Before merging to main:

- [ ] Test SLSA provenance generation on feature branch release
- [ ] Verify `slsa-verifier` can validate provenance
- [ ] Test PyPI attestations in TestPyPI first
- [ ] Verify `sigstore verify identity` works for published wheels
- [ ] Test SBOM signing and verification
- [ ] Verify lockfile signature verification
- [ ] End-to-end test of full release workflow

---

## References

- [SLSA Specification](https://slsa.dev/spec/v1.0/)
- [slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator)
- [PyPI Trusted Publishing](https://docs.pypi.org/trusted-publishers/)
- [PEP 740 - Attestations](https://peps.python.org/pep-0740/)
- [Sigstore cosign](https://docs.sigstore.dev/cosign/overview/)
- [OpenVEX Specification](https://github.com/openvex/spec)
