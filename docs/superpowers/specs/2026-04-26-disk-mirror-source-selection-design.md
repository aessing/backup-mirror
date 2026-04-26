# Home / Disk Mirror — Source Selection Design Spec

**Date:** 2026-04-26
**Status:** Approved
**Builds on:** [`2026-04-25-home-mirror-design.md`](./2026-04-25-home-mirror-design.md)

---

## Overview

Extends `mirror.sh` so it can mirror **either** the home folder **or** any other mounted external volume to a destination external disk. The script remains a single file (`mirror.sh`); a new "source selection" stage is added at the front of the existing wizard, and per-source configuration (exclusions, destination/log folder names) is dispatched from that selection.

This unlocks disk-to-disk mirroring (e.g. external USB drive → another external disk) using the same UX, progress display, error handling, and log format already shipped for home-folder mirroring.

The product is rebranded **Home / Disk Mirror** to reflect both modes. The filename `mirror.sh` is retained.

---

## Goals & Non-Goals

**Goals**
- Add a "source" stage to the wizard listing `Home Folder` and every detected external volume by name.
- Keep home-folder behavior byte-identical when `Home Folder` is selected.
- Mirror an external volume to another external volume with sensible default exclusions for macOS volume metadata.
- Prevent mirroring a volume to itself.
- Update README and tests; integrate ShellCheck.

**Non-Goals**
- Mirroring arbitrary directories outside `$HOME` or `/Volumes/`.
- Multi-source or scheduled runs.
- Source-specific exclusion lists supplied by the user at runtime (only the two built-in profiles are supported).

---

## Architecture

The wizard becomes five sequential stages:

1. **Source selection** *(new)* — `Home Folder` or any detected external volume
2. **Destination drive selection** — same as before, but the source volume (if any) is filtered out
3. **Run mode** — dry / live (unchanged)
4. **Mirror** — uses the source-specific source path and exclusion list
5. **Summary** — unchanged

A "profile" string (`home` or `volume`) carries the per-source configuration through the rest of the run.

---

## Components

### Source profile

Resolved at stage 1, propagated as several values:

| Field | `Home Folder` | External volume `<NAME>` |
|---|---|---|
| Profile id | `home` | `volume` |
| Source path | `$HOME/` | `/Volumes/<NAME>/` |
| Exclusion array | `HOME_EXCLUDES` (existing list, renamed from `EXCLUDES`) | `VOLUME_EXCLUDES` (new) |
| Destination dir | `<dest_vol>/Home Folder Backup` | `<dest_vol>/<NAME> Backup` |
| Log dir | `<dest_vol>/Home Folder Logs` | `<dest_vol>/<NAME> Logs` |
| Progress header | `Mirroring home folder…` | `Mirroring <NAME>…` |
| Source volume path (for destination filtering) | (none) | `/Volumes/<NAME>` |

The two exclusion arrays are kept strictly separate; the code never combines them.

### `VOLUME_EXCLUDES`

A small, fixed list of macOS volume metadata that is auto-regenerated and must not be mirrored:

```
.Spotlight-V100/
.Trashes/
.fseventsd/
.DocumentRevisions-V100/
.TemporaryItems/
```

### `select_source` (new)

- Lists `Home Folder` first, then each volume returned by `detect_drives` (in its existing display format)
- Uses the same fzf style as `select_drive` (height, prompt, color)
- Returns a tab-delimited tuple consumed by main: `<profile>\t<label>\t<source_path>\t<source_volume_or_empty>`
- Cancellation behaves like the other selection stages: red error, exit 1

### `select_drive` (modified)

- Accepts an optional argument: the path of the volume to exclude from the destination list (the source volume, when source is `volume`)
- When set, that volume is dropped from the candidates before fzf is shown
- If filtering leaves zero drives → red error, exit 1 ("plug in a second drive")

### `build_exclude_args` (modified)

- Takes a profile id (`home` or `volume`) and emits the appropriate array's `--exclude=` lines
- Defaults to `home` when called with no argument (preserves existing test compatibility)

### `count_source_files` / `count_source_bytes` (modified)

- Already accept a source dir; extended to take a profile id so they consult the matching exclusion array

### `run_mirror` (modified)

- New signature: `run_mirror <source_path> <dest> <mode> <profile> <log_label>`
  - `source_path`: e.g. `$HOME/` or `/Volumes/MyDisk/`
  - `dest`: e.g. `<vol>/Home Folder Backup` or `<vol>/MyDisk Backup`
  - `mode`: `dry` | `live`
  - `profile`: `home` | `volume` (selects the exclusion array)
  - `log_label`: `Home Folder` or `<NAME>` — used to name the log dir (`<log_label> Logs`) and to format the "Mirroring <label>…" header (`home folder` is lowercased for the home profile only)
- Internals are otherwise unchanged: same rsync flags, same progress parsing, same log header/footer.

### `main` (modified)

```text
print_header
profile, label, source, source_vol = select_source
volume = select_drive(exclude=source_vol)
dest = "<volume>/<dest_subfolder>"   # subfolder picked per profile
mode = select_run_mode(dest)
run_mirror source dest mode profile label
print_summary …
```

---

## UI

### Stage 1 — Source

