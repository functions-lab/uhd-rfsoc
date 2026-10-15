# rfsoc — the board side (PYNQ)

| path | what |
|---|---|
| `server/` | the UHD daemon: loads a bitstream, brings up RFDC / clocks / MTS / the 100G link, serves UHD clients (`server/README.md`) |
| `rfsoc_lib/` | the rfsoc_lib modules the daemon imports (RFDC, MTS, clocks, overlay, GT refclk, beamformer weights) and the clock register files `xrfclk/<board>/` |
| `push_bitstreams.sh` | copy built bitstreams into the board checkout's `server/` |

On the board this is part of the git checkout
`/home/xilinx/jupyter_notebooks/rfsoc-uhd` (top `README.md`, "Board"). Start
the daemon with `../run_daemon.sh` (stop, restart, status, log); it runs
`server/zcu216_uhd_daemon.py` as root in the PYNQ venv, which finds
`rfsoc_lib` next to it.
