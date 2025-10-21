# Upload Artifact with SHA256 Verification

Composite action that uploads GitHub Actions artifacts with cryptographic chain-of-custody verification.

## Features

- ✅ **Recursive SHA256 checksumming** of all files in directory
- ✅ **Meta-checksum generation** for checksum file integrity verification
- ✅ **Filesystem sync** before and after checksum generation
- ✅ **Detailed output** with file counts and checksums
- ✅ **Self-contained verification** - checksum files travel with artifacts

## Usage

```yaml
- name: Upload verified wheels
  uses: wamp-proto/wamp-cicd/actions/upload-artifact-verified@main
  with:
    name: wheels-macos-arm64
    path: dist/
    retention-days: 90
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `name` | Artifact name | Yes | - |
| `path` | Path to directory containing files | Yes | - |
| `retention-days` | Number of days to retain artifact | No | `90` |
| `if-no-files-found` | Behavior if no files found (`error`, `warn`, `ignore`) | No | `error` |

## Outputs

| Output | Description |
|--------|-------------|
| `artifact-id` | GitHub artifact ID |
| `artifact-url` | GitHub artifact URL |
| `meta-checksum` | SHA256 of CHECKSUMS.sha256 file |
| `file-count` | Number of files checksummed |

## How It Works

1. **Filesystem sync** - Ensures all files are written to disk
2. **Recursive file discovery** - Finds all files in directory (excluding checksum files)
3. **SHA256 generation** - Creates `CHECKSUMS.sha256` with all file hashes
4. **Meta-checksum** - Creates `CHECKSUMS.sha256.meta` containing SHA256 of checksum file
5. **Filesystem sync** - Ensures checksum files are written to disk
6. **Upload** - Uploads all files including verification metadata

## Files Created

The action creates two additional files in your directory:

- `CHECKSUMS.sha256` - OpenSSL format checksums for all files
- `CHECKSUMS.sha256.meta` - Single line containing SHA256 of the checksum file

## Example Output

```
======================================================================
==> Generating SHA256 Checksums (Chain of Custody)
======================================================================

Artifact: wheels-macos-arm64
Path: dist/

Syncing filesystem before checksum generation...
✅ Filesystem synced

Discovering files...
Found 2 files to checksum

Computing SHA256 checksums...
✅ Generated CHECKSUMS.sha256 (2 entries)

Computing meta-checksum...
✅ Generated CHECKSUMS.sha256.meta
   Meta-checksum: abc123def456...

Syncing filesystem after checksum generation...
✅ Filesystem synced

======================================================================
Checksum Generation Summary
======================================================================
Files checksummed:    2
Checksum file:        CHECKSUMS.sha256
Meta-checksum file:   CHECKSUMS.sha256.meta
Meta-checksum value:  abc123def456...
======================================================================
```

## Security Guarantees

- **Integrity**: SHA256 ensures any file modification is detected
- **Completeness**: Meta-checksum ensures checksum file itself isn't corrupted
- **Tamper detection**: Any modification to files or checksums is detected on download

## See Also

- [download-artifact-verified](../download-artifact-verified/README.md) - Companion action for verified downloads
