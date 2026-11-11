# host — the PC side

`libuhd_rfsoc.so` is a UHD 4.6 device module. It makes a ZCU216 or RFSoC 4x2
running the board daemon look like a USRP (`type=rfsoc`) to every stock UHD
application: `uhd_usrp_probe`, `rx_samples_to_file`, `benchmark_rate`,
GNU Radio, Python `uhd`.

Samples travel over the 100 GbE link with DPDK; control goes over the LAN.
Runs on x86_64 (AVX-512 when present) and aarch64 (NEON).

| in this directory | what |
|---|---|
| `lib/` | the module's sources (`lib/README.md`) |
| `tools/` | the `uhd-rfsoc` wrapper, checks that need no board, Python helpers (`tools/README.md`) |
| `setup_cx5.sh`, `setup_dpdk.sh` | one-time setup of the 100G port and of DPDK |
| `benchmark/` | tests on the real board (`benchmark/README.md`) |
| `gnuradio/` | GNU Radio flowgraphs (`gnuradio/README.md`) |
| `uhd/`, `gnuradio/gnuradio/` | the upstream sources as reference submodules; not needed to build |

Internals, every device argument and the known limitations: `AGENTS.md`.

## What you need

- Ubuntu 24.04: UHD 4.6 and DPDK 23.11 are its packages. On another Linux,
  install UHD 4.6 to a prefix and pass `-DUHD_ROOT=<prefix>` to CMake. The
  module builds against UHD 4.6 only.
- A 100G NVIDIA/Mellanox ConnectX-5, -6 or -7 NIC (driver `mlx5_core`) with
  a QSFP28 cable to the board.
- Root for every application that streams (DPDK needs it).
  `uhd_find_devices` does not need it.
- The board set up and its daemon running (`../rfsoc/README.md`).

## Set up the host (once)

```sh
sudo apt install libuhd-dev uhd-host python3-uhd libboost-dev \
    dpdk libdpdk-dev rdma-core ibverbs-providers cmake g++ pkg-config
sudo ./setup_cx5.sh <100g-iface> <host-data-ip>/24   # 100G, RS-FEC, MTU 9000, the address
sudo ./setup_dpdk.sh <100g-iface> --install          # hugepages (persistent), driver checks
```

- `<100g-iface>` is the NIC's network device (`ip link`).
- `<host-data-ip>` is the PC's end of the 100G link. It must be on the
  subnet of the FPGA's `data_ip` (the board's `rfsoc/server/uhd_rfsoc.conf`):
  e.g. `192.168.5.1/24` for a `data_ip` of `192.168.5.2`.
- Keep NetworkManager off the port:
  `sudo nmcli device set <100g-iface> managed no`.
- Re-run `setup_cx5.sh` after a reboot, or make it persistent (its header
  says how).

The NIC keeps its kernel driver, so its IP address, ARP and ping keep
working next to DPDK.

## Build and install

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ldd build/libuhd_rfsoc.so | grep uhd     # must show libuhd.so.4.6.0
sudo cmake --install build
```

This installs:

- the module into UHD's module directory
  (`/usr/lib/<multiarch>/uhd/modules/`), where UHD loads it by itself;
- the wrapper `uhd-rfsoc` into `/usr/local/bin`
  (`-DUHD_RFSOC_BIN_DIR=...` to change).

The build also produces checks that need no board, such as
`build/rfsoc_kernel_check` (`tools/README.md`).

## Find the board and stream

`uhd-rfsoc <app> [args]` runs a UHD application as root with the module
loaded, and finds UHD's examples by name:

```sh
uhd_find_devices --args type=rfsoc                 # no root: prints addr=<board-ip>
A=type=rfsoc,addr=<board-ip>
uhd-rfsoc uhd_usrp_probe --args $A,channels=4
uhd-rfsoc benchmark_rate --args $A,nports=4 --rx_rate 1.25e9 --duration 10 --rx_cpu sc16
uhd-rfsoc tx_waveforms --args $A,channels=2 --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
uhd-rfsoc python3 -c "import uhd; u = uhd.usrp.MultiUSRP('$A,channels=4'); print(u.get_rx_rate())"
```

Check the link end to end: capture the FPGA's test pattern instead of the
ADC, then verify every bit.

```sh
uhd-rfsoc rx_samples_to_file --args $A,pattern=1 --rate 1.25e9 --freq 1e9 \
    --nsamps 100000000 --file /dev/shm/x.dat
tools/check_pattern_file.py /dev/shm/x.dat --nsamps 100000000    # -> BIT-EXACT
```

`benchmark/dpdk_rx_test.sh` runs a complete first check: probe, full-rate
RX, the bit-exact capture, TX.

Good to know:

- **Without the wrapper**, plain `sudo` works too. UHD's examples are in
  `/usr/libexec/uhd/examples`, which is not on sudo's PATH. For a GUI, keep
  the display: `sudo -E gnuradio-companion`.
- **A build tree instead of the installed module:**
  `UHD_RFSOC_MODULE=$PWD/build/libuhd_rfsoc.so uhd-rfsoc ...`, with nothing
  installed (two copies of the module in one process is an error).
- **Channels:** `channels=N` selects the bitstream: 1, 2, 4, 8 or 16 on a
  ZCU216; 1 or 2 on an RFSoC 4x2. A new N reloads it (~16 s).
- **Rate:** `set_rx_rate` / `--rate` picks the sample rate (= bandwidth)
  from the installed builds' rates, met from below. The board retunes (~1 s)
  or reloads (seconds). The rates: `../README.md`, "Sample rate (bandwidth)
  and carrier".
- **Top rates in sc8 or sc12:** the rates that only a narrow wire format
  fits need the device argument `otw=sc8` (or `otw=sc12`) and the matching
  `--wirefmt` / `--otw`. Without it they are served at the fastest sc16
  rate.

## Full rate

One direction at a time runs clean at the link rate with the defaults: the
module keeps the application's threads off its DPDK cores by itself.

Both directions at once near the link rate need more care:

- the full-rate CPU layout (`AGENTS.md`, "Full-rate duplex");
- `tools/isolate_cpus.sh`;
- the `performance` CPU governor.

With these, a 6-core host reaches its limit at about 80 Gb/s each way
(`AGENTS.md`, "Where a 6-core host stops").
