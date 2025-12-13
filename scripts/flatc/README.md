# Shared FlatBuffers/flatc Support

This directory contains shared code for FlatBuffers bundling across
WAMP ecosystem projects (zlmdb, autobahn-python, etc.).

## Files

- `_flatc.py` - Module providing `get_flatc_path()` and `run_flatc()` functions
- `smoke_test_flatc.py` - Reusable smoke test functions for flatc verification

## Usage

### Setting up _flatc in your project

1. Copy `_flatc.py` to `src/<package>/_flatc/__init__.py`
2. Create `src/<package>/_flatc/bin/` directory for the flatc binary
3. Configure your build system to compile and include flatc

### Using smoke tests

1. Copy `smoke_test_flatc.py` to your project's `scripts/` directory
2. Import the test functions in your `smoke_test.py`:

```python
from smoke_test_flatc import (
    test_import_flatbuffers,
    test_flatc_binary,
    test_reflection_files,
)

# Add to your test list with package name:
tests = [
    ...,
    lambda: test_import_flatbuffers("zlmdb"),
    lambda: test_flatc_binary("zlmdb"),
    lambda: test_reflection_files("zlmdb"),
]
```

## Projects using this

- [zlmdb](https://github.com/crossbario/zlmdb)
- [autobahn-python](https://github.com/crossbario/autobahn-python)
