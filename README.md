# uhd-rfsoc

[![CI](https://github.com/WeiCheng14159/uhd-rfsoc/actions/workflows/ci.yml/badge.svg)](https://github.com/WeiCheng14159/uhd-rfsoc/actions/workflows/ci.yml)

Use an AMD RFSoC board as a UHD device over 100 GbE. Stock UHD 4.6
applications (`uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`,
GNU Radio, Python `uhd`) see the board as device `type=rfsoc`.

- Up to 16 RF channels in one stream.
- 2.5 GS/s aggregate in sc16, 5.0 GS/s in sc8.
- TX and RX at full rate at the same time.
- TX and RX beamforming in the FPGA.
- The sample rate (= bandwidth) is chosen at run time through UHD
  (`set_rx_rate`, `--rate`): the board retunes or reloads itself to serve it.

## Boards

| board | channels | converter rate fs (MS/s) | per-channel rate (MS/s) | carrier |
|---|---|---|---|---|
| AMD ZCU216 | 1, 2, 4, 8, 16 | 2500, 2457.6 or 2400 | 60 .. 1250 | 0 .. fs/2 |
| Real Digital RFSoC 4x2 | 1, 2 | 5000, 4915.2 or 4800 | 120 .. 2500 | 0 .. fs/2 |

To add another RFSoC board, see "Add a board" in `fpga/README.md`.

## How it fits together

```
 host PC                                              RFSoC board
 ┌──────────────────────┐   1 GbE LAN: control    ┌───────────────────────┐
 │ UHD application      │ ──────────────────────► │ daemon (PYNQ)         │
 │ libuhd_rfsoc.so      │   100 GbE: samples      │ FPGA: RF converters,  │
 │ ConnectX 100G NIC    │ ◄─────────────────────► │ packetizer, 100G MAC  │
 └──────────────────────┘                         └───────────────────────┘
```

| directory | what | runs on |
|---|---|---|
| `fpga/` | the bitstreams: one build flow for every board, plus the custom IP | Vivado |
| `rfsoc/` | the board daemon and the library it brings the converters up with | the board (PYNQ) |
| `host/` | the UHD module (DPDK data plane), the `uhd-rfsoc` wrapper, tools, hardware tests, GNU Radio flowgraphs | the host PC |

Every directory has a `README.md` for users and an `AGENTS.md` for
contributors. The top `AGENTS.md` holds the project rules and the wire
protocol.

## What you need

**Board**

- A ZCU216 or RFSoC 4x2 running PYNQ 2.7, 3.0 or 3.1.
- A QSFP28 100G cable to the host.

**Host**

- Linux on x86_64 (AVX-512 is used when present) or aarch64.
- A ConnectX-5, -6 or -7 100G NIC (driver mlx5).
- UHD 4.6, DPDK 23.11 and rdma-core: the stock packages of Ubuntu 24.04.
  GNU Radio 3.10 is optional.

**Bitstreams**

- The set for your board and its PYNQ version: prebuilt (step 1 below) or
  built with Vivado (`fpga/README.md`).

## Get started

### 1. Get the code and the bitstreams

On the PC:

```sh
git clone git@github.com:WeiCheng14159/uhd-rfsoc.git && cd uhd-rfsoc
git submodule update --init bitstreams      # the prebuilt bitstreams (~180 MB)
(cd bitstreams/pynq2.7/zcu216 && sha256sum -c --quiet SHA256SUMS)   # check a set
```

The `bitstreams/` submodule holds one set per PYNQ version and board, in
`bitstreams/pynq<version>/<board>/` (`.bit` + `.hwh` files). It is fetched
over SSH, so it needs an SSH key registered with GitHub.

Two other ways to get a set:

- Download `uhd-rfsoc-bitstreams-<board>-pynq<version>.zip` from a
  [release](https://github.com/WeiCheng14159/uhd-rfsoc/releases).
- Build it: `cd fpga && make BOARD=zcu216 templates` (add `PYNQ=3.0` or
  `PYNQ=3.1` for those images; `fpga/README.md`).

### 2. Set up the board

On the board (PYNQ, user `xilinx`):

```sh
git clone https://github.com/WeiCheng14159/uhd-rfsoc.git ~/jupyter_notebooks/uhd-rfsoc
cd ~/jupyter_notebooks/uhd-rfsoc
sudo rfsoc/setup_board.sh       # once
```

Then:

1. In `rfsoc/server/uhd_rfsoc.conf`, set `data_ip`: the FPGA's 100G address,
   on the subnet of the host's 100G port.
2. Copy the bitstreams into `rfsoc/server/`. From the PC:
   `rfsoc/push_bitstreams.sh bitstreams/pynq<version>/<board> xilinx@<board-ip>`
   (your own builds: `fpga/build/<board>/bitstreams`).
3. Start the daemon:

```sh
./run_daemon.sh           # returns once it serves (~20 s)
./run_daemon.sh status    # also: stop, restart, log, fg
```

Details and troubleshooting: `rfsoc/README.md`.

### 3. Set up the host

```sh
sudo apt install libuhd-dev uhd-host python3-uhd libboost-dev \
    dpdk libdpdk-dev rdma-core ibverbs-providers cmake g++ pkg-config
sudo host/setup_cx5.sh <100g-iface> <host-data-ip>/24   # the 100G port: RS-FEC, MTU 9000, address
sudo host/setup_dpdk.sh <100g-iface> --install          # hugepages, driver checks
cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release
cmake --build host/build -j
sudo cmake --install host/build                         # the UHD module and the uhd-rfsoc wrapper
```

Keep NetworkManager off the 100G port:
`sudo nmcli device set <100g-iface> managed no`. Details: `host/README.md`.

### 4. Run

Streaming needs root (the data plane is DPDK). `uhd-rfsoc <app>` adds `sudo`
and finds UHD's examples:

```sh
uhd_find_devices --args type=rfsoc      # lists every board; no root needed
uhd-rfsoc uhd_usrp_probe --args type=rfsoc,addr=<board-ip>,channels=4
uhd-rfsoc benchmark_rate --args type=rfsoc,addr=<board-ip> --rx_rate 1.25e9 --rx_cpu sc16
uhd-rfsoc tx_waveforms --args type=rfsoc,channels=2 --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
host/gnuradio/run_tones.sh 1 --addr <board-ip>    # GNU Radio: a tone out, its spectrum in
```

The device arguments you will use most:

| argument | meaning |
|---|---|
| `addr=<board-ip>` | which board; without it, the one discovery finds |
| `channels=N` | the channel count (default 1); a new N reloads the bitstream (~16 s) |
| `product=zcu216` / `rfsoc4x2` | only boards of that kind |
| `otw=sc8` / `sc12` | the wire format, for the rates only a narrow format fits (below) |

The device types from before the rename still work: `type=zcu216` (any
board) and `type=rfsoc4x2` (RFSoC 4x2 only). Every argument:
`host/AGENTS.md`, "Device arguments".

## Sample rate (bandwidth) and carrier

Each channel runs at **fs / F**: fs is the converter rate of the bitstream,
F the RFDC decimation (= interpolation) factor, one of 2, 3, 4, 5, 6, 8, 10,
12, 16, 20, 24, 40. The RFDC filters pass 0.96 x that rate (-3 dB), so the
rate is the bandwidth (`get_rx_bandwidth()` reports it).

- **Requests are met from below.** You get the highest offered rate at or
  below your request, or the lowest rate if the request is below them all.
  RX and TX always share one rate.
- **A rate change stops streaming.** Another rate of the loaded bitstream
  takes ~1 s (retune in place); a rate of another fs takes 10-20 s (reload).
  Set the rate before streaming, as UHD applications do.
- **The carrier** is the RFDC mixer (NCO), set per channel and direction
  anywhere in 0 .. fs/2.

Per-channel rates in MS/s, from the top rate down through every factor:

| board | channels | F | fs 2500 / 5000 | fs 2457.6 / 4915.2 | fs 2400 / 4800 |
|---|---|---|---|---|---|
| ZCU216 | 1, 2, 4 | 2 .. 40 | 1250 .. 62.5 | 1228.8 .. 61.44 | 1200 .. 60 |
| ZCU216 | 8 | 4 .. 40 | 625 .. 62.5 | 614.4 .. 61.44 | 600 .. 60 |
| ZCU216 | 16 | 8 .. 40 | 312.5 .. 62.5 | 307.2 .. 61.44 | 300 .. 60 |
| RFSoC 4x2 | 1 | 2 .. 40 | 2500 .. 125 | 2457.6 .. 122.88 | 2400 .. 120 |
| RFSoC 4x2 | 2 | 2 .. 40 | 1250 .. 125 (*) | 2457.6 .. 122.88 | 2400 .. 120 |

(*) The fs 5000 two-channel build starts at F = 4. The extra sc8max build
adds 2500 and 1666.67 MS/s.

Each column is one bitstream per channel count. Only installed bitstreams
count: install every fs to be offered every rate.

### Rates that need a narrower wire format

The 100G link carries 12.38 GB/s of samples, so the top rates of the
many-channel builds do not fit in sc16. What fits depends on the aggregate
rate, channels x per-channel rate:

| aggregate rate | wire formats that fit |
|---|---|
| up to 3.09 GS/s | sc16, sc12, sc8 |
| up to 4.13 GS/s | sc12, sc8 |
| up to 6.19 GS/s | sc8 |

Example: 4 channels at 1250 MS/s is 5.0 GS/s, sc8 only.

A rate that needs sc8 or sc12 is offered only when the client declares the
format: device argument `otw=sc8` (or `otw=sc12`) plus the application's
matching `--wirefmt` / `--otw`. Without it, the request is served at the
fastest sc16 rate.

The exact formats of every build and rate (fc32 too): Protocol §9 and §10 in
`AGENTS.md`, or the daemon's `info rate_otw=`.

## Development

CI (`.github/workflows/ci.yml`) builds the host module on x86_64 and
aarch64, checks the SIMD kernels bit for bit against the scalar code, runs
the daemon's unit tests, compiles every flowgraph and checks the Python and
shell sources. A `v*` tag publishes a release. Bitstreams are built locally
with Vivado, one set per board and PYNQ version, never in CI.

Contributing: start with `AGENTS.md`.

## Submodules

| path | what | needed for |
|---|---|---|
| `bitstreams/` | the prebuilt bitstreams, [uhd-rfsoc-bitstream](https://github.com/WeiCheng14159/uhd-rfsoc-bitstream), tagged like this repository (`v1.0` here pins its `v1.0`) | installing bitstreams on a board (on the PC) |
| `host/uhd` | UHD v4.6.0.0 sources, reference only | nothing: building uses the installed UHD |
| `host/gnuradio/gnuradio` | GNU Radio v3.10.9.2 sources, reference only | nothing |

```sh
git submodule update --init bitstreams          # only the bitstreams
git submodule update --init                     # every submodule
git pull && git submodule update bitstreams     # later: follow a new pin
```

`bitstreams/` comes as a shallow clone of its pinned commit; the other two
come with their full history (large, and nothing needs them). The board's
checkout needs no submodule: bitstreams are copied to it from the PC.
