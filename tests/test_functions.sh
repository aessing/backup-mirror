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
assert_file_exists() { local desc="$1" path="$2"
  if [[ -f "$path" ]]; then echo "  PASS: $desc"; ((++PASS))
  else echo "  FAIL: $desc — file missing: $path"; ((++FAIL)); fi
}

echo "=== shellcheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning -x "$(dirname "$0")/../mirror.sh" "$(dirname "$0")/test_functions.sh"; then
    echo "  PASS: shellcheck clean (severity=warning)"
    ((++PASS))
  else
    echo "  FAIL: shellcheck reported issues"
    ((++FAIL))
  fi
else
  echo "  SKIP: shellcheck not installed"
fi

# Source mirror.sh without running main
# shellcheck source=../mirror.sh
MIRROR_TEST_MODE=1 source "$(dirname "$0")/../mirror.sh"

echo "=== sep ==="
OUTPUT=$(sep)
assert_contains "sep contains dash chars" "$OUTPUT" "─"

echo "=== print_header ==="
OUTPUT=$(print_header)
assert_contains "header contains script name" "$OUTPUT" "Home / Disk Mirror"
assert_contains "header contains version" "$OUTPUT" "v1.1"
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
OUTPUT=$(render_run_mode_selection "dry")
assert_contains "dry mode selection is displayed" "$OUTPUT" "Dry run"
OUTPUT=$(render_run_mode_selection "live")
assert_contains "live mode selection is displayed" "$OUTPUT" "Live run"

echo "=== build_exclude_args (home) ==="
OUTPUT=$(build_exclude_args home)
assert_contains "home excludes iCloud" "$OUTPUT" "Library/Mobile Documents"
assert_contains "home excludes Caches" "$OUTPUT" "Library/Caches"
assert_contains "home excludes Trash" "$OUTPUT" ".Trash"
assert_contains "home excludes Developer" "$OUTPUT" "Library/Developer"
HOME_COUNT=$(echo "$OUTPUT" | grep -c '\-\-exclude' || true)
assert_eq "home has exactly 60 excludes" "$HOME_COUNT" "60"

echo "=== build_exclude_args (volume) ==="
OUTPUT=$(build_exclude_args volume)
assert_contains "volume excludes Spotlight" "$OUTPUT" ".Spotlight-V100"
assert_contains "volume excludes Trashes" "$OUTPUT" ".Trashes"
assert_contains "volume excludes fseventsd" "$OUTPUT" ".fseventsd"
assert_contains "volume excludes DocumentRevisions" "$OUTPUT" ".DocumentRevisions-V100"
assert_contains "volume excludes TemporaryItems" "$OUTPUT" ".TemporaryItems"
VOLUME_COUNT=$(echo "$OUTPUT" | grep -c '\-\-exclude' || true)
assert_eq "volume has exactly 5 excludes" "$VOLUME_COUNT" "5"

echo "=== exclusion arrays disjoint ==="
HOME_OUT=$(build_exclude_args home)
DISJOINT=1
for vol_path in ".Spotlight-V100" ".Trashes" ".fseventsd" ".DocumentRevisions-V100" ".TemporaryItems"; do
  if echo "$HOME_OUT" | grep -qE "exclude=${vol_path}\$"; then DISJOINT=0; fi
done
assert_eq "no volume excludes leak into home list" "$DISJOINT" "1"

echo "=== count_source_files ==="
# Count files in /tmp — should be fast and return a number
COUNT=$(count_source_files "/tmp")
assert_contains "count is non-empty" "$COUNT" ""
[[ "$COUNT" =~ ^[0-9]+$ ]] && echo "  PASS: count is numeric ($COUNT)" && ((++PASS)) \
  || { echo "  FAIL: count is not numeric: '$COUNT'"; ((++FAIL)); }

echo "=== count_source_bytes ==="
TMP_BYTES=$(mktemp -d)
printf 'hello' > "$TMP_BYTES/a.txt"
printf 'world!' > "$TMP_BYTES/b.txt"
BYTES=$(count_source_bytes "$TMP_BYTES")
assert_eq "counts total source bytes" "$BYTES" "11"

echo "=== count_source_files (volume profile excludes Spotlight) ==="
TMP_VOL=$(mktemp -d)
mkdir -p "$TMP_VOL/.Spotlight-V100" "$TMP_VOL/Photos"
printf 'a\n' > "$TMP_VOL/.Spotlight-V100/index"
printf 'b\n' > "$TMP_VOL/Photos/img.txt"
COUNT=$(count_source_files "$TMP_VOL" volume)
assert_eq "volume profile excludes Spotlight content" "$COUNT" "1"
COUNT_HOME=$(count_source_files "$TMP_VOL" home)
assert_eq "home profile does not exclude Spotlight" "$COUNT_HOME" "2"
rm -rf "$TMP_VOL"

