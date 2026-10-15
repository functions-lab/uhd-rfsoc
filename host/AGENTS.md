# AGENTS.md — rfsoc_lib/uhd/host (the PC side)

Read `../AGENTS.md` first (environment, sharing rules, invariants). This file
is the detailed reference of the UHD module; `README.md` is the short version.

## Rules for this directory
- Builds only where UHD 4.6 dev headers and DPDK exist (the PC). The UHD
  version is pinned by the submodule `../uhd` (tag v4.6.0.0); CMake refuses
  another major/minor.
- DPDK is the only sample transport. Stock UHD apps run with `sudo` (or through `tools/zcu216-uhd`)
  (root, module path, CPU layout); the module derives its default CPU layout
  from the topology (`dpdk::default_layout` in `lib/zcu216_dpdk.cpp`).
- Tests are on the real board (`../benchmark/`: robustness incl. the
  over-the-air checks, UHD compliance, 4T4R beamforming with phase
  calibration). Without a board: `build/zcu216_kernel_bench`,
  `build/zcu216_dram_bench` and the FPGA simulations
  (`hw_design/ip_design/uhd_ip/sim`).
- The PC is shared: wrap builds/tests in `flock /tmp/zcu216_pc.lock ...`; never
  write the sudo password into a file.
- Benchmarks live in `../benchmark/`, not here.

---

## Reference (former README)

`libuhd_zcu216.so` is a UHD 4.6 out-of-tree **device module**. It makes the ZCU216
RFSoC board look like a single-motherboard USRP (`type=zcu216`), so stock UHD
applications (`uhd_usrp_probe`, `rx_samples_to_file`, `tx_waveforms`,
`benchmark_rate`, GNU Radio, the `uhd` Python package) can receive and send
samples with it. It implements the host side of [`../PROTOCOL.md`](../PROTOCOL.md):
discovery on UDP 49700 and line-based control on TCP 49710 (kernel sockets, the
1 GbE LAN), VRT-style UDP sample packets in both directions and the FPGA's TX
status/flow-control packets over the 100G link (**DPDK**), the OTW formats of
§10 and the TX and RX beamformers of §11.

Samples travel over DPDK only: the kernel UDP path of wei-duke-wsp5 delivered
only ~60-67 % of a 1-channel 1200 MS/s stream (586 k packets/s, 38.7 Gb/s);
DPDK carries up to 3.0 GS/s of sc16 (96 Gb/s, 97 % of the link) in both
directions at once. So every UHD application that opens the device runs as root, through the
`zcu216-uhd` wrapper.

```
host/
  CMakeLists.txt            MODULE library (requires libdpdk); install -> UHD module dir + zcu216-uhd
  lib/zcu216_common.hpp     constants (PROTOCOL.md), control client, dev_state
  lib/zcu216_util.cpp       string helpers, TCP control client, discovery, interface lookup
  lib/zcu216_device.cpp     uhd::device, legacy property tree, find/make registration
  lib/zcu216_rx_streamer.*  RX: SPSC rings fed by the DPDK lcores, TSF merge/gap check, trimming,
                            then de-interleave + conversion (pool for large calls)
  lib/zcu216_tx_streamer.*  TX: packets built in mbufs (pool for large batches), credit flow
                            control from the status packets the TX lcore receives
  lib/zcu216_otw.*          OTW formats (PROTOCOL §10): the format table
  lib/zcu216_kernels.*      fused (de-)interleave + format conversion, AVX2 and scalar, == UHD's converters
  lib/zcu216_pool.*         pinned worker threads for the per-sample work of recv()/send()
  lib/zcu216_dpdk.*         the data plane: EAL, isolated rte_flow, RX lcores, TX lcore (+ status queue)
  tools/zcu216-uhd          wrapper: run a UHD app as root, with the module, off the lcore CPUs
  ../benchmark/dpdk_rx_test.sh     quick real-link check: probe, 1ch RX, rx_samples_to_file bit-exact, TX
  tools/check_pattern_file.py   bit-exact check of a capture/dump against the section-5 pattern
  tools/zcu216_kernel_bench.cpp  the kernels alone: AVX2 / scalar / UHD, the pool (GS/s), no board
  tools/zcu216_dram_bench.cpp  the host data path (kernels + pool) against DRAM at link rates, no board
  tools/isolate_cpus.sh     keep the rest of the system off the module's CPUs (full-rate runs)
  tools/zcu216_bf.py        §11 from Python: TX or RX (--rx) steer/enable/raw weights/shift with
                            set_user_register; --capture checks the RX beam bit for bit
  tools/uhd_smoke.py        Python MultiUSRP smoke test (board; ../benchmark/uhd_examples_hw.sh)
  tools/uhd_semantics.py    USRP semantics through the Python API (board; the same runner)
  setup_cx5.sh              ConnectX-5 100G port: link without autoneg, RS-FEC, MTU 9000
  setup_dpdk.sh             DPDK prerequisites: packages, hugepages, mlx5/RDMA checks
```

## PC setup (once)

```sh
cd rfsoc_lib/uhd/host
sudo ./setup_cx5.sh <iface> <host-data-ip>/24   # both required: 100G, no autoneg, RS-FEC, MTU 9000
sudo ./setup_dpdk.sh --install     # dpdk libdpdk-dev rdma-core ibverbs-providers pkg-config,
                                   # 4096 x 2 MB hugepages (persistent), mlx5/RDMA/MTU checks; idempotent
```

The ConnectX-5 stays bound to `mlx5_core` (no vfio): the mlx5 PMD is
*bifurcated*, it drives the port through rdma-core while the kernel keeps the
netdev, its IP, ARP and ping. wei-duke-wsp5 is already set up.

## Build and install

Needs `libuhd-dev` 4.6 (Ubuntu 24.04: `apt install libuhd-dev uhd-host python3-uhd`),
DPDK (`libdpdk-dev`, found through pkg-config; CMake stops with an error without
it), cmake and a C++17 compiler.

```sh
cd rfsoc_lib/uhd/host
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
sudo cmake --install build
#  -> /usr/lib/x86_64-linux-gnu/uhd/modules/libuhd_zcu216.so   (UHD loads it by itself)
#  -> /usr/local/bin/zcu216-uhd                                 (-DUHD_ZCU216_BIN_DIR=...)
```

**A stray UHD in /usr/local breaks this silently.** `UHDConfig.cmake` searches
`/usr/local` and pkg-config first, and GCC searches `/usr/local/include` before
`/usr/include` even with `-I/usr/include`. wei-duke-wsp5 has a source-built libuhd
4.7 (and 4.1) plus headers in `/usr/local`. A module linked against that pulls a
second libuhd into a 4.6 process, registers itself in the wrong library, and
`type=zcu216` is never found. The CMake file therefore pins the library to
`${UHD_ROOT}/lib/<multiarch>` (default `UHD_ROOT=/usr`), puts the headers
behind a private include shim, and fails if what it found is not 4.6. Check with
`ldd build/libuhd_zcu216.so | grep uhd`. It must show `libuhd.so.4.6.0`.

UHD `dlopen()`s every file under `<libdir>/uhd/modules` and every entry of
`UHD_MODULE_PATH` (colon-separated, files or directories, searched recursively).
Point `UHD_MODULE_PATH` at a **file**, never at the build directory (UHD would
try to dlopen every CMake file in it), and never at a second copy while the
module is installed: two copies in one process register `type=zcu216` twice.
To run an uninstalled build, use `ZCU216_MODULE=$PWD/build/libuhd_zcu216.so
zcu216-uhd ...` with nothing installed.

## Running applications

Any stock UHD application, run as root (DPDK needs CAP_NET_ADMIN,
CAP_NET_RAW, CAP_IPC_LOCK and hugepages; the module checks at `make()`):

