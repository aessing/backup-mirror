# Home / Disk Mirror — Source Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `mirror.sh` so it can mirror the home folder OR a selected external volume, with separate exclusion lists per profile and dynamic destination/log folder names. Rebrand to "Home / Disk Mirror" v1.1, integrate ShellCheck, and rewrite the README.

**Architecture:** Insert a new `select_source` stage at the front of the wizard. A `profile` string (`home` | `volume`) is threaded through `build_exclude_args`, `count_source_files`, `count_source_bytes`, and `run_mirror`. `select_drive` learns to filter out a source volume to prevent self-mirroring. Two disjoint exclusion arrays (`HOME_EXCLUDES`, `VOLUME_EXCLUDES`) — never combined.

**Tech Stack:** Bash, fzf, rsync (macOS openrsync), ShellCheck (dev-only).

**Spec:** [`docs/superpowers/specs/2026-04-26-disk-mirror-source-selection-design.md`](../specs/2026-04-26-disk-mirror-source-selection-design.md)

---

## File Map

| File | Purpose | Change |
|---|---|---|
| `mirror.sh` | Main script | Modified throughout |
| `tests/test_functions.sh` | Test suite | Updated assertions + new tests + ShellCheck step |
| `README.md` | Project README | Rewritten from one-line placeholder |
| `docs/superpowers/specs/2026-04-25-home-mirror-design.md` | Synced spec | Already updated in prior commit |
| `docs/superpowers/specs/2026-04-26-disk-mirror-source-selection-design.md` | New feature spec | Already created |

---

## Task 1: Rename `EXCLUDES` → `HOME_EXCLUDES`, add `VOLUME_EXCLUDES`, profile-aware `build_exclude_args`

**Files:**
- Modify: `mirror.sh` (constants block around line 19-89, `build_exclude_args` around line 212-216)
- Modify: `tests/test_functions.sh` (build_exclude_args section around line 49-57)

- [ ] **Step 1: Update tests first (failing)**

Replace the `=== build_exclude_args ===` block in `tests/test_functions.sh` with:

```bash
echo "=== build_exclude_args (home) ==="
OUTPUT=$(build_exclude_args home)
assert_contains "home excludes iCloud" "$OUTPUT" "Library/Mobile Documents"
assert_contains "home excludes Caches" "$OUTPUT" "Library/Caches"
assert_contains "home excludes Trash" "$OUTPUT" ".Trash"
assert_contains "home excludes Developer" "$OUTPUT" "Library/Developer"
HOME_COUNT=$(echo "$OUTPUT" | grep -c '\-\-exclude' || true)
[[ "$HOME_COUNT" -gt 10 ]] && echo "  PASS: home has $HOME_COUNT excludes" && ((++PASS)) \
  || { echo "  FAIL: home has too few excludes ($HOME_COUNT)"; ((++FAIL)); }

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
VOL_OUT=$(build_exclude_args volume)
DISJOINT=1
for vol_path in ".Spotlight-V100" ".Trashes" ".fseventsd" ".DocumentRevisions-V100" ".TemporaryItems"; do
  if echo "$HOME_OUT" | grep -qE "exclude=${vol_path}\$"; then DISJOINT=0; fi
done
assert_eq "no volume excludes leak into home list" "$DISJOINT" "1"
```

- [ ] **Step 2: Run tests — expect failure**

```bash
bash tests/test_functions.sh
```

