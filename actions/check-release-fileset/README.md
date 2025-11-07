# Check Release Fileset Action

Validate and clean distribution directories for PyPI uploads. Ensures only required wheels, source distributions, and platform-specific files are present before publishing.

## Features

- ✅ **Target-based validation** - Explicitly declare required wheel targets
- ✅ **Automatic cleanup** - Removes dev wheels (`linux_*`), extra wheels, and metadata files
- ✅ **Comprehensive reporting** - Detailed logs of what was found, matched, missing, and removed
- ✅ **Flexible modes** - Strict validation for production, check mode for debugging
- ✅ **Multiple Python implementations** - Supports CPython, PyPy, and free-threaded Python
- ✅ **Cross-platform** - Linux (manylinux), macOS, Windows
- ✅ **Pure Python support** - Universal wheels (`py3-none-any`)

## Quick Start

### Binary Wheels (C Extensions)

For packages like `zlmdb` with compiled C extensions:

```yaml
- name: Validate release fileset
  uses: wamp-proto/wamp-cicd/actions/check-release-fileset@main
  with:
    distdir: dist
    targets: |
      cpy311-linux-x86_64-manylinux_2_34
      cpy312-linux-x86_64-manylinux_2_34
      cpy313-linux-x86_64-manylinux_2_34
      cpy314-linux-x86_64-manylinux_2_34
      cpy311-linux-aarch64-manylinux_2_28
      cpy312-linux-aarch64-manylinux_2_28
      cpy313-linux-aarch64-manylinux_2_28
      cpy314-linux-aarch64-manylinux_2_28
      pypy311-linux-x86_64-manylinux_2_34
      pypy311-linux-aarch64-manylinux_2_36
      cpy311-macos-arm64
      cpy312-macos-arm64
      cpy311-win-amd64
      cpy312-win-amd64
      source
```

### Pure Python (Universal Wheel)

For packages like `cfxdb` with no C extensions:

```yaml
- name: Validate release fileset
  uses: wamp-proto/wamp-cicd/actions/check-release-fileset@main
  with:
    distdir: dist
    targets: |
      py3-none-any
      source
```

## Inputs

### `distdir`

**Required:** No
**Default:** `dist`

Directory containing distribution files to validate and clean.

### `targets`

**Required:** Yes

Newline or comma-separated list of required wheel targets and source distribution.

#### Target Format

`{impl}{version}-{platform}-{arch}[-{abi_tag}]`

**Components:**

- `impl`: Implementation
  - `cp` or `cpy`: CPython
  - `pp` or `pypy`: PyPy
- `version`: Python version (e.g., `311`, `312`, `313`, `314`, `314t` for free-threaded)
- `platform`: Operating system
  - `linux`: Linux (manylinux/musllinux)
  - `macos`: macOS
  - `win`: Windows
- `arch`: CPU architecture
  - `x86_64` or `amd64`: x86-64 / AMD64
  - `aarch64` or `arm64`: ARM64
- `abi_tag`: ABI compatibility tag (optional, typically for Linux)
  - `manylinux_2_28`: glibc 2.28+ (Debian 10+, Ubuntu 18.04+, RHEL 8+)
  - `manylinux_2_34`: glibc 2.34+ (Debian 11+, Ubuntu 21.10+, RHEL 9+)
  - `manylinux_2_36`: glibc 2.36+ (Debian 12+, Ubuntu 22.10+)

#### Special Keywords

- `source` or `sdist`: Require source distribution (`.tar.gz`)
- `py3-none-any`: Universal pure Python wheel (no C extensions)

#### Examples

```yaml
targets: |
  # CPython 3.11 on Linux x86_64 with glibc 2.34+
  cpy311-linux-x86_64-manylinux_2_34

  # PyPy 3.11 on Linux ARM64 with glibc 2.36+
  pypy311-linux-aarch64-manylinux_2_36

  # CPython 3.12 on macOS ARM64 (no ABI tag needed)
  cpy312-macos-arm64

  # CPython 3.11 on Windows x86_64 (no ABI tag needed)
  cpy311-win-amd64

  # Free-threaded Python 3.14 on Linux (PEP 703)
  cpy314t-linux-x86_64-manylinux_2_34

  # Universal pure Python wheel
  py3-none-any

  # Source distribution
  source
```

### `mode`

**Required:** No
**Default:** `strict`

Validation mode:

- `strict`: Fail build if required files are missing (production releases)
- `check`: Report issues but don't fail build (useful for debugging)

### `allow-dev-wheels`

**Required:** No
**Default:** `false`

Allow `linux_*` wheels (not `manylinux_*`) to pass validation.

**Important:** Should be `false` for PyPI uploads, as PyPI requires `manylinux_*` tags.
Set to `true` only for local development/testing builds.

### `allow-extra-wheels`

**Required:** No
**Default:** `false`

Allow extra wheels not specified in targets list.

- `false`: Extra wheels are removed (cleanup)
- `true`: Extra wheels trigger warnings but are kept

## Outputs

### `validation-passed`

**Type:** Boolean (`true` or `false`)

Whether validation passed completely.

### `wheels-found`

**Type:** Integer

Number of wheels found in distdir.

### `wheels-required`

**Type:** Integer

Number of wheels required by targets specification.

### `wheels-matched`

**Type:** Integer

Number of wheels that matched required targets.

### `wheels-missing`

**Type:** Integer

Number of required wheels missing.

### `wheels-extra`

**Type:** Integer

Number of extra wheels found (not in targets).

### `wheels-removed`

**Type:** Integer

Number of wheels removed during cleanup.

### `sdist-found`

