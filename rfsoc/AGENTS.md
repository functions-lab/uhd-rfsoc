# AGENTS.md — rfsoc

- `rfsoc_lib/` holds only what the daemon (and `host/benchmark/phase_cal.py`)
  imports; keep it that way.
- The package name `rfsoc_lib` is load-bearing (imports, the daemon's
  library search): do not rename it.
- On the board this directory is part of a git clone of the repository; code
  changes reach it by git (commit, then `git pull` on the board), bitstreams
  by `push_bitstreams.sh <bit_dir> <user@board>`. `server/zcu216_uhd.conf`
  and the bitstreams are board-local and gitignored.
- Daemon rules: `server/AGENTS.md`.