Expected: failures around `build_exclude_args volume` (function still takes no args / array doesn't exist).

- [ ] **Step 3: Rename array in `mirror.sh`**

In the constants block, change:

```bash
# Exclusions (relative to ~/)
EXCLUDES=(
```

to:

```bash
# Home folder exclusions (relative to ~/)
HOME_EXCLUDES=(
```

Leave the array contents unchanged.

- [ ] **Step 4: Add `VOLUME_EXCLUDES` array directly below `HOME_EXCLUDES`**

```bash
# External-volume exclusions (macOS volume metadata, auto-regenerated)
VOLUME_EXCLUDES=(
  ".Spotlight-V100/"
  ".Trashes/"
  ".fseventsd/"
  ".DocumentRevisions-V100/"
  ".TemporaryItems/"
)
```

- [ ] **Step 5: Update `build_exclude_args` to take a profile**

Replace:

```bash
build_exclude_args() {
  for path in "${EXCLUDES[@]}"; do
    printf '%s\n' "--exclude=${path%/}"
  done
}
```

with:

```bash
build_exclude_args() {
  local profile="${1:-home}"
  local -n arr
  case "$profile" in
    home)   arr=HOME_EXCLUDES ;;
    volume) arr=VOLUME_EXCLUDES ;;
    *)      printf '%s✖  Unknown profile: %s%s\n' "$RED" "$profile" "$R" >&2; return 1 ;;
  esac
  for path in "${arr[@]}"; do
    printf '%s\n' "--exclude=${path%/}"
  done
}
```

- [ ] **Step 6: Run tests — expect pass**

```bash
bash tests/test_functions.sh
```

Expected: all build_exclude_args tests pass; integration tests at the bottom may still fail because they reference `EXCLUDES` indirectly via `count_source_files` — that's Task 2.

- [ ] **Step 7: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "refactor: split exclusions into HOME_EXCLUDES and VOLUME_EXCLUDES"
```

---

## Task 2: Profile-aware `count_source_files` and `count_source_bytes`

**Files:**
- Modify: `mirror.sh` (`count_source_files` around 254-288, `count_source_bytes` around 290-328)
- Modify: `tests/test_functions.sh` (count_source_* sections)

- [ ] **Step 1: Add a failing test for volume profile exclusions**

Append to `tests/test_functions.sh` after the `=== count_source_bytes ===` block:

```bash
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
```

- [ ] **Step 2: Run tests — expect failure**

```bash
bash tests/test_functions.sh
```

Expected: new tests fail (function ignores second argument; both counts return 2).

- [ ] **Step 3: Update `count_source_files`**

Replace the body's exclusion loop. Change:

```bash
count_source_files() {
  local source_dir="${1:-$HOME}"

  local find_args=("$source_dir" -xdev)
  for path in "${EXCLUDES[@]}"; do
    find_args+=(-path "${source_dir}/${path%/}" -prune -o)
  done
```

to:

```bash
count_source_files() {
  local source_dir="${1:-$HOME}"
  local profile="${2:-home}"
  local -n excl_arr
  case "$profile" in
    home)   excl_arr=HOME_EXCLUDES ;;
    volume) excl_arr=VOLUME_EXCLUDES ;;
    *)      excl_arr=HOME_EXCLUDES ;;
  esac

  local find_args=("$source_dir" -xdev)
  for path in "${excl_arr[@]}"; do
    find_args+=(-path "${source_dir}/${path%/}" -prune -o)
  done
```

- [ ] **Step 4: Update `count_source_bytes` the same way**

Apply the identical change in `count_source_bytes`: add `local profile="${2:-home}"`, the same case block, and switch the loop to `"${excl_arr[@]}"`.

- [ ] **Step 5: Run tests — expect pass**

```bash
bash tests/test_functions.sh
```

Expected: new tests pass; existing tests that called `count_source_files "/tmp"` and `count_source_bytes "$TMP_BYTES"` still pass (default profile = `home`).

- [ ] **Step 6: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "refactor: profile-aware source counting"
```

---

## Task 3: Add `select_source` and a filterable `_format_drives_list` helper

**Files:**
- Modify: `mirror.sh` (after `select_drive`, around line 170)
- Modify: `tests/test_functions.sh`

- [ ] **Step 1: Failing tests**

Append to `tests/test_functions.sh` after the `select_drive and select_run_mode` block:

```bash
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
```

- [ ] **Step 2: Run tests — expect failure**

```bash
bash tests/test_functions.sh
```

Expected: `select_source is a function` fails; `filter_out_drive` undefined.

- [ ] **Step 3: Add `filter_out_drive` helper to `mirror.sh`**

Insert just above `select_drive`:

```bash
filter_out_drive() {
  local drives="$1"
  local exclude_path="$2"
  if [[ -z "$exclude_path" ]]; then
    printf '%s' "$drives"
    return
  fi
  printf '%s' "$drives" | awk -F'\t' -v exc="$exclude_path" '$2 != exc { print }'
}
```

- [ ] **Step 4: Add `select_source` function**

Insert immediately after `select_drive`:

