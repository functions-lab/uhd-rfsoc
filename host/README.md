# host — the PC side

`libuhd_zcu216.so`, a UHD 4.6 device module (type `zcu216`) that streams over
DPDK (mlx5, ConnectX-5), plus the `zcu216-uhd` wrapper every UHD app runs
through (root for DPDK, the module path, CPU placement).

```
sudo ./setup_cx5.sh <100g-iface> <host-data-ip>/24      # NIC: 100G, RS-FEC, MTU 9000
sudo ./setup_dpdk.sh <100g-iface> --install             # DPDK packages, hugepages
cmake -S . -B build && cmake --build build -j && sudo cmake --install build
zcu216-uhd uhd_usrp_probe --args type=zcu216,addr=<board-ip>
```

Full rate (up to 3.0 GS/s of sc16, 97 % of the link, both directions at
once) needs the full-rate CPU layout in `AGENTS.md`, `sudo tools/isolate_cpus.sh
apply` and governor `performance`; measured results:
`../benchmark/results/README.md`.

Tests are on the real board (`../benchmark/`). Without a board:
`build/zcu216_kernel_bench` (the AVX2 / scalar kernels and the pool),
`build/zcu216_dram_bench` (the host data path against DRAM) and the FPGA
simulations in `hw_design/ip_design/uhd_ip/sim`.
Device arguments, data plane and limitations: `AGENTS.md`.
