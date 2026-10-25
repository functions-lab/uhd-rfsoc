# host/lib — the UHD device module

The sources of `libuhd_zcu216.so`, a UHD 4.6 out-of-tree device module. UHD
`dlopen()`s it from its module directory, the module registers device type
`zcu216` (and `rfsoc4x2`), and from then on `uhd::device::find()` / `make()`
and every `multi_usrp` call reach the board: discovery and control over the
LAN (kernel sockets, Protocol §2-§3 of the top-level `AGENTS.md`), samples
and the FPGA's TX status over the 100G link through DPDK (§4-§7). Build and
use: `../README.md`; internals, device arguments and limitations:
`../AGENTS.md`.

| file | what |
|---|---|
| `zcu216_common.hpp` | the Protocol constants, the control client, `dev_state` (what the device and its streamers share: rate, tick rate, formats, the DPDK port, the worker pools) |
| `zcu216_util.cpp` | string and CPU-list helpers, the TCP control client, UDP discovery, interface / route lookup |
| `zcu216_device.cpp` | `uhd::device`: find / make registration, claim, the legacy (non-RFNoC) property tree that `multi_usrp` walks, CPU placement of the application, the beamformer nodes and user registers |
| `zcu216_rx_streamer.*` | `rx_streamer`: per-port SPSC rings fed by the DPDK RX lcores, TSF merge and gap detection, stream-command bookkeeping (§4a), trimming, then de-interleave + conversion into the application's buffers |
| `zcu216_tx_streamer.*` | `tx_streamer`: packets built straight into mbufs, timed starts, credit flow control from the status packets the TX lcore receives, async events |
| `zcu216_dpdk.*` | the data plane: EAL, the isolated `rte_flow` port, RX lcores, TX lcore with the status queue, the default CPU layout |
| `zcu216_otw.*` | the over-the-wire formats (§10): bytes per slot, granules, names |
| `zcu216_kernels.*` | the per-sample work: channel (de-)interleave fused with format conversion, AVX-512 / NEON and scalar, bit-identical to UHD's converters and to each other (`tools/zcu216_kernel_check.cpp`) |
| `zcu216_pool.*` | the pinned worker threads `recv()` / `send()` split large calls across |

How a stream flows: an RX lcore polls its NIC queue and publishes each packet
(zero-copy, the mbuf itself) to its ring; `recv()` merges the rings by TSF,
plans which packet stretches cover the request and converts them with one
fused kernel per stretch, on the worker pool when the call is large. `send()`
converts into mbuf payloads, prepends the headers and hands batches to the TX
lcore, which releases them to the NIC as the FPGA's consumed-word count (from
the status packets it polls itself) allows. Every rule about rates, formats,
timing and channels these files implement is written once, in the Protocol.