```bash
select_source() {
  if ! command -v fzf &>/dev/null; then
    printf '%s✖  fzf is required but not found. Install with: brew install fzf%s\n' "$RED" "$R" >&2
    exit 1
  fi

  local drives
  drives=$(detect_drives)

  local options
  options=$(printf 'Home Folder\thome\t%s\t\n' "$HOME/")
  if [[ -n "$drives" ]]; then
    while IFS=$'\t' read -r display path; do
      [[ -z "$display" ]] && continue
      local name
      name=$(basename "$path")
      options+=$(printf '\n%s\tvolume\t%s/\t%s' "$display" "$path" "$path")
    done <<< "$drives"
  fi

  printf '%s▶ Select source:%s\n' "$YELLOW" "$R" >&2
  printf '%s  Use ↑↓ arrow keys or type to filter%s\n\n' "$GRAY" "$R" >&2

  local selected
  selected=$(printf '%s\n' "$options" \
    | fzf --ansi \
          --height=40% \
          --border=none \
          --prompt="  " \
          --pointer="❯" \
          --color="pointer:#55efc4,hl:#74b9ff" \
          --delimiter=$'\t' \
          --with-nth=1) || true

  if [[ -z "$selected" ]]; then
    printf '%s✖  No source selected. Exiting.%s\n' "$RED" "$R" >&2
    exit 1
  fi

  # Output: profile<TAB>label<TAB>source_path<TAB>source_volume_or_empty
  local profile path source_vol label
  profile=$(awk -F'\t' '{print $2}' <<< "$selected")
  path=$(awk -F'\t' '{print $3}' <<< "$selected")
  source_vol=$(awk -F'\t' '{print $4}' <<< "$selected")
  if [[ "$profile" == "home" ]]; then
    label="Home Folder"
  else
    label=$(basename "$source_vol")
  fi
  printf '%s\t%s\t%s\t%s\n' "$profile" "$label" "$path" "$source_vol"
}
```

- [ ] **Step 5: Run tests — expect pass**

```bash
bash tests/test_functions.sh
```

Expected: new tests pass.

- [ ] **Step 6: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: add select_source and filter_out_drive helper"
```

---

## Task 4: Teach `select_drive` to exclude the source volume

**Files:**
- Modify: `mirror.sh` (`select_drive` around line 135-170)

- [ ] **Step 1: Failing test**

Append to `tests/test_functions.sh`:

```bash
echo "=== select_drive accepts exclude-path arg ==="
# Verify the helper integration: filter_out_drive is what select_drive calls.
# The interactive part is tested manually; here we just verify the function signature
# accepts an argument by inspecting the body for "filter_out_drive".
SELECT_DRIVE_BODY=$(type select_drive)
assert_contains "select_drive uses filter_out_drive" "$SELECT_DRIVE_BODY" "filter_out_drive"
```

- [ ] **Step 2: Run tests — expect failure**

```bash
bash tests/test_functions.sh
```

Expected: `select_drive uses filter_out_drive` fails.

- [ ] **Step 3: Update `select_drive` to call `filter_out_drive`**

Replace the body of `select_drive` with:

```bash
select_drive() {
  local exclude_path="${1:-}"

  if ! command -v fzf &>/dev/null; then
    printf '%s✖  fzf is required but not found. Install with: brew install fzf%s\n' "$RED" "$R" >&2
    exit 1
  fi

  local drives
  drives=$(detect_drives)
  drives=$(filter_out_drive "$drives" "$exclude_path")

  if [[ -z "$drives" ]]; then
    printf '%s✖  No external drives available as a destination. Plug in another drive and try again.%s\n' "$RED" "$R" >&2
    exit 1
  fi

  printf '%s▶ Select backup drive:%s\n' "$YELLOW" "$R" >&2
  printf '%s  Use ↑↓ arrow keys or type to filter%s\n\n' "$GRAY" "$R" >&2

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
    | awk -F'\t' '{print $NF}') || true

  if [[ -z "$selected" ]]; then
    printf '%s✖  No drive selected. Exiting.%s\n' "$RED" "$R" >&2
    exit 1
  fi

  echo "$selected"
}
```

- [ ] **Step 4: Run tests — expect pass**

```bash
bash tests/test_functions.sh
```

- [ ] **Step 5: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: select_drive can exclude a source volume"
```

