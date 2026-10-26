# AGENTS.md — rfsoc_lib

What a change here must keep (the daemon, `../server/hw_backend.py`, is the
only caller of the bring-up; `README.md` maps the modules).

- **One configuration dict.** `rfdc.py` and `rfdc_task.py` read the
  module-global `rfdc_config.RFDC_CONFIG` whatever the board. The daemon
  copies the board's clock limits (`RFSOC4X2_MIN_MAX_CONFIG`) and then the
  loaded build's geometry (`NEW_CONFIG`: fs, factor, NCOs, PL clock) into
  it before `RfdcTask`. Per-tile / per-block keys (`DACNCO<t><b>`,
  `ADCDecimFactor<t><b>`, ...) fall back to the flat ones (`RfdcConfig`).
- **The bring-up is `RfdcTask.run()`, in this order:** clock chips
  (`set_external_clocks`: always, so a run depends on its own
  configuration), `relock_pl_mmcm` (a clock-family change leaves the MTS
  MMCM unlocked), tile power-up (`MyRFdc.init`, PLL bypassed: the LMX2594
  output IS fs), block configuration (`setup`), NCOs. MTS is the daemon's,
  after the task (`MyMTS`), because it must end locked.
- **CWD = the library root** during `set_external_clocks` (the register
  files are `./rfsoc_lib/xrfclk/<board>/`); `xrfclk` needs `$BOARD`
  (`run_daemon.sh` sets both). `clock_plan` itself needs neither and is
  what the daemon's bitstream scan calls off the board.
- **Never rewrite an unchanged factor.** `XRFdc_SetDecimationFactor` /
  `SetInterpolationFactor` re-derive the fabric word width even when the
  value is unchanged, which breaks the compiled Data_Width gearbox; the
  guards in `config_adc_block` / `config_dac_block` stay. The daemon's
  run-time retune writes the factor and then puts the compiled
  `FabRdVldWords` / `FabWrVldWords` back.
- **MTS resets undo two things.** `MyMTS.init_tile_sync` resets the MTS
  clocking wizard (MMCM back to the build's frequency) and the DAC tiles
  (interpolation back to the build's). The `after_clkwiz_reset` /
  `after_dac_reset` hooks exist so a retune can put its own values back
  inside the sync; keep them.
- `RFSOC_MTS_TARGET="<dac>,<adc>"` (environment) sets a fixed MTS target
  latency instead of -1 (align to the slowest tile); opt-in, not yet
  characterised. `RFDC_CONFIG['NCOEventSource'] = "SYSREF"` applies
  mixer updates on a SYSREF edge instead of per tile (groundwork for
  cross-tile NCO phase, Protocol §3d); the daemon does not set it.
- `clk_wiz.mmcm_exact` must give the same (D, M, O) the FPGA build's
  `v49_clk_exact` gives (`fpga/boards/`): a factor the MMCM cannot make
  exactly from the build's PL clock is not offered.
- `gt_refclk.py` (ZCU216 only; the RFSoC 4x2's refclk is a fixed Si570):
  reads need no bus write; `program_gt_refclk` refuses a register file that
  would not give the target frequency, and is never run while the 100G
  link is in use (it restarts the GT refclk). The daemon programs it only
  when its status says the chip is unconfigured.
- Multi-tile sync needs `xrfdc.RFdc.mts_dac` / `mts_adc`; PYNQ 2.7 lacks
  them (`../setup_board.sh` adds them). `MyMTS` assumes they exist; the
  daemon checks before any hardware is touched.