```
┌────────────────────────────────────┐
│  Home / Disk Mirror   v1.1         │
└────────────────────────────────────┘

▶ Select source:
  Use ↑↓ arrow keys or type to filter

❯ Home Folder
  Backup Disk 2            ·  2.0 TB  ·  1.4 TB free
  My USB Drive             ·  500 GB  ·  120 GB free
```

### Stage 2 — Destination (existing label, unchanged otherwise)

```
✔  Source: My USB Drive

▶ Select backup drive:
  Use ↑↓ arrow keys or type to filter

❯ Schliessfach System 01   ·  7.3 TB  ·  2.8 TB free
  Backup Disk 2            ·  2.0 TB  ·  1.4 TB free
```

(`My USB Drive` is filtered out because it is the source.)

### Stage 3 — Run mode (unchanged)

### Stage 4 — Progress (label varies)

```
─────────────────────────────────────────────
⠸  Mirroring My USB Drive…
─────────────────────────────────────────────

  ████████░░░░░░░░░░░░  42%  (210 GB/500 GB)
```

### Stage 5 — Summary (unchanged)

Log path varies by source — e.g. `/Volumes/Schliessfach System 01/My USB Drive Logs/mirror_20260426_140012.log`.

---

## Rebrand

- `SCRIPT_NAME` constant: `Home Folder Mirror` → `Home / Disk Mirror`
- `VERSION` bumped: `1.0` → `1.1`
- Header box length adjusts automatically (already terminal-aware)
- Run-mode `Live run` description changes from `mirror home folder for real` to `mirror selected source for real`
- README rewritten to reflect both modes

---

## Error Handling (additions)

- No external volumes detected at source stage → script still offers `Home Folder` as the only option; if the user picks it the existing flow runs.
- Source volume = destination volume → defended by filtering at stage 2; if filtering empties the list, exit 1 with a clear message.
- Source path inaccessible (e.g. permission denied on `/Volumes/<NAME>` root) → rsync surfaces the error per its existing handling; the script does not pre-validate beyond `[[ -d ]]`.

---

## File Layout (additions)

Per backup drive, log/backup folders now follow the source label:

```
<drive>/
  Home Folder Backup/            # when source = home
  Home Folder Logs/

  <SOURCE> Backup/               # when source = a volume
  <SOURCE> Logs/
```

Multiple sources can share a destination drive — they live side-by-side under different folder names.

---

## ShellCheck Integration

ShellCheck is now installed locally. Add a top-level lint step to `tests/test_functions.sh`:

- Run `shellcheck mirror.sh tests/test_functions.sh` before the unit/integration assertions
- Fail the test suite if ShellCheck reports any errors at default severity
- Skip cleanly with a `SKIP` line if `shellcheck` is not on `PATH` (so CI without it still works)

Any existing ShellCheck warnings surfaced by this step are addressed inline (or suppressed with `# shellcheck disable=...` plus a reason comment) as part of this change.

---

## Testing

New unit/integration tests in `tests/test_functions.sh`:

1. **`select_source` is a function** — interactive, tested manually, but defined.
2. **`build_exclude_args home`** — emits the home exclusion list (existing assertions kept).
3. **`build_exclude_args volume`** — emits exactly the five `VOLUME_EXCLUDES` entries.
4. **Exclusion arrays are disjoint** — `HOME_EXCLUDES` does not contain any `VOLUME_EXCLUDES` entry and vice versa.
5. **`count_source_files volume`** on a temp dir containing a `.Spotlight-V100/foo` file excludes the metadata.
6. **`run_mirror` integration (volume profile)** — using a synthetic source dir and synthetic destination, verifies:
   - log dir is `<vol>/<label> Logs`
   - destination dir is `<vol>/<label> Backup`
   - progress header reads `Mirroring <label>…`
   - mirroring still deletes stale destination files
   - `.Spotlight-V100/` content in the synthetic source is excluded from the destination
7. **`select_drive` filtering** — given a fake drives list and an exclusion path, the filtered output omits the matching row (tested by exposing or extracting the filter step into a callable helper).
8. **ShellCheck step** — the suite calls `shellcheck` and treats it as a hard pass/fail (or `SKIP` if not installed).

Existing tests are updated to:
- Reference the new `HOME_EXCLUDES` array name
- Use `build_exclude_args home` where they previously called `build_exclude_args`
- Pass the new `run_mirror` argument list

---

## README

Replace the placeholder one-line `README.md` with a brief document covering:

- What the tool does (home + disk mirror to external drive)
- Requirements (`fzf`, `rsync`/`openrsync`, optional `shellcheck`)
- Usage: `./mirror.sh` and the four selections
- Where backups and logs land on the destination drive
- How exclusions work (and that the two profiles use different lists)
- How to run tests (`bash tests/test_functions.sh`)
- License / project status (one line each)

---

## Out of Scope (explicit)

- Custom user-supplied exclusion files
- Mirroring `/`, `/Users`, or other non-`$HOME`/non-`/Volumes/` paths
- Encrypted destinations or sparsebundles
- Scheduling / launchd integration
- Concurrent multi-source runs

---

## Migration / Compatibility

- Existing home-folder runs are unaffected: choosing `Home Folder` reproduces the prior behavior bit-for-bit (same source path, same exclusions, same destination/log folder names).
- Existing destination drives that already contain `Home Folder Backup/` and `Home Folder Logs/` continue to work without renaming.
- Old log files written before this change are pruned by the same 30-day rule.
