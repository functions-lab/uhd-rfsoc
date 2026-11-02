# rfsoc — the board side

What runs on the RFSoC board (a ZCU216 or an RFSoC 4x2 with its PYNQ image):
the daemon that makes the board a UHD device, the library it brings the
converters up with, and the scripts that set a board up.

| path | what |
|---|---|
| `server/` | the UHD daemon: loads a bitstream, brings up clocks / RFDC / MTS / the 100G link, serves UHD clients (`server/README.md`) |
| `rfsoc_lib/` | the board library the daemon imports (RFDC, clocks, MTS, overlay, GT refclk, beamformer weights) and the clock chips' register files (`rfsoc_lib/README.md`) |
| `setup_board.sh` | one-time board setup, run once on the board (below) |
| `xrfdc_mts_patch.py` | what `setup_board.sh` runs to add multi-tile sync to PYNQ's `xrfdc` |
| `push_bitstreams.sh` | run on the build machine: copies bitstreams into the board's checkout |
| `../run_daemon.sh` | start / stop / status / log of the daemon on the board |

## From a fresh PYNQ image to a serving daemon

You need: a ZCU216 or RFSoC 4x2 running its PYNQ image (2.7, 3.0 or 3.1)
on the LAN (ssh as user `xilinx`), the QSFP28 cable to the host PC, and the
bitstreams built for that PYNQ version (a
[release](https://github.com/WeiCheng14159/uhd-rfsoc/releases)'s
`uhd-rfsoc-bitstreams-<board>-pynq<version>.zip`, or built:
`fpga/README.md`).

1. **Clone on the board** (any directory works; this one is what
   `push_bitstreams.sh` and the systemd unit assume):

       git clone https://github.com/WeiCheng14159/uhd-rfsoc.git ~/jupyter_notebooks/uhd-rfsoc
       cd ~/jupyter_notebooks/uhd-rfsoc

2. **Set the board up** (once; safe to repeat, every step is a no-op where
   it was done):

       sudo rfsoc/setup_board.sh

   * adds the multi-tile-sync (MTS) bindings to the PYNQ venv's `xrfdc`
     Python wrapper where they are missing: PYNQ 2.7, 3.0 and 3.1 ship the
     same `xrfdc` without them (an `xrfdc` that already has them, patched by
     some other installer, is left alone). The daemon locks MTS at every
     bring-up and refuses to serve without it.
     The two patched files are kept as `*.stock` next to the originals, and
     the import is verified;
   * creates `rfsoc/server/uhd_rfsoc.conf` from `uhd_rfsoc.conf.example`
     if there is none (an existing one is never touched);
   * lists the bitstreams in `rfsoc/server/`.

   `rfsoc/setup_board.sh --check` only reports.

3. **Set the FPGA's 100G address**: in `rfsoc/server/uhd_rfsoc.conf` set
   `data_ip` to an address on the subnet of the PC's 100G port (the one
   `host/setup_cx5.sh` configures on the PC). Nothing else is configured:
   the board's LAN address is whatever DHCP gives it, the FPGA's MAC is
   derived from the board's (`data_mac` overrides it).

4. **Put the bitstreams in `rfsoc/server/`** (each `.bit` with its `.hwh`):
   from the PC, the set of the board's PYNQ version from the `bitstreams/`
   submodule (`git submodule update --init bitstreams`) or your own builds

       rfsoc/push_bitstreams.sh bitstreams/pynq2.7/<board> xilinx@<board-ip>
       rfsoc/push_bitstreams.sh fpga/build/<board>/bitstreams xilinx@<board-ip>

   or copy a release's files there by hand. Any subset works; every
   installed build's rates are offered to UHD (top `README.md`, "Sample rate
   (bandwidth) and carrier").

5. **Start the daemon** (top of the checkout):

       ./run_daemon.sh          # returns once it serves (~20 s: bitstream, clocks, MTS, 100G link)
       ./run_daemon.sh status   # running? which build and rate
       ./run_daemon.sh log      # follow /tmp/uhd_daemon.log
       ./run_daemon.sh stop     # also: restart, fg (foreground, Ctrl-C stops)

   It runs `server/uhd_rfsoc_daemon.py` as root in the PYNQ venv with
   `--allow-unlocked`; extra arguments go to the daemon (`--help` lists
   them). The board is detected from PYNQ's device tree (`ZCU216`,
   `RFSoC4x2`); UHD sees both as `type=rfsoc`.

6. **On the PC**: `uhd_find_devices --args type=rfsoc`, then any UHD
   application (`host/README.md`).

Updating later: `git pull` on the board for the code, `push_bitstreams.sh`
for bitstreams. `uhd_rfsoc.conf` and the bitstreams are board-local and
gitignored, so a pull leaves them alone.

## If it does not serve

`./run_daemon.sh` prints the daemon's last line and `/tmp/uhd_daemon.out`;
the full log is `/tmp/uhd_daemon.log`.

| message | fix |
|---|---|
| `not serving: this board's PYNQ xrfdc has no multi-tile-sync bindings` | `sudo rfsoc/setup_board.sh` |
| `no FPGA data IP configured` / `no rfsoc/server/uhd_rfsoc.conf` | step 2 and 3 |
| `no bitstreams in rfsoc/server` / `bitstream variant skipped: ...` | step 4; the reason is in the log (no `.hwh`, a build of the other board, no clock register files for its fs) |
| `MTS NOT locked after 10 attempts` | the converter clocks: check the CLK104 (ZCU216) is seated, power-cycle the board and start again |
| serving, but `uhd_usrp_probe` reports `cmac_aligned: false` | the 100G link: the PC's port must be at 100G with RS-FEC (`host/setup_cx5.sh`); `sudo bash -c 'source /etc/profile.d/pynq_venv.sh && python3 rfsoc/server/bringup.py --status'` decodes the CMAC status on the board |

A systemd unit template is in `server/uhd-rfsoc.service` for a board
dedicated to the daemon (starting it loads a bitstream and restarts the RF
clocks).
