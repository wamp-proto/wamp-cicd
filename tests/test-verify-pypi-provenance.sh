#!/usr/bin/env bash
#
# Test scripts/verify-pypi-provenance.sh (wamp-cicd #57): it lists every file of a release from
# the PyPI simple API, verifies the PEP 740 attestation of each with `pypi-attestations`, and
# exits non-zero if any file has no attestation or fails verification.
#
# The real script, against a stub `curl` that serves a crafted simple-API listing and a stub
# `pypi-attestations` whose verdict per file comes from the test. No network.
#
# Run: bash tests/test-verify-pypi-provenance.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../scripts/verify-pypi-provenance.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] ${2:-}"; sed 's/^/         /' "${WORK}/log" | tail -14; FAIL=$((FAIL + 1)); }

# curl: serves ${LISTING} for the simple-API URL of project "demo", and records the request.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CURL_LOG}"
case "$*" in
  *"https://pypi.org/simple/demo/"*) cat "${LISTING}" ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
STUB
# pypi-attestations: `verify pypi --repository URL pypi:FILE`; fails for every file in ${BAD_FILES}.
cat > "${WORK}/bin/pypi-attestations" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${VERIFY_LOG}"
file="${!#}"; file="${file#pypi:}"
for b in ${BAD_FILES:-}; do
  if [ "$b" = "$file" ]; then
    echo "Verification failed for ${file}: certificate's Build Config URI does not match" >&2
    exit 1
  fi
done
echo "OK: ${file}"
STUB
chmod +x "${WORK}/bin/curl" "${WORK}/bin/pypi-attestations"
export PATH="${WORK}/bin:${PATH}"
export CURL_LOG="${WORK}/curl.log" VERIFY_LOG="${WORK}/verify.log" LISTING="${WORK}/listing.json"

REPO=https://github.com/example/demo

# A simple-API (PEP 691) listing: 26.7.1 has a wheel and an sdist, 26.7.10 and 26.6.1 must not be
# picked up for 26.7.1. "provenance" is the PEP 740 provenance URL, or null when PyPI has none.
listing() {   # $1 = provenance of the 26.7.1 wheel (a URL or null)
  cat > "${LISTING}" <<EOF
{"meta": {"api-version": "1.1"}, "name": "demo", "files": [
  {"filename": "demo-26.6.1-py3-none-any.whl", "provenance": "https://pypi.org/integrity/demo/26.6.1/demo-26.6.1-py3-none-any.whl/provenance"},
  {"filename": "demo-26.7.1-py3-none-any.whl", "provenance": $1},
  {"filename": "demo-26.7.1.tar.gz", "provenance": "https://pypi.org/integrity/demo/26.7.1/demo-26.7.1.tar.gz/provenance"},
  {"filename": "demo-26.7.10-py3-none-any.whl", "provenance": "https://pypi.org/integrity/demo/26.7.10/demo-26.7.10-py3-none-any.whl/provenance"}
]}
EOF
}
run() {   # $@ = script arguments; exit code in RC
  : > "${CURL_LOG}"; : > "${VERIFY_LOG}"
  bash "$SCRIPT" "$@" > "${WORK}/log" 2>&1
  RC=$?
}
WHEEL_PROV='"https://pypi.org/integrity/demo/26.7.1/demo-26.7.1-py3-none-any.whl/provenance"'

echo "verify-pypi-provenance.sh:"

# [1] all files attested and verified: exit 0, one OK line per file of the version, and only those.
listing "$WHEEL_PROV"; BAD_FILES="" run demo 26.7.1 "$REPO"
if [ "$RC" = 0 ] \
   && grep -q "^OK .*demo-26.7.1-py3-none-any.whl" "${WORK}/log" \
   && grep -q "^OK .*demo-26.7.1.tar.gz" "${WORK}/log" \
   && ! grep -q "26.7.10\|26.6.1" "${VERIFY_LOG}" \
   && [ "$(wc -l < "${VERIFY_LOG}")" = 2 ]; then
  ok "all files OK -> exit 0, only the files of 26.7.1"
else
  bad "all files OK -> exit 0, only the files of 26.7.1" "rc=$RC"
fi

# [2] the simple API is asked for JSON (PEP 691), and verification names the repository.
if grep -q "application/vnd.pypi.simple.v1+json" "${CURL_LOG}" \
   && grep -q -- "--repository ${REPO} pypi:demo-26.7.1.tar.gz" "${VERIFY_LOG}"; then
  ok "simple API JSON requested, repository passed to pypi-attestations"
else
  bad "simple API JSON requested, repository passed to pypi-attestations"
fi

# [3] one file without an attestation on PyPI: exit 1, the file is named as missing, and the
#     other files are still verified.
listing null; BAD_FILES="" run demo 26.7.1 "$REPO"
if [ "$RC" = 1 ] \
   && grep -q "^MISSING .*demo-26.7.1-py3-none-any.whl" "${WORK}/log" \
   && grep -q "^OK .*demo-26.7.1.tar.gz" "${WORK}/log"; then
  ok "missing attestation -> exit 1, file named"
else
  bad "missing attestation -> exit 1, file named" "rc=$RC"
fi

# [4] one file fails verification: exit 1, the file is named with the verifier's reason.
listing "$WHEEL_PROV"; BAD_FILES="demo-26.7.1.tar.gz" run demo 26.7.1 "$REPO"
if [ "$RC" = 1 ] \
   && grep -q "^FAILED .*demo-26.7.1.tar.gz.*Build Config URI does not match" "${WORK}/log" \
   && grep -q "^OK .*demo-26.7.1-py3-none-any.whl" "${WORK}/log"; then
  ok "failed verification -> exit 1, file and reason named"
else
  bad "failed verification -> exit 1, file and reason named" "rc=$RC"
fi

# [5] a version with no files on PyPI: exit 1, nothing is "verified".
listing "$WHEEL_PROV"; BAD_FILES="" run demo 26.9.1 "$REPO"
if [ "$RC" = 1 ] && grep -q "no files" "${WORK}/log" && [ ! -s "${VERIFY_LOG}" ]; then
  ok "unknown version -> exit 1"
else
  bad "unknown version -> exit 1" "rc=$RC"
fi

# [6] the listing cannot be fetched: exit 2.
listing "$WHEEL_PROV"; BAD_FILES="" run nosuchproject 26.7.1 "$REPO"
if [ "$RC" = 2 ]; then ok "listing not fetchable -> exit 2"; else bad "listing not fetchable -> exit 2" "rc=$RC"; fi

# [7] wrong usage: exit 2 with a usage line.
run demo 26.7.1
if [ "$RC" = 2 ] && grep -qi "usage" "${WORK}/log"; then ok "usage -> exit 2"; else bad "usage -> exit 2" "rc=$RC"; fi

echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" = 0 ]
