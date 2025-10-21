# Download Artifact with SHA256 Verification

Composite action that downloads GitHub Actions artifacts with automatic retry and cryptographic integrity verification.

## Features

- ✅ **Automatic retry** with configurable delays for GitHub storage eventual consistency
- ✅ **Meta-checksum verification** ensures checksum file integrity
- ✅ **Per-file verification** detects any corrupted or modified files
- ✅ **Filesystem sync** after download before verification
- ✅ **Detailed summary table** showing verification results
- ✅ **Fail-safe design** - only succeeds after complete verification

## Usage

```yaml
- name: Download verified wheels
  uses: wamp-proto/wamp-cicd/actions/download-artifact-verified@main
  with:
    name: wheels-macos-arm64
    path: dist/
    run-id: ${{ needs.build.outputs.run_id }}
    max-attempts: 3
    retry-delay: 60
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `name` | Artifact name to download | Yes | - |
| `path` | Destination path for files | No | `./` |
| `run-id` | Workflow run ID to download from | No | current run |
| `github-token` | GitHub token for download | No | `${{ github.token }}` |
| `max-attempts` | Maximum retry attempts | No | `3` |
| `retry-delay` | Delay between retries (seconds) | No | `60` |

## Outputs

| Output | Description |
|--------|-------------|
| `success` | `true` if verification succeeded |
| `file-count` | Number of files verified |
| `meta-checksum` | Meta-checksum of CHECKSUMS.sha256 |

## How It Works

### Two-Level Verification

**Level 1: Checksum File Integrity**
1. Download artifact (includes files + `CHECKSUMS.sha256` + `CHECKSUMS.sha256.meta`)
2. Sync filesystem
3. Verify `CHECKSUMS.sha256.meta` exists
4. Compute SHA256 of `CHECKSUMS.sha256`
5. Compare against `CHECKSUMS.sha256.meta`
6. If mismatch → retry with delay (checksum file corrupted)

**Level 2: Individual File Verification**
1. Read each entry from verified `CHECKSUMS.sha256`
2. Verify file exists
3. Compute file's SHA256
4. Compare against expected checksum
5. If mismatch → retry entire download (file corrupted)

### Retry Logic

The action retries on:
- Download failures
- Missing checksum files
- Meta-checksum mismatches
- Individual file checksum mismatches

Each retry:
1. Waits configurable delay (default: 60s)
2. Cleans destination directory
3. Re-downloads entire artifact
4. Re-verifies from scratch

## Example Output

```
======================================================================
==> Downloading Artifact with Verification (Chain of Custody)
======================================================================

Artifact: wheels-macos-arm64
Destination: dist/
Max attempts: 3
Retry delay: 60s

────────────────────────────────────────────────────────────────────
Attempt 1 of 3
────────────────────────────────────────────────────────────────────

Downloading artifact...
✅ Download completed

Syncing filesystem after download...
✅ Filesystem synced

Checking for verification files...
✅ Verification files present

Verifying checksum file integrity...
✅ Checksum file integrity verified
   Meta-checksum: abc123def456...

Verifying individual file checksums...

✅ autobahn-25.10.1-cp311-macosx_11_0_arm64.whl
✅ autobahn-25.10.1-cp312-macosx_11_0_arm64.whl

======================================================================
Verification Summary (Attempt 1/3)
======================================================================
Artifact:          wheels-macos-arm64
Meta-checksum:     abc123def456...
Files verified:    2
Files failed:      0

┌────────────────────────────────────────────────────────────────┐
│ ✅ SUCCESS - All files verified                                │
└────────────────────────────────────────────────────────────────┘

======================================================================
```

## Corruption Detection Example

```
────────────────────────────────────────────────────────────────────
Attempt 1 of 3
────────────────────────────────────────────────────────────────────

...

Verifying individual file checksums...

✅ autobahn-25.10.1-cp311-macosx_11_0_arm64.whl
❌ autobahn-25.10.1-pp311-pypy311_pp73-manylinux2014_aarch64.whl: CHECKSUM MISMATCH!
   Expected: 2f28a516c421f04734cebbc0f2d2e3c7c8a4395bfc122795373ffc2bf7a2ec5a
   Actual:   7dd3b8975f972b2bf6b98717bf5ce7d7fc2d4e44c46cca573874ddb5fa22b0e0

======================================================================
Verification Summary (Attempt 1/3)
======================================================================
Artifact:          wheels-arm64
Meta-checksum:     def789ghi012...
Files verified:    1
Files failed:      1

┌────────────────────────────────────────────────────────────────┐
│ ❌ FAILED - Checksum verification errors detected              │
└────────────────────────────────────────────────────────────────┘

Failed files:
  - ./autobahn-25.10.1-pp311-pypy311_pp73-manylinux2014_aarch64.whl (mismatch)

⏳ Retrying in 60s...
======================================================================
```

## Why Retry Logic is Needed

GitHub Actions artifact storage has a known issue where:

1. Workflow completes → status becomes "completed/success"
2. Artifacts still uploading in background (async writes)
3. Downloads may start before uploads finish
4. Files may be partially written or corrupted

The retry logic with delay gives GitHub's storage time to complete asynchronous writes.

## Security Guarantees

- **Corruption detection**: Any byte-level changes are detected
- **Completeness**: Missing files trigger failure
- **Tamper resistance**: Checksum file itself is verified via meta-checksum
- **No silent failures**: Only reports success after complete verification

## See Also

- [upload-artifact-verified](../upload-artifact-verified/README.md) - Companion action for verified uploads
