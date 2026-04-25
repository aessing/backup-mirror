#!/usr/bin/env bash
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
VERSION="1.0"
SCRIPT_NAME="Home Folder Mirror"
START_TIME=$(date +%s)

# Colors
R=$'\033[0m'
ORANGE=$'\033[38;5;208m'
BLUE=$'\033[0;34m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RED=$'\033[0;31m'
GRAY=$'\033[0;90m'
BOLD=$'\033[1m'

# Exclusions (relative to ~/)
EXCLUDES=(
  # iCloud / cloud sync
  "Library/Mobile Documents/"
  "Library/CloudStorage/"
  # Caches & build artefacts
  "Library/Caches/"
  "Library/Logs/"
  "Library/Saved Application State/"
  "Library/Developer/"
  ".cache/"
  ".npm/"
  ".nvm/"
  ".kube/cache/"
  # Apple sandboxed app data (unreadable without per-app entitlements)
  "Library/Containers/"
  "Library/Group Containers/"
  # Apple system data (not useful in a personal backup)
  "Library/Application Support/CrashReporter/"
  "Library/Application Support/MobileSync/"
  "Library/Application Support/com.apple.sharedfilelist/"
  "Library/Biome/"
  "Library/CoreFollowUp/"
  "Library/DuetExpertCenter/"
  "Library/IntelligencePlatform/"
  "Library/Daemon Containers/"
  "Library/ContainerManager/"
  "Library/PersonalizationPortrait/"
  "Library/Metadata/CoreSpotlight/"
  "Library/Trial/"
  "Library/StatusKit/"
  # Games
  "Library/Application Support/Steam/steamapps/"
  # Trash
  ".Trash/"
)

# Runtime state (set by run_mirror before processing begins)
TRANSFER_COUNT=0
ERROR_COUNT=0
TOTAL_FILES=0
LOG_FILE=""
MIRROR_EXIT_CODE=0
COUNT_FILE=""   # temp file written by background file-count job
COUNT_PID=0

# ── Helpers ───────────────────────────────────────────────────────────────────
sep() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 60)
  printf "${ORANGE}"
  printf '─%.0s' $(seq 1 "$cols")
  printf "${R}\n"
}

