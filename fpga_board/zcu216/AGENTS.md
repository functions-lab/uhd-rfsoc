# AGENTS.md — fpga_board/zcu216

- Design: `block_designs/zcu216_uhd_v49/zcu216_uhd_v49.tcl` (+ `.xdc`), one for
  N = 1, 2, 4, 8, 16; block design name `zcu216_v49_<N>ch_qsfp`. Only Xilinx
  IP + `../../fpga_ip/ip/uhd_ip` (ip_repo_paths is exactly that).
- `v49_geometry` (in the design tcl) is the single N -> factor / Data_Width /
  beat / fabric-clock table; the factor is a block-design parameter on EVERY
  ADC and DAC tile and slice; `verify_rate_variant` enforces it. Fabric clock
  = fs / F / (Data_Width / 2) = MTS_clk_wiz clk_out1 (`v49_clk_exact` when the
  wizard's solver misses).
- Run-time rate (PROTOCOL.md §8): MTS_clk_wiz is built with dynamic
  reconfiguration (`USE_DYN_RECONFIG`, `verify_rate_variant` checks it), so
  every build is a template: built and timed at its top factor, it serves
  every Gen3 factor above it at run time (the daemon retunes the MMCM and
  the RFDC factor, then re-runs MTS). The 5 templates (`make v49-templates`)
  cover the normal family; Data_Width, the beat and fs stay the build's, so
  the sc8max builds and another fs remain separate bitstreams.
- fs is set when the RFDC is created: rewriting Sampling_Rate afterwards
  detaches tiles 0, 2, 3 from tile 1's clock distribution.
- Channel c = ADC/DAC tile c/4 block c%4; N > 1 joins them with
  axis_combiner / axis_broadcaster (channel-major beat) and eth100g's
  ch_interleave makes the sample-major wire order.
- PS address map is fixed (daemon and rfsoc_lib depend on it): MTS_clk_wiz
  0x8020_0000, axi_gpio_led 0x8023_0000, axi_intc 0x8024_0000, RFDC
  0x8028_0000, eth100g 0x8002_0000 .. 0x8007_0000 (`PROTOCOL.md`).
- MTS must lock before any measurement (the daemon refuses otherwise).
- Implementation strategy per build: `strategy_of` in `scripts/v49_ladder.sh`.
- SPEAR's `hw_design/ZCU216/CLAUDE.md` has the board history this file
  condenses (the "v49" section).
