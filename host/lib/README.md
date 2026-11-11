# host/lib — the UHD device module

The sources of `libuhd_rfsoc.so`, a UHD 4.6 out-of-tree device module.

UHD loads it from its module directory. The module registers device type
`rfsoc` (and the older names `zcu216`, `rfsoc4x2`), and from then on
`uhd::device::find()` / `make()` and every `multi_usrp` call reach the
board:

- discovery and control over the LAN, with kernel sockets (Protocol §2-§3
  of the top-level `AGENTS.md`);
- samples and the FPGA's TX status over the 100G link, with DPDK (§4-§7).

Build and use: `../README.md`. Internals, device arguments and limitations:
`../AGENTS.md`.

## Files

| file | what |
|---|---|
| `rfsoc_common.hpp` | the Protocol constants, the control client, and `dev_state`: what the device and its streamers share (rate, tick rate, formats, the DPDK port, the worker pools) |
| `rfsoc_util.cpp` | string and CPU-list helpers, the TCP control client, UDP discovery, interface / route lookup |
| `rfsoc_device.cpp` | `uhd::device`: find / make, claim, the property tree that `multi_usrp` walks, CPU placement of the application, the beamformer nodes and user registers |
| `rfsoc_rx_streamer.*` | `rx_streamer`: packet ordering and gap detection, stream-command bookkeeping (§4a), trimming, de-interleave and conversion into the application's buffers |
| `rfsoc_tx_streamer.*` | `tx_streamer`: packets built straight into NIC buffers, timed starts, flow control, async events |
| `rfsoc_dpdk.*` | the data plane: DPDK setup, the RX cores, the TX core with the status queue, the default CPU layout |
| `rfsoc_otw.*` | the over-the-wire formats (§10): bytes per slot, granules, names |
| `rfsoc_kernels.*` | the per-sample work: channel (de-)interleave fused with format conversion, in AVX-512, NEON and scalar code, all bit-identical |
| `rfsoc_pool.*` | the pinned worker threads that large `recv()` / `send()` calls are split across |

## How a stream flows

**RX**

1. An RX core polls its NIC queue and publishes each packet, without
   copying it, to a ring.
2. `recv()` merges the rings by timestamp and works out which packets cover
   the request.
3. One fused kernel per stretch de-interleaves and converts the samples, on
   the worker pool when the call is large.

**TX**

1. `send()` converts the samples straight into packet payloads and prepends
   the headers.
2. It hands batches to the TX core.
3. The TX core releases them to the NIC as fast as the FPGA's flow-control
   credit allows. It reads that credit from the status packets it polls
   itself.

Every rule about rates, formats, timing and channels that these files
implement is written once, in the Protocol.
