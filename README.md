# Home / Disk Mirror

[![CI/CD](https://github.com/aessing/backup-mirror/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/aessing/backup-mirror/actions/workflows/ci-cd.yml)

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

Live runs use `rsync --delete`, so destination contents that no longer exist in the source are removed. The script refuses symlinked backup or log directories, parent-directory escapes, and paths that resolve outside the selected destination volume. Partial `rsync` transfers, including exit code `23`, are reported as failed and return a non-zero exit status.

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

## CI/CD

GitHub Actions runs the same syntax checks and test suite on branch pushes, pull requests, and manual dispatches. Pushing a tag that matches `v*` runs the tests first, then creates or updates a GitHub Release with `mirror.sh` and a SHA-256 checksum attached.

Dependabot checks GitHub Actions weekly and groups workflow action updates into a single PR. The security workflow runs CodeQL against GitHub Actions workflow YAML and runs Trivy filesystem scanning for vulnerabilities, secrets, and misconfigurations, uploading SARIF results to GitHub code scanning.

## Status

Personal tool. Single-file script, no install required beyond `chmod +x mirror.sh`.
