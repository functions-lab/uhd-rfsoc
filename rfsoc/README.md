# rfsoc — the board side (PYNQ)

| path | what |
|---|---|
| `server/` | the UHD daemon: loads a bitstream, brings up RFDC / clocks / MTS / the 100G link, serves UHD clients (`server/README.md`) |
| `rfsoc_lib/` | the rfsoc_lib modules the daemon imports (RFDC, MTS, clocks, overlay, GT refclk, beamformer weights) and the clock register files `xrfclk/<board>/` |
| `push_bitstreams.sh` | copy built bitstreams from the build machine into the board checkout's `server/` |

Board setup (once; top `README.md`, "Set up the board"):

1. On the PYNQ board, clone this repository to
   `/home/xilinx/jupyter_notebooks/rfsoc-uhd`.
2. From the build machine, copy the bitstreams:
   `rfsoc/push_bitstreams.sh <bitstream dir> xilinx@<board>` (or put the
   `.bit` / `.hwh` files of a release into `rfsoc/server/` by hand).
3. On the board, `cp rfsoc/server/zcu216_uhd.conf.example
   rfsoc/server/zcu216_uhd.conf` and set `data_ip` (and optionally
   `data_mac`).
4. Start the daemon with `./run_daemon.sh` at the top of the checkout (also
   `stop`, `restart`, `status`, `log`, `fg`; log `/tmp/uhd_daemon.log`). It
   runs `server/zcu216_uhd_daemon.py` as root in the PYNQ venv, which finds
   `rfsoc_lib` next to it.
