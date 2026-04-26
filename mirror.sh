#!/usr/bin/env bash
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
VERSION="1.1"
SCRIPT_NAME="Home / Disk Mirror"
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

# Home folder exclusions (relative to ~/)
# shellcheck disable=SC2034  # consumed via eval indirection in build_exclude_args / count_source_*
HOME_EXCLUDES=(
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
  ".local/share/uv/"
  ".zcompcache/"
  ".zsh_sessions/"
  ".thumbnails/"
  ".android/"
  # VS Code / Copilot / tool binaries (reinstallable)
  ".vscode/extensions/"
  ".copilot/pkg/"
  ".tldrc/tldr/"
  # Container storage (Podman images & volumes)
  ".local/share/containers/"
  # Apple sandboxed app data (unreadable without per-app entitlements)
  "Library/Containers/"
  "Library/Group Containers/"
  # Apple system data (not useful in a personal backup)
  "Library/Application Support/CrashReporter/"
  "Library/Application Support/MobileSync/"
  "Library/Application Support/com.apple.sharedfilelist/"
  "Library/Application Support/CallHistoryTransactions/"
  "Library/Application Support/CloudDocs/"
  "Library/Application Support/Knowledge/"
  "Library/Application Support/com.apple.TCC/"
  "Library/Application Support/FileProvider/"
  "Library/Application Support/FaceTime/"
  "Library/Application Support/DifferentialPrivacy/"
  "Library/Application Support/CallHistoryDB/"
  "Library/Application Support/com.apple.avfoundation/"
  "Library/Assistant/"
  "Library/Autosave Information/"
  "Library/IdentityServices/"
  "Library/AppleMediaServices/"
  "Library/Accounts/"
  "Library/Safari/"
  "Library/Shortcuts/"
  "Library/Suggestions/"
  "Library/Weather/"
  "Library/Cookies/"
  "Library/DoNotDisturb/"
  "Library/Sharing/"
  "Library/com.apple.aiml.instrumentation/"
  "Library/com.apple.bluetooth.services.cloud/"
  "Library/Metadata/CoreSpotlight/"
  "Library/Metadata/com.apple.IntelligentSuggestions/"
  "Library/Biome/"
  "Library/CoreFollowUp/"
  "Library/DuetExpertCenter/"
  "Library/IntelligencePlatform/"
  "Library/Daemon Containers/"
  "Library/ContainerManager/"
  "Library/PersonalizationPortrait/"
  "Library/Trial/"
  "Library/StatusKit/"
  # Games
  "Library/Application Support/Steam/steamapps/"
  # Trash
  ".Trash/"
)

# External-volume exclusions (macOS volume metadata, auto-regenerated)
# shellcheck disable=SC2034  # consumed via eval indirection in build_exclude_args / count_source_*
VOLUME_EXCLUDES=(
  ".Spotlight-V100/"
  ".Trashes/"
  ".fseventsd/"
  ".DocumentRevisions-V100/"
  ".TemporaryItems/"
)

# Runtime state (set by run_mirror before processing begins)
TRANSFER_COUNT=0
ERROR_COUNT=0
DELETE_COUNT=0
TOTAL_FILES=0
TOTAL_BYTES=0
TRANSFERRED_BYTES=0
CURRENT_FILE_BYTES=0
LOG_FILE=""
MIRROR_EXIT_CODE=0

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
  local top mid bot
  top="┌$(printf '─%.0s' $(seq 1 "$len"))┐"
  mid="│${title}│"
  bot="└$(printf '─%.0s' $(seq 1 "$len"))┘"
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

filter_out_drive() {
  local drives="$1"
  local exclude_path="$2"
  if [[ -z "$exclude_path" ]]; then
    printf '%s' "$drives"
    return
  fi
  printf '%s' "$drives" | awk -F'\t' -v exc="$exclude_path" '$2 != exc { print }'
}

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

