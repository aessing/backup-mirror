# Home Folder Mirror — Design Spec

**Date:** 2026-04-25  
**Status:** Approved

---

## Overview

A Bash script that mirrors the user's home folder to an external backup drive. Designed for rotation across three backup disks. Presents a minimal TUI using `fzf` (already installed via Homebrew) for drive selection and run-mode choice. No additional dependencies required.

---

## Architecture

Single Bash script: `mirror.sh`

Four sequential stages:

1. **Drive selection** — detect mounted external volumes, present with fzf, confirm destination path
2. **Run mode** — fzf prompt to choose dry run or live run
3. **Mirror** — execute rsync with live console output; capture errors inline
4. **Summary** — print stats and log path on completion

---

## Components

### Drive Detection

- List entries in `/Volumes/` excluding the system volume (`/`)
- For each volume, show: name, total size, free space (via `df`)
- Pass to `fzf` for interactive selection
- Construct destination: `<selected_volume>/Home Folder Backup/`
- Create destination directory if it does not exist

### Run Mode Selection

- Second `fzf` prompt with two options: `Dry run` / `Live run`
- Dry run: add `--dry-run` flag to rsync; prefix all output with a clear notice
- Live run: execute rsync for real

### rsync Invocation

macOS ships with openrsync (protocol 29, compatible with rsync 2.6.9). It does not support `--info=progress2` or `--log-file`. The script works within these constraints.

```
rsync \
  --archive \
  --delete \
  --human-readable \
  --progress \
  --stats \
  <exclusions> \
  ~/ \
  "<dest>/" \
  2>&1 | tee -a "<dest>/mirror.log"
```

`--archive` enables: recursive, symlinks, permissions, timestamps, owner, group.  
`--delete` removes files on the destination that no longer exist in the source (true mirror).  
`--stats` provides final transfer summary parsed for the summary screen.  
Stderr and stdout are piped through `tee` to write to the log file on the drive while still displaying on screen.

### Progress Display

Global percentage is not available from openrsync directly. Instead:

- Before rsync runs, `find ~` counts the total number of files (excluding the same exclusion paths) and stores the count
- During rsync, the script counts lines of output matching file transfers to derive an approximate overall percentage
- If the pre-count takes more than 3 seconds, it is skipped and the display shows per-file progress only (current file name, transfer rate, elapsed time)

### Exclusions (11 paths)

```
--exclude="Library/Mobile Documents/"
--exclude="Library/Caches/"
--exclude="Library/Logs/"
--exclude="Library/Saved Application State/"
--exclude="Library/Developer/"
--exclude="Library/CloudStorage/"
--exclude="Library/Application Support/CrashReporter/"
--exclude="Library/Application Support/MobileSync/"
--exclude="Library/Application Support/com.apple.sharedfilelist/"
--exclude="Library/Application Support/Steam/steamapps/"
--exclude=".Trash/"
```

### Console Output

- Spinner character cycling on the "Mirroring…" header line (using a background loop updating a single line)
- rsync `--progress` output streamed live: current file path and transfer rate
- Errors (non-zero rsync exit codes per file) printed inline in yellow/red with `(logged)` note
- Separator lines using `─` repeated to terminal width (`tput cols`)

### Error Logging

- rsync stdout+stderr piped through `tee -a` to `<dest>/Home Folder Backup/mirror.log`
- Script writes a run header to the log before rsync starts: timestamp, mode (dry/live), destination
- Script writes a run footer after rsync exits: exit status, file counts, duration
- Errors are identifiable in the log by rsync's own error prefix (`rsync: `, `rsync error:`)

### Summary Screen

Parsed from rsync `--stats` output at end of run:

| Field | Source |
|---|---|
| Files transferred | rsync stats: "Number of regular files transferred" |
| Files deleted | rsync stats: "Number of deleted files" |
| Total size | rsync stats: "Total transferred file size" |
| Duration | wall-clock time from script start |
| Errors | Count of non-zero file-level errors captured during run |
| Log path | Absolute path to mirror.log on the drive |

---

## UI Design

### Terminal window style
- macOS-style header box (bordered, with script name and version)
- Separator lines scaled to terminal width
- Color palette: purple for structure, blue for info, green for success, yellow for warnings, red for errors, gray for secondary text
- No external color libraries — uses ANSI escape codes directly

### Stage 1 — Drive Selection
```
┌──────────────────────────────────┐
│  ⌂  Home Folder Mirror   v1.0   │
└──────────────────────────────────┘

▶ Select backup drive:
  (use arrow keys or type to filter)

❯ Schliessfach System 01   ·  7.3 TB  ·  2.8 TB free
  Backup Disk 2             ·  2.0 TB  ·  1.4 TB free
  Backup Disk 3             ·  2.0 TB  ·  890 GB free
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
  Documents/Projects/client-work/report.pdf
  Library/Application Support/Logitech/GHUB/…

  ████████████████░░░░░░░░  67%  ·  4.1 GB / 6.1 GB  ·  12.4 MB/s  ·  ETA 2m 48s

⚠  Error: Documents/locked-file.pdf — permission denied (logged)
```

### Stage 4 — Summary
```
─────────────────────────────────────────────
✔  Mirror complete   2026-04-25 14:32:07
─────────────────────────────────────────────
  Files transferred:   1,842
  Files deleted:       23
  Total size:          6.1 GB
  Duration:            8m 14s
  Errors:              1  →  see mirror.log

  Log: /Volumes/Schliessfach System 01/Home Folder Backup/mirror.log
```

---

## Error Handling

- If no external volumes are detected: print error and exit cleanly
- If destination directory cannot be created: print error and exit
- If rsync exits with code 23 (partial transfer): treat as warning, not fatal — summarize count in summary
- If rsync exits with any other non-zero code: print error, append to log, exit with that code
- Ctrl+C during mirror: trap SIGINT, print aborted message, append abort entry to log

---

## File Layout

```
~/home-mirror/
  mirror.sh          # main script (executable)
  README.md
  docs/
    superpowers/
      specs/
        2026-04-25-home-mirror-design.md
```

Log written to backup drive, not the project:
```
<drive>/Home Folder Backup/
  mirror.log
  <mirrored home folder contents>
```

---

## Testing

1. Plug in one of the three backup drives
2. Run `./mirror.sh` — verify drive appears in fzf list with correct sizes
3. Select drive, choose **Dry run** — verify output shows files that would be transferred/deleted, nothing changes on disk
4. Run again with **Live run** — verify files appear on the backup drive
5. Delete a file from home folder, run again — verify `--delete` removes it from backup
6. Check `mirror.log` on the drive for correct timestamp format and run header/footer
7. Verify all 11 exclusion paths are absent from the backup
8. Unplug drive, run script — verify "no drives found" message and clean exit
