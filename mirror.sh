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
detect_drives()      { echo "stub"; }
select_drive()       { echo "/tmp/stub"; }
select_run_mode()    { echo "dry"; }
build_exclude_args() { echo "--exclude=stub"; }
count_source_files() { echo 0; }
process_output_line(){ true; }
run_mirror()         { true; }
parse_stats()        { echo "0|0|0"; }
print_summary()      { true; }
handle_abort()       { true; }

main() {
  print_header
  echo "Scaffold OK"
}

# Guard: don't run main when sourced for testing
[[ "${MIRROR_TEST_MODE:-0}" == "1" ]] || main "$@"
