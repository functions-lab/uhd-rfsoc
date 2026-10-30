# AGENTS.md — fpga/boards/zcu216

Design rules and board facts of the ZCU216 builds; the flow rules are in
`../../AGENTS.md`, the rates in Protocol §9 (top `AGENTS.md`).

- Designs: `block_designs/zcu216_uhd_v49/` (250 MHz family: LMX2594 from
  250 MHz, PL_CLK 300 MHz, SYSREF 10 MHz, fs 2500 and 2400) and
  `block_designs/zcu216_uhd_v49_245m76/` (245.76 MHz family: PL_CLK 122.88
  MHz, SYSREF 7.68 MHz, fs 2457.6; Protocol §8a). Non-Xilinx IP: only
  `fpga/ip/repo/uhd_ip`.
- `v49_geometry` (in the design tcl) is the N -> factor / Data_Width / beat /
  fabric-clock table: beats of 128 (1ch), 256 (2ch) and 512 bits (4, 8,
  16ch), fabric clock = fs / F / (Data_Width / 2) = MTS_clk_wiz clk_out1
  (`v49_clk_exact` writes an exact MMCM setting when the wizard's solver
  misses), at most 312.5 MHz (the templates: 312.5 at fs 2500, 307.2 at
  2457.6, 300 at 2400). `v49_apply_geometry` writes the row into the design,
  `verify_rate_variant` checks everything the daemon relies on.
- Run-time rate (Protocol §8): MTS_clk_wiz has dynamic reconfiguration
  (`USE_DYN_RECONFIG`, checked), so every build is a template, built and
  timed at its factor and serving every Gen3 factor above it. Data_Width,
  the beat and fs stay the build's: another fs is another bitstream.
- fs is set when the RFDC is created (`create_hier_cell_rfdc`): rewriting
  Sampling_Rate afterwards detaches tiles 0, 2, 3 from tile 1's clock
  distribution. Writing a converter mode drops Multi_Tile_Sync to false, so
  the geometry dict re-asserts it in the same `set_property`.
- Channel c = ADC/DAC tile c/4, block c%4; N > 1 joins them with
  axis_combiner / axis_broadcaster (channel-major beat) and eth100g's
  ch_interleave makes the sample-major wire order; the RX and TX
  beamformers (N >= 2) sit on the channel-major beat (Protocol §11).
- 100 GbE: the four zSFP28 cages, one CAUI-4 lane each (GTY quads 128 and
  129; `board_cmac_lanes zsfp`). Its refclk is the 8A34001, which boots
  unconfigured; the daemon programs it at bring-up
  (`fpga/ip/src/cmac_100g/AGENTS.md`).
- The RFDC comes up only through rfsoc_lib's `RfdcTask` at the compiled
  factor (`rfsoc/server/hw_backend.py`); MTS must lock before any
  measurement (the daemon refuses to serve otherwise, and retries: MTS can
  fail its first attempt after a reboot). A tile whose converter clock is
  not good is refused unless `--allow-unlocked`.
- Implementation strategy per build: `builds.txt` (the 512-bit-beat
  templates need Performance_ExtraTimingOpt for the 322 MHz CMAC-side paths).
