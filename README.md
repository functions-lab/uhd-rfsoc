# rfsoc-uhd

Xilinx RFSoC boards as UHD devices over 100 GbE. Stock UHD 4.6 applications
(`uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`, GNU Radio, Python
`uhd`) talk to the board as device `type=zcu216`: up to 16 RF channels, 3.0
GS/s aggregate in sc16 (6.0 GS/s in sc8), TX and RX beamforming, full-rate TX
and RX at once.

Harvested from the SPEAR codebase (the v49 "QSFP" work) and kept in step with
it by `sync/` (see below).

| directory | what | runs on |
|---|---|---|
| `fpga_ip/` | the custom FPGA IP: UHD data-plane cores (`ip_design/uhd_ip`, packaged in `ip/uhd_ip`), the 100G CMAC wrapper (`ip_design/cmac_100g`), the ZCU208 dual-ADC I/Q joiners (`ip/iprepo`) | Vivado |
| `fpga_board/` | one directory per board: the block design (`block_designs/<board>_uhd_v49/`, one `.tcl` + `.xdc` for every channel count) and its build flow | Vivado |
| `host/` | the UHD device module `libuhd_zcu216.so` (DPDK), the `zcu216-uhd` wrapper, benchmarks / test oracle, GNU Radio flowgraphs | PC |
| `rfsoc/` | the board daemon (`server/`) and the `rfsoc_lib` modules it uses (RFDC, clocks, MTS) | board (PYNQ) |
| `PROTOCOL.md` | the daemon <-> host <-> FPGA contract (wire format, registers, control) | -- |
| `sync/` | the SPEAR sync tool and manifest | -- |

Pinned upstream sources (git submodules, shallow, at the exact releases this
PC builds and runs against -- the Ubuntu 24.04 packages `libuhd 4.6.0.0` and
`gnuradio 3.10.9.2`):

| path | source | pinned to |
|---|---|---|
| `host/uhd/` | EttusResearch/uhd | `v4.6.0.0` (50fa3baa) -- the UHD `host/` module is built against (`host/CMakeLists.txt` requires 4.6) |
| `host/gnuradio/gnuradio/` | gnuradio/gnuradio | `v3.10.9.2` (c7c828a1) -- the GNU Radio the flowgraphs in `host/gnuradio/` target |

```
git submodule update --init --depth 1     # after cloning; reference sources, not needed to build host/
```

Boards: ZCU216 (1, 2, 4, 8, 16 channels; tested on hardware), ZCU208 (1, 2
channels; built, not yet tested on a board), RFSoC 4x2 (not ported:
`fpga_board/rfsoc4x2/README.md`).

## Quick start (ZCU216)

```
# FPGA (Vivado 2021.1 on PATH): package the cores once, then any build
make -C fpga_board/zcu216 v49-package
make -C fpga_board/zcu216 v49 N=4 F=3 FS=2250          # -> fpga_board/zcu216/build/v49_qsfp/bitstreams/
make -C fpga_board/zcu216 v49-ladder                     # all 51 builds of host/benchmark/oracle_builds.txt

# PC (once): NIC, DPDK, module
sudo host/setup_cx5.sh <100g-iface> <host-data-ip>/24
sudo host/setup_dpdk.sh <100g-iface> --install
cmake -S host -B host/build && cmake --build host/build -j && sudo cmake --install host/build

# board: the code by git (section "Board"), the bitstreams by rsync, then the daemon
git push zcu216 master
rfsoc/push_bitstreams.sh                                  # fpga_board/zcu216/build/v49_qsfp/bitstreams -> board
ssh xilinx@zcu216-0 'cd jupyter_notebooks/rfsoc-uhd/rfsoc/server && sudo -E env BOARD=ZCU216 XILINX_XRT=/usr \
    /usr/local/share/pynq-venv/bin/python3 zcu216_uhd_daemon.py --allow-unlocked'

# PC: any UHD app through the wrapper
zcu216-uhd uhd_usrp_probe --args type=zcu216,addr=<board-data-ip>
```

The daemon picks the bitstream from the requested channel count and rate.
Details: `host/README.md` (PC), `rfsoc/server/README.md` (board),
`fpga_board/README.md` (FPGA), `host/benchmark/README.md` (tests and measured
results).

## Paths in the harvested docs

The READMEs and AGENTS.md files under `fpga_ip/`, `host/` and `rfsoc/server/`
come from SPEAR unchanged (so they sync exactly) and use SPEAR's paths:

| SPEAR path | here |
|---|---|
| `hw_design/ip_design/*`, `hw_design/ip/*` | `fpga_ip/ip_design/*`, `fpga_ip/ip/*` |
| `hw_design/ZCU216/...`, `hw_design/ZCU208/...` | `fpga_board/zcu216/...`, `fpga_board/zcu208/...` |
| `block_designs/zcu2xx_v49_qsfp/zcu2xx_v49_qsfp.{tcl,xdc}` | `block_designs/zcu2xx_uhd_v49/zcu2xx_uhd_v49.{tcl,xdc}` |
| `hw_design/ZCU216/CLAUDE.md`, `hw_design/ZCU208/CLAUDE.md` | `fpga_board/zcu216/AGENTS.md`, `fpga_board/zcu208/AGENTS.md` |
| `rfsoc_lib/uhd/host` (and `../host` from benchmark/) | `host` |
| `rfsoc_lib/uhd/benchmark` (and `../benchmark` from host/ or server/) | `host/benchmark` |
| `rfsoc_lib/uhd/gnuradio` | `host/gnuradio` |
| `rfsoc_lib/uhd/server` | `rfsoc/server` |
| `rfsoc_lib/uhd/PROTOCOL.md` | `PROTOCOL.md` |
| `rfsoc_lib/<module>.py`, `rfsoc_lib/xrfclk` | `rfsoc/rfsoc_lib/<module>.py`, `rfsoc/rfsoc_lib/xrfclk` |

On the board this repository is a git checkout (below), so the daemon is
`rfsoc/server` there too; SPEAR docs that say `<remote_dir>/rfsoc_lib/uhd/server`
mean `<checkout>/rfsoc/server`.

## Board

The ZCU216 (`xilinx@zcu216-0`) holds a git checkout of this repository at
`/home/xilinx/jupyter_notebooks/rfsoc-uhd`, configured to accept pushes into
its checked-out branch (`receive.denyCurrentBranch=updateInstead`):

```
git remote add zcu216 xilinx@zcu216-0:/home/xilinx/jupyter_notebooks/rfsoc-uhd   # once
git push zcu216 master          # PC -> board (refused if the board has uncommitted edits to those files)
git fetch zcu216 && git merge zcu216/master      # board -> PC (after committing on the board)
```

Not in git, so kept on the board only: the bitstreams
(`rfsoc/push_bitstreams.sh` copies them into `rfsoc/server/`, the daemon's
default bitstream directory) and the board's settings
`rfsoc/server/zcu216_uhd.conf` (from `zcu216_uhd.conf.example`: `data_ip`,
`name`). The daemon finds `rfsoc_lib` next to `rfsoc/server` by itself;
`host/benchmark/oracle.sh` drives it there (`BOARD_DIR` defaults to that
checkout).

## Keeping in step with SPEAR

`sync/manifest` lists every file taken from SPEAR, its path here, and the few
rewrites this layout needs; nothing else differs. `sync/spear_sync.py pull`
brings SPEAR changes in, `push --into <SPEAR checkout>` carries changes made
here back. See `sync/README.md`.
