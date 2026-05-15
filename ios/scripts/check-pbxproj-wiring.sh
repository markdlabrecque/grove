#!/usr/bin/env bash
# check-pbxproj-wiring.sh — assert every *Tests.swift under OracleTests/ is
# referenced in project.pbxproj.
#
# LIMITATION: this uses a plain filename grep, which means a filename that
# appears only in a comment inside project.pbxproj would pass this check.
# In practice, pbxproj comments always appear alongside the real entry (Xcode
# writes "/* Foo.swift */" as a human-readable annotation next to the UUID),
# so the false-positive rate is negligible for V1. A stricter check would parse
# the PBXSourcesBuildPhase stanza — left as a TODO if the team ever needs it.
#
# HOW TO FIX a failure:
#   Open ios/Oracle/Oracle.xcodeproj in Xcode, select the file in the Project
#   navigator, open the File inspector (right panel), and tick the OracleTests
#   checkbox under "Target Membership". Xcode will re-write project.pbxproj.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/ios/Oracle/OracleTests"
PBXPROJ="$REPO_ROOT/ios/Oracle/Oracle.xcodeproj/project.pbxproj"

if [ ! -d "$TESTS_DIR" ]; then
  echo "ERROR: OracleTests directory not found at $TESTS_DIR" >&2
  exit 1
fi

if [ ! -f "$PBXPROJ" ]; then
  echo "ERROR: project.pbxproj not found at $PBXPROJ" >&2
  exit 1
fi

missing=0
while IFS= read -r f; do
  base=$(basename "$f")
  if ! grep -q "$base" "$PBXPROJ"; then
    echo "ERROR: $base exists in OracleTests/ but is not referenced in project.pbxproj" >&2
    echo "  Fix: Open Oracle.xcodeproj in Xcode, select $base, and tick OracleTests under Target Membership." >&2
    missing=1
  fi
done < <(find "$TESTS_DIR" -name '*Tests.swift' -not -path '*/Fixtures/*')

if [ "$missing" -eq 0 ]; then
  echo "ios-lint-pbxproj: all OracleTests/*.swift files are referenced in project.pbxproj."
fi

exit "$missing"