```sh
A=type=zcu216,addr=<board-ip>         # uhd_find_devices --args type=zcu216 prints it
E=/usr/libexec/uhd/examples           # UHD's examples (sudo's PATH does not have them)
sudo uhd_usrp_probe --args $A,channels=4
sudo $E/rx_samples_to_file --args $A,nports=4 --rate 1.25e9 --freq 1e9 --nsamps 100000000 --file /dev/shm/x.dat
sudo $E/benchmark_rate --args $A,nports=4 --rx_rate 1.25e9 --duration 10 --rx_cpu sc16
sudo $E/tx_waveforms --args $A,channels=2 --rate 1.25e9 --freq 1e9 --wave-type SINE --wave-freq 10e6
sudo python3 -c "import uhd; u=uhd.usrp.MultiUSRP('$A'); print(u.recv_num_samps(10000, 1e9, 1.25e9))"
sudo -E gnuradio-companion            # a GUI needs DISPLAY; -E keeps it (and PYTHONPATH: unset a stale one)
```

`channels=N` (device arg) picks the channel count, i.e. the bitstream
(N = 1, 2, 4, 8, 16; a reload takes ~16 s). Within one N the rate is a
`set_rx_rate`/`set_tx_rate`: a template build retunes in place (~1 s, MTS
locked) to the highest of its rates at or below the request (below every
rate: the lowest); a fixed build is one bitstream per RFDC factor
(`../benchmark/oracle_builds.txt`).

