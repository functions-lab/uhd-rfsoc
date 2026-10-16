# host — the PC side

`libuhd_zcu216.so`, a UHD 4.6 device module (type `zcu216`) that streams over
DPDK (mlx5: ConnectX-5, -6 or -7). Installed, it serves every stock UHD application
run as root (DPDK): `sudo <app> --args type=zcu216,channels=N,...`. The
module places the application's threads off its DPDK cores itself. It builds
and runs on x86_64 and aarch64 Linux.

```
sudo ./setup_cx5.sh <100g-iface> <host-data-ip>/24      # NIC: 100G, RS-FEC, MTU 9000
sudo ./setup_dpdk.sh <100g-iface> --install             # DPDK packages, hugepages
cmake -S . -B build && cmake --build build -j && sudo cmake --install build
sudo uhd_usrp_probe --args type=zcu216,addr=<board-ip>,channels=4
sudo /usr/libexec/uhd/examples/tx_waveforms --args type=zcu216,channels=2 --rate 625e6 --freq 950e6
```

The board must be serving first: this repository cloned on the PYNQ board,
the bitstreams copied there with `rfsoc/push_bitstreams.sh <bitstream dir>
<ssh target>`, and the daemon started there with `./run_daemon.sh` (see
`../README.md`).

Full rate (up to 3.0 GS/s of sc16, 97 % of the link, both directions at
once) needs the full-rate CPU layout in `AGENTS.md`, `sudo tools/isolate_cpus.sh
apply` and governor `performance`.

Tests on the real board: `benchmark/`. Without a board:
`build/zcu216_kernel_check` (the SIMD kernels -- AVX-512 on x86, NEON on
aarch64 -- against the scalar ones, bit for bit), `build/zcu216_kernel_bench`
(kernel and worker-pool throughput), `build/zcu216_dram_bench` (x86 only: the
host data path against DRAM) and the FPGA simulations in
`../fpga_ip/ip_design/uhd_ip/sim`.
Device arguments, data plane and limitations: `AGENTS.md`.
