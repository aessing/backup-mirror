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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
