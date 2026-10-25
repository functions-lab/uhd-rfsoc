# host — the PC side

`libuhd_zcu216.so` is a UHD 4.6 device module (`type=zcu216`) that makes a
ZCU216 or RFSoC 4x2 running the board daemon (`../rfsoc/server`) look like a
USRP to every stock UHD application: `uhd_usrp_probe`, `rx_samples_to_file`,
`benchmark_rate`, GNU Radio, Python `uhd`. Samples travel over a 100 GbE link
with DPDK; control goes over the LAN. x86_64 (AVX-512 when present) and
aarch64 (NEON).

| in this directory | what |
|---|---|
| `lib/` | the module's sources (`lib/README.md`) |
| `tools/` | the `zcu216-uhd` wrapper, the no-board checks, the Python helpers (`tools/README.md`) |
| `setup_cx5.sh`, `setup_dpdk.sh` | one-time setup of the 100G port and of DPDK |
| `benchmark/` | tests on the real board (`benchmark/README.md`) |
| `gnuradio/` | GNU Radio flowgraphs (`gnuradio/README.md`) |
| `uhd/`, `gnuradio/gnuradio/` | the pinned upstream releases, as git submodules for reference; not needed to build |

Internals, every device argument, the data plane and the known limitations:
`AGENTS.md`.

## What you need

* Ubuntu 24.04 (UHD 4.6 and DPDK 23.11 are its packages) or another Linux
  with UHD 4.6 installed to a prefix (`-DUHD_ROOT=<prefix>` below) and DPDK
  found by pkg-config. The module is built against exactly UHD 4.6: CMake
  refuses anything else.
* A 100G NVIDIA/Mellanox ConnectX NIC (ConnectX-5, -6 or -7; driver
  `mlx5_core`) with a QSFP28 cable to the board.
* Root for every application that streams (DPDK needs it); `uhd_find_devices`
  does not.
* The board set up and serving: this repository cloned on the PYNQ board,
  the bitstreams copied there, `./run_daemon.sh` started (`../README.md`,
  "Set up the board").

## Set up the host (once)

```sh
sudo apt install libuhd-dev uhd-host python3-uhd libboost-dev \
    dpdk libdpdk-dev rdma-core ibverbs-providers cmake g++ pkg-config
sudo ./setup_cx5.sh <100g-iface> <host-data-ip>/24   # 100G without autoneg, RS-FEC, MTU 9000, the address
sudo ./setup_dpdk.sh <100g-iface> --install          # hugepages (persistent), mlx5 / RDMA checks
```

`<100g-iface>` is the NIC's netdev (`ip link`); `<host-data-ip>` is the PC's
end of the 100G link and must be on the subnet of the FPGA's `data_ip` (the
board's `rfsoc/server/zcu216_uhd.conf`), e.g. `192.168.5.1/24` for a
`data_ip` of `192.168.5.2`. Keep NetworkManager off the port
(`sudo nmcli device set <100g-iface> managed no`); `setup_cx5.sh` must be
re-run after a reboot unless its settings are made persistent (see its
header). A 200G / 400G port (ConnectX-7) is brought down to 100G CAUI-4 by
the script. The NIC stays bound to `mlx5_core`: the DPDK mlx5 driver is
bifurcated, the kernel keeps the netdev, its IP, ARP and ping.

## Build and install

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ldd build/libuhd_zcu216.so | grep uhd          # must be libuhd.so.4.6.0
sudo cmake --install build
#  -> /usr/lib/<multiarch>/uhd/modules/libuhd_zcu216.so   (UHD loads it by itself)
#  -> /usr/local/bin/zcu216-uhd                             (-DUHD_ZCU216_BIN_DIR=... to change)
```

Also built: `build/zcu216_kernel_check` (the SIMD kernels against the scalar
ones, bit for bit: run it, exit status 0), `build/zcu216_kernel_bench` and
(x86) `build/zcu216_dram_bench` -- host-only checks, no board needed
(`tools/README.md`).

## Find the board and stream

```sh
uhd_find_devices --args type=zcu216                 # no root: addr=<board-ip>, data_ip=, fpga=
A=type=zcu216,addr=<board-ip>
sudo uhd_usrp_probe --args $A,channels=4            # the tree; channels=N picks the N-channel build
E=/usr/libexec/uhd/examples                         # UHD's examples (not on sudo's PATH)
sudo $E/rx_samples_to_file --args $A,pattern=1 --rate 1.25e9 --freq 1e9 \
    --nsamps 100000000 --file /dev/shm/x.dat         # the FPGA's test pattern instead of the ADC
tools/check_pattern_file.py /dev/shm/x.dat --nsamps 100000000   # -> BIT-EXACT: the link works
sudo $E/benchmark_rate --args $A,nports=4 --rx_rate 1.25e9 --duration 10 --rx_cpu sc16
sudo $E/tx_waveforms --args $A,channels=2 --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
sudo python3 -c "import uhd; u = uhd.usrp.MultiUSRP('$A,channels=4'); print(u.get_rx_rate())"
sudo -E gnuradio-companion                          # GUI: -E keeps DISPLAY
```

`zcu216-uhd <app> [args]` runs the same things (sudo, the module's path,
bare example names such as `benchmark_rate` found for you): `zcu216-uhd
rx_samples_to_file --args ...`. A build tree instead of the installed module:
`ZCU216_MODULE=$PWD/build/libuhd_zcu216.so zcu216-uhd ...` (with nothing
installed; two copies of the module in one process is an error).

* `channels=N` (1, 2, 4, 8, 16 on a ZCU216; 1, 2 on an RFSoC 4x2) selects the
  bitstream; a new N reloads it (~16 s). Within one N, `set_rx_rate` /
  `--rate` picks the sample rate (= bandwidth) from the installed builds'
  rates, met from below; the board retunes (~1 s) or reloads (seconds). The
  rates per board: `../README.md`, "Sample rate (bandwidth) and carrier
  frequency".
* The top rates that only `sc8` (or `sc12`) fit on the link need the device
  arg `otw=sc8` (`otw=sc12`) and the matching `--wirefmt` / `--otw`;
  without it a request for them is served at the fastest sc16 rate.
* A first bring-up check of the whole link (probe, full-rate RX, bit-exact
  capture, TX): `benchmark/dpdk_rx_test.sh`.

## Full rate

The module places the application's threads off its DPDK cores by itself and
one direction at a time runs clean at the link rate with the defaults. Both
directions at once near the link limit (96 Gb/s each way) need the full-rate
layout in `AGENTS.md` ("Full-rate duplex"), `tools/isolate_cpus.sh` and the
`performance` governor.
