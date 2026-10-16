# fpga_board — one directory per RFSoC board

| board | design | channels | status |
|---|---|---|---|
| `zcu216/` | `block_designs/zcu216_uhd_v49/` | 1, 2, 4, 8, 16 | built and tested on zcu216-0 (`host/benchmark/results/README.md`) |
| `rfsoc4x2/` | `block_designs/rfsoc4x2_uhd_v49/` | 1, 2 (fs 5000) | RFSoC 4x2, rfsoc4x2-0 (`rfsoc4x2/README.md`) |

Each board's design is ONE self-contained block design (`.tcl` + `.xdc`) for
every channel count, factor and sample rate; the build names it
`<board>_v49_<N>ch_qsfp` and the bitstreams
`<board>_v49_<N>ch_qsfp_f<F>[_fs<fs>].{bit,hwh}`. Its only IP outside Vivado's
catalog is in `../fpga_ip/ip` (the build's IP repository path names exactly
what it needs).

```
make -C zcu216 v49-package                       # ../fpga_ip/ip_design/uhd_ip -> ../fpga_ip/ip/uhd_ip
make -C zcu216 v49 N=4 F=3 FS=2250 [STEP=bd]     # one build
make -C zcu216 v49-ladder [MAXPAR=3] [JOBS=8]    # every build the board's oracle list has
make -C zcu216 v49-templates                     # one per channel count: run-time rate
make -C rfsoc4x2 v49-templates                   # the RFSoC 4x2's two (1ch F2, 2ch F4 at fs 5000)
```

Every build is a run-time-rate template (`PROTOCOL.md` §8): its converter
clock's MMCM has dynamic reconfiguration, so the daemon serves every RFDC
factor above the built one by retuning in place. One bitstream per channel
count (`v49-templates`) covers the normal family; the per-factor ladder is
only needed for fixed-rate comparisons.

Output: `<board>/build/v49_qsfp/bitstreams/` (timing-clean) or
`bitstreams_timing_fail/`; the Vivado project is deleted after each build.
Copy bitstreams to the board with `../rfsoc/push_bitstreams.sh`.
