# mender-convert — Claude Code Rules

## Shell Script Standards

These rules apply to every shell script written or modified in this repo.

### Logging

- Every script that runs more than one command **must** log to a file under `logs/`.
- Use `exec > >(tee -a "$LOG_FILE") 2>&1` at the top so output goes to both terminal and log simultaneously.
- Print the log path at the start and end of every script:
  ```bash
  echo "Log: ${LOG_FILE}"
  ```
- Use numbered steps for long operations so the user always knows where the script is:
  ```bash
  echo "[1/4] Extracting ISO..."
  ```

### No Silent Failures

- **Never use `2>/dev/null`** on any command that can fail. Suppress only truly harmless noise (e.g. `pkill` when no process exists).
- **Never pipe through `tail` or `grep` without preserving the exit code** — use `|| die` instead.
- Every external command that can fail must be followed by `|| die "description"`:
  ```bash
  xorriso ... || die "xorriso extract failed"
  ```
- Define a `die()` function in every script:
  ```bash
  die() {
      echo ""
      echo "ERROR: $*"
      echo "Full log: ${LOG_FILE}"
      exit 1
  }
  ```
- Use `trap` to catch unexpected failures and print the line number and log path:
  ```bash
  trap 'echo "FAILED at line ${LINENO}. Full log: ${LOG_FILE}"' ERR
  ```

### Script Header

Every script must start with:
```bash
set -euo pipefail
```

And include a root check where needed:
```bash
[ "$(id -u)" -eq 0 ] || die "Run as root (sudo)"
```

### General

- Print a clear summary at the end: what was produced, where it is, what to do next.
- Long-running operations (xorriso, dd, docker, qemu) must show progress — use `status=progress` for dd, avoid silencing xorriso output entirely.
- Prereq checks (`check_cmd`) must run before any work starts, not mid-script.
