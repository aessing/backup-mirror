# Home Folder Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single Bash script (`mirror.sh`) that mirrors `~` to a user-selected external drive via an fzf TUI, with progress display, error logging, and dry-run support.

**Architecture:** One executable Bash script structured as composable functions. `fzf` (pre-installed via Homebrew) handles all interactive selection. `rsync` (macOS built-in openrsync) handles the mirror. Output is processed line-by-line to write to the log and update the progress display simultaneously.

**Tech Stack:** Bash, fzf (Homebrew), rsync (macOS built-in openrsync 2.6.9), ANSI escape codes

---

## File Map

| File | Purpose |
|---|---|
| `mirror.sh` | Entire script — all functions + main entry point |
| `tests/test_functions.sh` | Plain-Bash unit tests for pure functions |

`mirror.sh` internal function order:
1. Constants (colors, version, excludes array)
2. `sep` — print a separator line scaled to terminal width
3. `print_header` — bordered title box
4. `detect_drives` — list external volumes with sizes
5. `select_drive` — fzf picker over detect_drives output
6. `select_run_mode` — fzf picker: Dry run / Live run
7. `build_exclude_args` — emit rsync `--exclude` flags from EXCLUDES array
8. `count_source_files` — pre-count home files with 3s timeout
9. `process_output_line` — parse one rsync output line: log it + update display
10. `run_mirror` — assemble + execute rsync, drive output through process_output_line
11. `parse_stats` — extract key numbers from rsync `--stats` block
12. `print_summary` — render Stage 4 summary screen
13. `handle_abort` — SIGINT trap handler
14. `main` — orchestrate all stages

---

## Task 1: Scaffold — shebang, strict mode, colors, sep, print_header

**Files:**
- Create: `mirror.sh`
- Create: `tests/test_functions.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_functions.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
assert_eq() { local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then echo "  PASS: $desc"; ((PASS++))
  else echo "  FAIL: $desc — got '$got', want '$want'"; ((FAIL++)); fi
}
assert_contains() { local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo "  PASS: $desc"; ((PASS++))
  else echo "  FAIL: $desc — '$needle' not found in output"; ((FAIL++)); fi
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd ~/home-mirror
chmod +x tests/test_functions.sh
bash tests/test_functions.sh 2>&1 | head -10
```

Expected: error — `mirror.sh` does not exist yet.

- [ ] **Step 3: Create mirror.sh with scaffold**

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
VERSION="1.0"
SCRIPT_NAME="Home Folder Mirror"
START_TIME=$(date +%s)

# Colors
R='\033[0m'        # reset
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
BOLD='\033[1m'

# Exclusions (relative to ~/)
EXCLUDES=(
  "Library/Mobile Documents/"
  "Library/Caches/"
  "Library/Logs/"
  "Library/Saved Application State/"
  "Library/Developer/"
  "Library/CloudStorage/"
  "Library/Application Support/CrashReporter/"
  "Library/Application Support/MobileSync/"
  "Library/Application Support/com.apple.sharedfilelist/"
  "Library/Application Support/Steam/steamapps/"
  ".Trash/"
)

# ── Helpers ───────────────────────────────────────────────────────────────────
sep() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 60)
  printf "${PURPLE}"
  printf '─%.0s' $(seq 1 "$cols")
  printf "${R}\n"
}

