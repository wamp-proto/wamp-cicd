#!/usr/bin/env bash

sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# Validate a Git branch/ref name against the WAMP shell-safe, filesystem-safe policy.
#
# Permissive for normal naming habits (e.g. "fix_9", "feature/foo",
# "rel_v25.9.1_part4b", "bugfix-123", "master", tags like "v25.9.1"), but rejects
# whitespace, all shell metacharacters and a leading '-' (argument-injection guard).
# The validated name is also the one reused in the mandatory audit file path
# (.audit/<user>_<branch>.md), so it must stay filesystem-safe too.
#
# This is defense-in-depth + policy enforcement; the primary injection defense is to
# never interpolate untrusted ${{ ... }} context into a run: body (pass via env: and
# reference quoted shell variables instead).
#
# Returns 0 if valid, non-zero otherwise.
validate_branch_name() {
  local name="$1"
  local re='^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$'
  [[ "$name" =~ $re ]]
}

if [ "$#" -eq 1 ]; then
  sanitize "$1"
fi
