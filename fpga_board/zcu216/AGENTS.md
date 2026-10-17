# AGENTS.md — fpga_board/zcu216

- Designs: `block_designs/zcu216_uhd_v49/zcu216_uhd_v49.tcl` (+ `.xdc`; 250 MHz
  clock family, fs 2250 / 2400 / 2500) and
  `block_designs/zcu216_uhd_v49_245m76/zcu216_uhd_v49_245m76.tcl` (+ `.xdc`;
  245.76 MHz family, fs 2457.6: PL_CLK 122.88 MHz, SYSREF 7.68 MHz, Protocol
  §8a), each one for N = 1, 2, 4, 8, 16; block design name
  `zcu216_v49_<N>ch_qsfp`. The 245.76 MHz templates are 1/2/4ch F2, 8ch F4
  and 16ch F8, all at a 307.2 MHz converter clock. Only Xilinx
  IP + `../../fpga_ip/ip/uhd_ip` (ip_repo_paths is exactly that).
- `v49_geometry` (in the design tcl) is the single N -> factor / Data_Width /
  beat / fabric-clock table; the factor is a block-design parameter on EVERY
  ADC and DAC tile and slice; `verify_rate_variant` enforces it. Fabric clock
  = fs / F / (Data_Width / 2) = MTS_clk_wiz clk_out1 (`v49_clk_exact` when the
  wizard's solver misses).
- Run-time rate (Protocol §8): MTS_clk_wiz is built with dynamic
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
  0x8028_0000, eth100g 0x8002_0000 .. 0x8007_0000 (Protocol §11,
  `rfsoc/server/eth100g.py`).
- MTS must lock before any measurement (the daemon refuses otherwise).
- The RFDC comes up only through rfsoc_lib's `RfdcTask` at the factor
  compiled into the block design (`rfsoc/server/hw_backend.py`); the
  template retune (`HwBackend._retune_hw`) is the only run-time factor change.
- Implementation strategy per build: `strategy_of` in `scripts/v49_ladder.sh`.
- Board facts that cost time: the GT refclk (8A34001) boots unconfigured and
  the daemon programs it (`fpga_ip/ip_design/cmac_100g/AGENTS.md`); MTS can
  fail its first attempt after a reboot (the daemon retries); a tile whose
  converter clock is not good is refused unless `--allow-unlocked`.
