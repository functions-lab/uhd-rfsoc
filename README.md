# rfsoc-uhd

Xilinx RFSoC boards as UHD devices over 100 GbE. Stock UHD 4.6 applications
(`uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`, GNU Radio, Python
`uhd`) talk to the board as device `type=zcu216`: up to 16 RF channels, 3.0
GS/s aggregate in sc16 (6.0 GS/s in sc8), TX and RX beamforming, full-rate TX
and RX at once.

[![CI](https://github.com/WeiCheng14159/rfsoc-uhd/actions/workflows/ci.yml/badge.svg)](https://github.com/WeiCheng14159/rfsoc-uhd/actions/workflows/ci.yml)

## What you need

| side | what |
|---|---|
| board | a **ZCU216** (1, 2, 4, 8 or 16 channels, fs 2500 / 2250 or 2457.6 MS/s) or a **Real Digital RFSoC 4x2** (1 or 2 channels, fs 5000 or 4915.2 MS/s), running PYNQ 3.x, with a QSFP28 100G cable to the host |
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
the daemon (~1 s, MTS kept), e.g. 750, 562.5, 450 ... 56.25 MS/s at 4
channels. The sc8max builds carry `otw=sc8` only and reach rates whose sc16
stream would not fit the link.

| board | file | channels | top rate, MS/s per channel |
|---|---|---|---|
| ZCU216 | `zcu216_v49_1ch_qsfp_f2_fs2500.bit` | 1 | 1250 |
| | `zcu216_v49_2ch_qsfp_f2_fs2500.bit` | 2 | 1250 |
| | `zcu216_v49_4ch_qsfp_f3_fs2250.bit` | 4 | 750 |
| | `zcu216_v49_8ch_qsfp_f6_fs2250.bit` | 8 | 375 |
| | `zcu216_v49_16ch_qsfp_f12_fs2250.bit` | 16 | 187.5 |
| | `zcu216_v49_4ch_qsfp_f2_fs2500.bit` | 4 | 1250 (sc8max) |
| | `zcu216_v49_8ch_qsfp_f3_fs2250.bit` | 8 | 750 (sc8max) |
| | `zcu216_v49_16ch_qsfp_f6_fs2250.bit` | 16 | 375 (sc8max) |
| RFSoC 4x2 | `rfsoc4x2_v49_1ch_qsfp_f2_fs5000.bit` | 1 | 2500 |
| | `rfsoc4x2_v49_2ch_qsfp_f4_fs5000.bit` | 2 | 1250 |
| | `rfsoc4x2_v49_2ch_qsfp_f2_fs5000.bit` | 2 | 2500 (sc8max) |

A second clock family puts the converters on a 245.76 MHz reference: fs
2457.6 MS/s on the ZCU216 and 4915.2 MS/s on the RFSoC 4x2, i.e. per-channel
rates 1228.8, 819.2, 614.4, 491.52, 409.6, 307.2, 245.76, 204.8, 153.6,
122.88 ... MS/s. One template per channel count serves every factor; its
top rates carry only `otw=sc8` (and `sc12`) where sc16 would not fit the
link, the lower ones every format.

| board | file | channels | rates, MS/s per channel (sc16 from) |
|---|---|---|---|
| ZCU216 | `zcu216_v49_1ch_qsfp_f2_fs2457p6.bit` | 1 | 1228.8 .. 61.44 (all) |
| | `zcu216_v49_2ch_qsfp_f2_fs2457p6.bit` | 2 | 1228.8 .. 61.44 (all) |
| | `zcu216_v49_4ch_qsfp_f2_fs2457p6.bit` | 4 | 1228.8 .. 61.44 (614.4) |
| | `zcu216_v49_8ch_qsfp_f4_fs2457p6.bit` | 8 | 614.4 .. 61.44 (307.2) |
| | `zcu216_v49_16ch_qsfp_f8_fs2457p6.bit` | 16 | 307.2 .. 61.44 (153.6) |
| RFSoC 4x2 | `rfsoc4x2_v49_1ch_qsfp_f2_fs4915p2.bit` | 1 | 2457.6 .. 122.88 (all) |
| | `rfsoc4x2_v49_2ch_qsfp_f2_fs4915p2.bit` | 2 | 2457.6 .. 122.88 (1228.8) |

Install the builds of both families side by side: the daemon offers every
rate of every installed build, and an application picks one through UHD
(`set_rx_rate` / `set_tx_rate`, or `--rate`): the highest offered rate at or
below the request. A rate of the other family reloads the bitstream and
reprograms the board's clock chips (10-20 s); a rate of the loaded build
retunes in place (~1 s). At the top rates the FPGA delivers every packet in
every format, but full-duplex `sc12` near the link limit (4-16 channels,
3.3-3.9 GS/s aggregate) is more than an x86 host converting to sc16
keeps up with (RX loss at the NIC); `sc8` there, and `sc16` from the rate
where it fits, run clean.

Download them (with their `.hwh`) from the release, or build them:

```sh
# Vivado 2021.1 on PATH
make -C fpga_board/zcu216 v49-package          # package the custom cores (once)
make -C fpga_board/zcu216 v49-templates        # the five ZCU216 templates
make -C fpga_board/zcu216 v49 N=8 F=3 FS=2250  # one build, e.g. the 8ch sc8max
make -C fpga_board/rfsoc4x2 v49-templates      # the two RFSoC 4x2 templates
make -C fpga_board/zcu216 v49-templates-245m76    # the 245.76 MHz family (fs 2457.6)
make -C fpga_board/rfsoc4x2 v49-templates-245m76  # the 245.76 MHz family (fs 4915.2)
# -> fpga_board/<board>/build/v49_qsfp/bitstreams/
```

## Set up the board (once)

On the PYNQ board (user `xilinx`):

```sh
git clone https://github.com/WeiCheng14159/rfsoc-uhd.git ~/jupyter_notebooks/rfsoc-uhd
cd ~/jupyter_notebooks/rfsoc-uhd
cp rfsoc/server/zcu216_uhd.conf.example rfsoc/server/zcu216_uhd.conf   # set data_ip (the FPGA's 100G address)
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
`set_rx_rate` / `set_tx_rate` retune in place (~1 s) to the highest
supported rate at or below the request. For the sc8max rates pass
`otw=sc8`.

More: `host/README.md` (host module, device arguments), `rfsoc/server/README.md`
(daemon), `fpga_board/README.md` (FPGA), `host/benchmark/README.md`
(hardware tests), `host/gnuradio/README.md` (GNU Radio). Internals and the
wire protocol: `AGENTS.md`.

## Continuous integration

`.github/workflows/ci.yml` builds the host module on x86_64 and aarch64
(Ubuntu 24.04, UHD 4.6, DPDK 23.11), checks the SIMD kernels bit for bit
against the scalar ones (`zcu216_kernel_check`), and checks the Python and
shell sources. A `v*` tag publishes a GitHub release
(`.github/workflows/release.yml`).
