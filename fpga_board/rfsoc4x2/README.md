# fpga_board/rfsoc4x2 — the RFSoC 4x2 as a UHD device over 100 GbE

Two block designs, one per clock family, each for N = 1 or 2 channels
(block design name `rfsoc4x2_v49_<N>ch_qsfp`). The RF-ADC tiles are dual
(5 GS/s), so the rates are twice the ZCU216's at the same factor:

| design | fs (MS/s) | templates (`make v49-templates[-245m76]`) | per-channel rates |
|---|---|---|---|
| `block_designs/rfsoc4x2_uhd_v49/` | 5000 | 1ch F2, 2ch F4 (+ 2ch F2: 2 x 2500 MS/s in sc8 only, serving 2500 .. 833.33) | 2500 .. 125 (1ch), 1250 .. 125 (2ch) |
| `block_designs/rfsoc4x2_uhd_v49_245m76/` | 4915.2 | 1ch F2, 2ch F2 | 2457.6 .. 122.88 (2ch: sc8 at the top, sc16 from 1228.8) |

```sh
make v49-package                 # once: the UHD cores (../../fpga_ip/ip/uhd_ip)
make v49-templates               # 1ch F2 and 2ch F4 at fs 5000
make v49 N=2 F=2                 # the sc8-only 2ch F2 build (512-bit beat)
make v49-templates-245m76        # 1ch F2 and 2ch F2 at fs 4915.2
make v49 N=1 F=2 [STEP=bd]       # one build (fs 5000 unless FS=4915.2)
make v49-ladder                  # every fixed-factor build (host/benchmark/oracle_builds_rfsoc4x2.txt)
```

Part `xczu48dr-ffvg1517-2-e`, board part `realdigital.org:rfsoc4x2:part0:1.0`
from `board_files/rfsoc4x2/1.0` (Real Digital's RFSoC4x2-BSP, Apache-2.0,
vendored: the build points Vivado at it, nothing is installed). The 100 GbE
link is the QSFP28 cage (GTY quad 128) on the board's Si570 reference clock.
Output `build/v49_qsfp/bitstreams/`; see `../README.md` for the flow and
`AGENTS.md` for the design rules and board facts.