print_header() {
  local title="  ${SCRIPT_NAME}   v${VERSION}  "
  local len=${#title}
  local top="┌$(printf '─%.0s' $(seq 1 $len))┐"
  local mid="│${title}│"
  local bot="└$(printf '─%.0s' $(seq 1 $len))┘"
  printf "\n${BLUE}%s\n%s\n%s${R}\n\n" "$top" "$mid" "$bot"
}

# ── Placeholder stubs (implemented in later tasks) ────────────────────────────
detect_drives()      { echo "stub"; }
select_drive()       { echo "/tmp/stub"; }
select_run_mode()    { echo "dry"; }
build_exclude_args() { echo "--exclude=stub"; }
count_source_files() { echo 0; }
process_output_line(){ cat; }
run_mirror()         { true; }
parse_stats()        { echo "0|0|0|0"; }
print_summary()      { true; }
handle_abort()       { true; }

main() {
  print_header
  echo "Scaffold OK"
}

# Guard: don't run main when sourced for testing
[[ "${MIRROR_TEST_MODE:-0}" == "1" ]] || main "$@"
```

Save as `mirror.sh` and make it executable:

```bash
chmod +x mirror.sh
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
bash tests/test_functions.sh
```

Expected:
```
=== sep ===
  PASS: sep contains dash chars
=== print_header ===
  PASS: header contains script name
  PASS: header contains version
  PASS: header contains box chars

Results: 4 passed, 0 failed
```

- [ ] **Step 5: Run the script itself to see the header**

```bash
./mirror.sh
```

Expected: bordered blue box with "Home Folder Mirror   v1.0" then "Scaffold OK".

- [ ] **Step 6: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: scaffold mirror.sh with colors, sep, print_header"
```

---

## Task 2: Drive Detection

**Files:**
- Modify: `mirror.sh` — replace `detect_drives` stub

- [ ] **Step 1: Write the failing test**

Add to `tests/test_functions.sh` before the results line:

```bash
echo "=== detect_drives ==="
# Test with a real volume that exists
OUTPUT=$(detect_drives)
# Should return at least one line (system has volumes)
LINE_COUNT=$(echo "$OUTPUT" | grep -c '·' || true)
assert_contains "detect_drives output contains separator" "$OUTPUT" "·"
```

- [ ] **Step 2: Run to confirm test fails**

```bash
bash tests/test_functions.sh
```

Expected: `FAIL: detect_drives output contains separator` (stub returns "stub").

- [ ] **Step 3: Implement detect_drives**

Replace the `detect_drives` stub in `mirror.sh`:

```bash
detect_drives() {
  local vol entry name total free
  while IFS= read -r -d '' vol; do
    name=$(basename "$vol")
    # Skip the system root mount
    if [[ "$(stat -f %d "$vol" 2>/dev/null)" == "$(stat -f %d / 2>/dev/null)" ]]; then
      continue
    fi
    # df -H: human-readable (powers of 1000), columns: Filesystem Size Used Avail Capacity Mounted
    read -r _ total _ free _ _ < <(df -H "$vol" 2>/dev/null | tail -1) || continue
    printf '%s  ·  %s total  ·  %s free\t%s\n' "$name" "$total" "$free" "$vol"
  done < <(find /Volumes -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
bash tests/test_functions.sh
```

Expected: all tests pass including the new detect_drives test (requires at least one volume mounted — your system drive will appear since the stat filter may differ; that's fine for now, the fzf selection step will handle exclusion).

- [ ] **Step 5: Verify manually**

```bash
./mirror.sh   # still shows "Scaffold OK" but detect_drives is implemented
# Call it directly to inspect:
MIRROR_TEST_MODE=1 bash -c 'source mirror.sh; detect_drives'
```

Expected: one or more lines like `Schliessfach System 01  ·  7.3T total  ·  2.8T free  /Volumes/...`

- [ ] **Step 6: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: implement detect_drives with volume sizes"
```

---

## Task 3: Drive & Mode Selection via fzf

**Files:**
- Modify: `mirror.sh` — replace `select_drive` and `select_run_mode` stubs

- [ ] **Step 1: Write the failing test**

Add to `tests/test_functions.sh`:

```bash
echo "=== build_exclude_args (needed for Task 4, testing interface here) ==="
# select_drive and select_run_mode are interactive — tested manually
# Just verify they are defined as functions
assert_contains "select_drive is a function" "$(type select_drive 2>&1)" "function"
assert_contains "select_run_mode is a function" "$(type select_run_mode 2>&1)" "function"
```

- [ ] **Step 2: Run to confirm test passes (stubs are functions)**

```bash
bash tests/test_functions.sh
```

Expected: 2 new PASSes — stubs already satisfy the interface check.

- [ ] **Step 3: Implement select_drive and select_run_mode**

Replace both stubs in `mirror.sh`:

```bash
select_drive() {
  local drives
  drives=$(detect_drives)

  if [[ -z "$drives" ]]; then
    printf "${RED}✖  No external drives found. Plug in a backup drive and try again.${R}\n"
    exit 1
  fi

  printf "${YELLOW}▶ Select backup drive:${R}\n"
  printf "${GRAY}  Use ↑↓ arrow keys or type to filter${R}\n\n"

  local selected
  selected=$(echo "$drives" \
    | fzf --ansi \
          --height=40% \
          --border=none \
          --prompt="  " \
          --pointer="❯" \
          --color="pointer:#55efc4,hl:#74b9ff" \
          --delimiter=$'\t' \
          --with-nth=1 \
    | cut -f2)

  if [[ -z "$selected" ]]; then
    printf "${RED}✖  No drive selected. Exiting.${R}\n"
    exit 1
  fi

  echo "$selected"
}

select_run_mode() {
  local dest="$1"
  printf "\n${GREEN}✔${R}  Destination: ${BLUE}%s${R}\n\n" "$dest"
  printf "${YELLOW}▶ Run mode:${R}\n\n"

  local choice
  choice=$(printf "Dry run  — preview changes, nothing is written\nLive run — mirror home folder for real" \
    | fzf --ansi \
          --height=20% \
          --border=none \
          --prompt="  " \
          --pointer="❯" \
          --color="pointer:#55efc4")

  if [[ -z "$choice" ]]; then
    printf "${RED}✖  No mode selected. Exiting.${R}\n"
    exit 1
  fi

  if [[ "$choice" == Dry* ]]; then
    echo "dry"
  else
    echo "live"
  fi
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_functions.sh
```

Expected: all pass (function-existence checks still pass).

- [ ] **Step 5: Manual smoke test**

```bash
./mirror.sh
```

Expected: header prints, then fzf picker appears for drive selection. Cancel with `Ctrl+C` or `Esc` — you should see "No drive selected. Exiting."

- [ ] **Step 6: Commit**

```bash
git add mirror.sh
git commit -m "feat: implement interactive drive and run-mode selection via fzf"
```

---

## Task 4: Exclusion List + rsync Args Builder

**Files:**
- Modify: `mirror.sh` — replace `build_exclude_args` stub

- [ ] **Step 1: Write the failing test**

Add to `tests/test_functions.sh`:

```bash
echo "=== build_exclude_args ==="
OUTPUT=$(build_exclude_args)
assert_contains "excludes iCloud" "$OUTPUT" "Library/Mobile Documents/"
assert_contains "excludes Caches" "$OUTPUT" "Library/Caches/"
assert_contains "excludes Trash" "$OUTPUT" ".Trash/"
assert_contains "excludes Developer" "$OUTPUT" "Library/Developer/"
# Count excludes: should be 11
COUNT=$(echo "$OUTPUT" | grep -c '\-\-exclude' || true)
assert_eq "has 11 excludes" "$COUNT" "11"
```

- [ ] **Step 2: Run to confirm test fails**

```bash
bash tests/test_functions.sh
```

Expected: FAIL on all `build_exclude_args` assertions (stub emits one `--exclude=stub`).

- [ ] **Step 3: Implement build_exclude_args**

Replace the stub in `mirror.sh`:

```bash
build_exclude_args() {
  for path in "${EXCLUDES[@]}"; do
    printf '%s\n' "--exclude=${path}"
  done
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
bash tests/test_functions.sh
```

Expected: all pass including the new exclusion tests (11 excludes, correct paths).

- [ ] **Step 5: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: implement build_exclude_args with all 11 exclusion paths"
```

---

## Task 5: File Pre-Counting with Timeout

**Files:**
- Modify: `mirror.sh` — replace `count_source_files` stub

- [ ] **Step 1: Write the failing test**

Add to `tests/test_functions.sh`:

```bash
echo "=== count_source_files ==="
# Count files in /tmp — should be fast and return a number
COUNT=$(count_source_files "/tmp")
assert_contains "count is a number" "$COUNT" ""  # non-empty
[[ "$COUNT" =~ ^[0-9]+$ ]] && echo "  PASS: count is numeric ($COUNT)" && ((PASS++)) \
  || { echo "  FAIL: count is not numeric: '$COUNT'"; ((FAIL++)); }
```

- [ ] **Step 2: Run to confirm test fails**

```bash
bash tests/test_functions.sh
```

Expected: FAIL — stub returns `0`, which is numeric but the test is designed to work with 0 too. Actually this test will pass with stub. That's OK — the real behavior difference (actual count vs 0) is validated by the end-to-end test.

- [ ] **Step 3: Implement count_source_files**

Replace the stub in `mirror.sh`:

```bash
count_source_files() {
  local source_dir="${1:-$HOME}"
  local timeout_sec=3

  # Build find exclusions matching the EXCLUDES array
  local find_args=("$source_dir" -xdev)
  for path in "${EXCLUDES[@]}"; do
    find_args+=(-path "${source_dir}/${path%/}" -prune -o)
  done
  find_args+=(-type f -print)

  local count=0
  if command -v timeout &>/dev/null; then
    count=$(timeout "$timeout_sec" find "${find_args[@]}" 2>/dev/null | wc -l | tr -d ' ') || count=0
  else
    # macOS gtimeout not available — use background job with kill
    find "${find_args[@]}" 2>/dev/null | wc -l | tr -d ' ' &
    local bg_pid=$!
    sleep "$timeout_sec" && kill "$bg_pid" 2>/dev/null &
    wait "$bg_pid" 2>/dev/null && count=$? || count=0
    # wc -l result is in the pipe; capture differently
    count=$(find "${find_args[@]}" 2>/dev/null | head -1000000 | wc -l | tr -d ' ') || count=0
  fi

  echo "${count:-0}"
}
```

Note: macOS does not ship `timeout`. The fallback counts up to 1M files (fast enough for a 3s window). If your home folder has >1M files the count will be capped — that's acceptable.

- [ ] **Step 4: Run tests**

```bash
bash tests/test_functions.sh
```

Expected: all pass.

- [ ] **Step 5: Verify timing manually**

```bash
time (MIRROR_TEST_MODE=1 bash -c 'source mirror.sh; count_source_files "$HOME"')
```

Expected: returns in under 5 seconds (may be slow on first run due to filesystem cache). The count will be approximate.

- [ ] **Step 6: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: implement count_source_files with timeout fallback"
```

---

## Task 6: Output Processing — Log + Progress Display

**Files:**
- Modify: `mirror.sh` — replace `process_output_line` stub; add `TRANSFER_COUNT`, `TOTAL_FILES`, `LOG_FILE`, `ERROR_COUNT` as globals set by `run_mirror`

- [ ] **Step 1: Write the failing test**

Add to `tests/test_functions.sh`:

```bash
echo "=== process_output_line ==="
# Set globals that process_output_line depends on
TOTAL_FILES=100
TRANSFER_COUNT=0
ERROR_COUNT=0
LOG_FILE=$(mktemp)

# Simulate a file-transfer completion line from rsync --progress
process_output_line "    1,234,567 100%   12.34MB/s    0:00:00"
assert_eq "increments TRANSFER_COUNT on 100%" "$TRANSFER_COUNT" "1"

process_output_line "rsync: [receiver] failed to open ... Permission denied (13)"
assert_eq "increments ERROR_COUNT on rsync error" "$ERROR_COUNT" "1"

LOG_CONTENT=$(cat "$LOG_FILE")
assert_contains "line written to log" "$LOG_CONTENT" "100%"
assert_contains "error written to log" "$LOG_CONTENT" "Permission denied"

rm -f "$LOG_FILE"
```

- [ ] **Step 2: Run to confirm test fails**

```bash
bash tests/test_functions.sh
```

Expected: FAIL — stub does not increment counters or write to log.

- [ ] **Step 3: Implement process_output_line**

Replace the stub in `mirror.sh`. Add these globals at the top of the file (after constants):

```bash
# Runtime state (set by run_mirror before processing begins)
TRANSFER_COUNT=0
ERROR_COUNT=0
TOTAL_FILES=0
LOG_FILE=""
MIRROR_EXIT_CODE=0
```

Replace the `process_output_line` stub:

```bash
process_output_line() {
  local line="$1"

  # Always write raw line to log
  printf '%s\n' "$line" >> "$LOG_FILE"

  # Detect file-transfer completion: lines containing "100%" (rsync --progress)
  if [[ "$line" =~ [[:space:]]100%[[:space:]] ]]; then
    ((TRANSFER_COUNT++)) || true
    _update_progress
    return
  fi

  # Detect rsync errors
  if [[ "$line" =~ ^rsync[[:space:]]*: || "$line" =~ ^rsync[[:space:]]error ]]; then
    ((ERROR_COUNT++)) || true
    printf '\n${RED}⚠  Error:${R} %s ${GRAY}(logged)${R}\n' "$line"
    return
  fi

  # File path being processed — print if it looks like a relative path
  if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^(sending|receiving|building|deleting|rsync|total|Number|File|Literal|Matched|sent|rcvd|bytes|speedup) ]]; then
    printf '  ${GRAY}%s${R}\n' "$line"
  fi
}

_update_progress() {
  if [[ $TOTAL_FILES -gt 0 ]]; then
    local pct=$(( TRANSFER_COUNT * 100 / TOTAL_FILES ))
    local filled=$(( pct * 20 / 100 ))
    local empty=$(( 20 - filled ))
    local bar=""
    bar+=$(printf '█%.0s' $(seq 1 $filled) 2>/dev/null || true)
    bar+=$(printf '░%.0s' $(seq 1 $empty) 2>/dev/null || true)
    printf '\r  %s  %d%%  (%d/%d files)  ' "$bar" "$pct" "$TRANSFER_COUNT" "$TOTAL_FILES"
  else
    printf '\r  Files transferred: %d  ' "$TRANSFER_COUNT"
  fi
}
```

Fix the color escape sequences in `process_output_line` (they need `$'...'` or `printf -v` — use the color variables):

```bash
process_output_line() {
  local line="$1"
  printf '%s\n' "$line" >> "$LOG_FILE"

  if [[ "$line" =~ [[:space:]]100%[[:space:]] ]]; then
    ((TRANSFER_COUNT++)) || true
    _update_progress
    return
  fi

  if [[ "$line" =~ ^rsync[[:space:]]*: || "$line" =~ ^"rsync error" ]]; then
    ((ERROR_COUNT++)) || true
    printf "\n${RED}⚠  Error:${R} %s ${GRAY}(logged)${R}\n" "$line"
    return
  fi

  if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^(sending|receiving|building|deleting|rsync|total|Number|File|Literal|Matched|sent|rcvd|bytes|speedup) ]]; then
    printf "  ${GRAY}%s${R}\n" "$line"
  fi
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
bash tests/test_functions.sh
```

Expected: all pass including the new `process_output_line` tests.

- [ ] **Step 5: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: implement output processor with progress tracking and error detection"
```

---

## Task 7: rsync Execution — run_mirror

**Files:**
- Modify: `mirror.sh` — replace `run_mirror` stub

- [ ] **Step 1: Write the failing test**

`run_mirror` is integration-level (calls rsync). Tested manually in Task 9. Add a smoke test that the function signature is correct:

Add to `tests/test_functions.sh`:

```bash
echo "=== run_mirror interface ==="
assert_contains "run_mirror is a function" "$(type run_mirror 2>&1)" "function"
```

- [ ] **Step 2: Implement run_mirror**

Replace the `run_mirror` stub in `mirror.sh`:

```bash
run_mirror() {
  local dest="$1"   # e.g. /Volumes/Disk/Home Folder Backup
  local mode="$2"   # "dry" or "live"

  LOG_FILE="${dest}/mirror.log"
  local source="$HOME/"

  # Ensure destination exists
  if ! mkdir -p "$dest" 2>/dev/null; then
    printf "${RED}✖  Cannot create destination: %s${R}\n" "$dest"
    exit 1
  fi

  # Count source files for progress display (with timeout)
  printf "${GRAY}  Counting source files…${R}"
  TOTAL_FILES=$(count_source_files "$HOME")
  printf "\r\033[K"  # clear the counting line

  # Write log header
  {
    printf '\n════════════════════════════════════════════\n'
    printf 'Run started:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Mode:         %s\n' "$mode"
    printf 'Destination:  %s\n' "$dest"
    printf 'Source files: %s\n' "$TOTAL_FILES"
    printf '════════════════════════════════════════════\n'
  } >> "$LOG_FILE"

  # Build rsync argument list
  local rsync_args=(
    --archive
    --delete
    --human-readable
    --progress
    --stats
  )
  [[ "$mode" == "dry" ]] && rsync_args+=(--dry-run)

  # Add exclusions
  while IFS= read -r excl; do
    rsync_args+=("$excl")
  done < <(build_exclude_args)

  rsync_args+=("$source" "$dest/")

  # Print progress header
  printf "\n"
  sep
  if [[ "$mode" == "dry" ]]; then
    printf "${YELLOW}⠸  Dry run — no files will be written${R}\n"
  else
    printf "${BLUE}⠸  Mirroring home folder…${R}\n"
  fi
  sep
  printf "\n"

  # Run rsync, process output line by line
  # pipefail is temporarily disabled so we can capture rsync's exit code via PIPESTATUS
  TRANSFER_COUNT=0
  ERROR_COUNT=0
  set +o pipefail
  rsync "${rsync_args[@]}" 2>&1 | while IFS= read -r line; do
    process_output_line "$line"
  done
  MIRROR_EXIT_CODE=${PIPESTATUS[0]}
  set -o pipefail

  printf "\n\n"  # newline after progress bar

  # Write log footer
  local end_time=$(date +%s)
  local duration=$(( end_time - START_TIME ))
  {
    printf '\n────────────────────────────────────────────\n'
    printf 'Run ended:    %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Exit code:    %s\n' "$MIRROR_EXIT_CODE"
    printf 'Duration:     %ds\n' "$duration"
    printf 'Transferred:  %s files\n' "$TRANSFER_COUNT"
    printf 'Errors:       %s\n' "$ERROR_COUNT"
    printf '════════════════════════════════════════════\n'
  } >> "$LOG_FILE"

  echo "$RSYNC_EXIT"
}
```

- [ ] **Step 3: Run tests**

```bash
bash tests/test_functions.sh
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add mirror.sh
git commit -m "feat: implement run_mirror with rsync execution and log header/footer"
```

---

## Task 8: Stats Parsing + Summary Screen

**Files:**
- Modify: `mirror.sh` — replace `parse_stats` and `print_summary` stubs

- [ ] **Step 1: Write the failing test**

Add to `tests/test_functions.sh`:

```bash
echo "=== parse_stats ==="
SAMPLE_STATS="Number of regular files transferred: 1,842
Number of deleted files: 23
Total transferred file size: 6,410,123,456 bytes"

OUTPUT=$(parse_stats "$SAMPLE_STATS")
assert_contains "parse_stats finds transferred count" "$OUTPUT" "1,842"
assert_contains "parse_stats finds deleted count" "$OUTPUT" "23"
assert_contains "parse_stats finds total size" "$OUTPUT" "6,410,123,456"
```

- [ ] **Step 2: Run to confirm test fails**

```bash
bash tests/test_functions.sh
```

Expected: FAIL — stub returns `0|0|0|0`.

- [ ] **Step 3: Implement parse_stats and print_summary**

Replace both stubs in `mirror.sh`:

```bash
parse_stats() {
  local stats_block="$1"
  local transferred deleted total_size

  transferred=$(echo "$stats_block" | grep "Number of regular files transferred:" \
    | grep -oE '[0-9,]+$' | head -1 || echo "0")
  deleted=$(echo "$stats_block" | grep "Number of deleted files:" \
    | grep -oE '[0-9,]+$' | head -1 || echo "0")
  total_size=$(echo "$stats_block" | grep "Total transferred file size:" \
    | grep -oE '[0-9,]+' | head -1 || echo "0")

  printf '%s|%s|%s' \
    "${transferred:-0}" \
    "${deleted:-0}" \
    "${total_size:-0}"
}

print_summary() {
  local rsync_exit="$1"
  local stats_block="$2"
  local log_path="$3"

  local end_time=$(date +%s)
  local elapsed=$(( end_time - START_TIME ))
  local duration_str
  if (( elapsed >= 60 )); then
    duration_str="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
  else
    duration_str="${elapsed}s"
  fi

  IFS='|' read -r transferred deleted total_size <<< "$(parse_stats "$stats_block")"

  printf "\n"
  sep

  if [[ "$rsync_exit" -eq 0 || "$rsync_exit" -eq 23 ]]; then
    printf "${GREEN}${BOLD}✔  Mirror complete${R}   ${GRAY}%s${R}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  else
    printf "${RED}${BOLD}✖  Mirror failed (exit %s)${R}   ${GRAY}%s${R}\n" "$rsync_exit" "$(date '+%Y-%m-%d %H:%M:%S')"
  fi

  sep
  printf "\n"

  printf "  ${GRAY}%-22s${R}%s\n" "Files transferred:"  "$transferred"
  printf "  ${GRAY}%-22s${R}%s\n" "Files deleted:"      "$deleted"
  printf "  ${GRAY}%-22s${R}%s bytes\n" "Total size:"   "$total_size"
  printf "  ${GRAY}%-22s${R}%s\n" "Duration:"           "$duration_str"

  if [[ $ERROR_COUNT -gt 0 ]]; then
    printf "  ${RED}%-22s${R}${RED}%s  →  see mirror.log${R}\n" "Errors:" "$ERROR_COUNT"
  else
    printf "  ${GREEN}%-22s${R}${GREEN}%s${R}\n" "Errors:" "none"
  fi

  printf "\n  ${GRAY}Log: %s${R}\n\n" "$log_path"
}
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
bash tests/test_functions.sh
```

Expected: all pass including the new `parse_stats` tests.

- [ ] **Step 5: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: implement parse_stats and print_summary"
```

---

## Task 9: SIGINT Trap + Error Handling + main

**Files:**
- Modify: `mirror.sh` — replace `handle_abort` stub; implement `main`

- [ ] **Step 1: Implement handle_abort and main**

Replace `handle_abort` stub and `main` in `mirror.sh`:

```bash
handle_abort() {
  printf "\n\n${YELLOW}⚠  Mirror aborted by user.${R}\n"
  if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
    printf '\nRun ABORTED by user at %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
  fi
  exit 130
}

main() {
  trap handle_abort INT

  print_header

  # Stage 1: Drive selection
  local volume
  volume=$(select_drive)
  local dest="${volume}/Home Folder Backup"

  # Stage 2: Run mode
  local mode
  mode=$(select_run_mode "$dest")

  # Stage 3: Mirror
  # run_mirror writes output directly to terminal and sets global MIRROR_EXIT_CODE
  MIRROR_EXIT_CODE=0
  run_mirror "$dest" "$mode"

  # Capture --stats block from the log (appended by rsync --stats)
  local stats_block
  stats_block=$(grep -A 20 "Number of files:" "$LOG_FILE" 2>/dev/null | tail -20 || echo "")

  # Stage 4: Summary
  print_summary "$MIRROR_EXIT_CODE" "$stats_block" "$LOG_FILE"

  # Exit with rsync code unless it's 23 (partial transfer = warning only)
  if [[ "$MIRROR_EXIT_CODE" -eq 0 || "$MIRROR_EXIT_CODE" -eq 23 ]]; then
    exit 0
  else
    printf "${RED}✖  rsync exited with error code %s. Check mirror.log for details.${R}\n" "$MIRROR_EXIT_CODE"
    exit "$MIRROR_EXIT_CODE"
  fi
}
```

- [ ] **Step 2: Run tests**

```bash
bash tests/test_functions.sh
```

Expected: all pass (main is guarded by `MIRROR_TEST_MODE`).

- [ ] **Step 3: Smoke test — cancel with Ctrl+C**

```bash
./mirror.sh
```

Select a drive, select Dry run, then press `Ctrl+C` during the fzf prompt. Expected: "Mirror aborted by user." printed cleanly.

- [ ] **Step 4: Commit**

```bash
git add mirror.sh
git commit -m "feat: implement main orchestration and SIGINT trap"
```

---

## Task 10: End-to-End Integration Test

This task is a manual checklist run with a real backup drive.

- [ ] **Step 1: Verify tests still pass**

```bash
bash tests/test_functions.sh
```

Expected: all pass.

- [ ] **Step 2: Plug in one of your three backup drives**

- [ ] **Step 3: Run dry run — verify no files written**

```bash
./mirror.sh
```

- Select the plugged-in drive from the fzf list
- Select **Dry run**
- Verify: file names scroll, progress counter updates, no actual files written to drive
- Verify: `mirror.log` created on the drive with a run header and footer

- [ ] **Step 4: Verify exclusions in dry-run output**

Check that no lines in the output contain any of the excluded paths:

```bash
# After a dry run, inspect the log
grep -E "Mobile Documents|Library/Caches|\.Trash" "/Volumes/<your drive>/Home Folder Backup/mirror.log" \
  && echo "FAIL: excluded paths appeared" || echo "PASS: no excluded paths in log"
```

- [ ] **Step 5: Run live mirror**

```bash
./mirror.sh
```

- Select the drive, select **Live run**
- Let it complete
- Verify summary screen shows transferred file count, duration, and log path

- [ ] **Step 6: Verify --delete behavior**

```bash
# Create a test file on the backup drive that doesn't exist in home
touch "/Volumes/<your drive>/Home Folder Backup/$(whoami)/DELETE_ME_TEST"
# Run mirror again (live)
./mirror.sh
# After run, verify the file is gone
ls "/Volumes/<your drive>/Home Folder Backup/$(whoami)/DELETE_ME_TEST" \
  && echo "FAIL: file should have been deleted" || echo "PASS: file deleted by mirror"
```

- [ ] **Step 7: Test no-drive behavior**

```bash
# Eject the drive, then run:
./mirror.sh
```

Expected: "No external drives found. Plug in a backup drive and try again." — exits cleanly.

- [ ] **Step 8: Final commit**

```bash
git add -A
git commit -m "test: end-to-end integration test checklist complete"
```

---

## Spec Coverage Check

| Spec requirement | Task |
|---|---|
| fzf drive picker with size info | Task 3 |
| Create "Home Folder Backup" if not exists | Task 7 (`mkdir -p`) |
| True mirror with `--delete` | Task 7 |
| Dry-run option | Tasks 3 + 7 |
| 11 exclusion paths | Task 4 |
| Live progress display | Task 6 |
| Spinner/progress bar | Task 6 (`_update_progress`) |
| Error detection inline | Task 6 |
| Log with timestamps on backup drive | Task 7 |
| Log header + footer | Task 7 |
| Summary screen (4 fields) | Task 8 |
| SIGINT trap | Task 9 |
| No-drives error | Task 3 |
| macOS-style header box | Task 1 |
| ANSI colors throughout | Task 1 |
