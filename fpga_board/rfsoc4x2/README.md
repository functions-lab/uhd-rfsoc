# fpga_board/rfsoc4x2 — the RFSoC 4x2 as a UHD device over 100 GbE

`block_designs/rfsoc4x2_uhd_v49/rfsoc4x2_uhd_v49.tcl` + `.xdc`: the whole design,
for every build (V49_NCH = 1 or 2 channels, V49_FACTOR, V49_FS; fs 5000 MS/s).
`block_designs/rfsoc4x2_uhd_v49_245m76/` is the same for the 245.76 MHz clock
family (fs 4915.2 MS/s; PL clock 122.88 MHz).
`scripts/v49_build.tcl` makes a project for the board
(`xczu48dr-ffvg1517-2-e`, board part `realdigital.org:rfsoc4x2:part0:1.0`), adds
the CMAC (`../../fpga_ip/ip_design/cmac_100g`, on the QSFP28) in a generated RTL
top, builds and keeps the bitstream; `scripts/v49_ladder.sh` builds the whole
list.

```
make v49-package                 # once: the UHD cores (../../fpga_ip/ip/uhd_ip)
make v49-templates               # the two run-time-rate templates (1ch F2, 2ch F4)
make v49 N=1 F=2 [STEP=bd]       # one build
make v49 N=2 F=2                 # sc8max: 2 x 2500 MS/s, sc8 only (512-bit beat)
make v49-templates-245m76        # fs 4915.2: 1ch F2 (2457.6 .. 122.88 MS/s) and
                                 # 2ch F2 (2 x 2457.6 sc8 .. 2 x 122.88)
```

Each bitstream is a run-time-rate template: the daemon retunes it to every
lower factor of its channel count, 1ch 2500 .. 125 MS/s and 2ch 1250 .. 125
MS/s (~1 s per change, MTS re-locked each time). The rates are twice the
ZCU216's at the same factor: the dual RF-ADC tiles sample at 5 GS/s.

`board_files/rfsoc4x2/1.0` are Real Digital's Vivado board files
(github.com/RealDigitalOrg/RFSoC4x2-BSP, Apache-2.0): the build points
Vivado at them, nothing is installed. Output: `build/v49_qsfp/bitstreams/`;
copy to the board with (from the top of the repository)
`rfsoc/push_bitstreams.sh fpga_board/rfsoc4x2/build/v49_qsfp/bitstreams
xilinx@<board>`.

`AGENTS.md` has the design rules and the board facts.