render_run_mode_selection() {
  local mode="$1"
  case "$mode" in
    dry)
      printf '%s✔%s  Run mode: %sDry run%s — preview changes, nothing is written\n' "$GREEN" "$R" "$YELLOW" "$R"
      ;;
    live)
      printf '%s✔%s  Run mode: %sLive run%s — mirror home folder for real\n' "$GREEN" "$R" "$ORANGE" "$R"
      ;;
  esac
}

select_run_mode() {
  local dest="$1"
  printf "\n${GREEN}✔${R}  Destination: ${BLUE}%s${R}\n\n" "$dest" >&2
  printf '%s▶ Run mode:%s\n\n' "$YELLOW" "$R" >&2

  local choice
  choice=$(printf "Dry run  — preview changes, nothing is written\nLive run — mirror selected source for real" \
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
    render_run_mode_selection "dry" >&2
    echo "dry"
  else
    render_run_mode_selection "live" >&2
    echo "live"
  fi
}

build_exclude_args() {
  local profile="${1:-home}"
  local arr_name
  case "$profile" in
    home)   arr_name=HOME_EXCLUDES ;;
    volume) arr_name=VOLUME_EXCLUDES ;;
    *)      printf '%s✖  Unknown profile: %s%s\n' "$RED" "$profile" "$R" >&2; return 1 ;;
  esac
  # bash 3.2 (macOS system bash) has no namerefs; eval is used for safe array indirection.
  local path
  eval 'for path in "${'"$arr_name"'[@]}"; do
    printf "%s\n" "--exclude=${path%/}"
  done'
}

physical_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd -P "$path" && pwd)
  else
    local parent base
    parent=$(dirname "$path")
    base=$(basename "$path")
    (cd -P "$parent" && printf '%s/%s\n' "$(pwd)" "$base")
  fi
}

trim_trailing_slashes() {
  local path="$1"
  while [[ "$path" != "/" && "$path" == */ ]]; do
    path="${path%/}"
  done
  printf '%s' "${path:-/}"
}

