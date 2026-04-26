# Home Folder Mirror — Design Spec

**Date:** 2026-04-25
**Status:** Implemented (synced 2026-04-26 to reflect built reality)
**Successor:** [`2026-04-26-disk-mirror-source-selection-design.md`](./2026-04-26-disk-mirror-source-selection-design.md) extends this design to allow mirroring external volumes as well as the home folder.

---

## Overview

A Bash script that mirrors the user's home folder to an external backup drive. Designed for rotation across multiple backup disks. Presents a minimal TUI using `fzf` (already installed via Homebrew) for drive selection and run-mode choice. No additional dependencies required at runtime.

---

## Architecture

Single Bash script: `mirror.sh`

Four sequential stages:

1. **Drive selection** — detect mounted external volumes, present with fzf, confirm destination path
2. **Run mode** — fzf prompt to choose dry run or live run
3. **Mirror** — execute rsync with live console output; capture errors inline; write a structured log
4. **Summary** — print stats and log path on completion

---

## Components

### Drive Detection

- List entries in `/Volumes/` excluding the system volume (compared via `stat -f %d`)
- For each volume, show: name, total size, free space (via `df -H`)
- Pass to `fzf` for interactive selection (tab-delimited, only the display column shown)
- Construct destination: `<selected_volume>/Home Folder Backup/`
- Create destination directory if it does not exist
- `validate_destination` rejects symlink destinations and rejects destinations that resolve outside the selected volume

### Run Mode Selection

- Second `fzf` prompt with two options: `Dry run` / `Live run`
- Dry run: add `--dry-run` flag to rsync; progress header is yellow
- Live run: execute rsync for real; progress header is orange

### rsync Invocation

macOS ships with openrsync (compatible with rsync 2.6.9). It does not support `--info=progress2` or `--log-file`. The script works within these constraints by streaming `--progress` output and parsing it line by line.

```
rsync \
  --archive \
  --no-specials \
  --delete \
  --human-readable \
  --verbose \
  --progress \
  --stats \
  [--dry-run] \
  <exclusions> \
  ~/ \
  "<dest>/"
```

`--archive` enables: recursive, symlinks, permissions, timestamps, owner, group.
`--no-specials` avoids `mkstempsock`-style errors on macOS sockets/special files.
`--delete` removes files on the destination that no longer exist in the source (true mirror).
`--stats` provides a final transfer summary parsed for the summary screen.
Output is captured by reading rsync's combined stdout/stderr line by line and routing each line either to the log file, the live progress display, or an inline error block.

### Progress Display

Global percentage uses byte-based progress when possible:

- Before rsync runs, the script counts source files (`count_source_files`) and total source bytes (`count_source_bytes`) using `find` with the same exclusions, capped at a 3-second timeout (the count is skipped if it takes longer)
- During rsync, lines matching the rsync `--progress` regex (`<bytes> <pct>%`) are parsed:
  - At 100%, the file's bytes are added to `TRANSFERRED_BYTES` and `TRANSFER_COUNT` increments
  - Below 100%, `CURRENT_FILE_BYTES` is updated for live display
- The progress bar shows: byte percentage if total bytes are known; else file-count percentage if file count is known; else an activity bar with cumulative file count

### Exclusions

The script ships with a categorized exclusion list (~50 paths) covering:

- iCloud and cloud sync (`Library/Mobile Documents/`, `Library/CloudStorage/`)
- Caches and build artefacts (`Library/Caches/`, `Library/Logs/`, `.cache/`, `.npm/`, `.nvm/`, `.kube/cache/`, `.local/share/uv/`, `.zcompcache/`, `.zsh_sessions/`, `.thumbnails/`, `.android/`, `Library/Saved Application State/`, `Library/Developer/`)
- Tool binaries that are reinstallable (`.vscode/extensions/`, `.copilot/pkg/`, `.tldrc/tldr/`)
- Container storage (`.local/share/containers/`)
- Apple sandboxed app data unreadable without entitlements (`Library/Containers/`, `Library/Group Containers/`)
- Apple system data not useful in a personal backup (CrashReporter, MobileSync, sharedfilelist, CallHistoryDB, CloudDocs, Knowledge, TCC, FileProvider, FaceTime, DifferentialPrivacy, avfoundation, Assistant, Autosave Information, IdentityServices, AppleMediaServices, Accounts, Safari, Shortcuts, Suggestions, Weather, Cookies, DoNotDisturb, Sharing, aiml.instrumentation, bluetooth.services.cloud, Metadata/CoreSpotlight, Metadata/IntelligentSuggestions, Biome, CoreFollowUp, DuetExpertCenter, IntelligencePlatform, Daemon Containers, ContainerManager, PersonalizationPortrait, Trial, StatusKit)
- Games (`Library/Application Support/Steam/steamapps/`)
- Trash (`.Trash/`)

`build_exclude_args` translates the array into `--exclude=<path>` rsync arguments.

### Console Output

- Header box rendered in **orange** (ANSI 256-color 208), with script name and version
- Separator lines using `─` repeated to terminal width (`tput cols`)
- Color palette: orange for structural elements, blue for info, green for success, yellow for warnings/dry mode, red for errors, gray for secondary text
- Live progress line redrawn in place on `/dev/tty` (does not pollute pipelines or non-interactive runs)
- Errors printed inline as a red block with `(logged)` annotation; the progress line is cleared (`\r\033[K`) before the error is printed and a blank line follows it before the progress line redraws
- No external color libraries — uses ANSI escape codes directly