---

## Task 5: Update `run_mirror` for source/profile/log_label

**Files:**
- Modify: `mirror.sh` (`run_mirror` around line 430-528)
- Modify: `tests/test_functions.sh` (run_mirror integration block around line 145+)

- [ ] **Step 1: Update existing integration test to match new signature**

In `tests/test_functions.sh`, find the `=== run_mirror integration ===` block. Replace each `HOME="$TEST_HOME" run_mirror "$TEST_DEST" live` and `... dry` call with the new signature (positional: source, dest, mode, profile, log_label):

```bash
HOME="$TEST_HOME" run_mirror "$TEST_HOME/" "$TEST_DEST" live home "Home Folder" >/dev/null
```

```bash
HOME="$TEST_HOME" run_mirror "$TEST_HOME/" "$TEST_DEST" dry home "Home Folder" >/dev/null
```

```bash
HOME="$TEST_HOME" run_mirror "$TEST_HOME/" "$TEST_VOL/Home Folder Backup" live home "Home Folder" >/dev/null 2>&1
```

- [ ] **Step 2: Add a volume-profile integration test**

Append after the existing `run_mirror integration` block, before the `Results:` line:

```bash
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
```

- [ ] **Step 3: Run tests — expect failure**

```bash
bash tests/test_functions.sh
```

Expected: failures because `run_mirror` still has the old 2-arg signature.

- [ ] **Step 4: Update `run_mirror` signature and body**

Replace the start of `run_mirror`. Change:

```bash
run_mirror() {
  local dest="$1"   # e.g. /Volumes/Disk/Home Folder Backup
  local mode="$2"   # "dry" or "live"

  local volume
  volume=$(dirname "$dest")
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local log_dir="${volume}/Home Folder Logs"
  local source="$HOME/"
```

to:

```bash
run_mirror() {
  local source="$1"     # e.g. "$HOME/" or "/Volumes/MyDisk/"
  local dest="$2"       # e.g. "<vol>/Home Folder Backup" or "<vol>/MyDisk Backup"
  local mode="$3"       # "dry" or "live"
  local profile="${4:-home}"
  local log_label="${5:-Home Folder}"

  local volume
  volume=$(dirname "$dest")
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local log_dir="${volume}/${log_label} Logs"
```

(Note: the old `local source="$HOME/"` line is removed because `source` is now a parameter.)

- [ ] **Step 5: Use the profile when counting and excluding**

In the same function, change:

```bash
  TOTAL_FILES=$(count_source_files "$HOME")
  TOTAL_BYTES=$(count_source_bytes "$HOME")
```

to:

```bash
  TOTAL_FILES=$(count_source_files "$source" "$profile")
  TOTAL_BYTES=$(count_source_bytes "$source" "$profile")
```

And change:

```bash
  while IFS= read -r excl; do
    rsync_args+=("$excl")
  done < <(build_exclude_args)
```

to:

```bash
  while IFS= read -r excl; do
    rsync_args+=("$excl")
  done < <(build_exclude_args "$profile")
```

- [ ] **Step 6: Use the log_label in the progress header**

Change:

```bash
  if [[ "$mode" == "dry" ]]; then
    printf '%s⠸  Dry run — no files will be written%s\n' "$YELLOW" "$R"
  else
    printf '%s⠸  Mirroring home folder…%s\n' "$ORANGE" "$R"
  fi
```

to:

```bash
  if [[ "$mode" == "dry" ]]; then
    printf '%s⠸  Dry run — no files will be written%s\n' "$YELLOW" "$R"
  else
    local pretty="$log_label"
    [[ "$profile" == "home" ]] && pretty="home folder"
    printf '%s⠸  Mirroring %s…%s\n' "$ORANGE" "$pretty" "$R"
  fi
```

- [ ] **Step 7: Run tests — expect pass**

```bash
bash tests/test_functions.sh
```

Expected: home and volume integration tests both pass.

