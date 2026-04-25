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

# Runtime state (set by run_mirror before processing begins)
TRANSFER_COUNT=0
ERROR_COUNT=0
TOTAL_FILES=0
LOG_FILE=""
MIRROR_EXIT_CODE=0

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
    printf '%s✖  fzf is required but not found. Install with: brew install fzf%s\n' "$RED" "$R"
    exit 1
  fi

  local drives
  drives=$(detect_drives)

  if [[ -z "$drives" ]]; then
    printf '%s✖  No external drives found. Plug in a backup drive and try again.%s\n' "$RED" "$R"
    exit 1
  fi

  printf '%s▶ Select backup drive:%s\n' "$YELLOW" "$R"
  printf '%s  Use ↑↓ arrow keys or type to filter%s\n\n' "$GRAY" "$R"

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
    printf '%s✖  No drive selected. Exiting.%s\n' "$RED" "$R"
    exit 1
  fi

  echo "$selected"
}

select_run_mode() {
  local dest="$1"
  printf "\n${GREEN}✔${R}  Destination: ${BLUE}%s${R}\n\n" "$dest"
  printf '%s▶ Run mode:%s\n\n' "$YELLOW" "$R"

  local choice
  choice=$(printf "Dry run  — preview changes, nothing is written\nLive run — mirror home folder for real" \
    | fzf --ansi \
          --height=20% \
          --border=none \
          --prompt="  " \
          --pointer="❯" \
          --color="pointer:#55efc4") || true

  if [[ -z "$choice" ]]; then
    printf '%s✖  No mode selected. Exiting.%s\n' "$RED" "$R"
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
  local filled empty bar pct
  if [[ $TOTAL_FILES -gt 0 ]]; then
    pct=$(( TRANSFER_COUNT * 100 / TOTAL_FILES ))
    filled=$(( pct * 20 / 100 ))
    empty=$(( 20 - filled ))
    bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf '\r  %s  %d%%  (%d/%d files)  ' "$bar" "$pct" "$TRANSFER_COUNT" "$TOTAL_FILES" > /dev/tty 2>/dev/null || true
  else
    printf '\r  Files transferred: %d  ' "$TRANSFER_COUNT" > /dev/tty 2>/dev/null || true
  fi
}

process_output_line() {
  local line="$1"

  # Guard against empty LOG_FILE
  [[ -n "$LOG_FILE" ]] || return

  # Always write raw line to log
  printf '%s\n' "$line" >> "$LOG_FILE"

  # Detect file-transfer completion: rsync --progress lines contain "100%"
  if [[ "$line" =~ ^[[:space:]]+[0-9,]+[[:space:]]+100%([[:space:]]|$) ]]; then
    ((++TRANSFER_COUNT)) || true
    _update_progress
    return
  fi

  # Detect rsync errors
  if [[ "$line" =~ ^"rsync: " || "$line" =~ ^"rsync error" ]]; then
    ((++ERROR_COUNT)) || true
    printf '\n%s⚠  Error:%s %s %s(logged)%s\n' "$RED" "$R" "$line" "$GRAY" "$R"
    return
  fi

  # Print file paths being processed (lines starting with a non-space, non-rsync-keyword char)
  if [[ "$line" =~ ^[^[:space:]] && ! "$line" =~ ^(sending|receiving|building|deleting|rsync|[Tt]otal|Number|File|Literal|Matched|sent|rcvd|bytes|speedup|created|cannot|IO[[:space:]]|link_stat) ]]; then
    printf '  %s%s%s\n' "$GRAY" "$line" "$R"
  fi
}
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