### Error and Run Logging

- Logs are written to `<volume>/Home Folder Logs/mirror_<YYYYMMDD_HHMMSS>.log` — a per-run timestamped file in a sibling folder to the backup folder
- The log directory is created if missing
- Logs older than 30 days in the same folder are pruned (`find -mtime +30 -delete`) at the start of each run
- Each log starts with a header (timestamp, mode, destination) and ends with a footer (exit code, duration, source files, source bytes, transferred files, transferred bytes, deleted files, errors)
- Every line of rsync output (progress, deletions, file paths, errors) is appended to the log
- Errors are identified by rsync's prefixes: `rsync(<pid>): `, `rsync: `, or `rsync error`

### Summary Screen

Parsed from the rsync `--stats` block at the end of the run:

| Field | Source |
|---|---|
| Files transferred | rsync stats: "Number of (regular) files transferred" |
| Files deleted | rsync stats: "Number of deleted files" (fallback: in-script `DELETE_COUNT`) |
| Total size | rsync stats: "Total transferred file size" |
| Duration | wall-clock seconds since script start, formatted `Xm Ys` ≥60s |
| Errors | in-script `ERROR_COUNT` from parsed error lines |
| Log path | absolute path to the timestamped log on the drive |

---

## UI Design

### Stage 1 — Drive Selection

```
┌────────────────────────────────────┐
│  Home Folder Mirror   v1.0         │
└────────────────────────────────────┘

▶ Select backup drive:
  Use ↑↓ arrow keys or type to filter

❯ Schliessfach System 01   ·  7.3 TB  ·  2.8 TB free
  Backup Disk 2            ·  2.0 TB  ·  1.4 TB free
```

### Stage 2 — Run Mode

```
✔  Destination: /Volumes/Schliessfach System 01/Home Folder Backup

▶ Run mode:

❯ Dry run  — preview changes, nothing is written
  Live run — mirror home folder for real
```

### Stage 3 — Progress

```
─────────────────────────────────────────────
⠸  Mirroring home folder…
─────────────────────────────────────────────

  ████████████░░░░░░░░  67%  (4.1 GB/6.1 GB)

⚠  rsync: [receiver] failed to open … Permission denied (13) (logged)
```

### Stage 4 — Summary

```
─────────────────────────────────────────────
✔  Mirror complete   2026-04-25 14:32:07
─────────────────────────────────────────────

  Files transferred:    1,842
  Files deleted:        23
  Total size:           6,410,123,456 bytes
  Duration:             8m 14s
  Errors:               none

  Log: /Volumes/Schliessfach System 01/Home Folder Logs/mirror_20260425_142207.log
```

---

## Error Handling

- No external volumes detected → red error, exit 1
- No drive selected (fzf cancelled) → red error, exit 1
- No run mode selected → red error, exit 1
- Destination cannot be created → red error, exit 1
- Destination is a symlink → red error, exit 1
- Destination resolves outside the selected volume → red error, exit 1
- rsync exit 0 or 23 (partial transfer) → treated as success in summary; script exits 0
- Other non-zero rsync exits → printed in red, full code propagated as script exit code
- Ctrl+C → trap SIGINT, print aborted message, append abort entry to log, exit 130

---

## File Layout

```
backup-mirror/
  mirror.sh                  # main script (executable)
  README.md
  tests/
    test_functions.sh        # Bash unit + integration tests
  docs/
    superpowers/
      specs/
        2026-04-25-home-mirror-design.md     # this file
      plans/
        2026-04-25-home-mirror.md
```

Per backup drive:

```
<drive>/
  Home Folder Backup/        # mirrored home contents
  Home Folder Logs/
    mirror_<YYYYMMDD_HHMMSS>.log
```

---

## Testing

`tests/test_functions.sh` sources `mirror.sh` with `MIRROR_TEST_MODE=1` to bypass `main` and exercises the helpers directly. Coverage includes:

- `sep`, `print_header` rendering
- `detect_drives` (or skipped when no external volumes mounted)
- `select_drive` / `select_run_mode` are defined as functions; `render_run_mode_selection` rendering
- `build_exclude_args` produces the expected `--exclude=` lines
- `count_source_files` returns a numeric count
- `count_source_bytes` returns the correct sum
- `render_progress_line` falls back to an activity bar when totals are unknown; activity bar is stable across counts
- `render_error_block` emits the line-clear sequence and the trailing blank line
- `process_output_line` increments `TRANSFER_COUNT`/`TRANSFERRED_BYTES` only at 100%, tracks in-flight bytes, increments `DELETE_COUNT` and `ERROR_COUNT`, and writes every line to the log
- `parse_stats` parses both rsync and openrsync wording
- `run_mirror` integration: writes a timestamped log under `Home Folder Logs/`, deletes stale destination files, prunes logs older than 30 days, rejects symlink destinations without modifying the symlink target

Manual verification on a real drive: dry run shows expected changes, live run produces the mirror, deleting a source file removes it on the next live run, all configured exclusion paths are absent from the backup, unplugging the drive yields the "no drives found" message.