**Type:** Boolean (`true` or `false`)

Whether source distribution was found.

### `sdist-required`

**Type:** Boolean (`true` or `false`)

Whether source distribution was required.

### `files-removed-count`

**Type:** Integer

Total number of files removed (wheels + metadata).

### `final-file-count`

**Type:** Integer

Number of files remaining after cleanup.

## Example Workflows

### Full Example: zlmdb Release

```yaml
jobs:
  release:
    name: Create GitHub Release and Publish to PyPI
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      # ... download artifacts to dist/ ...

      - name: Validate and clean release fileset
        id: check-fileset
        uses: wamp-proto/wamp-cicd/actions/check-release-fileset@main
        with:
          distdir: dist
          mode: strict
          targets: |
            cpy311-linux-x86_64-manylinux_2_34
            cpy312-linux-x86_64-manylinux_2_34
            cpy313-linux-x86_64-manylinux_2_34
            cpy314-linux-x86_64-manylinux_2_34
            cpy311-linux-aarch64-manylinux_2_28
            cpy312-linux-aarch64-manylinux_2_28
            cpy313-linux-aarch64-manylinux_2_28
            cpy314-linux-aarch64-manylinux_2_28
            pypy311-linux-x86_64-manylinux_2_34
            pypy311-linux-aarch64-manylinux_2_36
            cpy311-macos-arm64
            cpy312-macos-arm64
            cpy311-win-amd64
            cpy312-win-amd64
            source

      - name: Report validation results
        run: |
          echo "Validation passed: ${{ steps.check-fileset.outputs.validation-passed }}"
          echo "Wheels matched: ${{ steps.check-fileset.outputs.wheels-matched }}"
          echo "Wheels missing: ${{ steps.check-fileset.outputs.wheels-missing }}"
          echo "Wheels removed: ${{ steps.check-fileset.outputs.wheels-removed }}"
          echo "Final file count: ${{ steps.check-fileset.outputs.final-file-count }}"

      - name: Publish to PyPI
        uses: pypa/gh-action-pypi-publish@release/v1
        with:
          packages-dir: dist/
          # ... other PyPI config ...
```

### Debug Mode Example

```yaml
- name: Check release fileset (debug)
  uses: wamp-proto/wamp-cicd/actions/check-release-fileset@main
  with:
    distdir: dist
    mode: check  # Don't fail build
    allow-extra-wheels: true  # Keep extra wheels for inspection
    targets: |
      cpy311-linux-x86_64-manylinux_2_34
      source
```

## What Gets Removed

The action automatically removes:

1. **Dev wheels**: Wheels with `linux_*` tags (when `allow-dev-wheels: false`)
   - Example: `zlmdb-25.10.2-cp311-cp311-linux_x86_64.whl`
   - Reason: PyPI requires `manylinux_*` tags

2. **Extra wheels**: Wheels not matching any target (when `allow-extra-wheels: false`)
   - Example: Accidentally built wheels for Python 3.10 when only 3.11+ is supported

3. **Metadata files**: Files not for PyPI upload
   - `CHECKSUMS*.sha256`
   - `CHECKSUMS*.meta`
   - `VALIDATION.txt`
   - `*.sig`, `*.asc`

## What Gets Kept

After validation, only these remain:

- ✅ Wheels matching target specifications
- ✅ Source distribution (if required)
- ✅ manylinux/musllinux tagged wheels (not `linux_*`)
- ✅ macOS wheels
- ✅ Windows wheels

## Validation Rules

The action checks:

1. **All required wheels present**: Every target must have a matching wheel
2. **Source distribution present** (if `source` in targets)
3. **No dev wheels** (if `allow-dev-wheels: false`)
4. **No extra wheels** (if `allow-extra-wheels: false`)

## Common Patterns

### Minimal CPython-only

```yaml
targets: |
  cpy311-linux-x86_64-manylinux_2_34
  cpy311-macos-arm64
  cpy311-win-amd64
  source
```

### Full Multi-Version

```yaml
targets: |
  cpy311-linux-x86_64-manylinux_2_34
  cpy312-linux-x86_64-manylinux_2_34
  cpy313-linux-x86_64-manylinux_2_34
  cpy314-linux-x86_64-manylinux_2_34
  source
```

### CPython + PyPy

```yaml
targets: |
  cpy311-linux-x86_64-manylinux_2_34
  pypy311-linux-x86_64-manylinux_2_34
  source
```

### Pure Python Only

```yaml
targets: |
  py3-none-any
  source
```

## Troubleshooting

### "Missing required wheels"

**Problem:** Required wheels not found in distdir.

**Solutions:**
- Verify wheel build workflow completed successfully
- Check artifact download step downloaded to correct directory
- Verify wheel filename format matches PEP 427

### "Extra wheels (will be removed)"

**Problem:** Unexpected wheels in distdir.

**Solutions:**
- Add missing targets to the `targets` list
- Set `allow-extra-wheels: true` to keep them (not recommended for PyPI)
- Fix wheel build workflow to not build unwanted wheels

### "Dev wheel will be removed"

**Problem:** `linux_*` wheels present instead of `manylinux_*`.

**Solutions:**
- Ensure `auditwheel repair` runs during wheel build
- For PyPy on Debian: Install `auditwheel` (see zlmdb example)
- Never set `allow-dev-wheels: true` for PyPI uploads

## License

MIT License - See [LICENSE](../../LICENSE) for details.

## Contributing

Part of the [WAMP Protocol](https://wamp-proto.org/) CI/CD infrastructure.

For issues or contributions, see [wamp-cicd](https://github.com/wamp-proto/wamp-cicd).
