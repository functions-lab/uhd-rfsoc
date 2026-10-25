# AGENTS.md — rfsoc

Read the top `AGENTS.md` first (rules, the Protocol). `README.md` here is
the board setup for people; this file is the rules of the board side.

## Rules
- `rfsoc_lib/` holds only what the daemon imports, plus the two pure-numpy
  modules other parts of the repository share (`dsp/beamformer.py`: the
  §11 weights, also used by the `fpga_ip` simulations; `dsp/phase_search.py`:
  `host/benchmark/phase_cal.py`). Nothing else goes in; its gotchas are
  `rfsoc_lib/AGENTS.md`.
- The package name `rfsoc_lib` and its position next to `server/` are
  load-bearing (`backend.find_lib_root` finds it from the daemon's
  directory): do not rename or move either.
- The board holds a git clone of the repository; code reaches it by `git
  pull`, bitstreams by `push_bitstreams.sh <bit_dir> <user@board>`.
  `server/zcu216_uhd.conf` and `server/*.bit` / `*.hwh` are board-local and
  gitignored (top `.gitignore`); never add a board's addresses or files to
  the code.
- A fresh PYNQ image must come up with `README.md`'s steps alone. The only
  change made to the image is `setup_board.sh`'s: the MTS bindings of PYNQ
  2.7's `xrfdc` (`xrfdc_mts_patch.py`, idempotent, originals kept as
  `*.stock`, tested without a board by `server/tests/test_xrfdc_mts_patch.py`).
  The daemon reports a missing binding as one line naming the script
  (`hw_backend.SetupError`), never as a traceback. Keep it that way for any
  further image dependency.
- Tests without a board: `python3 -m unittest discover -s rfsoc/server/tests`
  (the protocol against a stubbed backend, the xrfdc patch). With a board:
  `server/tests/client_check.py` from the host, and `host/benchmark/`.
  Never load a bitstream or leave the daemon running on a board unasked.
- Daemon rules and internals: `server/AGENTS.md`.

## Where things are
| what | where |
|---|---|
| daemon entry, control / discovery servers | `server/zcu216_uhd_daemon.py` |
| the Protocol's commands | `server/protocol.py` |
| the board (bring-up, retune, reload, NCO / gain, sensors) | `server/hw_backend.py`, `server/boards.py` |
| FPGA register maps of the data plane | `server/eth100g.py`, `server/tx_beamformer.py`, `server/rx_beamformer.py` |
| wire format reference (packets, §10 conversions) | `server/vrt.py` |
| RFDC bring-up, clocks, MTS, run-time MMCM retune | `rfsoc_lib/rfdc_task.py`, `rfdc.py`, `clocks.py`, `mts.py`, `clk_wiz.py` |
| LMK04828 / LMX2594 register files per board | `rfsoc_lib/xrfclk/<board>/` |
| 8A34001 GT refclk (ZCU216) | `rfsoc_lib/gt_refclk.py` + `xrfclk/ZCU216/gt_refclk_8a34001_156M25.txt` |
| board setup, bitstream copy, launcher | `setup_board.sh`, `xrfdc_mts_patch.py`, `push_bitstreams.sh`, `../run_daemon.sh` |