echo "=== render_progress_line ==="
TOTAL_BYTES=0
TOTAL_FILES=0
TRANSFER_COUNT=7
TRANSFERRED_BYTES=0
CURRENT_FILE_BYTES=0
OUTPUT=$(render_progress_line)
assert_contains "unknown total progress still shows a bar" "$OUTPUT" "█"
assert_contains "unknown total progress keeps file count" "$OUTPUT" "7 files transferred"
BAR_AT_7=$(build_activity_bar)
TRANSFER_COUNT=93849
BAR_AT_MANY=$(build_activity_bar)
assert_eq "unknown total activity bar is stable" "$BAR_AT_MANY" "$BAR_AT_7"
ERROR_BLOCK=$(render_error_block "rsync: warning: sample"; printf END)
assert_contains "error clears current progress line" "$ERROR_BLOCK" $'\r\033[K'
assert_contains "error leaves blank row before progress redraw" "$ERROR_BLOCK" $'\n\nEND'

echo "=== process_output_line ==="
# Set globals that process_output_line depends on
TOTAL_FILES=100
TOTAL_BYTES=1000
TRANSFERRED_BYTES=0
CURRENT_FILE_BYTES=0
TRANSFER_COUNT=0
ERROR_COUNT=0
DELETE_COUNT=0
LOG_FILE=$(mktemp)

process_output_line "          500  50%    1.00MB/s    0:00:00"
assert_eq "tracks current file bytes before completion" "$CURRENT_FILE_BYTES" "500"
assert_eq "does not complete bytes before 100%" "$TRANSFERRED_BYTES" "0"

# Simulate a file-transfer completion line from rsync --progress
process_output_line "        1,000 100%   12.34MB/s    0:00:00"
assert_eq "increments TRANSFER_COUNT on 100%" "$TRANSFER_COUNT" "1"
assert_eq "adds completed file bytes on 100%" "$TRANSFERRED_BYTES" "1000"
assert_eq "clears current file bytes on completion" "$CURRENT_FILE_BYTES" "0"

process_output_line "deleting stale.txt"
assert_eq "increments DELETE_COUNT on deleting line" "$DELETE_COUNT" "1"

process_output_line "rsync: [receiver] failed to open ... Permission denied (13)"
assert_eq "increments ERROR_COUNT on rsync error" "$ERROR_COUNT" "1"

LOG_CONTENT=$(cat "$LOG_FILE")
assert_contains "error written to log" "$LOG_CONTENT" "Permission denied"
assert_contains "normal rsync output written to log" "$LOG_CONTENT" "1,000 100%"
assert_contains "delete output written to log" "$LOG_CONTENT" "deleting stale.txt"

rm -f "$LOG_FILE"

echo "=== run_mirror interface ==="
assert_contains "run_mirror is a function" "$(type run_mirror 2>&1)" "function"

echo "=== parse_stats ==="
DELETE_COUNT=0
SAMPLE_STATS="Number of regular files transferred: 1,842
Number of deleted files: 23
Total transferred file size: 6,410,123,456 bytes"

OUTPUT=$(parse_stats "$SAMPLE_STATS")
assert_contains "parse_stats finds transferred count" "$OUTPUT" "1,842"
assert_contains "parse_stats finds deleted count" "$OUTPUT" "23"
assert_contains "parse_stats finds total size" "$OUTPUT" "6,410,123,456"

OPENRSYNC_STATS="Number of files: 3
Number of files transferred: 1
Total file size: 12 B
Total transferred file size: 6 B"
OUTPUT=$(parse_stats "$OPENRSYNC_STATS")
assert_eq "parse_stats handles openrsync transferred wording" "$OUTPUT" "1|0|6"

echo "=== run_mirror integration ==="
TMP_ROOT=$(mktemp -d)
TEST_HOME="$TMP_ROOT/home"
TEST_VOL="$TMP_ROOT/vol"
TEST_DEST="$TEST_VOL/Home Folder Backup"
mkdir -p "$TEST_HOME/Documents" "$TEST_DEST"
printf 'hello\n' > "$TEST_HOME/Documents/a.txt"
printf 'stale\n' > "$TEST_DEST/stale.txt"

HOME="$TEST_HOME" run_mirror "$TEST_HOME/" "$TEST_DEST" live home "Home Folder" >/dev/null
assert_contains "run_mirror writes timestamped log path" "$LOG_FILE" "$TEST_VOL/Home Folder Logs/mirror_"
assert_file_exists "run_mirror writes timestamped log file" "$LOG_FILE"
assert_contains "run_mirror logs transfer stats" "$(cat "$LOG_FILE")" "Number of files transferred:"
assert_contains "run_mirror logs delete output" "$(cat "$LOG_FILE")" "deleting stale.txt"
assert_eq "run_mirror counts source files" "$TOTAL_FILES" "1"
assert_eq "run_mirror counts source bytes" "$TOTAL_BYTES" "6"
[[ ! -e "$TEST_DEST/stale.txt" ]] && echo "  PASS: run_mirror deletes stale destination file" && ((++PASS)) \
  || { echo "  FAIL: stale destination file still exists"; ((++FAIL)); }

