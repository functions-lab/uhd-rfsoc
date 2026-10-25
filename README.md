# rfsoc-uhd

Xilinx RFSoC boards as UHD devices over 100 GbE. Stock UHD 4.6 applications
(`uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`, GNU Radio, Python
`uhd`) talk to the board as device `type=zcu216`: up to 16 RF channels, 2.5
GS/s aggregate in sc16 (5.0 GS/s in sc8), TX and RX beamforming, full-rate TX
and RX at once. The sample rate, and with it the bandwidth, is variable: an
application picks it through UHD (`set_rx_rate`, `--rate`), from 61.44 to
1250 MS/s per channel on the ZCU216 and from 122.88 to 2500 MS/s on the
RFSoC 4x2, and the board retunes or reloads itself to serve it.

[![CI](https://github.com/WeiCheng14159/rfsoc-uhd/actions/workflows/ci.yml/badge.svg)](https://github.com/WeiCheng14159/rfsoc-uhd/actions/workflows/ci.yml)

## What you need

| side | what |
|---|---|
| board | a **ZCU216** (1, 2, 4, 8 or 16 channels, fs 2500 or 2457.6 MS/s) or a **Real Digital RFSoC 4x2** (1 or 2 channels, fs 5000 or 4915.2 MS/s), running PYNQ 3.x, with a QSFP28 100G cable to the host |
| host | Linux, x86_64 (AVX-512 used when present) or aarch64 (NEON), a 100G NVIDIA/Mellanox ConnectX NIC (ConnectX-5/6/7, mlx5), Ubuntu 24.04 packages `libuhd-dev` 4.6, `uhd-host`, `python3-uhd`, `dpdk` / `libdpdk-dev` 23.11, `rdma-core`; optionally `gnuradio` 3.10 |
| FPGA builds (optional) | Vivado 2021.1; prebuilt bitstreams are attached to each [release](https://github.com/WeiCheng14159/rfsoc-uhd/releases) |

The only software dependencies are UHD and GNU Radio (and DPDK for the data
plane); the exact upstream releases are pinned as git submodules for
reference (`host/uhd` at v4.6.0.0, `host/gnuradio/gnuradio` at v3.10.9.2:
`git submodule update --init --depth 1`). They are not needed to build.

## Layout

| directory | what | runs on |
|---|---|---|
| `host/` | the UHD device module `libuhd_zcu216.so` (DPDK data plane), its wrapper and tools, hardware tests (`host/benchmark/`), GNU Radio flowgraphs (`host/gnuradio/`) | host PC |
| `rfsoc/` | the board daemon (`server/`) and the `rfsoc_lib` modules it uses (RFDC, clocks, MTS) | board (PYNQ) |
| `run_daemon.sh` | start / stop the daemon on the board | board |
| `fpga_board/` | per board: the block designs (`block_designs/<board>_uhd_v49/` and, for the 245.76 MHz clock family, `<board>_uhd_v49_245m76/`; each one `.tcl` + `.xdc` for every channel count) and their build flow | Vivado |
| `fpga_ip/` | the custom FPGA IP: UHD data-plane cores, the 100G CMAC wrapper, the RFSoC 4x2 dual-ADC I/Q joiners | Vivado |

## Bitstreams

Each channel count has one run-time-rate template: it serves its top rate
and every lower RFDC decimation / interpolation factor, changed in place by
the daemon (~1 s, MTS kept), e.g. 1250, 833.33, 625 ... 62.5 MS/s at 4
channels. A template's top rates carry only `otw=sc8` (and `sc12`) where
sc16 would not fit the link, the lower ones every format. The RFSoC 4x2's
sc8max build reaches 2 x 2500 MS/s in `otw=sc8` and also serves the rates
down to 833.33 MS/s, with sc16 from 1250.

| board | file | channels | rates, MS/s per channel (sc16 from) |
|---|---|---|---|
| ZCU216 | `zcu216_v49_1ch_qsfp_f2_fs2500.bit` | 1 | 1250 .. 62.5 (all) |
| | `zcu216_v49_2ch_qsfp_f2_fs2500.bit` | 2 | 1250 .. 62.5 (all) |
| | `zcu216_v49_4ch_qsfp_f2_fs2500.bit` | 4 | 1250 .. 62.5 (625) |
| | `zcu216_v49_8ch_qsfp_f4_fs2500.bit` | 8 | 625 .. 62.5 (312.5) |
| | `zcu216_v49_16ch_qsfp_f8_fs2500.bit` | 16 | 312.5 .. 62.5 (156.25) |
| RFSoC 4x2 | `rfsoc4x2_v49_1ch_qsfp_f2_fs5000.bit` | 1 | 2500 .. 125 (all) |
| | `rfsoc4x2_v49_2ch_qsfp_f4_fs5000.bit` | 2 | 1250 .. 125 (all) |
| | `rfsoc4x2_v49_2ch_qsfp_f2_fs5000.bit` (sc8max) | 2 | 2500 .. 833.33 (1250) |

A second clock family puts the converters on a 245.76 MHz reference: fs
2457.6 MS/s on the ZCU216 and 4915.2 MS/s on the RFSoC 4x2. One template per
channel count serves every factor; its top rates carry only `otw=sc8` (and
`sc12`) where sc16 would not fit the link, the lower ones every format.

| board | file | channels | rates, MS/s per channel (sc16 from) |
|---|---|---|---|
| ZCU216 | `zcu216_v49_1ch_qsfp_f2_fs2457p6.bit` | 1 | 1228.8 .. 61.44 (all) |
| | `zcu216_v49_2ch_qsfp_f2_fs2457p6.bit` | 2 | 1228.8 .. 61.44 (all) |
| | `zcu216_v49_4ch_qsfp_f2_fs2457p6.bit` | 4 | 1228.8 .. 61.44 (614.4) |
| | `zcu216_v49_8ch_qsfp_f4_fs2457p6.bit` | 8 | 614.4 .. 61.44 (307.2) |
| | `zcu216_v49_16ch_qsfp_f8_fs2457p6.bit` | 16 | 307.2 .. 61.44 (153.6) |
| RFSoC 4x2 | `rfsoc4x2_v49_1ch_qsfp_f2_fs4915p2.bit` | 1 | 2457.6 .. 122.88 (all) |
| | `rfsoc4x2_v49_2ch_qsfp_f2_fs4915p2.bit` | 2 | 2457.6 .. 122.88 (1228.8) |

Download them (with their `.hwh`) from the release, or build them:

```sh
# Vivado 2021.1 on PATH
make -C fpga_board/zcu216 v49-package          # package the custom cores (once)
make -C fpga_board/zcu216 v49-templates        # the five ZCU216 templates
make -C fpga_board/zcu216 v49 N=8 F=4 FS=2500  # one build, e.g. the 8ch template
make -C fpga_board/rfsoc4x2 v49-templates      # the two RFSoC 4x2 templates
make -C fpga_board/zcu216 v49-templates-245m76    # the 245.76 MHz family (fs 2457.6)
make -C fpga_board/rfsoc4x2 v49-templates-245m76  # the 245.76 MHz family (fs 4915.2)
# -> fpga_board/<board>/build/v49_qsfp/bitstreams/
```

## Sample rate (bandwidth) and carrier frequency

The bandwidth IS the sample rate: each channel is digitised at fs / F, F the
RFDC decimation (= interpolation) factor in force, and the RFDC's filters
pass 0.96 x that rate (-3 dB; `host/benchmark/rate_bandwidth.py` measures
it), so UHD's `get_rx_bandwidth()` reports the rate. To change the
bandwidth, change the rate:

```sh
sudo /usr/libexec/uhd/examples/rx_samples_to_file --args type=zcu216,channels=2 \
    --rate 245.76e6 --freq 950e6 --nsamps 1000000 --file /tmp/rx.dat
sudo python3 -c "import uhd; u = uhd.usrp.MultiUSRP('type=zcu216,channels=2'); \
    u.set_rx_rate(614.4e6); print(u.get_rx_rate(), u.get_rx_bandwidth())"
```

* A request is met from below: the highest offered rate at or below it (so
  the bandwidth never exceeds the request), or the lowest rate if the
  request is below all of them. Read back `get_rx_rate()`: RX and TX always
  run at the same rate (one factor).
* A rate of the loaded bitstream retunes in place (~1 s: factor, converter
  clock, MTS); a rate of another bitstream of the same channel count (the
  other clock family, or the RFSoC 4x2's sc8max build) reloads (10-20 s). Streaming
  stops either way: set the rate before streaming, as UHD applications do.
* The rates that need more than sc16 fits on the link are offered only to a
  client that declares a narrower wire format: device arg `otw=sc8` (or
  `sc12`). Without one a request for them gets the fastest sc16 rate.
* The carrier is the RFDC fine-mixer NCO, set per channel and direction
  anywhere in the first Nyquist zone, 0 to fs/2 (a request outside is
  clamped).

F runs over 2 3 4 5 6 8 10 12 16 20 24 40, from each template's top rate
down. With every bitstream of both clock families installed (see
Bitstreams), the rates on offer (`get_rx_rates`, `uhd_usrp_probe`) are, in
MS/s per channel, with the wire formats in brackets where not every format
fits:

| board | N | fs 2500 / 5000 (250 MHz family) | fs 2457.6 / 4915.2 (245.76 MHz family) |
|---|---|---|---|
| ZCU216 | 1, 2 | 1250, 833.33, 625, 500, 416.67, 312.5, 250, 208.33, 156.25, 125, 104.17, 62.5 | 1228.8, 819.2, 614.4, 491.52, 409.6, 307.2, 245.76, 204.8, 153.6, 122.88, 102.4, 61.44 |
| | 4 | 1250 [sc8], 833.33 [sc12 sc8], 625 .. 62.5 | 1228.8 [sc8], 819.2 [sc12 sc8], 614.4 .. 61.44 |
| | 8 | 625 [sc8], 500, 416.67 [sc12 sc8]; 312.5 .. 62.5 | 614.4 [sc8], 491.52, 409.6 [sc12 sc8]; 307.2 .. 61.44 |
| | 16 | 312.5 [sc8], 250, 208.33 [sc12 sc8]; 156.25 .. 62.5 | 307.2 [sc8], 245.76, 204.8 [sc12 sc8]; 153.6 .. 61.44 |
| | carrier | 0 - 1250 MHz | 0 - 1228.8 MHz |
| RFSoC 4x2 | 1 | 2500, 1666.67, 1250, 1000, 833.33, 625, 500, 416.67, 312.5, 250, 208.33, 125 | 2457.6, 1638.4, 1228.8, 983.04, 819.2, 614.4, 491.52, 409.6, 307.2, 245.76, 204.8, 122.88 |
| | 2 | 2500 [sc8], 1666.67 [sc12 sc8], 1250 .. 125 | 2457.6 [sc8], 1638.4 [sc12 sc8], 1228.8 .. 122.88 |
| | carrier | 0 - 2500 MHz | 0 - 2457.6 MHz |

fc32 is offered where the link and the build's fabric beat allow it; the
daemon's `info rate_otw=` lists the formats of every rate (Protocol §9, §10
in `AGENTS.md`).

Only the installed bitstreams count: install both families' builds side by
side for every rate above (a rate of the other family also reprograms the
board's clock chips as part of its reload). The carrier range follows the
loaded build's fs: the frontend / NCO range
(`get_rx_lo_freq_range("NCO")`, `uhd_usrp_probe`'s "Freq range") is 0 -
fs/2 after every rate change, e.g. 1250 -> 1228.8 MHz when a 4-channel
ZCU216 goes from 625 to 614.4 MS/s. (`get_rx_freq_range()` adds the DSP
part's +-rate/2, as UHD does for every device; the centre still stops at
fs/2.)

At the top rates the FPGA delivers every packet in every format, but
full-duplex `sc12` near the link limit (4-16 channels, 3.3-4.0 GS/s
aggregate) is more than an x86 host converting to sc16 keeps up with (RX
loss at the NIC); `sc8` there, and `sc16` from the rate where it fits, run
clean in strict full-rate tests, bar an occasional run lost to the host.

## Set up the board (once)

On the PYNQ board (user `xilinx`):

```sh
git clone https://github.com/WeiCheng14159/rfsoc-uhd.git ~/jupyter_notebooks/rfsoc-uhd
cd ~/jupyter_notebooks/rfsoc-uhd
sudo rfsoc/setup_board.sh   # once: xrfdc MTS bindings if the image lacks them, zcu216_uhd.conf from the example
# then set data_ip (the FPGA's 100G address) in rfsoc/server/zcu216_uhd.conf
```

Put the bitstreams and their `.hwh` files in `rfsoc/server/` (from the
build machine: `rfsoc/push_bitstreams.sh <bitstream dir> xilinx@<board>`).
Then, on the board:

```sh
./run_daemon.sh             # start; returns once it serves (~20 s: bitstream, clocks, MTS)
./run_daemon.sh status      # running? which build and rate
./run_daemon.sh stop        # also: restart, log, fg (foreground); log /tmp/uhd_daemon.log
```

## Set up the host (once)

```sh
sudo apt install libuhd-dev uhd-host python3-uhd dpdk libdpdk-dev rdma-core ibverbs-providers cmake g++ pkg-config
sudo host/setup_cx5.sh <100g-iface> <host-data-ip>/24     # 100G without autoneg, RS-FEC, MTU 9000
sudo host/setup_dpdk.sh <100g-iface> --install            # hugepages, mlx5 / RDMA checks
cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release
cmake --build host/build -j
sudo cmake --install host/build                           # module into UHD's module dir, wrapper zcu216-uhd
```

`host/setup_cx5.sh` takes the port down to 100G CAUI-4, so a 200G / 400G
port (e.g. a ConnectX-7) works as well. Keep NetworkManager off the port
(`sudo nmcli device set <100g-iface> managed no`).

## Run

Any stock UHD application, run as root (the data plane is DPDK); the channel
count is the device arg `channels=`:

```sh
uhd_find_devices --args type=zcu216                      # every board; type=rfsoc4x2: only 4x2s
sudo uhd_usrp_probe --args type=zcu216,addr=<board-ip>,channels=4
sudo /usr/libexec/uhd/examples/tx_waveforms --args type=zcu216,channels=2 \
    --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
sudo python3 -c "import uhd; u = uhd.usrp.MultiUSRP('type=zcu216,channels=4'); print(u.get_rx_rate())"
host/gnuradio/run_tones.sh normal 4                      # GNU Radio: 4 tones out, 4 spectra in
```

A new `channels=` reloads the bitstream (~16 s). Within one channel count
`set_rx_rate` / `set_tx_rate` pick the sample rate (= bandwidth) as in
"Sample rate (bandwidth) and carrier frequency" above. For the rates only
sc8 (or sc12) fits pass `otw=sc8` (`otw=sc12`).

More: `host/README.md` (host setup), `host/AGENTS.md` (host module, device arguments), `rfsoc/server/README.md`
(daemon), `fpga_board/README.md` (FPGA), `host/benchmark/README.md`
(hardware tests), `host/gnuradio/README.md` (GNU Radio). Internals and the
wire protocol: `AGENTS.md`.

## Continuous integration

`.github/workflows/ci.yml` builds the host module on x86_64 and aarch64
(Ubuntu 24.04, UHD 4.6, DPDK 23.11), checks the SIMD kernels bit for bit
against the scalar ones (`zcu216_kernel_check`), and checks the Python and
shell sources. A `v*` tag publishes a GitHub release
(`.github/workflows/release.yml`).
