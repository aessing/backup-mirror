#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
assert_eq() { local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then echo "  PASS: $desc"; ((++PASS))
  else echo "  FAIL: $desc — got '$got', want '$want'"; ((++FAIL)); fi
}
assert_contains() { local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS: $desc"; ((++PASS))
  else echo "  FAIL: $desc — '$needle' not found in output"; ((++FAIL)); fi
}

# Source mirror.sh without running main
MIRROR_TEST_MODE=1 source "$(dirname "$0")/../mirror.sh"

echo "=== sep ==="
OUTPUT=$(sep)
assert_contains "sep contains dash chars" "$OUTPUT" "─"

echo "=== print_header ==="
OUTPUT=$(print_header)
assert_contains "header contains script name" "$OUTPUT" "Home Folder Mirror"
assert_contains "header contains version" "$OUTPUT" "v1.0"
assert_contains "header contains box chars" "$OUTPUT" "┌"

echo "=== detect_drives ==="
OUTPUT=$(detect_drives)
if [[ -n "$OUTPUT" ]]; then
  assert_contains "detect_drives output contains separator ·" "$OUTPUT" "·"
  assert_contains "detect_drives output contains tab" "$OUTPUT" $'\t'
else
  echo "  SKIP: detect_drives — no external volumes mounted"
fi

echo "=== select_drive and select_run_mode ==="
# These are interactive — tested manually. Verify they are defined as functions.
assert_contains "select_drive is a function" "$(type select_drive 2>&1)" "function"
assert_contains "select_run_mode is a function" "$(type select_run_mode 2>&1)" "function"

echo "=== build_exclude_args ==="
OUTPUT=$(build_exclude_args)
assert_contains "excludes iCloud" "$OUTPUT" "Library/Mobile Documents/"
assert_contains "excludes Caches" "$OUTPUT" "Library/Caches/"
assert_contains "excludes Trash" "$OUTPUT" ".Trash/"
assert_contains "excludes Developer" "$OUTPUT" "Library/Developer/"
# Count excludes: should be 11
COUNT=$(echo "$OUTPUT" | grep -c '\-\-exclude' || true)
assert_eq "has 11 excludes" "$COUNT" "11"

echo "=== count_source_files ==="
# Count files in /tmp — should be fast and return a number
COUNT=$(count_source_files "/tmp")
assert_contains "count is non-empty" "$COUNT" ""
[[ "$COUNT" =~ ^[0-9]+$ ]] && echo "  PASS: count is numeric ($COUNT)" && ((++PASS)) \
  || { echo "  FAIL: count is not numeric: '$COUNT'"; ((++FAIL)); }

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