OLD_LOG="$TEST_VOL/Home Folder Logs/mirror_20000101_000000.log"
mkdir -p "$(dirname "$OLD_LOG")"
printf 'old\n' > "$OLD_LOG"
touch -t 200001010000 "$OLD_LOG" 2>/dev/null || true
HOME="$TEST_HOME" run_mirror "$TEST_HOME/" "$TEST_DEST" dry home "Home Folder" >/dev/null
[[ ! -e "$OLD_LOG" ]] && echo "  PASS: run_mirror prunes logs older than 30 days" && ((++PASS)) \
  || { echo "  FAIL: old log was not pruned"; ((++FAIL)); }

TMP_ROOT=$(mktemp -d)
TEST_HOME="$TMP_ROOT/home"
TEST_VOL="$TMP_ROOT/vol"
VICTIM="$TMP_ROOT/victim"
mkdir -p "$TEST_HOME" "$TEST_VOL" "$VICTIM"
printf 'hello\n' > "$TEST_HOME/file.txt"
printf 'do-not-delete\n' > "$VICTIM/stale.txt"
ln -s "$VICTIM" "$TEST_VOL/Home Folder Backup"
set +e
HOME="$TEST_HOME" run_mirror "$TEST_HOME/" "$TEST_VOL/Home Folder Backup" live home "Home Folder" >/dev/null 2>&1
SYMLINK_RC=$?
set -e
assert_eq "run_mirror rejects symlink destination" "$SYMLINK_RC" "1"
assert_file_exists "symlink rejection preserves target files" "$VICTIM/stale.txt"

echo "=== select_source ==="
assert_contains "select_source is a function" "$(type select_source 2>&1)" "function"

echo "=== filter_out_drive ==="
DRIVES_INPUT=$'Disk One  ·  1 TB  ·  500 GB free\t/Volumes/Disk One\nDisk Two  ·  2 TB  ·  1 TB free\t/Volumes/Disk Two'
FILTERED=$(filter_out_drive "$DRIVES_INPUT" "/Volumes/Disk One")
assert_contains "filter keeps non-matching drive" "$FILTERED" "Disk Two"
[[ "$FILTERED" != *"Disk One"* ]] && echo "  PASS: filter drops the matching drive" && ((++PASS)) \
  || { echo "  FAIL: filter did not drop matching drive"; ((++FAIL)); }
EMPTY=$(filter_out_drive "$DRIVES_INPUT" "")
assert_eq "empty filter is a no-op" "$EMPTY" "$DRIVES_INPUT"

echo "=== select_drive accepts exclude-path arg ==="
# Verify the helper integration: filter_out_drive is what select_drive calls.
# The interactive part is tested manually; here we just verify the function signature
# accepts an argument by inspecting the body for "filter_out_drive".
SELECT_DRIVE_BODY=$(type select_drive)
assert_contains "select_drive uses filter_out_drive" "$SELECT_DRIVE_BODY" "filter_out_drive"

echo "=== run_mirror integration (volume profile) ==="
TMP_ROOT_V=$(mktemp -d)
TEST_SRC_VOL="$TMP_ROOT_V/MyDisk"
TEST_DEST_VOL="$TMP_ROOT_V/dest"
mkdir -p "$TEST_SRC_VOL/.Spotlight-V100" "$TEST_SRC_VOL/Photos" "$TEST_DEST_VOL"
printf 'idx\n' > "$TEST_SRC_VOL/.Spotlight-V100/index"
printf 'pic\n' > "$TEST_SRC_VOL/Photos/img.txt"

run_mirror "$TEST_SRC_VOL/" "$TEST_DEST_VOL/MyDisk Backup" live volume "MyDisk" >/dev/null
assert_file_exists "volume mirror writes Photos/img.txt" "$TEST_DEST_VOL/MyDisk Backup/Photos/img.txt"
[[ ! -e "$TEST_DEST_VOL/MyDisk Backup/.Spotlight-V100/index" ]] \
  && echo "  PASS: volume mirror excludes Spotlight" && ((++PASS)) \
  || { echo "  FAIL: Spotlight content was mirrored"; ((++FAIL)); }
assert_contains "volume mirror writes log under <label> Logs" "$LOG_FILE" "$TEST_DEST_VOL/MyDisk Logs/mirror_"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
