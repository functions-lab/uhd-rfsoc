# fpga_board — one directory per RFSoC board

| directory | design | channels | board |
|---|---|---|---|
| `zcu216/` | `block_designs/zcu216_uhd_v49/` | 1, 2, 4, 8, 16 (fs 2500) | Xilinx ZCU216 (`zcu216/README.md`) |
| | `block_designs/zcu216_uhd_v49_245m76/` | 1, 2, 4, 8, 16 (fs 2457.6) | |
| `rfsoc4x2/` | `block_designs/rfsoc4x2_uhd_v49/` | 1, 2 (fs 5000) | Real Digital RFSoC 4x2 (`rfsoc4x2/README.md`) |
| | `block_designs/rfsoc4x2_uhd_v49_245m76/` | 1, 2 (fs 4915.2) | |

Each design is ONE self-contained block design (`.tcl` + `.xdc`) for every
channel count, factor and sample rate of its clock family: the 250 MHz one
(LMX2594 from 250 MHz, PL clock 300 MHz) or the 245.76 MHz one (LMX2594 from
245.76 MHz, PL clock 122.88 MHz); `FS=` picks it. The build names it
`<board>_v49_<N>ch_qsfp` and the bitstreams
`<board>_v49_<N>ch_qsfp_f<F>[_fs<fs>].{bit,hwh}` (the decimal point of fs as
`p`: `_fs2457p6`). Its only IP outside Vivado's
catalog is in `../fpga_ip/ip` (the build's IP repository path names exactly
what it needs).

```
make -C zcu216 v49-package                       # ../fpga_ip/ip_design/uhd_ip -> ../fpga_ip/ip/uhd_ip
make -C zcu216 v49 N=8 F=4 FS=2500 [STEP=bd]     # one build
make -C zcu216 v49-ladder [MAXPAR=3] [JOBS=8]    # every build of host/benchmark/oracle_builds.txt
make -C zcu216 v49-templates                     # one per channel count: 1/2/4ch F2, 8ch F4, 16ch F8 at fs 2500
make -C rfsoc4x2 v49-templates                   # the RFSoC 4x2's two (1ch F2, 2ch F4 at fs 5000)
make -C zcu216 v49-templates-245m76              # 245.76 MHz family: 1/2/4ch F2, 8ch F4, 16ch F8 at fs 2457.6
make -C rfsoc4x2 v49-templates-245m76            # 245.76 MHz family: 1ch F2, 2ch F2 at fs 4915.2
```

Every build is a run-time-rate template (Protocol §8): its converter
clock's MMCM has dynamic reconfiguration, so the daemon serves every RFDC
factor above the built one by retuning in place. One bitstream per channel
count (`v49-templates`) covers its clock family; the per-factor ladder is
only needed for fixed-rate comparisons.

Output: `<board>/build/v49_qsfp/bitstreams/` (timing-clean) or
`bitstreams_timing_fail/`; the Vivado project is deleted after each build.
Copy bitstreams to the board with `rfsoc/push_bitstreams.sh <bitstream dir>
xilinx@<board>` (from the top of the repository).

Needs Vivado 2021.1 on PATH (`settings64.sh` sourced).