path_has_symlink_component() {
  local base="$1"
  local path="$2"
  local relative current part

  [[ "$path" == "$base" ]] && return 1
  relative="${path#"$base"/}"
  current="$base"

  while [[ -n "$relative" ]]; do
    if [[ "$relative" == */* ]]; then
      part="${relative%%/*}"
      relative="${relative#*/}"
    else
      part="$relative"
      relative=""
    fi

    [[ -z "$part" || "$part" == "." ]] && continue
    current="${current%/}/$part"
    [[ -L "$current" ]] && return 0
    [[ -e "$current" ]] || break
  done

  return 1
}

validate_destination() {
  local dest="$1"
  local volume="$2"
  local kind="${3:-destination}"

  local clean_volume clean_dest relative
  clean_volume=$(trim_trailing_slashes "$volume")
  clean_dest=$(trim_trailing_slashes "$dest")

  if [[ "$clean_volume" == "/" ]]; then
    if [[ "$clean_dest" != /* ]]; then
      printf '%s✖  Refusing %s outside selected volume: %s%s\n' "$RED" "$kind" "$dest" "$R" >&2
      return 1
    fi
  elif [[ "$clean_dest" != "$clean_volume" && "$clean_dest" != "$clean_volume"/* ]]; then
    printf '%s✖  Refusing %s outside selected volume: %s%s\n' "$RED" "$kind" "$dest" "$R" >&2
    return 1
  fi

  relative=""
  if [[ "$clean_dest" != "$clean_volume" ]]; then
    relative="${clean_dest#"$clean_volume"/}"
  fi
  case "$relative" in
    ..|../*|*/../*|*/..)
      printf '%s✖  Refusing %s with parent-directory reference: %s%s\n' "$RED" "$kind" "$dest" "$R" >&2
      return 1
      ;;
  esac

  if path_has_symlink_component "$clean_volume" "$clean_dest"; then
    printf '%s✖  Refusing symlink %s: %s%s\n' "$RED" "$kind" "$dest" "$R" >&2
    return 1
  fi

  if ! mkdir -p "$dest" 2>/dev/null; then
    printf '%s✖  Cannot create %s: %s%s\n' "$RED" "$kind" "$dest" "$R" >&2
    return 1
  fi

  local real_volume real_dest
  real_volume=$(physical_path "$volume") || return 1
  real_dest=$(physical_path "$dest") || return 1

  if [[ "$real_dest" != "$real_volume"/* ]]; then
    printf '%s✖  %s resolves outside selected volume: %s%s\n' "$RED" "$kind" "$dest" "$R" >&2
    return 1
  fi
}

count_source_files() {
  local source_dir="${1:-$HOME}"
  local profile="${2:-home}"
  local arr_name
  case "$profile" in
    home)   arr_name=HOME_EXCLUDES ;;
    volume) arr_name=VOLUME_EXCLUDES ;;
    *)      arr_name=HOME_EXCLUDES ;;
  esac

  local find_args=("$source_dir" -xdev)
  local prune_base
  # shellcheck disable=SC2034  # referenced inside eval below for bash 3.2 array indirection
  prune_base=$(trim_trailing_slashes "$source_dir")
  local path
  # bash 3.2 — eval for array indirection (see build_exclude_args).
  eval 'for path in "${'"$arr_name"'[@]}"; do
    if [[ "$prune_base" == "/" ]]; then
      find_args+=(-path "/${path%/}" -prune -o)
    else
      find_args+=(-path "${prune_base}/${path%/}" -prune -o)
    fi
  done'
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

count_source_bytes() {
  local source_dir="${1:-$HOME}"
  local profile="${2:-home}"
  local arr_name
  case "$profile" in
    home)   arr_name=HOME_EXCLUDES ;;
    volume) arr_name=VOLUME_EXCLUDES ;;
    *)      arr_name=HOME_EXCLUDES ;;
  esac

  local find_args=("$source_dir" -xdev)
  local prune_base
  # shellcheck disable=SC2034  # referenced inside eval below for bash 3.2 array indirection
  prune_base=$(trim_trailing_slashes "$source_dir")
  local path
  # bash 3.2 — eval for array indirection (see build_exclude_args).
  eval 'for path in "${'"$arr_name"'[@]}"; do
    if [[ "$prune_base" == "/" ]]; then
      find_args+=(-path "/${path%/}" -prune -o)
    else
      find_args+=(-path "${prune_base}/${path%/}" -prune -o)
    fi
  done'
  find_args+=(-type f -print0)

  local tmpfile
  tmpfile=$(mktemp) || { echo 0; return; }

  find "${find_args[@]}" 2>/dev/null \
    | while IFS= read -r -d '' file; do
        stat -f %z "$file" 2>/dev/null || stat -c %s "$file" 2>/dev/null || echo 0
      done \
    | awk '{sum += $1} END {printf "%.0f\n", sum}' > "$tmpfile" &
  local pipe_pid=$!

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

human_bytes() {
  local bytes="${1:-0}"
  awk -v bytes="$bytes" '
    BEGIN {
      split("B KB MB GB TB", units, " ")
      value = bytes + 0
      unit = 1
      while (value >= 1000 && unit < 5) {
        value /= 1000
        unit++
      }
      if (unit == 1) {
        printf "%d %s", value, units[unit]
      } else {
        printf "%.1f %s", value, units[unit]
      }
    }
  '
}

build_progress_bar() {
  local pct="$1"
  local filled empty bar
  filled=$(( pct * 20 / 100 ))
  empty=$(( 20 - filled ))
  bar="${ORANGE}"
  local i
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  bar+="${GRAY}"
  for (( i=0; i<empty;  i++ )); do bar+="░"; done
  bar+="${R}"
  printf '%s' "$bar"
}

build_activity_bar() {
  printf '%s' "${ORANGE}█████${GRAY}░░░░░░░░░░░░░░░${R}"
}

render_progress_line() {
  local pct shown_bytes
  if [[ $TOTAL_BYTES -gt 0 ]]; then
    shown_bytes=$(( TRANSFERRED_BYTES + CURRENT_FILE_BYTES ))
    [[ $shown_bytes -gt $TOTAL_BYTES ]] && shown_bytes=$TOTAL_BYTES
    pct=$(( shown_bytes * 100 / TOTAL_BYTES ))
    printf '%s  %d%%  (%s/%s)' "$(build_progress_bar "$pct")" "$pct" "$(human_bytes "$shown_bytes")" "$(human_bytes "$TOTAL_BYTES")"
  elif [[ $TOTAL_FILES -gt 0 ]]; then
    pct=$(( TRANSFER_COUNT * 100 / TOTAL_FILES ))
    printf '%s  %d%%  (%d/%d files)' "$(build_progress_bar "$pct")" "$pct" "$TRANSFER_COUNT" "$TOTAL_FILES"
  else
    printf '%s  %d files transferred  (total unavailable)' "$(build_activity_bar)" "$TRANSFER_COUNT"
  fi
}

_update_progress() {
  [[ -w /dev/tty ]] && printf '\r  %s  ' "$(render_progress_line)" > /dev/tty 2>/dev/null || :
} 2>/dev/null

render_error_block() {
  local line="$1"
  printf '\r\033[K%s⚠  %s%s %s(logged)%s\n\n' "$RED" "$line" "$R" "$GRAY" "$R"
}

process_output_line() {
  local line="$1"
  [[ -n "$LOG_FILE" ]] || return

  printf '%s\n' "$line" >> "$LOG_FILE"

  if [[ "$line" =~ ^[[:space:]]+([0-9,]+)[[:space:]]+([0-9]+)%([[:space:]]|$) ]]; then
    local progress_bytes progress_pct
    progress_bytes="${BASH_REMATCH[1]//,/}"
    progress_pct="${BASH_REMATCH[2]}"

    if [[ "$progress_pct" == "100" ]]; then
      TRANSFERRED_BYTES=$(( TRANSFERRED_BYTES + progress_bytes ))
      CURRENT_FILE_BYTES=0
      ((++TRANSFER_COUNT)) || true
    else
      CURRENT_FILE_BYTES=$progress_bytes
    fi

    _update_progress
    return
  fi

  if [[ "$line" == deleting\ * ]]; then
    ((++DELETE_COUNT)) || true
    return
  fi

  # Warnings and errors (rsync(PID): warning/error: … or old-style rsync: …)
  if [[ "$line" =~ ^rsync\([0-9]+\): ]] || [[ "$line" =~ ^"rsync: " ]] || [[ "$line" =~ ^"rsync error" ]]; then
    ((++ERROR_COUNT)) || true
    render_error_block "$line"
    _update_progress
    return
  fi

  # Everything else (file paths, per-file progress details): discard
}
run_mirror() {
  local source="$1"     # e.g. "$HOME/" or "/Volumes/MyDisk/"
  local dest="$2"       # e.g. "<vol>/Home Folder Backup" or "<vol>/MyDisk Backup"
  local mode="$3"       # "dry" or "live"
  local profile="${4:-home}"
  local log_label="${5:-Home Folder}"

  MIRROR_EXIT_CODE=0
  LOG_FILE=""

  local volume
  volume=$(dirname "$dest")
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local log_dir="${volume}/${log_label} Logs"

  if ! validate_destination "$dest" "$volume"; then
    MIRROR_EXIT_CODE=1
    return 1
  fi

  if ! validate_destination "$log_dir" "$volume" "log directory"; then
    MIRROR_EXIT_CODE=1
    return 1
  fi

  LOG_FILE="${log_dir}/mirror_${timestamp}.log"
  find "$log_dir" -maxdepth 1 -name 'mirror_*.log' -mtime +30 -delete 2>/dev/null || true

  TOTAL_FILES=$(count_source_files "$source" "$profile")
  TOTAL_BYTES=$(count_source_bytes "$source" "$profile")

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
    --no-specials
    --delete
    --human-readable
    --verbose
    --progress
    --stats
  )
  [[ "$mode" == "dry" ]] && rsync_args+=(--dry-run)

  # Add exclusions
  while IFS= read -r excl; do
    rsync_args+=("$excl")
  done < <(build_exclude_args "$profile")

  rsync_args+=("$source" "$dest/")

  # Print progress header
  printf '\n'
  sep
  if [[ "$mode" == "dry" ]]; then
    printf '%s⠸  Dry run — no files will be written%s\n' "$YELLOW" "$R"
  else
    local pretty="$log_label"
    [[ "$profile" == "home" ]] && pretty="home folder"
    printf '%s⠸  Mirroring %s…%s\n' "$ORANGE" "$pretty" "$R"
  fi
  sep
  printf '\n'

  # Run rsync, process output line by line
  TRANSFER_COUNT=0
  TRANSFERRED_BYTES=0
  CURRENT_FILE_BYTES=0
  ERROR_COUNT=0
  DELETE_COUNT=0
  local tmprc
  if ! tmprc=$(mktemp); then
    MIRROR_EXIT_CODE=1
    printf '%s✖  Cannot create temporary rsync status file.%s\n' "$RED" "$R" >&2
    printf '\nInternal error: cannot create temporary rsync status file.\n' >> "$LOG_FILE" 2>/dev/null || true
    return 1
  fi
  while IFS= read -r line; do
    process_output_line "$line"
  done < <(set +e; rsync "${rsync_args[@]}" 2>&1; echo $? > "$tmprc")
  MIRROR_EXIT_CODE=$(cat "$tmprc" 2>/dev/null || echo 0)
  rm -f "$tmprc"

  printf '\n\n'  # newline after progress bar

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
    printf 'Source bytes: %s\n' "$TOTAL_BYTES"
    printf 'Transferred:  %s files\n' "$TRANSFER_COUNT"
    printf 'Transferred:  %s bytes\n' "$TRANSFERRED_BYTES"
    printf 'Deleted:      %s files\n' "$DELETE_COUNT"
    printf 'Errors:       %s\n' "$ERROR_COUNT"
    printf '════════════════════════════════════════════\n'
  } >> "$LOG_FILE"

  return "$MIRROR_EXIT_CODE"
}
parse_stats() {
  local stats_block="$1"
  local transferred deleted total_size

  transferred=$(printf '%s' "$stats_block" | grep -E "Number of (regular )?files transferred:" \
    | grep -oE '[0-9,]+' | head -1)
  deleted=$(printf '%s' "$stats_block" | grep "Number of deleted files:" \
    | grep -oE '[0-9,]+' | head -1)
  total_size=$(printf '%s' "$stats_block" | grep "Total transferred file size:" \
    | grep -oE '[0-9,]+' | head -1)

  printf '%s|%s|%s' \
    "${transferred:-0}" \
    "${deleted:-${DELETE_COUNT:-0}}" \
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

  if [[ "$rsync_exit" -eq 0 ]]; then
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
  local run_status=0
  if run_mirror "$source_path" "$dest" "$mode" "$profile" "$label"; then
    run_status=0
  else
    run_status=$?
    [[ "$MIRROR_EXIT_CODE" -eq 0 ]] && MIRROR_EXIT_CODE="$run_status"
  fi

  if [[ "$run_status" -ne 0 && -z "$LOG_FILE" ]]; then
    exit "$run_status"
  fi

  # Capture --stats block from the log
  local stats_block=""
  if [[ -f "$LOG_FILE" ]]; then
    stats_block=$(grep -A 20 "Number of files:" "$LOG_FILE" 2>/dev/null | tail -20 || true)
  fi

  # Stage 5: Summary
  print_summary "$MIRROR_EXIT_CODE" "$stats_block" "$LOG_FILE"

  if [[ "$MIRROR_EXIT_CODE" -eq 0 ]]; then
    exit 0
  else
    printf '%s✖  rsync exited with error code %s. Check the log for details.%s\n' \
      "$RED" "$MIRROR_EXIT_CODE" "$R"
    exit "$MIRROR_EXIT_CODE"
  fi
}

# Guard: don't run main when sourced for testing
[[ "${MIRROR_TEST_MODE:-0}" == "1" ]] || main "$@"
