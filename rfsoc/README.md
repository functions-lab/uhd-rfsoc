# rfsoc — the board side

What runs on the RFSoC board (a ZCU216 or an RFSoC 4x2 with its PYNQ image).

| path | what |
|---|---|
| `server/` | the daemon that makes the board a UHD device (`server/README.md`) |
| `rfsoc_lib/` | the library the daemon brings the converters up with, and the clock chips' register files (`rfsoc_lib/README.md`) |
| `setup_board.sh` | one-time board setup, run on the board |
| `xrfdc_mts_patch.py` | used by `setup_board.sh`: adds multi-tile sync to PYNQ's `xrfdc` |
| `get_bitstreams.sh` | run on the PC: fetches the one prebuilt bitstream set a board needs, and can copy it to the board |
| `push_bitstreams.sh` | run on the PC: copies bitstreams into the board's checkout |
| `../run_daemon.sh` | start / stop / status / log of the daemon, run on the board |

## From a fresh PYNQ image to a serving daemon

You need:

- a ZCU216 or RFSoC 4x2 running PYNQ 2.7, 3.0 or 3.1, on the LAN (ssh as
  user `xilinx`);
- the QSFP28 cable to the host PC;
- the bitstreams for that PYNQ version: the `bitstreams/` submodule, a
  [release](https://github.com/WeiCheng14159/uhd-rfsoc/releases), or your
  own builds (`fpga/README.md`).

### 1. Clone on the board

```sh
git clone https://github.com/WeiCheng14159/uhd-rfsoc.git ~/jupyter_notebooks/uhd-rfsoc
cd ~/jupyter_notebooks/uhd-rfsoc
```

Any directory works; this one is the default of `push_bitstreams.sh` and of
the systemd unit.

### 2. Set the board up (once)

```sh
sudo rfsoc/setup_board.sh
```

It is safe to repeat, and `rfsoc/setup_board.sh --check` only reports. The
script:

- adds the multi-tile-sync (MTS) bindings to PYNQ's `xrfdc` Python wrapper
  if they are missing. PYNQ ships without them, and the daemon refuses to
  serve without MTS. The two patched files are kept as `*.stock`;
- creates `rfsoc/server/uhd_rfsoc.conf` from `uhd_rfsoc.conf.example` if
  there is none (an existing one is never touched);
- lists the bitstreams in `rfsoc/server/`.

### 3. Set the FPGA's 100G address

In `rfsoc/server/uhd_rfsoc.conf`, set `data_ip` to an address on the subnet
of the PC's 100G port (the one `host/setup_cx5.sh` configures).

Nothing else needs configuring: the board's LAN address is whatever DHCP
gives it, and the FPGA's MAC is derived from the board's (`data_mac`
overrides it).

**Reference clock** (optional). By default the board takes a 10 MHz
reference from its reference input (CLK104 REF IN on a ZCU216, the
reference SMA on an RFSoC 4x2), for example a GPSDO shared by several
boards, and falls back to its own oscillator when nothing is connected.
Boards that must agree in frequency (a gNB and a UE radio) need the shared
reference. `clock_source = internal` in `uhd_rfsoc.conf` uses the board's
oscillator only.

### 4. Put the bitstreams in `rfsoc/server/`

From the PC, one command installs the prebuilt set. It asks the board for
its type and PYNQ version, downloads only that set (15-55 MB, not every
set) and copies it over:

```sh
rfsoc/get_bitstreams.sh xilinx@<board-ip>
```

The same in two steps, or with your own builds:

```sh
rfsoc/get_bitstreams.sh zcu216 2.7                                             # fetch one set: <board> <pynq-version>
rfsoc/push_bitstreams.sh bitstreams/pynq2.7/zcu216 xilinx@<board-ip>           # copy it to the board
rfsoc/push_bitstreams.sh fpga/build/<board>/bitstreams xilinx@<board-ip>       # your builds
```

`rfsoc/get_bitstreams.sh -n xilinx@<board-ip>` is a dry run: it prints the
board type, the PYNQ version and the set, and copies nothing. A board or
PYNQ version without a prebuilt set is refused with the list of the sets
that exist; build that one yourself (`fpga/README.md`).

Or copy a release's files there by hand, each `.bit` with its `.hwh`. Any
subset works: every installed build's rates are offered to UHD (top
`README.md`, "Sample rate (bandwidth) and carrier").

### 5. Start the daemon

From the top of the checkout:

```sh
./run_daemon.sh          # returns once it serves (~20 s: bitstream, clocks, MTS, 100G link)
./run_daemon.sh status   # running? which build and rate
./run_daemon.sh log      # follow /tmp/uhd_daemon.log
./run_daemon.sh stop     # also: restart, fg (foreground, Ctrl-C stops)
```

The daemon runs as root in the PYNQ environment. Extra arguments go to
`server/uhd_rfsoc_daemon.py` (`--help` lists them). The board type is
detected by itself; UHD sees both boards as `type=rfsoc`.

### 6. On the PC

`uhd_find_devices --args type=rfsoc`, then any UHD application
(`host/README.md`).

### Updating later

`git pull` on the board for the code, `push_bitstreams.sh` for bitstreams.
`uhd_rfsoc.conf` and the bitstreams are board-local and gitignored, so a
pull leaves them alone.

## If it does not serve

`./run_daemon.sh` prints the daemon's last line. The full log is
`/tmp/uhd_daemon.log`, its console output `/tmp/uhd_daemon.out`.

| message | fix |
|---|---|
| `not serving: this board's PYNQ xrfdc has no multi-tile-sync bindings` | `sudo rfsoc/setup_board.sh` |
| `no FPGA data IP configured` / `no rfsoc/server/uhd_rfsoc.conf` | steps 2 and 3 |
| `no bitstreams in rfsoc/server` / `bitstream variant skipped: ...` | step 4. The log says why a build was skipped: no `.hwh`, a build of the other board, or no clock register files for its fs |
| `MTS NOT locked after 10 attempts` | the converter clocks: check that the CLK104 (ZCU216) is seated, power-cycle the board, start again |
| serving, but `uhd_usrp_probe` reports `cmac_aligned: false` | the 100G link: the PC's port must be at 100G with RS-FEC (`host/setup_cx5.sh`). To decode the link status on the board, see "Debugging" in `server/README.md` |

## Start at boot

`server/uhd-rfsoc.service` is a systemd unit template, for a board dedicated
to the daemon: starting it loads a bitstream and restarts the RF clocks.
