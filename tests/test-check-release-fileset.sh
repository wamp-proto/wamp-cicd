#!/usr/bin/env bash
#
# Test for actions/check-release-fileset ABI-tag matching (wamp-cicd #11).
#
# Extracts the composite action's `run:` script from action.yml and drives it
# against crafted dist/ filesets, asserting that a free-threaded cp314t wheel
# does NOT satisfy a GIL cp314 target (and vice-versa), plus regression coverage
# for the existing CPython/PyPy/macOS/Windows/source targets.
#
# Run: bash tests/test-check-release-fileset.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_YML="${HERE}/../actions/check-release-fileset/action.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extract the composite action's `run: |` block and dedent the 8-space YAML
# indentation, so we exercise the REAL production shell (no duplicated logic).
SCRIPT="${WORK}/fileset.sh"
awk '/^      run: \|/{f=1;next} /^branding:/{f=0} f' "$ACTION_YML" | sed 's/^        //' > "$SCRIPT"
if [ ! -s "$SCRIPT" ]; then
  echo "FATAL: could not extract run: script from $ACTION_YML" >&2
  exit 2
fi

PASS=0
FAIL=0

# run_case <name> <expected_exit> <targets> <dist-file>...
run_case() {
  local name="$1" expected="$2" targets="$3"; shift 3
  local dist="${WORK}/dist"
  rm -rf "$dist"; mkdir -p "$dist"
  local f
  for f in "$@"; do : > "${dist}/${f}"; done
  : > "${WORK}/gh_output"
  local rc=0
  env DISTDIR="$dist" TARGETS="$targets" MODE=strict \
      ALLOW_DEV_WHEELS=false ALLOW_EXTRA_WHEELS=false KEEP_METADATA=true \
      GITHUB_OUTPUT="${WORK}/gh_output" \
      bash "$SCRIPT" > "${WORK}/log" 2>&1 || rc=$?
  if [ "$rc" = "$expected" ]; then
    echo "  ok   [$name] exit=$rc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] exit=$rc (expected $expected)"
    tail -8 "${WORK}/log" | sed 's/^/         /'
    FAIL=$((FAIL + 1))
  fi
}

V="26.7.1"  # arbitrary version string for the fixture filenames

echo "== ABI-tag correctness (the #11 fix) =="
# GIL cp314 target must REJECT a free-threaded cp314t wheel (-> missing -> fail)
run_case "cpy314 rejects cp314t (aarch64)" 1 "cpy314-linux-aarch64-manylinux_2_28" \
  "pkg-${V}-cp314-cp314t-manylinux_2_24_aarch64.manylinux_2_28_aarch64.whl"
# GIL cp314 target ACCEPTS a proper cp314 wheel
run_case "cpy314 accepts cp314 (aarch64)" 0 "cpy314-linux-aarch64-manylinux_2_28" \
  "pkg-${V}-cp314-cp314-manylinux_2_24_aarch64.manylinux_2_28_aarch64.whl"
# free-threaded cpy314t target ACCEPTS its cp314t wheel
run_case "cpy314t accepts cp314t (aarch64)" 0 "cpy314t-linux-aarch64-manylinux_2_28" \
  "pkg-${V}-cp314-cp314t-manylinux_2_24_aarch64.manylinux_2_28_aarch64.whl"
# free-threaded cpy314t target REJECTS a GIL cp314 wheel
run_case "cpy314t rejects cp314 (aarch64)" 1 "cpy314t-linux-aarch64-manylinux_2_28" \
  "pkg-${V}-cp314-cp314-manylinux_2_24_aarch64.manylinux_2_28_aarch64.whl"

echo "== regressions (existing targets unaffected) =="
run_case "cpy311 accepts cp311" 0 "cpy311-linux-x86_64-manylinux_2_28" \
  "pkg-${V}-cp311-cp311-manylinux_2_28_x86_64.whl"
run_case "cpy311 rejects cp314" 1 "cpy311-linux-x86_64-manylinux_2_28" \
  "pkg-${V}-cp314-cp314-manylinux_2_28_x86_64.whl"
run_case "pypy311 accepts pypy311_pp73" 0 "pypy311-linux-aarch64-manylinux_2_34" \
  "pkg-${V}-pp311-pypy311_pp73-manylinux_2_34_aarch64.whl"
run_case "macos cp314 arm64" 0 "cpy314-macos-arm64" \
  "pkg-${V}-cp314-cp314-macosx_15_0_arm64.whl"
run_case "win cp314 amd64" 0 "cpy314-win-amd64" \
  "pkg-${V}-cp314-cp314-win_amd64.whl"
run_case "source required present" 0 "source" \
  "pkg-${V}.tar.gz"

echo ""
echo "TOTAL: pass=${PASS} fail=${FAIL}"
[ "$FAIL" = 0 ]
