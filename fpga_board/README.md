# fpga_board — one directory per RFSoC board

| board | design | channels | status |
|---|---|---|---|
| `zcu216/` | `block_designs/zcu216_uhd_v49/` | 1, 2, 4, 8, 16 | built and tested on zcu216-0 (`host/benchmark/results/README.md`) |
| `zcu208/` | `block_designs/zcu208_uhd_v49/` | 1, 2 | built, timing-clean; not yet run on a board |
| `rfsoc4x2/` | -- | -- | not ported (`rfsoc4x2/README.md`) |

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
```

Output: `<board>/build/v49_qsfp/bitstreams/` (timing-clean) or
`bitstreams_timing_fail/`; the Vivado project is deleted after each build.
Copy bitstreams to the board with `../rfsoc/push_bitstreams.sh`.
