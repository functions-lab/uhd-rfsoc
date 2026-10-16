# server — the ZCU216 side

The control daemon UHD talks to (TCP 49710, discovery UDP 49700). It loads the
`zcu216_v49_*` bitstream for the requested channel count -- the highest rate
at or below the requested one that carries the client's wire format -- brings up the
RFDC (via `rfsoc_lib`), programs the GT refclk, aligns the 100G link and
drives the FPGA data plane and beamformers.

```
sudo -E env BOARD=ZCU216 XILINX_XRT=/usr python3 zcu216_uhd_daemon.py --allow-unlocked
python3 bringup.py --status                   # read-only link / refclk status
python3 tests/client_check.py --addr <board-ip>   # protocol check against the board
```

Needs `zcu216_uhd.conf` next to it (from `zcu216_uhd.conf.example`: the FPGA's
100G `data_ip`) and the `.bit`/`.hwh` pairs of `../benchmark/oracle_builds.txt`:
`BIT_DIR=hw_design/ZCU216/build/v49_qsfp/bitstreams FORCE=1 deploy.sh` copies
exactly those, deletes any other, md5-verifies them and checks the LMX2594
file of every converter rate.
Details: `AGENTS.md`; contract: `../PROTOCOL.md`.

**RFSoC 4x2** (1T1R / 2T2R, `rfsoc4x2_v49_*` builds, fs 5000:
`fpga_board/rfsoc4x2`): the same daemon, `--board RFSoC4x2` (or `$UHD_BOARD`,
or detected when the bitstream directory holds only RFSoC 4x2 builds). Deploy
with `BOARD=rfsoc4x2 BIT_DIR=<its bitstreams> FORCE=1 deploy.sh
xilinx@rfsoc4x2-0`, or, for this repository's board checkout,
`rfsoc/push_bitstreams.sh`.
