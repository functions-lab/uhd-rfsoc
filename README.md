# uhd-rfsoc

AMD RFSoC boards as UHD devices over 100 GbE. Stock UHD 4.6 applications
(`uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`, GNU Radio, Python
`uhd`) see the board as device `type=rfsoc`: up to 16 RF channels in one
stream, 2.5 GS/s aggregate in sc16 (5.0 GS/s in sc8), TX and RX beamforming,
full-rate TX and RX at once. The sample rate (= bandwidth) is whatever the
application asks for through UHD (`set_rx_rate`, `--rate`); the board
retunes or reloads itself to serve it.

[![CI](https://github.com/WeiCheng14159/uhd-rfsoc/actions/workflows/ci.yml/badge.svg)](https://github.com/WeiCheng14159/uhd-rfsoc/actions/workflows/ci.yml)

## Boards

| board | channels | converter rate fs (MS/s) | per-channel rate (MS/s) | carrier |
|---|---|---|---|---|
| AMD ZCU216 | 1, 2, 4, 8, 16 | 2500 or 2457.6 | 61.44 .. 1250 | 0 .. fs/2 |
| Real Digital RFSoC 4x2 | 1, 2 | 5000 or 4915.2 | 122.88 .. 2500 | 0 .. fs/2 |

Another RFSoC board can be added: `fpga/README.md` ("Add a board") and a
`Board` entry in `rfsoc/server/boards.py`.

## What you need

| side | what |
|---|---|
| board | one of the above with PYNQ, and a QSFP28 100G cable to the host |
| host | Linux on x86_64 (AVX-512 used when present) or aarch64, a ConnectX-5/6/7 100G NIC (mlx5), Ubuntu 24.04 packages `libuhd-dev` 4.6, `uhd-host`, `python3-uhd`, `dpdk` / `libdpdk-dev` 23.11, `rdma-core`; optionally `gnuradio` 3.10 |
| bitstreams | from a [release](https://github.com/WeiCheng14159/uhd-rfsoc/releases), or built with Vivado 2021.1 (`fpga/README.md`) |

UHD 4.6.0.0 and GNU Radio 3.10.9.2 are pinned as reference submodules
(`host/uhd`, `host/gnuradio/gnuradio`); building does not need them.

## Get started

**1. Bitstreams.** Download the board's `.bit` + `.hwh` files from the
release, or build them:

```sh
cd fpga && make BOARD=zcu216 templates   # or BOARD=rfsoc4x2; -> fpga/build/<board>/bitstreams/
```

**2. The board** (PYNQ, user `xilinx`):

```sh
git clone https://github.com/WeiCheng14159/uhd-rfsoc.git ~/jupyter_notebooks/uhd-rfsoc
cd ~/jupyter_notebooks/uhd-rfsoc
sudo rfsoc/setup_board.sh       # once: xrfdc MTS bindings if missing, rfsoc/server/uhd_rfsoc.conf
# set data_ip (the FPGA's 100G address, on the host port's subnet) in rfsoc/server/uhd_rfsoc.conf
```

Copy the bitstreams into `rfsoc/server/` (from the build machine:
`rfsoc/push_bitstreams.sh fpga/build/<board>/bitstreams xilinx@<board-ip>`),
then on the board:

```sh
./run_daemon.sh                 # start; returns once it serves (~20 s)
./run_daemon.sh status          # also: stop, restart, log, fg; log /tmp/uhd_daemon.log
```

**3. The host:**

```sh
sudo apt install libuhd-dev uhd-host python3-uhd dpdk libdpdk-dev rdma-core ibverbs-providers cmake g++ pkg-config
sudo host/setup_cx5.sh <100g-iface> <host-data-ip>/24   # 100G CAUI-4, RS-FEC, MTU 9000
sudo host/setup_dpdk.sh <100g-iface> --install          # hugepages, mlx5 / RDMA checks
cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release && cmake --build host/build -j
sudo cmake --install host/build                         # the module into UHD's module dir, the wrapper uhd-rfsoc
```

Keep NetworkManager off the 100G port (`sudo nmcli device set <100g-iface>
managed no`). `host/README.md` has the details.

**4. Run** any UHD application as root (the data plane is DPDK);
`uhd-rfsoc <app>` adds `sudo` and finds UHD's examples:

```sh
uhd_find_devices --args type=rfsoc                      # every board (no root needed)
uhd-rfsoc uhd_usrp_probe --args type=rfsoc,addr=<board-ip>,channels=4
uhd-rfsoc benchmark_rate --args type=rfsoc,addr=<board-ip> --rx_rate 1.25e9 --rx_cpu sc16
uhd-rfsoc tx_waveforms --args type=rfsoc,channels=2 --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
host/gnuradio/run_tones.sh 1 --addr <board-ip>          # GNU Radio: a tone out, its spectrum in
```

Device args: `addr=` picks a board (else discovery), `channels=N` the
channel count (a new N reloads the bitstream, ~16 s), `product=zcu216` /
`rfsoc4x2` filters by board. The names from before the rename still work:
`type=zcu216` (any board) and `type=rfsoc4x2` (RFSoC 4x2 only).

## Sample rate (bandwidth) and carrier

Each channel is digitised at fs / F, F the RFDC decimation (= interpolation)
factor, and the RFDC filters pass 0.96 x that rate (-3 dB), so the rate IS
the bandwidth (`get_rx_bandwidth()` reports it).

* A rate request is met from below: the highest offered rate at or below it
  (else the lowest). RX and TX always run at the same rate.
* A rate of the loaded bitstream retunes in place (~1 s); another
  bitstream's rate (the other clock family) reloads (10-20 s). Streaming
  stops either way: set the rate before streaming, as UHD applications do.
* Rates only a narrower wire format fits on the link are offered when the
  client declares it: device arg `otw=sc8` (or `sc12`) and the matching
  `--wirefmt` / `--otw`.
* The carrier is the RFDC fine-mixer NCO, per channel and direction,
  anywhere in 0 .. fs/2 of the loaded build.

Each channel count has one run-time-rate build per clock family (a
template) that serves every factor F of 2 3 4 5 6 8 10 12 16 20 24 40 from
its top rate down. The rates, in MS/s per channel (wire formats in brackets
where not every one fits):

| board | N | 250 MHz family (fs 2500 / 5000) | 245.76 MHz family (fs 2457.6 / 4915.2) |
|---|---|---|---|
| ZCU216 | 1, 2 | 1250, 833.33, 625, 500, 416.67, 312.5, 250, 208.33, 156.25, 125, 104.17, 62.5 | 1228.8, 819.2, 614.4, 491.52, 409.6, 307.2, 245.76, 204.8, 153.6, 122.88, 102.4, 61.44 |
| | 4 | 1250 [sc8], 833.33 [sc12 sc8], 625 .. 62.5 | 1228.8 [sc8], 819.2 [sc12 sc8], 614.4 .. 61.44 |
| | 8 | 625 [sc8], 500, 416.67 [sc12 sc8], 312.5 .. 62.5 | 614.4 [sc8], 491.52, 409.6 [sc12 sc8], 307.2 .. 61.44 |
| | 16 | 312.5 [sc8], 250, 208.33 [sc12 sc8], 156.25 .. 62.5 | 307.2 [sc8], 245.76, 204.8 [sc12 sc8], 153.6 .. 61.44 |
| RFSoC 4x2 | 1 | 2500, 1666.67, 1250 .. 125 | 2457.6, 1638.4, 1228.8 .. 122.88 |
| | 2 | 1250 .. 125; with the extra sc8max build also 2500 [sc8], 1666.67 [sc12 sc8] | 2457.6 [sc8], 1638.4 [sc12 sc8], 1228.8 .. 122.88 |

Only installed bitstreams count: install both families for every rate. The
daemon's `info rate_otw=` lists each rate's formats (Protocol §9, §10 in
`AGENTS.md`).

## Layout

| directory | what | runs on |
|---|---|---|
| `fpga/` | the bitstreams: one build flow for every board in `fpga/boards/<board>/`, the custom IP in `fpga/ip/` | Vivado |
| `rfsoc/` | the board daemon (`server/`) and the `rfsoc_lib` it uses (RFDC, clocks, MTS); `run_daemon.sh` (top) starts it | board (PYNQ) |
| `host/` | the UHD module `libuhd_rfsoc.so` (DPDK data plane), the `uhd-rfsoc` wrapper and tools, hardware tests (`benchmark/`), GNU Radio flowgraphs (`gnuradio/`) | host PC |

Each directory's `README.md` is for users, its `AGENTS.md` for contributors;
`AGENTS.md` here has the rules and the wire protocol.

## Continuous integration

`.github/workflows/ci.yml` builds the host module on x86_64 and aarch64
(Ubuntu 24.04, UHD 4.6, DPDK 23.11), checks the SIMD kernels against the
scalar ones bit for bit, runs the daemon's unit tests, compiles every
flowgraph and checks the Python and shell sources. A `v*` tag publishes a
release (`.github/workflows/release.yml`).
