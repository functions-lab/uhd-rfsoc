# rfsoc-uhd

Xilinx RFSoC boards as UHD devices over 100 GbE. Stock UHD 4.6 applications
(`uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`, GNU Radio, Python
`uhd`) talk to the board as device `type=zcu216`: up to 16 RF channels, 3.0
GS/s aggregate in sc16 (6.0 GS/s in sc8), TX and RX beamforming, full-rate TX
and RX at once.

Harvested from the SPEAR codebase (the v49 "QSFP" work) and kept in step with
it by `sync/` (`sync/README.md`).

| directory | what | runs on |
|---|---|---|
| `fpga_ip/` | the custom FPGA IP: UHD data-plane cores (`ip_design/uhd_ip`, packaged in `ip/uhd_ip`), the 100G CMAC wrapper (`ip_design/cmac_100g`), the dual-ADC I/Q joiners of the RFSoC 4x2 (`ip/iprepo`) | Vivado |
| `fpga_board/` | one directory per board: the block design (`block_designs/<board>_uhd_v49/`, one `.tcl` + `.xdc` for every channel count) and its build flow | Vivado |
| `host/` | the UHD device module `libuhd_zcu216.so` (DPDK; stock UHD apps run it with `sudo`), benchmarks / test oracle, GNU Radio flowgraphs | PC |
| `rfsoc/` | the board daemon (`server/`) and the `rfsoc_lib` modules it uses (RFDC, clocks, MTS) | board (PYNQ) |
| `run_daemon.sh` | start / stop the daemon on the board | board |
| `PROTOCOL.md` | the daemon <-> host <-> FPGA contract (wire format, registers, control) | -- |
| `sync/` | keeping the board's checkout (`board.sh`) and SPEAR (`spear_sync.py`) in step | PC |

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

Boards: ZCU216 (1, 2, 4, 8, 16 channels at fs 2500 MS/s; tested on zcu216-0)
and RFSoC 4x2 (1, 2 channels at fs 5000 MS/s, up to 2500 MS/s per channel;
`fpga_board/rfsoc4x2/README.md`, rfsoc4x2-0). The ZCU208 is not supported.

## Quick start (ZCU216)

```
# FPGA (Vivado 2021.1 on PATH): package the cores once, then any build
make -C fpga_board/zcu216 v49-package
make -C fpga_board/zcu216 v49 N=4 F=3 FS=2250          # -> fpga_board/zcu216/build/v49_qsfp/bitstreams/
make -C fpga_board/zcu216 v49-ladder                     # all 51 builds of host/benchmark/oracle_builds.txt

# PC (once): NIC, DPDK, the UHD module
sudo host/setup_cx5.sh <100g-iface> <host-data-ip>/24
sudo host/setup_dpdk.sh <100g-iface> --install
cmake -S host -B host/build && cmake --build host/build -j && sudo cmake --install host/build

# board: the code by git, the bitstreams by rsync (section "Board")
sync/board.sh push
rfsoc/push_bitstreams.sh                                  # fpga_board/zcu216/build/v49_qsfp/bitstreams -> board
```

## Running

On the board (`ssh xilinx@zcu216-0`, in `~/jupyter_notebooks/rfsoc-uhd`):

```
./run_daemon.sh             # start; returns once it serves (~20 s: bitstream, clocks, MTS)
./run_daemon.sh status      # running? which build and rate
./run_daemon.sh stop        # also: restart, log, fg (foreground)
```

On the PC, any stock UHD application, run as root (the data plane is DPDK);
the channel count is the device arg `channels=` (1, 2, 4, 8, 16):

```
uhd_find_devices --args type=zcu216                      # no root needed
sudo uhd_usrp_probe --args type=zcu216,addr=<board-ip>,channels=4
sudo /usr/libexec/uhd/examples/tx_waveforms --args type=zcu216,channels=2 \
    --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
sudo python3 -c "import uhd; u = uhd.usrp.MultiUSRP('type=zcu216,channels=4'); print(u.get_rx_rate())"
```

A new `channels=` reloads the bitstream (~16 s). Within one channel count
`set_rx_rate` / `set_tx_rate` retune in place (~1 s): the highest supported
rate at or below the request, e.g. 750, 562.5, 450 ... 56.25 MS/s at 4
channels; the reported bandwidth is the rate.

If `uhd_usrp_probe` fails with a DPDK port error, the PC's 100G port lost its
address (NetworkManager): `sudo nmcli device set <100g-iface> managed no` and
run `host/setup_cx5.sh` again.

More: `host/README.md` (PC, device arguments), `rfsoc/server/README.md`
(daemon), `fpga_board/README.md` (FPGA), `host/benchmark/README.md` (tests,
measured results), `host/gnuradio/README.md` (GNU Radio).

## Board

Each board holds a git checkout of this repository at
`/home/xilinx/jupyter_notebooks/rfsoc-uhd`, kept on the PC's branch and
commit: the ZCU216 `xilinx@zcu216-0` (git remote `zcu216`) and the RFSoC 4x2
`xilinx@rfsoc4x2-0` (remote `rfsoc4x2`):

```
git remote add zcu216   xilinx@zcu216-0:/home/xilinx/jupyter_notebooks/rfsoc-uhd     # once
git remote add rfsoc4x2 xilinx@rfsoc4x2-0:/home/xilinx/jupyter_notebooks/rfsoc-uhd   # once
git config board.remotes "zcu216 rfsoc4x2"   # once: the boards push / status / the hooks go to
sync/board.sh hooks on      # once: every commit / checkout here updates every board
sync/board.sh status        # every side: branch, commit, uncommitted files
sync/board.sh push          # PC -> boards (-b <remote>: one board)
sync/board.sh -b zcu216 pull   # board -> PC (after committing on the board)
```

A new board's checkout starts empty: on the board `git init
~/jupyter_notebooks/rfsoc-uhd && git -C ~/jupyter_notebooks/rfsoc-uhd config
receive.denyCurrentBranch updateInstead`, then `sync/board.sh -b <remote> push`.

Kept on the board only (not in git): the bitstreams in `rfsoc/server/`
(`rfsoc/push_bitstreams.sh` copies them: `rfsoc/push_bitstreams.sh
fpga_board/rfsoc4x2/build/v49_qsfp/bitstreams xilinx@rfsoc4x2-0` for the 4x2)
and the board's settings `rfsoc/server/zcu216_uhd.conf` (from
`zcu216_uhd.conf.example`: `data_ip`, `name`).
