# server — the board daemon

The control daemon UHD talks to (TCP 49710, discovery UDP 49700). It loads the
`zcu216_v49_*` bitstream for the requested channel count -- the highest rate
at or below the requested one that carries the client's wire format -- brings up the
RFDC (via `rfsoc_lib`), programs the GT refclk, aligns the 100G link and
drives the FPGA data plane and beamformers.

```
../../run_daemon.sh                           # start it (the usual way; also stop, status, log)
python3 bringup.py --status                   # read-only link / refclk status (root, PYNQ venv)
python3 tests/client_check.py --addr <board-ip>   # protocol check against the running daemon
```

Needs, next to it:

- `zcu216_uhd.conf`, copied from `zcu216_uhd.conf.example`: the FPGA's 100G
  `data_ip` (required) and `data_mac` (optional);
- the `.bit` / `.hwh` pairs to serve: from the build machine with
  `../push_bitstreams.sh <bitstream dir> xilinx@<board>`, or those of a
  release copied here. `host/benchmark/oracle_builds.txt` lists every build;
  any subset works, and both clock families (fs 2500 and 2457.6 on
  the ZCU216, 5000 and 4915.2 on the RFSoC 4x2) can be installed together:
  every rate of every build is offered. The board's LMK04828 / LMX2594
  register files for each build's clock plan are in `../rfsoc_lib/xrfclk/`
  (Protocol §8a).

Details: `AGENTS.md`; contract: Protocol (the top `AGENTS.md`).

**RFSoC 4x2** (1T1R / 2T2R, `rfsoc4x2_v49_*` builds, fs 5000:
`fpga_board/rfsoc4x2`): the same daemon, `--board RFSoC4x2` (or `$UHD_BOARD`,
or detected when the bitstream directory holds only RFSoC 4x2 builds). Copy its
bitstreams with `../push_bitstreams.sh
fpga_board/rfsoc4x2/build/v49_qsfp/bitstreams xilinx@<board>`.
