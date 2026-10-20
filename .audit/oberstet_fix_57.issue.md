Issue:    wamp-proto/wamp-cicd#57
Title:    verify-pypi: shared PyPI provenance (PEP 740) verification script and just recipe for all WAMP Python packages
URL:      https://github.com/wamp-proto/wamp-cicd/issues/57
State:    OPEN at freeze
Author:   @oberstet
Updated:  2026-09-29T11:23:50Z
Comments: 0
Frozen:   2026-10-20T07:13:57Z by `just new-branch`
SHA-256:  60e852124ac876c409c00473b215fd307c00b95f80f733639f9ed95036478832 (of everything below the line)

---


## Problem

Five of the six WAMP Python packages already publish PEP 740 attestations to PyPI (Trusted
Publishing with `attestations: true`); autobahn follows for 26.9.1. Nothing in our tooling ever
*checks* them. Verification works today, by hand:

```
$ pypi-attestations verify pypi --repository https://github.com/crossbario/zlmdb \
      pypi:zlmdb-26.7.1-pp311-pypy311_pp73-manylinux_2_34_aarch64.whl
OK: zlmdb-26.7.1-pp311-pypy311_pp73-manylinux_2_34_aarch64.whl
$ pypi-attestations --version
pypi-attestations 0.0.30
```

but only one file at a time, and only for someone who knows the command. A release has 30+ files
(zlmdb, autobahn); a missing attestation on any one of them would currently go unnoticed.

## Proposed change

1. **`scripts/verify-pypi-provenance.sh <pypi-project> <version> <github-repository-url>`** in
   wamp-cicd:
   - lists every file of the release from the PyPI simple API (JSON, PEP 691:
     `Accept: application/vnd.pypi.simple.v1+json`; the HTML/JSON project pages may serve a
     JavaScript challenge to scripts, the simple API does not);
   - runs `pypi-attestations verify pypi --repository <url> pypi:<file>` for each file;
   - prints one line per file and a summary; exits non-zero if **any** file has no attestation or
     fails verification (loud, actionable: which file, what failed).
2. **A recipe pattern** for each repository's justfile:
   ```
   # Verify the PyPI provenance (PEP 740 attestations) of every file of a release
   verify-pypi version=<current version from pyproject.toml>:
       bash .cicd/scripts/verify-pypi-provenance.sh <project> {{version}} https://github.com/<slug>
   ```
   `pypi-attestations` is installed by each repository's `just install-tools`.
3. **Post-release CI step** (in the pattern of the hardening issue): run the script after the upload,
   in a job *without* `id-token` (after a short wait for PyPI to serve the new files); non-blocking
   at first, blocking once it has been proven on one release.
4. **Docs snippet** for each repository's `docs/installation.rst` ("Verifying a release"), showing
   the user-side check with `pypi-attestations` and explaining what it proves: the file was
   uploaded by the named repository's `release.yml` workflow in the `pypi` environment. It does
   not prove how the file was built (build provenance: `SLSA.md` item 1).
5. **Tests** in `tests/` for the script: a stubbed file listing (no network) covering all-OK, one
   file missing its attestation, and one verification failure.

## Network requirements

Verification needs `pypi.org`, `files.pythonhosted.org` and the Sigstore trust root
(`tuf-repo-cdn.sigstore.dev`). The Rekor inclusion proof is part of the attestation, so no query
to `rekor.sigstore.dev` is needed. Egress-restricted hosts must allowlist these.

## Acceptance

- [ ] `just verify-pypi 26.7.1` in zlmdb and crossbar reports OK for every file; for autobahn 26.7.1
      it reports every file as missing an attestation (the known gap) and exits non-zero.
- [ ] Rolled out with the per-repository 26.9.1 provenance issues (tracking table in the hardening
      issue).

Related: wamp-proto/wamp-cicd "Harden the PyPI publish jobs fleet-wide"; `SLSA.md`.

Note: This issue was drafted with AI assistance (Claude Code).

---

## Comments at freeze (0)

