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

- **Home folder profile** — ~60 macOS-specific paths (iCloud sync, caches, sandboxed app data, system metadata, Trash, etc.)
- **Volume profile** — five macOS volume metadata folders (`.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.DocumentRevisions-V100`, `.TemporaryItems`)

Lists live at the top of `mirror.sh` (`HOME_EXCLUDES`, `VOLUME_EXCLUDES`).

## Tests

```sh
bash tests/test_functions.sh
```

Runs ShellCheck (if installed), unit tests for pure helpers, and integration tests that exercise `run_mirror` end-to-end against synthetic source/destination directories under `mktemp -d`.

## Status

Personal tool. Single-file script, no install required beyond `chmod +x mirror.sh`.