print_header() {
  local title="  ${SCRIPT_NAME}   v${VERSION}  "
  local len=${#title}
  local top="┌$(printf '─%.0s' $(seq 1 $len))┐"
  local mid="│${title}│"
  local bot="└$(printf '─%.0s' $(seq 1 $len))┘"
  printf "\n${ORANGE}%s\n%s\n%s${R}\n\n" "$top" "$mid" "$bot"
}

# ── Placeholder stubs (implemented in later tasks) ────────────────────────────
detect_drives() {
  local vol name total free
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

select_drive() {
  if ! command -v fzf &>/dev/null; then
    printf '%s✖  fzf is required but not found. Install with: brew install fzf%s\n' "$RED" "$R" >&2
    exit 1
  fi

  local drives
  drives=$(detect_drives)

  if [[ -z "$drives" ]]; then
    printf '%s✖  No external drives found. Plug in a backup drive and try again.%s\n' "$RED" "$R" >&2
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

select_run_mode() {
  local dest="$1"
  printf "\n${GREEN}✔${R}  Destination: ${BLUE}%s${R}\n\n" "$dest" >&2
  printf '%s▶ Run mode:%s\n\n' "$YELLOW" "$R" >&2

  local choice
  choice=$(printf "Dry run  — preview changes, nothing is written\nLive run — mirror home folder for real" \
    | fzf --ansi \
          --height=20% \
          --border=none \
          --prompt="  " \
          --pointer="❯" \
          --color="pointer:#55efc4") || true

  if [[ -z "$choice" ]]; then
    printf '%s✖  No mode selected. Exiting.%s\n' "$RED" "$R" >&2
    exit 1
  fi

  if [[ "$choice" == Dry* ]]; then
    echo "dry"
  else
    echo "live"
  fi
}

build_exclude_args() {
  for path in "${EXCLUDES[@]}"; do
    printf '%s\n' "--exclude=${path%/}"
  done
}
count_source_files() {
  local source_dir="${1:-$HOME}"

  local find_args=("$source_dir" -xdev)
  for path in "${EXCLUDES[@]}"; do
    find_args+=(-path "${source_dir}/${path%/}" -prune -o)
  done
  find_args+=(-type f -print)

  local tmpfile
  tmpfile=$(mktemp) || { echo 0; return; }

  find "${find_args[@]}" 2>/dev/null | wc -l | tr -d ' ' > "$tmpfile" &
  local pipe_pid=$!  # PID of tr (last in pipeline); killing it cascades SIGPIPE to wc and find

  local waited=0
  while kill -0 "$pipe_pid" 2>/dev/null && [[ $waited -lt 3 ]]; do
    sleep 1
    ((++waited)) || true
  done

  if kill -0 "$pipe_pid" 2>/dev/null; then
    kill "$pipe_pid" 2>/dev/null || true
    wait "$pipe_pid" 2>/dev/null || true
    rm -f "$tmpfile"
    echo 0
    return
  fi

  wait "$pipe_pid" 2>/dev/null || true
  local count
  count=$(cat "$tmpfile" 2>/dev/null | tr -d ' \n' || echo 0)
  rm -f "$tmpfile"
  echo "${count:-0}"
}
_update_progress() {
  # Pick up async count result as soon as it lands
  if [[ $TOTAL_FILES -eq 0 && -n "${COUNT_FILE:-}" && -s "${COUNT_FILE:-}" ]]; then
    TOTAL_FILES=$(tr -d ' \n' < "$COUNT_FILE" 2>/dev/null || echo 0)
  fi

  local filled empty bar pct
  if [[ $TOTAL_FILES -gt 0 ]]; then
    pct=$(( TRANSFER_COUNT * 100 / TOTAL_FILES ))
    filled=$(( pct * 20 / 100 ))
    empty=$(( 20 - filled ))
    bar="${ORANGE}"
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    bar+="${GRAY}"
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    bar+="${R}"
    [[ -w /dev/tty ]] && printf '\r  %s  %d%%  (%d/%d files)  ' "$bar" "$pct" "$TRANSFER_COUNT" "$TOTAL_FILES" > /dev/tty 2>/dev/null || :
  else
    [[ -w /dev/tty ]] && printf '\r  %s%d files transferred%s  ' "$GRAY" "$TRANSFER_COUNT" "$R" > /dev/tty 2>/dev/null || :
  fi
} 2>/dev/null

process_output_line() {
  local line="$1"
  [[ -n "$LOG_FILE" ]] || return

  # File-transfer completion: rsync --progress "100%" line → update progress bar only
  if [[ "$line" =~ ^[[:space:]]+[0-9,]+[[:space:]]+100%([[:space:]]|$) ]]; then
    ((++TRANSFER_COUNT)) || true
    _update_progress
    return
  fi

  # Warnings and errors (rsync(PID): warning/error: … or old-style rsync: …)
  if [[ "$line" =~ ^rsync\([0-9]+\): ]] || [[ "$line" =~ ^"rsync: " ]] || [[ "$line" =~ ^"rsync error" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
    ((++ERROR_COUNT)) || true
    printf '\n%s⚠  %s%s %s(logged)%s\n' "$RED" "$line" "$R" "$GRAY" "$R"
    return
  fi

  # Stats block lines (needed for summary parsing): log only, don't display
  if [[ "$line" =~ ^(Number\ of|Total\ file|Total\ transferred|Literal\ data|Matched\ data|File\ list|sent\ [0-9]|total\ size) ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
    return
  fi

  # Everything else (file paths, per-file progress details): discard
}
run_mirror() {
  local dest="$1"   # e.g. /Volumes/Disk/Home Folder Backup
  local mode="$2"   # "dry" or "live"

  local volume
  volume=$(dirname "$dest")
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local log_dir="${volume}/Home Mirror Logs"
  local source="$HOME/"

  # Ensure destination and log directory exist
  if ! mkdir -p "$dest" "$log_dir" 2>/dev/null; then
    printf '%s✖  Cannot create destination: %s%s\n' "$RED" "$dest" "$R"
    exit 1
  fi

  LOG_FILE="${log_dir}/mirror_${timestamp}.log"

  # Purge log files older than 30 days
  find "$log_dir" -maxdepth 1 -name 'mirror_*.log' -mtime +30 -delete 2>/dev/null || true

  # Start file count in background (result read lazily by _update_progress)
  TOTAL_FILES=0
  COUNT_FILE=$(mktemp) || COUNT_FILE=""
  if [[ -n "$COUNT_FILE" ]]; then
    (count_source_files "$HOME" > "$COUNT_FILE") &
    COUNT_PID=$!
  fi

  # Write log header
  {
    printf '\n════════════════════════════════════════════\n'
    printf 'Run started:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Mode:         %s\n' "$mode"
    printf 'Destination:  %s\n' "$dest"
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
  printf '\n'
  sep
  if [[ "$mode" == "dry" ]]; then
    printf '%s⠸  Dry run — no files will be written%s\n' "$YELLOW" "$R"
  else
    printf '%s⠸  Mirroring home folder…%s\n' "$BLUE" "$R"
  fi
  sep
  printf '\n'

  # Run rsync, process output line by line
  TRANSFER_COUNT=0
  ERROR_COUNT=0
  local tmprc
  tmprc=$(mktemp) || { MIRROR_EXIT_CODE=0; return; }
  while IFS= read -r line; do
    process_output_line "$line"
  done < <(set +e; rsync "${rsync_args[@]}" 2>&1; echo $? > "$tmprc")
  MIRROR_EXIT_CODE=$(cat "$tmprc" 2>/dev/null || echo 0)
  rm -f "$tmprc"

  printf '\n\n'  # newline after progress bar

  # Collect async file count (kill if still running, grab result if done)
  if [[ -n "${COUNT_FILE:-}" ]]; then
    kill "${COUNT_PID:-0}" 2>/dev/null || true
    wait "${COUNT_PID:-0}" 2>/dev/null || true
    [[ $TOTAL_FILES -eq 0 ]] && TOTAL_FILES=$(tr -d ' \n' < "$COUNT_FILE" 2>/dev/null || echo 0)
    rm -f "$COUNT_FILE"
  fi

  # Write log footer
  local end_time
  end_time=$(date +%s)
  local duration=$(( end_time - START_TIME ))
  {
    printf '\n────────────────────────────────────────────\n'
    printf 'Run ended:    %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Exit code:    %s\n' "$MIRROR_EXIT_CODE"
    printf 'Duration:     %ds\n' "$duration"
    printf 'Source files: %s\n' "$TOTAL_FILES"
    printf 'Transferred:  %s files\n' "$TRANSFER_COUNT"
    printf 'Errors:       %s\n' "$ERROR_COUNT"
    printf '════════════════════════════════════════════\n'
  } >> "$LOG_FILE"
}
parse_stats() {
  local stats_block="$1"
  local transferred deleted total_size

  transferred=$(printf '%s' "$stats_block" | grep "Number of regular files transferred:" \
    | grep -oE '[0-9,]+' | head -1)
  deleted=$(printf '%s' "$stats_block" | grep "Number of deleted files:" \
    | grep -oE '[0-9,]+' | head -1)
  total_size=$(printf '%s' "$stats_block" | grep "Total transferred file size:" \
    | grep -oE '[0-9,]+' | head -1)

  printf '%s|%s|%s' \
    "${transferred:-0}" \
    "${deleted:-0}" \
    "${total_size:-0}"
}

print_summary() {
  local rsync_exit="$1"
  local stats_block="$2"
  local log_path="$3"

  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - START_TIME ))
  local duration_str
  if (( elapsed >= 60 )); then
    duration_str="$(( elapsed / 60 ))m $(( elapsed % 60 ))s"
  else
    duration_str="${elapsed}s"
  fi

  local transferred deleted total_size
  IFS='|' read -r transferred deleted total_size <<< "$(parse_stats "$stats_block")"

  printf '\n'
  sep

  if [[ "$rsync_exit" -eq 0 || "$rsync_exit" -eq 23 ]]; then
    printf '%s%s✔  Mirror complete%s   %s%s%s\n' "$GREEN" "$BOLD" "$R" "$GRAY" "$(date '+%Y-%m-%d %H:%M:%S')" "$R"
  else
    printf '%s%s✖  Mirror failed (exit %s)%s   %s%s%s\n' "$RED" "$BOLD" "$rsync_exit" "$R" "$GRAY" "$(date '+%Y-%m-%d %H:%M:%S')" "$R"
  fi

  sep
  printf '\n'

  printf '  %s%-22s%s%s\n' "$GRAY" "Files transferred:" "$R" "$transferred"
  printf '  %s%-22s%s%s\n' "$GRAY" "Files deleted:"    "$R" "$deleted"
  printf '  %s%-22s%s%s bytes\n' "$GRAY" "Total size:"  "$R" "$total_size"
  printf '  %s%-22s%s%s\n' "$GRAY" "Duration:"         "$R" "$duration_str"

  if [[ ${ERROR_COUNT:-0} -gt 0 ]]; then
    printf '  %s%-22s%s%s%s  →  see log%s\n' "$GRAY" "Errors:" "$R" "$RED" "${ERROR_COUNT:-0}" "$R"
  else
    printf '  %s%-22s%s%snone%s\n' "$GRAY" "Errors:" "$R" "$GREEN" "$R"
  fi

  printf '\n  %sLog: %s%s\n\n' "$GRAY" "$log_path" "$R"
}
handle_abort() {
  printf '\n\n%s⚠  Mirror aborted by user.%s\n' "$YELLOW" "$R"
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
  MIRROR_EXIT_CODE=0
  run_mirror "$dest" "$mode"

  # Capture --stats block from the log
  local stats_block=""
  if [[ -f "$LOG_FILE" ]]; then
    stats_block=$(grep -A 20 "Number of files:" "$LOG_FILE" 2>/dev/null | tail -20 || true)
  fi

  # Stage 4: Summary
  print_summary "$MIRROR_EXIT_CODE" "$stats_block" "$LOG_FILE"

  # Exit with rsync code unless it's 23 (partial transfer = warning only)
  if [[ "$MIRROR_EXIT_CODE" -eq 0 || "$MIRROR_EXIT_CODE" -eq 23 ]]; then
    exit 0
  else
    printf '%s✖  rsync exited with error code %s. Check mirror.log for details.%s\n' \
      "$RED" "$MIRROR_EXIT_CODE" "$R"
    exit "$MIRROR_EXIT_CODE"
  fi
}

# Guard: don't run main when sourced for testing
[[ "${MIRROR_TEST_MODE:-0}" == "1" ]] || main "$@"