**CPU placement.** At `make()` the module pins the thread that opened the
device -- and so every thread it starts afterwards (GNU Radio's block
threads, an app's RX/TX threads) -- to the CPUs that no DPDK lcore and no
conversion worker uses, nor their hyperthread siblings (wei-duke-wsp5
default layout: CPUs 0,6, beside the EAL main lcore): an application thread
that shares a CPU with a polling lcore starves it. An affinity already
narrower than the online CPUs (`taskset`) is kept; device arg
`app_cpus=<list>` sets it, `app_cpus=all` leaves it alone. Threads the
application started before `make()` keep their affinity.

`tools/zcu216-uhd <app> [args]` does the same from outside (sudo -E, taskset,
`UHD_MODULE_PATH` = the installed module or `$ZCU216_MODULE`, bare example
names looked up in `/usr/libexec/uhd/examples`); the benchmarks use it to run
an uninstalled build (`ZCU216_MODULE=$PWD/build/libuhd_zcu216.so`), and its
`ZCU216_APP_CPUS` / `ZCU216_LCORE_CPUS` / `ZCU216_WORKER_CPUS` /
`ZCU216_RX_WORKERS` place the app when the lcores or workers are moved.

`uhd_find_devices` needs no root: discovery and control use kernel sockets,
and `find()` does not open the data plane.

## Data plane (DPDK)

* **Bifurcated, isolated mlx5.** The port is put in `rte_flow` isolated mode
  before it is configured, so DPDK sees only what its flow rules match:
  IPv4/UDP to `<host ip>:recv_port+k` goes to RX queue k (k < nports), and UDP
  to the TX status port (`async_port`, default `recv_port+16`, PROTOCOL §7) to
  one more queue, queue `nports` (the *status queue*, 256 descriptors). ARP,
  ICMP and everything else stay with the kernel netdev, so the ARP probe and the
  neighbour table work as on a plain NIC. A non-isolated DPDK app (plain
  `dpdk-testpmd`) on the same port would steal *all* traffic from the kernel,
  ARP included, until it exits.
* **RX.** One polling lcore per queue (or several queues per lcore when nports
  exceeds the cores) runs `rte_eth_rx_burst`, checks Eth/IPv4/UDP (our IP, the
  queue's port, no fragments), and hands the packet to that queue's SPSC ring
  (zero-copy by default: the ring slot points into the mbuf; `rx_zero_copy=0`
  copies the payload). `recv()` then *plans* (TSF merge, reorder, gap detection `O`,
  trimming -- all in one place, the application thread) the packet stretches
  that cover the request, and *converts* them: one fused kernel per stretch
  de-interleaves the requested channels and converts the format straight into
  the application's buffers ([Conversion](#conversion-kernels-and-worker-pool)).
  A call worth at least `par_min_slots` wire slots is cut into disjoint output
  ranges that the worker pool and the application thread convert in parallel.
  Ring slots stay owned by `recv()` (a private read cursor runs ahead of the
  published one) until their stretch is converted; planning converts what it
  has whenever the next packet has not arrived, so conversion overlaps the
  wait. When a ring is full the lcore stops polling that queue, so a slow
  application loses packets in the NIC (counted as `imissed`, reported as
  `O`). `num_recv_frames` (default 4096 per port: ~13 ms of a 1ch 1250 MS/s
  sc16 stream over the default 2 ports) is that ring.
* **TX.** The TX streamer builds each VRT packet directly in an mbuf: the
  header while planning the batch, the payload (interleave + conversion, one
  fused kernel, on the pool when the batch is worth `par_min_slots`) just
  before the batch of up to 32 goes out. `send()` prepends Ethernet/IPv4
  (checksum)/UDP headers (source port: an ephemeral port reserved by a bound
  kernel socket) and hands the batch through an SPSC ring to the TX lcore,
  which calls `rte_eth_tx_burst`.
* **TX status / credit (PROTOCOL §7) through DPDK.** The TX lcore also polls
  the status queue between bursts. For every status packet it extends the
  FPGA's 32-bit consumed-word count (baseline from `stream_setup_tx`, wrap
  handled, stale reports ignored) into the atomic counter the sender reads,
  sets the burst-ACK flag and pushes events (`U`, `S`, `L`, ACK) into a
  lock-free ring for `recv_async_msg()` -- no kernel socket, no interrupt, no
  thread wake-up between the NIC and the credit. `send()` waits for credit by
  spinning on that counter (`pause` for `tx_spin_us`, then `sched_yield` up to
  `tx_yield_us`, then 20 us naps for long waits such as a timed start far
  ahead); during a wait longer than 200 us it also hands the worker pool a
  no-op every 100 us (`tx_keep_warm`), so the workers are still spinning when
  the credit returns. (Status packets once went through a kernel socket and
  an async thread: their delivery gaps reached p99 284 us / max 885 us
  against a buffer that then held 437 us, and TX at 1ch 1200 MS/s reached
  69 %.) The TX lcore never sleeps while
  packets or status flow; after 50 ms of neither it naps 20 us per round.
* **Lifecycle.** The EAL is initialised once per process, at the first device
  `make()` (`rte_eal_init` cannot run twice). The port is configured
  (isolated, `nports` RX queues) and started in `make()` too, with no flow
  rules yet, so nothing reaches it: starting takes 0.1 s to seconds, which
  must not eat into the lead time of a timed command scheduled after
  `set_time_now()` (tx_timed_samples). `make()` then waits up to 3 s for the
  port's link (warning if it stays down): frames sent before it is up are
  lost. A streamer adds its flows and launches
  its lcores; the port is stopped (flows removed, queues idle) when the device
  is destroyed, and a later open in the same process (e.g. a second
  `MultiUSRP`) restarts it. A stream arg `nports` above the device arg
  restarts the port once. At process exit the port is closed and
  `rte_eal_cleanup()` runs, unless a streamer was never destroyed. lcores sleep
  20 us after ~1-2 ms of empty polls, so an idle streamer does not burn four
  cores.
* **Core layout** (default, from the CPU topology, `dpdk::default_layout`;
  physical cores C0, C1, ... = hyperthread sibling groups; wei-duke-wsp5:
  Xeon w3-2423, 6 cores / 12 threads, CPU c and c+6 are siblings): C0 = the
  EAL main lcore and the application (the module's placement, CPUs 0,6; the
  main lcore IS the application thread, idle as an lcore after
  `rte_eal_init`), C1 = the RX lcore (CPU 1) and the TX lcore + status queue
  (CPU 7), one conversion worker on each other core (CPUs 2,3,4,5). At
  100GbE rates `recv()`/`send()` are bound by the workers' memory traffic
  (one DIMM channel here: ~22-27 GB/s in all), so they get every core but
  the first two; measured on the 16ch 187.5 MS/s build this layout passes
  sc12 RX strict where the previous one (app on the last core, 3 workers)
  did not. The TX mbuf pool is a LIFO (`dpdk_tx_pool_ops=stack`): see the
  option. Change with `dpdk_rx_cores=`, `dpdk_tx_core=`, `dpdk_main_core=`,
  `rx_workers=`, `worker_cpus=` (and `ZCU216_APP_CPUS=`, `ZCU216_LCORE_CPUS=`,
  `ZCU216_WORKER_CPUS=` / `ZCU216_RX_WORKERS=` for the wrapper).
* **sc8max builds at line rate** (4ch F2 fs2500 1250 MS/s, 8ch F3 / 16ch F6
  fs2250 750 / 375 MS/s: 5.0 / 6.0 GS/s each way, `otw=sc8`): use cpu sc8 (sc16
  on the host doubles the memory traffic) and the full-rate duplex layout below.
  One direction at a time is clean (RX only and TX only, 8ch and 16ch: 40 of 40
  runs). Full duplex at 96 Gb/s each way is at this PC's limit, in sc16 as in
  sc8 (`../benchmark/results/README.md`, "sc8max": 8ch sc8 40/50, 8ch sc16
  18/20 clean). Tried without making it clean: RX ring 2048 / 4096 frames, deep
  C-states off, `tx_warmup=0` (fewer RX overflows at TX-stream creation, a few
  small TX underruns instead at 16ch). Every loss was host-side: the FPGA
  streamer's overflow count stayed 0.
* **Python at line rate** (UHD's benchmark_rate.py, 1ch 1.2 GS/s duplex,
  measured before the rate ladder):
  keep spb_pkts at 32 and give the RX ring more than the ~30 ms that
  get_tx_stream() holds the GIL while the example's RX thread already
  streams (`num_recv_frames=32768`): then RX loses nothing. TX still sees
  ~1 underrun per 5 s (1-6 in 20 s, scaling with duration): the Python TX
  thread now and then pauses longer than the 0.87 ms the 4 MiB FPGA buffer
  holds at 4.8 GB/s (with gc disabled 3/0/0 in three 20 s runs, with it
  3/1/6). The C++ examples at the same rate and layout are clean.
* **CPU isolation for full-rate runs**: `sudo tools/isolate_cpus.sh apply`
  (runtime only; `restore` undoes it) moves every other task, the unbound
  kernel workers and the movable IRQs to CPU 9, the one the duplex layout
  below leaves free. Without it containerd, tailscaled, gnome-shell,
  kworkers and the weekly fstrim ran on the module's CPUs thousands of times
  per run and preempted each DPDK lcore 15-37 times; a preemption the
  buffers do not cover loses data in both directions at once. 2ch at 2500
  MSPS, full-rate duplex, 30 s: 2/5 runs clean without, 5/5 with.
* **Full-rate duplex** (RX and TX at once, 96 Gb/s each way, wei-duke-wsp5:
  6 cores, one DIMM). The one-direction defaults overload the cores; split
  them and shrink every in-flight footprint so both directions stay in L3:
  `ZCU216_APP_CPUS=0,1,6,7` (the app's RX and TX threads get two cores) and
  `rx_workers=2,worker_cpus=2:3,tx_workers=3,tx_worker_cpus=4:5:11,`
  `dpdk_rx_cores=8,dpdk_tx_core=10,dpdk_rxd=128,tx_max_pkts=256,`
  `num_recv_frames=1024` (a 1024-packet RX ring keeps even a stalled backlog
  near L3; at 4096 a stall left RX behind on cold buffers, 2 runs in 6 at
  53-72 %). With the default dpdk_rxd (512/queue) or both pools on the same
  4 cores RX falls to ~40-50 %. With this layout, `tools/isolate_cpus.sh
  apply` and governor `performance`, every build x wire format of
  `../benchmark/oracle_builds.txt` (169 cases: 1-16 channels, every RFDC
  factor, up to 97 % of the link) runs 30 s of full-rate duplex with no
  drop, overflow or underrun: `../benchmark/results/README.md`. Keep the PC
  otherwise idle for the cases near the link rate: the FPGA's 4 MiB TX
  buffer covers 0.35 ms of host stall at 97 % of the link.
* **EAL arguments.** Default: `-a <dpdk_port> --file-prefix uhd_zcu216 --in-memory
  --no-telemetry -l <main>,<rx cores>,<tx core>` (here `-l 0,2,3,4,5,1`).
  `--in-memory` leaves no files in `/dev/hugepages` and needs no shared config,
  so it does not collide with another DPDK process. `dpdk_eal=` or the
  environment variable `ZCU216_DPDK_EAL` replace everything but `-l`, which is
  appended unless given.
* **Errors are raised at `make()`:** not root, no free hugepages, EAL failure,
  port not found or busy (with a hint about another DPDK application on the
  port), bad core lists, a loopback data IP. Flow rule failures are raised
  when the streamer is created.
* **fork().** The EAL loads every PMD in its plugin directory, and
  `librte_net_mlx4`'s constructor calls `ibv_fork_init()` unconditionally. That
  turns on rdma-core's fork protection: every buffer rdma-core or the mlx5 PMD
  registers is then `madvise(MADV_DONTFORK)`ed page by page, including ordinary
  malloc heap pages that also hold application data. A child created with
  `fork()` lacks those pages and segfaults on its first touch before `exec()`.
  That is why stock `rx_samples_to_file` died with **"Error: stod"**: its disk
  pre-test forks `dd` through boost::process, the child died of SIGSEGV, `dd`
  printed nothing, and `std::stod("")` threw. The kernel on wei-duke-wsp5 copies
  DMA-pinned pages at fork (rdma-core reports `IBV_FORK_UNNEEDED`), so the
  protection buys nothing there: before `rte_eal_init` the module calls
  `ibv_dofork_range(p, 0)`, which makes the later `ibv_fork_init()` a no-op
  (rdma-core's "too late" rule). Measured on the real port: 76 (after `make()`)
  and 239 (after the RX streamer) `VM_DONTCOPY` regions before, 0 and 0 after;
  `rx_samples_to_file` 3/3 "Error: stod" before, 3/3 "Done!" after. On a kernel
  without copy-on-fork the protection is left on and a warning says so.

### Conversion throughput (wei-duke-wsp5, 6-core Xeon w3-2423)

The measured end-to-end result is `../benchmark/results/README.md`. The
kernels alone, one thread (`build/zcu216_kernel_bench --cpu C`, CPUs 8-11,
GS/s of wire slots; UHD 4.6's own SSE2 converter for comparison):

| kernel | AVX2 | scalar | UHD |
|---|---|---|---|
| RX sc16 -> fc32, N = 1 | 4.5 | 0.9 | 3.6 |
| RX sc16 -> fc32 de-interleave, N = 4 / 8 / 16 | 3.3-3.6 | 0.9-1.0 | -- |
| RX sc16 -> sc16 de-interleave, N = 4 | 5.5 | 1.5 | -- |
| RX sc8 -> fc32 / sc16 de-interleave, N = 8 | 3.5 / 6.0 | 0.9 | -- |
| RX sc12 -> fc32, N = 4 | 2.2 | 0.6 | -- |
| TX fc32 -> sc16, N = 1 | 5.9 | 0.1-0.6 | 4.0 |
| TX fc32 -> sc16 interleave, N = 4 / 16 | 5.2 / 4.8 | 0.1-0.6 | -- |
| TX fc32 -> sc12 / sc8 interleave, N = 4 | 3.0 / 4.6 | 0.1 | -- |

(What the builds need: up to 1.25 GS/s at N = 1, 2.5 GS/s at N = 2, 3.0 GS/s
on the 4-16 channel normal builds, 4.8 GS/s of sc8 on the sc8max ones.) A 64-packet RX
call (N = 8, fc32) runs at 3.0-3.5 GS/s on the caller alone and 5-7 GS/s with
the pool: the conversion is cache/memory-bandwidth bound beyond ~2 threads.
`benchmark_rate` asks for one packet per `recv()`/`send()` (its buffer is
`get_max_num_samps()`), so it runs the kernels inline in its thread; an
application with larger buffers (GNU Radio, `rx_samples_to_file --spb`,
`recv_num_samps`) gets the pool too.

## Device arguments

| arg | default | meaning |
|---|---|---|
| `type` | | `zcu216`. With any other `type` the module returns nothing without touching the network. |
| `addr` | broadcast | board management IP (control). Without it, discovery broadcasts on every IPv4 interface for 150 ms (`find_timeout=`) and each board answers with the address it was reached on. If UDP discovery is filtered, `type=zcu216,addr=` falls back to `info` over TCP. |
| `serial`, `name` | | filter discovery results |
| `channels` | 1 | the build to use: N = 1, 2, 4, 8 or 16 channels in one stream (PROTOCOL §9). Sent as `set_channels N` right after `claim`; the daemon loads that N's default build -- the fastest whose sc16 stream fits the link: 1250 MS/s at 1-2 channels, 750 / 375 / 187.5 MS/s at 4 / 8 / 16 -- if another is loaded (seconds, `rate_timeout`). A daemon that answers `ERR unknown command` is a 1-channel daemon: the module warns and uses N = 1. |
| `otw` | | the OTW format the application will stream in (§10), declared with every `set_rx_rate`/`set_tx_rate` (`otw=`, §3) so the daemon picks -- or refuses before reloading -- the build for it, and the default of a stream whose `otw_format` is empty. A rate is served by the highest build at or below it that carries the declared format. Needed for the sc8max builds: `channels=4,otw=sc8` and 1250 MS/s loads 4ch F2 fs2500 (sc8 only); without `otw=sc8` the same request gets the 750 MS/s sc16 build. Once a streamer exists, its format is declared instead. |
| `ctrl_port`, `disc_port` | 49710, 49700 | |
| `ctrl_timeout` | 10 | seconds to wait for a control reply |
| `rate_timeout` | 120 | seconds to wait for a reply that may reload the FPGA |
| `data_ip` | from `info` | override the FPGA data IP (the board's `zcu216_uhd.conf` sets the real one; no built-in default: a daemon reporting none is an error) |
| `host_data_ip` | auto | local IP for the data plane. Default: the source address the kernel routes to `data_ip` (UDP `connect()` + `getsockname()`). |
| `host_data_mac` | auto | default: `SIOCGIFHWADDR` of the interface that owns `host_data_ip` |
| `recv_port` | 49810 | RX UDP port base: ports `recv_port + k`, k < nports (one stream for all channels) |
| `nports` | 2 | RX UDP ports = DPDK RX queues (<= 16), round-robin from the FPGA; queue k is polled by RX lcore k mod (number of RX cores). 2 carries the 3.0 GS/s sc16 maximum on one RX lcore (full-rate duplex, with the full-rate layout). |
| `spp` | `info spp` (2048) | **slots** per RX packet (= samples at N = 1), multiple of 16 and N, limited by `mtu` |
| `spb_pkts` | 32 | packets per application buffer: `get_max_num_samps()` = spb_pkts x spp / N (RX and TX), 1..64. At N = 1 a packet is 1.6 us at 1.25 GS/s: the Python bindings make ~50k calls/s, so benchmark_rate.py received 7.7 % at 1 packet per call, 28 % at 4, ~100 % at 32. UHD's rx_samples_to_udp sends each such buffer as one datagram: give it `spb_pkts=` so spb_pkts x spp / N x 8 bytes (fc32) stays under 65507 (3 at N = 1, 7 at N = 2, 15 at N = 4). At N > 1 one packet holds only spp / N samples per channel, so UHD apps that size their buffers by `get_max_num_samps()` would otherwise call `recv()`/`send()` for every fraction of a microsecond |
| `pps_emulation` | 1 | there is no PPS input (sensor `pps_present` = false). 1: `set_time_next_pps(t)` makes the device time read t at its next whole second (a timed `set_time`, PROTOCOL §3c) and returns at once, `get_time_last_pps()` is the last whole second, and time source `external` is accepted as the emulated PPS (it stays `internal`). 0: those calls throw `no PPS input` |
| `num_recv_frames` | 4096 | packet slots per RX ring (one ring per port, 8.3 KB each) between the lcores and `recv()` |
| `rx_zero_copy` | 1 | RX ring slots point into the lcores' mbufs (the port's pool gets `num_recv_frames` more mbufs per queue); 0 = the lcore copies each payload into the ring |
| `rx_overflow_hyst` | 1 | after an overflow, discard until the rings drain to `rx_overflow_resume`; 0 = no discard phase |
| `rx_overflow_resume` | 0.0625 | after an overflow the lcores discard until every RX ring holds at most this fraction of `num_recv_frames` (256 of 4096, ~2 MB): recv() then resumes on buffers still in L3. Resuming at half full (the old rule) left it ~16 MB behind and slow for the rest of the stream (1 run in 20 of 16ch sc16 at 71 %). |
| `reorder_ms` | 2 | nports>1: how long to wait for a missing TSF before declaring a gap |
| `pattern` | 0 | `1` = ask the FPGA for the section-5 test pattern instead of ADC samples |
| `tx_spp` | 2048 | slots per TX packet (multiple of 16 and N, <= 2048) |
| `tx_port` | 49900 | FPGA TX port |
| `async_port` | `recv_port+16` | TX status port (§7): steered into the DPDK status queue, read by the TX lcore |
| `tx_spin_us`, `tx_yield_us` | 20, 2000 | credit wait in `send()`: spin (`pause`) this long, then `sched_yield` until `tx_yield_us`, then 20 us naps |
| `tx_max_pkts` | 2040 | TX packets allowed in flight (FPGA packet slots, §6) |
| `tx_prefill` | auto | packets the TX lcore holds before releasing an untimed burst back to back (an untimed burst plays from its first packet, so this is its starting lead). `auto`: `tx_prefill_lead_us` of play-out at the current rate and wire format, at least 32, at most 3/4 of the FPGA credit, 256 and `tx_max_pkts` - 1. A number fixes it, 0 turns it off. The fixed 32 used before were 27 us of 1ch fc32: every full-rate fc32 run underflowed once, right after them |
| `tx_prefill_lead_us` | 200 | play-out the auto prefill aims for |
| `tx_prefill_us` | 1000 | the hold is released after this long even if not full (counted as "released by timeout" in the DPDK TX close line) |
| `tx_warmup_rounds` | 4 | at stream creation, run the packing path this many times over scratch buffers (worker pool, kernels, assembly buffers at full size). 0 = off |
| `tx_keep_warm` | 1 | while send() waits more than 200 us for credit (the FPGA full ahead of a timed start), hand the pool a no-op every 100 us so its workers stay in their spin window; measured: the first packing after a ~250 ms wait took 4 ms and underflowed at 4ch 562.5 MS/s sc8. 0 = off |
| `tx_warmup` | 512 | zero-filled packets the TX lcore sends to UDP port 9 of the FPGA (which drops them) when the streamer is created, to warm the DPDK TX path; 0 = off |
| `tx_ignore_credit` | 0 | 1 = TX flow control off (measurement only: overruns the FPGA buffer) |
| `tx_drain_timeout` | 2.0 | on streamer destruction, wait this long for queued TX to play out |
| `tx_arp_prime` | 1 | before the first TX burst, send one byte to UDP port 9 of the FPGA so the kernel learns its MAC (see FPGA MAC below) |
| `data_mac` | learned | FPGA data MAC for DPDK TX (default: kernel neighbour table after the ARP probe, else `info data_mac=`; neither -> error) |
| `dpdk_port` | PCI of the data interface | EAL device of the 100G port (sysfs of the interface that routes to the FPGA; error if it has none), or a vdev name such as `net_tap0` |
| `dpdk_eal` | see [Data plane](#data-plane-dpdk) | EAL arguments, space-separated. UHD args cannot hold `,` or `=`: write `;` and `~` (or set `ZCU216_DPDK_EAL` in the environment, verbatim). Only the first open in a process initialises the EAL. |
| `dpdk_rx_cores` | first thread of C1 | CPUs of the RX lcores (`2-5` or `2:3:4:5`; not `,`) |
| `dpdk_tx_core` | second thread of C1 | CPU of the TX lcore |
| `dpdk_main_core` | 0 | EAL main lcore (the application thread's affinity is restored after `rte_eal_init`) |
| `dpdk_rxd`, `dpdk_txd` | RX: 1024 / RX queues (512 at nports=2), TX: 4096 | NIC descriptors per RX queue / of the TX queue. RX is kept short on purpose: the buffers the NIC fills must still be in L3 when it refills them (with the LIFO RX pool), or recv() reads them from DRAM and their dead dirty lines are written back -- 16ch sc16 RX at 12 GB/s passes strict with 2 x 512 and 2 x 256, falls to ~67 % with 2 x 1024 on a 15 MB L3. |
| `dpdk_tx_pool_ops`, `dpdk_rx_pool_ops` | `stack`, `stack` | DPDK mempool drivers of the TX / RX mbuf pools. TX `stack` (LIFO) reuses the most recently freed mbuf, still in L3: `send()` allocates from a non-lcore thread, so a ring hands it the coldest of ~12k mbufs and every packet write first reads its lines from DRAM -- on one DIMM channel sc16 TX at 12 GB/s went 54 % -> 100 %. RX `stack` with the short RX rings (`dpdk_rxd`) rewrites a just-consumed buffer while it is in L3 (either change alone leaves 16ch sc16 RX at ~65 %; together: strict PASS at 12 GB/s). `ring` = DPDK's default. |
| `rx_workers` | one per core from C2 on (4 here; 4 if lcores are given) | conversion worker threads for `recv()` and `send()` (one pool per device; 0 = everything in the application thread) |
| `worker_cpus` | first thread of C2, C3, ... | CPUs the workers are pinned to (`8-11`, `8:9:10:11`); with explicit lcores: the last `rx_workers` online CPUs that are neither lcores nor `dpdk_main_core` |
| `tx_workers`, `tx_worker_cpus` | as `rx_workers` / `worker_cpus` | send()'s own worker pool. `worker_pool::run()` executes a second concurrent caller inline, so simultaneous RX and TX need one pool each; split the cores for full-rate duplex (below). |
| `worker_spin_us` | 200 | a worker busy-waits this long after its last task before it sleeps (futex) |
| `par_min_slots` | 16384 | a `recv()` batch / `send()` batch worth at least this many wire slots (all channels) is split across the pool; below that the application thread converts alone (the dispatch costs ~0.1-0.2 us hot, a few us from sleep) |
| `app_cpus` | free cores | CPUs for the application thread that opens the device and the threads it starts afterwards. Default: the CPUs no DPDK lcore and no worker uses, nor their hyperthread siblings (here 0,6); an affinity already narrower than the online CPUs (taskset) is kept; `all` = leave it alone ([Running applications](#running-applications)) |

`spp`, `nports`, `recv_port`, `pattern`, `reorder_ms`, `tx_spp` also work as
stream args (`stream_args.args`). The kernel-socket args of earlier versions
(`use_dpdk`, `recv_buff_size`, `send_buff_size`) are ignored with a warning.
`spp` / `tx_spp` count slots of the stream's OTW format; their defaults are an
8192-byte payload (sc16 2048, sc8 4096, sc12 2688, fc32 1024 slots).

Environment variables:

| variable | effect |
|---|---|
| `ZCU216_TX_STATS=1` | at TX streamer destruction, print where `send()`'s time went (packing, credit wait), the slow episodes, and the gaps between status packets as the TX lcore saw them |
| `ZCU216_RX_TRACE=<n>` | log the first n packets the RX merge takes (port, TSF, nsamps, SOB/EOB, the expected TSF, what each port has queued) |
| `ZCU216_NO_SIMD=1` | scalar kernels instead of AVX2 |
| `ZCU216_DPDK_EAL` | EAL arguments, verbatim (as `dpdk_eal=`) |
| `ZCU216_APP_CPUS`, `ZCU216_LCORE_CPUS`, `ZCU216_WORKER_CPUS`, `ZCU216_RX_WORKERS`, `ZCU216_MODULE` | the wrapper (`tools/zcu216-uhd`): app CPUs, where moved lcores / workers are, the module file |

## OTW formats (PROTOCOL §10)

`stream_args.otw_format` (`--wirefmt` in rx_samples_to_file /
tx_samples_from_file, `--rx_otw`/`--tx_otw` in benchmark_rate, `--otw` in
tx_waveforms) picks what crosses the 100G link; the FPGA converts to and from
the converters' int16, so a narrower format carries a higher aggregate rate.
The module sends `otw=<fmt>` with `stream_setup` / `stream_setup_tx` (not for
sc16, so an older daemon keeps working) and refuses a format the daemon does
not list in `info otw_formats=`.

| cpu \ otw | sc16 | sc8 | sc12 | fc32 |
|---|---|---|---|---|
| **fc32** RX | UHD `sc16_chdr`, 1/32767 | UHD `sc8_item32_be`, 1/128 | UHD `sc12_item32_le`, 1/2048 | copy |
| **fc32** TX | UHD, ×32767 | UHD `sc8_item32_be`, ×128 | UHD → sc16 (×32767), then rhu(x/16) sat, packed | copy |
| **fc64** RX | UHD, 1/32767 | UHD `sc8_item32_be`, 1/128 | UHD sc12 → sc16 → fc64, 1/32768 | UHD `fc32_item32_le` |
| **fc64** TX | UHD, ×32767 | UHD, ×128 | UHD → sc16, then packed | UHD `fc32_item32_le` |
| **sc16** RX | copy | v × 256 | UHD (v × 16) | round(f × 32768), sat |
| **sc16** TX | copy | rhu(x/256), sat | rhu(x/16), sat, packed | x / 32768 |
| **sc8** | refused | copy | refused | refused |

rhu = round half up, the FPGA's own RX rule (`server/vrt.py quantize`), so a
host quantisation and an FPGA one agree bit for bit. Full scale: fc32/fc64
±1.0 in every format (sc8 -128..127 → -1.0..0.992, sc12 -2048..2047 →
-1.0..0.9995, fc32 exactly int16/32768); sc16 keeps the converters' int16
scale in every format. UHD 4.6's own fc32 → sc12 packer truncates and wraps
at +1.0 (2048 → -2048, measured), so TX sc12 goes through sc16 and the module
packs (`zcu216_kernels.cpp pack_sc12`, the same words as UHD's for in-range
values).

### Conversion kernels and worker pool

The "UHD ..." entries above are no longer UHD converter calls but the module's
own kernels (`lib/zcu216_kernels.*`) that produce exactly the same bits
(checked, while it existed, by zcu216_selftest against `uhd::convert` for every format pair, N
= 1, 2, 4, 8, 16, channel subsets, calls starting/ending on any sample,
random data with -32768, rounding ties, NaN, inf). Each kernel fuses the
channel (de-)interleave with the conversion, works per slot (sc12 included),
so a call can start and end anywhere, and has an AVX2 variant (runtime
dispatch; `ZCU216_NO_SIMD=1` forces the scalar loops): 8 samples of all N
channels are loaded, transposed in registers (8x8 32-bit transposes; N = 2,
4 by permutes) and the requested channels stored; sc8 is widened to sc16
first, sc12 unpacked/packed with `pshufb` + `pmaddwd`. TX float rounding is
UHD's SSE2 rule everywhere (`cvtps2dq`: round to even, saturated; NaN/huge ->
-32768; fc64 truncates like UHD's `cvttpd`): UHD itself runs a scalar loop on
the unaligned head and the `n % 4` tail of every call that *truncates*, so its
output for a non-integer sample depends on its position in the call; the
kernels do not.

The worker pool (`lib/zcu216_pool.*`, `rx_workers` threads pinned to
`worker_cpus`) is shared by RX and TX. A call hands out disjoint output
ranges through one 64-bit atomic (generation | task count | next task) to the
workers and the calling thread and returns when all are done; workers spin
`worker_spin_us` after their last task, then sleep on a futex. If RX and TX
want the pool at the same time, the second caller converts alone instead of
waiting.

## How UHD calls map to the protocol

* **Tree.** This is the legacy (non-RFNoC) layout that `multi_usrp_impl` and
  `uhd_usrp_probe` walk. Motherboard `/mboards/0`, one daughterboard `A`,
  frontends `A:0 .. A:N-1` (frontend c = converter channel c), one DSP per
  multi_usrp channel, and the subdev spec (identity `A:0 A:1 ...` by default).
* **Subdev spec.** Any order and subset of distinct frontends, e.g. `A:1 A:0`
  or `A:3`: multi_usrp channel i (its frontend calls, its DSP, and stream
  channel i of every streamer made afterwards) is converter channel spec[i].
  `get_rx_num_channels()` = the spec's length (N by default).
* **Channels (PROTOCOL §9).** `channels=N` picks the build (`set_channels N`
  before `info` is read). Per-channel settings are per converter:
  `set_rx_freq(f, c)` -> `set_rx_freq c f`, likewise gains and antennas. The rate,
  the tick rate and the stream are shared: `set_rx_rate` on any channel sets all
  of them (one query refreshes every channel's cache). The master clock rate is
  one tick per slot (TICK_STEP 1 on every build), N x the per-channel rate --
  1.25 GHz for 1ch at 1250 MS/s, 3.0 GHz for the 4-16 channel max-rate
  builds, 6.0 GHz for sc8max 8ch / 16ch (5.0 GHz at 4ch) -- and a per-channel
  sample advances N ticks.
* **Frequency (PROTOCOL §3b).** UHD's tune helper splits a request into an RF
  part (frontend `freq/value`) and a DSP part (`dsps/<i>/freq/value`, range
  ±rate/2). Both go to the daemon's `set_*_freq <ch> <rf> dsp=<dsp>`, which
  programs the one RFDC NCO to rf - dsp (RX) / rf + dsp (TX), clamped to
  0..fs/2, and replies with the two parts in effect. So `tune_request_t(f,
  lo_off)` reports `actual_rf_freq` = f + lo_off, `actual_dsp_freq` = lo_off (RX)
  or -lo_off (TX), and `get_rx_freq()` = f, the frequency the converter mixes
  to; `dsp_freq_policy` MANUAL / AUTO / NONE behave as on a USRP. A plain tune
  has DSP part 0 (one NCO write; the DSP node skips an unchanged value).
* **LOs.** Each frontend has `los/all` and `los/NCO` (`source` `internal` only,
  `export` false): `get_rx_lo_names()` = `all, NCO`, `get_rx_lo_freq("NCO")` =
  the RF part, `set_rx_lo_freq("NCO", f)` tunes it. The frontend also has the
  node `freq/ value` that UHD 4.6's `get_*_lo_freq()` reads on devices without
  LOs.
* **Bandwidth.** The sample rate (fs / the decimation or interpolation
  factor in force; the RFDC filters' -3 dB width is 0.96 x it,
  `../benchmark/results/README.md`), range = that value; it follows the
  rate, setting it only reads it back.
* **Rate.** `set_rx_rate` goes to the daemon's `set_rx_rate <ch> <hz> [otw=<fmt>]`
  (the declared format: device arg `otw=` or the latest streamer's) and is
  served by the highest of this N's builds (`get_rx_rates`) at or below it
  that carries the declared format (below every build: the lowest). The
  reply's second token is the new build's tick rate, which differs between
  builds of one N (4ch 750 MS/s ticks at 3.0 GHz, 4ch 1250 MS/s sc8max at
  5.0 GHz): the module takes it
  as the master clock rate and, after a reload, re-reads `info` (`beat_slots`,
  formats, beamformer). A refusal (`... needs otw=sc8`) reaches the
  application as the exception of `set_rx_rate`. Bandwidth follows the rate and is read-only.
* **Gain.** RX gain element `DSA`, TX gain element `VOP`, forwarded to
  `set_*_gain`. Antennas: one port each, `RX` (forwarded) and `TX`; the usual
  USRP names (`RX2`, `TX/RX`, `RX1`, `TX1`, ...) select it and the real name is
  reported.
* **Clock and time source.** Forwarded to `set/get_*_source`, with the options from
  `get_*_sources`.
* **Master clock rate.** `info tick_rate` (and the `set_channels` / `set_rx_rate`
  replies), fixed by the loaded bitstream. Setting another value logs a warning
  and keeps the bitstream value.
* **Time.** `time/now` is `get_time`/`set_time` in ticks.
  - There is **no PPS** (mboard sensor `pps_present` = false). With
    `pps_emulation=1` (default) the PPS edges are the whole seconds of device
    time: `get_time_last_pps()` returns the last one, and `set_time_next_pps(t)`
    sends `set_time t at=<next whole second>` and returns at once; the daemon
    sets the time AT that edge (to within the AXI write). So
    `set_time_unknown_pps(0)` behaves as on a USRP: it returns after its own
    waits (<= 1 s for an edge, then 1 s) with the time just past 0. Not a
    multi-board sync. `pps_emulation=0` makes these calls throw.
  - `set_command_time(t)`: tune and gain requests carry `at=<t in ticks>`; the
    daemon applies them when its timekeeper reaches t, ~1 ms accurate, and every
    request with the same t in ONE batch (all NCOs, then one phase reset /
    update event per tile, PROTOCOL §3c/§3d) -- a multi-channel retune with a
    common command time is applied together. The tree returns the commanded
    value at once. `clear_command_time()` returns to immediate requests. Timed
    **stream** commands carry their own time (§4a).
* **Sensors.** Motherboard sensors come from `list_sensors`/`get_sensor`
  (`bool`/`real`/`int`/`string`); one the daemon cannot read is the string
  `n/a`, never an exception (so `usrp_list_sensors` lists them all). Frontend
  `lo_locked` is the daemon's `get_*_lo_locked <ch>`: the converter tile clock
  of that channel (the NCO runs on it), PLL locked or, PLL bypassed, the tile's
  clock detected. An older daemon: the mboard `adc/dac_pll_locked`.
* **GPIO.** None. multi_usrp lists banks `RXA`/`TXA` for every dboard; using
  them throws `NotImplementedError: ZCU216: no GPIO` (the `gpio` example fails
  with that message).
* **EEPROM.** The mboard EEPROM holds `name`, `serial` and `product` from
  discovery. Writes are ignored.
* **Ownership.** `claim` is sent at `make()` and held for the device's lifetime.
  A second process gets `the ZCU216 is in use by another UHD session`. The
  destructor stops streams, drains TX and sends `unclaim`. Inside one process,
  UHD's device cache returns the same device for the same args.

### RX (PROTOCOL §4, §5)

* **stream_setup.** Sent when the streamer is created, not in
  `issue_stream_cmd()`, because `get_max_num_samps()` must already return the
  `spp` the daemon accepted.
* **Stream commands (PROTOCOL §4a).** Queued by the daemon and run in order,
  like a USRP: timed `num_done`s back to back, `num_more` chains (contiguous
  samples, exact counts, `ERROR_CODE_BROKEN_CHAIN` when a chain is not
  continued in time), `ERROR_CODE_LATE_COMMAND` (no samples) for a timed
  command whose time has passed. Every accepted command is a pending burst on
  the host; continuations the daemon joined to a chain continue the current
  one. Timed commands meant back to back need a few ms between them (the
  daemon issues each when the streamer is idle).
* **Fragments.** A `recv()` that ends inside a packet sets `more_fragments`;
  the next call's `fragment_offset` = the samples of that packet already
  returned.
* **Receive path.** Each DPDK RX lcore hands the packets of its queue(s) to a
  lock-free SPSC ring per queue ([Data plane](#data-plane-dpdk)).
  `recv()` merges the rings by TSF, validates
  the SID and length (whole slots of the OTW format), converts to the CPU
  format with the fused kernels ([Conversion](#conversion-kernels-and-worker-pool);
  sc16 -> fc32: scale 1/32767, UHD's `sc16_chdr` result), keeps leftovers across
  calls, and honours `one_packet`, SOB/EOB, `time_spec` and timeouts.
* **Loss.** A TSF different from `prev TSF + prev nsamps × ticks_per_sample`
  without SOB returns `ERROR_CODE_OVERFLOW` once, prints `O` and sets `time_spec`
  to the first missing sample, so `benchmark_rate` counts dropped samples
  exactly. A late packet from another queue (TSF below the expected value) is
  dropped and counted.
* **Trimming (§4 granularity).** For a timed start, the host drops the leading
  `requested_time − TSF` samples and reports `time_spec` = the requested time.
  For `num_done`, it delivers exactly `num_samps`, puts EOB on the last one and
  discards the FPGA's round-up. Because the FPGA starts at the beat *containing*
  the time, the host asks for `num_samps + lead` samples (lead ≤ 3). Whichever
  way the FPGA counts, the requested window is then fully covered.
* **Multi-channel (§9).** The wire always carries all N channels, slot `i` =
  channel `i % N`, sample `i / N`, SID `0x5A160000`. The streamer de-interleaves
  the channels in `stream_args.channels` (any subset, any order) into their
  buffers and drops the rest, in the same kernel pass as the conversion. All channels of a sample share its time, so they are aligned by
  construction; no timed command is needed. Gaps are counted in slots,
  `time_spec` advances N ticks per sample, and a `num_done` of n samples per
  channel asks the FPGA for `(n + lead) x N` slots and is trimmed to exactly n.
  Stream commands go out once with `<ch>` = 0; multi_usrp's
  `issue_stream_cmd(ALL_CHANS)` visits every channel, and only the streamer's
  first channel forwards it.
* **One RX streamer at a time.** There is one stream, and each packet goes to
  one streamer's rings (zero-copy). A new RX streamer that shares a channel
  with the existing one replaces it (logged: an application re-creating its
  streamer); one for a disjoint channel set while the first still exists is
  refused with `... still exists; a second RX streamer ... cannot run beside
  it` -- request all channels in one streamer, or destroy the first. A new TX
  streamer replaces the old one. `benchmark_rate --multi_streamer` is
  therefore not supported.

### TX (PROTOCOL §6, §7)

* **Header.** Packed by hand: always 4 words, TSF words included even when
  untimed (`[21:20]=0`, TSF 0). `vrt::if_hdr_pack_le` would drop the TSF words,
  and the FPGA would count the packet as malformed.
* **Packetising.** `send()` converts to the OTW format (sc16: scale 32767) and
  cuts packets of up to `tx_spp` slots, in whole 64-byte words of the format
  (16 sc16, 32 sc8, 64 sc12, 8 fc32 slots, and a multiple of N). A tail
  shorter than that is carried, unconverted, into the next `send()`. The last
  packet of a burst is zero-padded to the granule, and a zero-length EOB
  becomes one granule of zero slots.
* **Multi-channel (§9).** Packets carry whole samples of all N channels,
  interleaved slot by slot; a channel not in `stream_args.channels` is sent as
  zeros. One kernel pass converts and interleaves the channels straight into
  the mbuf. One packet of `n` samples per channel is `n x N / 16` credit
  words, so the flow control is unchanged. Packets are built straight into
  DPDK mbufs and handed to the TX lcore 32 at a time
  ([Data plane](#data-plane-dpdk)).
* **Bursts.** SOB is set on the first packet of a burst, or implicitly when
  `send()` is called outside a burst: `benchmark_rate` and `tx_timed_samples` never
  set `start_of_burst`. `has_time_spec` is honoured only there (TSF flag `[21:20]=1`),
  and EOB comes from `end_of_burst`.
* **Timed start.** The FPGA starts a timed burst on the fabric beat containing
  its TSF (`info beat_slots=`: 4 slots at N = 1, 8 on the 256-bit builds, 16 on
  the 512-bit ones; `max(4, N)` for a daemon without the key). The host
  therefore sends TSF = the beat and prepends the lead as zero samples, so the
  first user sample plays exactly at `t` (at N = 1: TSF = floor4(t), `t mod 4`
  zeros). This mirrors the RX lead-in trim, which uses the same beat.
* **Credit.** `stream_setup_tx` replies `tx_buf_words fc_interval
  consumed_baseline`; a 2-token reply means baseline 0. The FPGA's consumed count
  is monotonic and never resets. The host keeps the last raw value (starting at
  the baseline) and adds 32-bit wraparound deltas, so in-flight = sent −
  (consumed − baseline). Two limits hold together: in-flight words ≤
  `tx_buf_words` (32752 64-byte words, 2 MiB, on every v49 build: the part of
  the FPGA's ~4 MiB TX buffer the host counts; udp_player's play-out chain
  holds the rest), and in-flight packets ≤
  `tx_max_pkts` (2040). A packet counts as in flight until its last word is
  retired, which matters for packets below about 144 samples. Status packets
  come from `<fpga>:49801` to the status queue ([Data plane](#data-plane-dpdk));
  the source port is not checked. `send()` spins for credit and returns what it
  accepted when its timeout expires, like UHD. The TX lcore extends the 32-bit
  consumed count and queues events for `tx_streamer::recv_async_msg()` and
  `device::recv_async_msg()`; it prints `U` (underflow), `S` (sequence) or `L`
  (late). `ZCU216_TX_STATS=1` prints, at streamer destruction, where `send()`'s
  time went (packing, credit wait) and the gaps between status packets as the
  TX lcore saw them.
* **Warm-up.** At streamer creation the packing path runs `tx_warmup_rounds`
  times over scratch buffers (worker pool, kernels, the per-slot assembly
  buffers reserved at full size) and the TX lcore sends `tx_warmup` packets to
  the FPGA's discard port; untimed bursts start with a prefill
  (`tx_prefill`). Measured: without the warm-up, the first packing after a
  ~250 ms wait for a timed start could take 4 ms, longer than the FPGA buffer
  lasts near the link rate.
* **Destruction.** Queued samples may play out: the destructor waits up to
  `tx_drain_timeout` for the burst ACK, or for consumed == sent, before sending
  `stream_stop_tx`. `send_waveform()` drops its streamer right after EOB. If the
  destructor ran inside an unfinished burst, `stream_stop_tx` is sent immediately.
* **FPGA MAC.** DPDK frames need the FPGA's MAC. Before the first burst the
  streamer sends one byte through the kernel to UDP port 9 of the FPGA data IP
  (the FPGA ignores UDP to other ports, §6) and waits 20 ms; the kernel's ARP
  reply lands in the neighbour table, which the module reads
  (`/proc/net/arp`). Fallback: the daemon's `info data_mac=`; with neither
  the streamer refuses (no built-in MAC). `data_mac=` overrides both, and
  `tx_arp_prime=0` skips the probe.

### TX and RX beamformers (PROTOCOL §11)

On an N >= 2 build the module adds, for each beamformer the loaded build has
(checked at `make()`: `info bf=1` / `rbf=1`), these tree nodes under
`/mboards/0/tx_beamformer` (TX; also under its alias `/mboards/0/beamformer`,
the name from before the RX beamformer) and `/mboards/0/rx_beamformer` (RX):

| node | type | daemon command (TX / RX) |
|---|---|---|
| `enable` | bool | `set_bf_enable` / `set_rbf_enable` |
| `angle_deg` | double (NaN = raw weights, no angle) | `set_bf_angle` / `set_rbf_angle` (computes and loads the weights) |
| `carrier_freq`, `element_spacing` | double (Hz, m) | `set_bf_params` / `set_rbf_params` (re-steers if an angle is in effect) |
| `weights` | `std::vector<std::complex<double>>`, Q1.15 / 32767 | `set_bf_weights` / `set_rbf_weights` (quantised `round(x * 32767)`, saturated); length must be N |
| `weights_q15` | `std::vector<int>` re0, im0, ... (read-only) | `get_bf` / `get_rbf` |
| `weights_str` | `std::string` "re0,im0,re1,..." (read-only; for Python, whose tree bindings have no vector access) | `get_bf` / `get_rbf` |
| `shift` (RX only) | int 0..15, reset log2(N) | `set_rbf_shift` |

Every read goes to the daemon, so the tree shows what the FPGA holds.
`multi_usrp::set_user_register(addr, value)` (the legacy path:
`/mboards/0/user/regs`, `std::pair<uint8_t, uint32_t>`, also in Python) uses
the §11 map, TX at 0 and RX at 64:

| TX | RX | meaning |
|---|---|---|
| 0 | 64 | enable (0/1) |
| 1 | 65 | steering angle in millidegrees (int32): computes and loads the weights |
| 2 | 66 | carrier frequency in kHz |
| 3 | 67 | element spacing in nm |
| -- | 68 | RX SHIFT 0..15 |
| 15 | 79 | LOAD the staged raw weights (peek32 reads N) |
| 16 + c | 80 + c | raw weight c (int16 re \| int16 im << 16), staged until LOAD |

UHD 4.6's multi_usrp has **no `get_user_register`**; the read-back is
`get_user_settings_iface(chan)->peek32(addr)` (C++; the node
`<rx frontend>/user_settings/iface`, same map) or, from Python, the tree:
`usrp.get_tree().access_double('/mboards/0/rx_beamformer/angle_deg').get()`,
`access_int('/mboards/0/rx_beamformer/shift')`, `access_str('.../weights_str')`
(the Python tree has bool/int/double/string accessors only, so the complex
weights are C++-only). On a build without a beamformer its nodes are absent
(test `tree.exists('/mboards/0/rx_beamformer/enable')`) and its user
registers raise `uhd::not_implemented_error` naming it ("this 4-channel build
has no RX beamformer ... info rbf=0"; on N = 1 "... has no TX beamformer").
An address outside 0..31 and 64..95 raises `uhd::value_error`. The nodes
reflect the build loaded at `make()`; the registers follow `info` after a
rate change.

With the TX beamformer enabled, TX channel 0 is fanned out to all N DACs (DAC
c gets ch0 x w[c]); the other channels of the TX stream are ignored. With the
RX beamformer enabled, **RX channel 0 of the stream is the beam**
`sat16((sum_c x_c w[c] + 2^(14+shift)) >> (15+shift))` and channels 1..N-1
the raw elements 1..N-1. The same angle gives the same weights in both
directions (no conjugate). The daemon resets both to bypass when the claim is
released (device destruction).

`tools/zcu216_bf.py` is a complete Python example (TX by default, `--rx` for
the RX beamformer; `--check` verifies the read-back, `--capture NSAMPS` checks
RX channel 0 against the formula bit for bit):

```sh
zcu216-uhd python3 tools/zcu216_bf.py --args $A,channels=4 --carrier 28e9 --spacing 5.35e-3 --angle 30 --enable
zcu216-uhd python3 tools/zcu216_bf.py --args $A,channels=4 --disable
zcu216-uhd python3 tools/zcu216_bf.py --rx --args $A,channels=4 --angle -20 --shift 2 --enable
# the beam on real ADC data, bit for bit: w[0] = 0, so the beam depends only
# on the delivered channels 1..N-1 (the test pattern bypasses the FPGA beamformer)
zcu216-uhd python3 tools/zcu216_bf.py --rx --args $A,channels=4 \
    --weights "0,0 32767,0 0,-32768 -20000,10000" --shift 1 --enable --capture 200000 --check
```

## Tests

### Without a board

The host-side benchmarks and the FPGA simulations.

```sh
build/zcu216_kernel_bench --cpu 1 --pool-cpus 2,3,4,5   # the kernels: AVX2 / scalar / UHD, the pool, GS/s
build/zcu216_dram_bench --dir duplex --n 16 --otw sc16 --cpu sc16 ...   # see its header
make -C ../../hw_design/ip_design/uhd_ip sim-streamer sim-player sim-fmt   # the IP simulations
```

`zcu216_kernel_bench` is what the per-sample work costs on this CPU (the
table above). Its pool rows (RX sc16 -> fc32, N = 8, one 64-packet call),
2026-10-05 on wei-duke-wsp5, workers pinned with `--pool-cpus 2,3,4,5`,
caller on CPU 1, two runs: caller alone 3.8 GS/s; + 1 worker 5.3-6.9;
+ 2 workers 4.2-4.5; + 4 workers 4.5-4.6. Beyond one worker such a call
gets no faster -- open, not yet explained. With unpinned workers (no
`--pool-cpus`) every pool row is slower than the caller alone (4.9 -> 2.3 ->
1.5 -> 0.9). `zcu216_dram_bench` runs the module's kernels and worker pool against a packet
ring much larger than L3 while a "NIC" thread streams the DMA traffic at a set
rate: whether this PC's memory system can carry a configuration at all,
before the board is involved. Everything else is measured on the board
(`../benchmark/`).

### Real link: `../benchmark/dpdk_rx_test.sh`

On wei-duke-wsp5, with the board daemon running and the 100G link aligned:

```sh
cd ~/git/SPEAR-qsfp/rfsoc_lib/uhd/host
../benchmark/dpdk_rx_test.sh        # uses the installed zcu216-uhd; ZCU216_MODULE=... for a build tree
```

1. `uhd_usrp_probe` over DPDK and sensor `cmac_aligned` = true;
2. `benchmark_rate` RX sc16, nports=4: 0 dropped, 0 overruns (fc32 is
   reported, not judged);
3. `rx_samples_to_file` with the test pattern, 100 M samples into `/dev/shm`
   (`num_recv_frames=32768`, ring for the file writer): "Done!" and
   `check_pattern_file.py` BIT-EXACT;
4. `tx_timed_samples` burst ACK (plus a TX `benchmark_rate`, reported);
5. the kernel still resolves the FPGA by ARP on the same port.

NIC counters (`rx_out_of_buffer` = a DPDK queue was full) are printed before
and after. Steps by hand, for a first bring-up:

```sh
uhd_find_devices --args type=zcu216                      # broadcast, no root needed: addr=, data_ip=
A=type=zcu216,addr=<board-ip>
zcu216-uhd uhd_usrp_probe --args $A --sensor /mboards/0/sensors/cmac_aligned    # must be true
zcu216-uhd uhd_usrp_probe --args $A --sensor /mboards/0/sensors/adc_pll_locked
zcu216-uhd rx_samples_to_file --args $A,nports=4,pattern=1,num_recv_frames=32768 \
    --rate 1.25e9 --freq 1e9 --nsamps 100000000 --file /dev/shm/x.dat
tools/check_pattern_file.py /dev/shm/x.dat --nsamps 100000000          # -> BIT-EXACT
zcu216-uhd rx_timed_samples --args $A,pattern=1 --rate 1.25e9 --nsamps 10001 --secs 1.5
zcu216-uhd benchmark_rate --args $A,nports=4 --rx_rate 1.25e9 --duration 10 --rx_cpu sc16
zcu216-uhd tx_waveforms --args $A --rate 1.25e9 --freq 1e9 --wave-type SINE --wave-freq 10e6 --ampl 0.3
zcu216-uhd tx_timed_samples --args $A --rate 1.25e9 --nsamps 100000 --secs 1.5   # "ACK... success"
```

* `host_data_ip` resolves by routing to the FPGA data IP (`data_ip=` from
  discovery), which gives the 100G port's address once the port is up. If the
  module logs another interface, pass `host_data_ip=<host-data-ip>` explicitly.
* Rates use the builds' list (`get_rx_rates`); a rate not in it is served by
  the highest build at or below it, and UHD prints the coerced rate. Use that value for `check_pattern_file.py --tps` when
  it differs from the tick rate.
* ADC data is meaningless while zcu216-0's ADC reference clock is dead
  (../../hw_design/ZCU216/CLAUDE.md). That is why the checks use `pattern=1`.

## Known limitations

* Every process that opens the device needs root (DPDK); one process at a time
  can own the 100G port's DPDK queues, and the device is claimed per session anyway.
* No PPS: emulated (see Time above); no multi-board sync.
* Timed tuning and gain are software-timed in the daemon (~1 ms), not
  sample-synchronous. After a tune the NCO phases restart together per tile
  (PROTOCOL §3d); across tiles (N = 8, 16) the phase offset is not
  deterministic.
* Timed stream commands closer than a few ms apart: the later one may be late
  (the FPGA holds one command; the daemon queues).
* One RX streamer at a time (see RX); a new TX streamer replaces the old one.
* The sc8max builds need the device arg `otw=sc8` before `set_rx_rate` (an
  application's `set_rx_rate` comes before its streamer, so the module cannot
  know the format otherwise); without it the request is served by an sc16
  build.
* RX fc32 is refused on the 512-bit-beat builds (every 4, 8 and 16-channel
  build: udp_streamer would need two FIFO words per clock); TX fc32 works.
  The 1024-bit-beat sc8max builds (8ch, 16ch) carry sc8 only.
* UHD 4.6 has no `multi_usrp::get_user_register`: read the §11 registers back
  with `get_user_settings_iface(chan)->peek32()` (C++) or through the tree.
* On a net_tap vdev `nports` <= 3 (a DPDK 23.11 net_tap bug).
* `sc8` CPU format: only with otw `sc8` (a copy); with any other OTW format it
  is refused with a clear error (UHD 4.6 has no sc16 → sc8 converter).
* OTW sc8/sc12 lose the low bits by design (§10); `check_pattern_file.py
  --otw` can pin a quantised capture's start tick (and the channel offsets)
  only to within one quantisation step's worth of samples.
* TX gain is named `VOP` in dB as reported by the daemon.
