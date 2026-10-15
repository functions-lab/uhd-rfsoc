# AGENTS.md — rfsoc

- `rfsoc_lib/` holds only what the daemon (and `host/benchmark/phase_cal.py`)
  imports; adding an import of another SPEAR rfsoc_lib module means adding a
  `map` line to `sync/manifest`.
- The package name `rfsoc_lib` is load-bearing (imports, the daemon's
  library search): do not rename it.
- The board's checkout is updated by `sync/board.sh push` (git); bitstreams by
  `push_bitstreams.sh`; `server/zcu216_uhd.conf` is board-local.
- Daemon rules: `server/AGENTS.md`.