- [ ] **Step 8: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: run_mirror accepts source/profile/log_label"
```

---

## Task 6: Wire up new flow in `main` + rebrand

**Files:**
- Modify: `mirror.sh` (`SCRIPT_NAME`, `VERSION`, `select_run_mode` description, `main`)
- Modify: `tests/test_functions.sh` (header assertion around line 27)

- [ ] **Step 1: Update header test**

Change the existing assertion in `tests/test_functions.sh`:

```bash
assert_contains "header contains script name" "$OUTPUT" "Home Folder Mirror"
```

to:

```bash
assert_contains "header contains script name" "$OUTPUT" "Home / Disk Mirror"
```

And:

```bash
assert_contains "header contains version" "$OUTPUT" "v1.0"
```

to:

```bash
assert_contains "header contains version" "$OUTPUT" "v1.1"
```

- [ ] **Step 2: Run tests — expect failure**

```bash
bash tests/test_functions.sh
```

Expected: header tests fail.

- [ ] **Step 3: Rebrand constants**

In `mirror.sh`, change:

```bash
VERSION="1.0"
SCRIPT_NAME="Home Folder Mirror"
```

to:

```bash
VERSION="1.1"
SCRIPT_NAME="Home / Disk Mirror"
```

- [ ] **Step 4: Update run-mode description**

In `select_run_mode`, change:

```bash
  choice=$(printf "Dry run  — preview changes, nothing is written\nLive run — mirror home folder for real" \
```

to:

```bash
  choice=$(printf "Dry run  — preview changes, nothing is written\nLive run — mirror selected source for real" \
```

- [ ] **Step 5: Rewrite `main` to use the new flow**

Replace the body of `main` with:

```bash
main() {
  trap handle_abort INT

  print_header

  # Stage 1: Source selection
  local source_tuple
  source_tuple=$(select_source)
  local profile label source_path source_vol
  IFS=$'\t' read -r profile label source_path source_vol <<< "$source_tuple"

  printf '%s✔%s  Source: %s%s%s\n\n' "$GREEN" "$R" "$BLUE" "$label" "$R" >&2

  # Stage 2: Destination drive
  local volume
  volume=$(select_drive "$source_vol")
  local dest="${volume}/${label} Backup"

  # Stage 3: Run mode
  local mode
  mode=$(select_run_mode "$dest")

  # Stage 4: Mirror
  MIRROR_EXIT_CODE=0
  run_mirror "$source_path" "$dest" "$mode" "$profile" "$label"

  # Capture --stats block from the log
  local stats_block=""
  if [[ -f "$LOG_FILE" ]]; then
    stats_block=$(grep -A 20 "Number of files:" "$LOG_FILE" 2>/dev/null | tail -20 || true)
  fi

  # Stage 5: Summary
  print_summary "$MIRROR_EXIT_CODE" "$stats_block" "$LOG_FILE"

  if [[ "$MIRROR_EXIT_CODE" -eq 0 || "$MIRROR_EXIT_CODE" -eq 23 ]]; then
    exit 0
  else
    printf '%s✖  rsync exited with error code %s. Check the log for details.%s\n' \
      "$RED" "$MIRROR_EXIT_CODE" "$R"
    exit "$MIRROR_EXIT_CODE"
  fi
}
```

- [ ] **Step 6: Run tests — expect pass**

```bash
bash tests/test_functions.sh
```

- [ ] **Step 7: Manual smoke test (live, dry mode only)**

Plug in two external drives. Run:

```bash
./mirror.sh
```

Verify in order:
- Header reads `Home / Disk Mirror   v1.1`
- Source list shows `Home Folder` first, then attached volumes
- Picking a volume as source filters that volume out of the destination list
- Picking `Home Folder` shows all attached volumes as destinations
- Dry run completes; log appears at `<dest>/<label> Logs/mirror_<ts>.log`

- [ ] **Step 8: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "feat: source selection wizard with rebrand to Home / Disk Mirror v1.1"
```

---

## Task 7: ShellCheck integration

**Files:**
- Modify: `tests/test_functions.sh` (top of file, before existing tests)

- [ ] **Step 1: Add ShellCheck step at the top of the test suite**

Just before the `# Source mirror.sh without running main` line in `tests/test_functions.sh`, add:

```bash
echo "=== shellcheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$(dirname "$0")/../mirror.sh" "$(dirname "$0")/test_functions.sh"; then
    echo "  PASS: shellcheck clean"
    ((++PASS))
  else
    echo "  FAIL: shellcheck reported issues"
    ((++FAIL))
  fi
else
  echo "  SKIP: shellcheck not installed"
fi
```

- [ ] **Step 2: Run tests — observe ShellCheck output**

```bash
bash tests/test_functions.sh
```

Expected: ShellCheck likely reports a handful of warnings on existing code.

- [ ] **Step 3: Fix or suppress each ShellCheck finding**

For each finding:
- If it's a real bug: fix it.
- If it's a false positive (e.g. SC2178 on `local -n` nameref usage, SC2034 on intentionally unused color vars), add a `# shellcheck disable=SCxxxx` directive directly above the offending line with a one-line reason comment.

Common expected suppressions for this codebase:
- `SC2034` on color variables that are exported as part of the palette
- `SC2178` / `SC2155` around `local -n` namerefs in `build_exclude_args`, `count_source_files`, `count_source_bytes`

- [ ] **Step 4: Run tests until ShellCheck passes**

```bash
bash tests/test_functions.sh
```

Expected: all PASS, no ShellCheck FAIL.

- [ ] **Step 5: Commit**

```bash
git add mirror.sh tests/test_functions.sh
git commit -m "test: add shellcheck step and address its findings"
```

---

## Task 8: Rewrite README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `README.md` contents**

Overwrite `README.md` with:

```markdown
# Home / Disk Mirror

A small Bash script (`mirror.sh`) that mirrors a chosen source — your **home folder** or any **mounted external volume** — to another external drive on macOS, with a clean fzf-driven TUI, dry-run mode, per-run logs, and sensible default exclusions.

## Requirements

- macOS (uses built-in `openrsync` and `stat -f`)
- [`fzf`](https://github.com/junegunn/fzf) — `brew install fzf`
- [`shellcheck`](https://www.shellcheck.net) — `brew install shellcheck` (only required to run the test suite)

## Usage

```sh
./mirror.sh
```

Then walk through the four prompts:

1. **Source** — `Home Folder` or any attached external volume
2. **Destination** — any other attached external volume (the source volume is filtered out)
3. **Run mode** — `Dry run` (preview) or `Live run` (real mirror)
4. **Mirror** — progress is shown; a per-run log is written to the destination

## Where things land on the destination drive

```
<destination>/
  <label> Backup/        # mirrored content
  <label> Logs/
    mirror_<YYYYMMDD_HHMMSS>.log
```

Where `<label>` is `Home Folder` for the home profile, or the source volume's name for the volume profile. Logs older than 30 days are pruned automatically.

## Exclusions

Two disjoint built-in lists, applied based on the source profile:

- **Home folder profile** — ~50 macOS-specific paths (iCloud sync, caches, sandboxed app data, system metadata, Trash, etc.)
- **Volume profile** — five macOS volume metadata folders (`.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`, `.TemporaryItems`)

Lists live at the top of `mirror.sh` (`HOME_EXCLUDES`, `VOLUME_EXCLUDES`).

## Tests

```sh
bash tests/test_functions.sh
```

Runs ShellCheck (if installed), unit tests for pure helpers, and integration tests that exercise `run_mirror` end-to-end against synthetic source/destination directories under `mktemp -d`.

## Status

Personal tool. Single-file script, no install required beyond `chmod +x mirror.sh`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for Home / Disk Mirror"
```

---

## Self-Review Notes

**Spec coverage:**
- Source profile fields (path, exclusions, dest, log dir, header) → Tasks 1, 2, 5
- Two disjoint exclusion arrays → Task 1
- `select_source` and source list ordering → Task 3
- Source-volume filtered from destination → Tasks 3 + 4
- Rebrand to `Home / Disk Mirror` v1.1 → Task 6
- `select_run_mode` description update → Task 6
- ShellCheck integration → Task 7
- README rewrite → Task 8
- Tests for: select_source defined, build_exclude_args per profile, exclusion arrays disjoint, count_source_files volume profile, run_mirror volume integration, select_drive uses filter helper, ShellCheck step → all covered

**Placeholder scan:** clean.

**Type/name consistency:** `HOME_EXCLUDES`, `VOLUME_EXCLUDES`, `select_source`, `filter_out_drive`, `run_mirror(source, dest, mode, profile, log_label)` used consistently across tasks.
