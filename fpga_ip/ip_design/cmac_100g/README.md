# cmac_100g — 100 GbE MAC for the ZCU216 zSFP28 cages

RTL wrapper around the Xilinx CMAC (`cmac_usplus`, CAUI-4, RS-FEC) and a
split-quad GTY wizard reaching the four zSFP28 cages (quads 128/129). Used by
the `zcu216_v49_<N>ch_qsfp` designs in the RTL top, not in the block design.

- `cmac_100g.v` — top: CMAC + GT + clocking; ctl/status words and refclk/user-clock
  frequency counters (bits documented in the header).
- `create_cmac_ip.tcl` — creates the CMAC and GT wizard IP in the current
  project and adds the RTL; `CMAC_REFCLK` picks `refclk_156.25/` (default, the
  8A34001-driven clock) or `refclk_161.1328125/`.
- `cmac_caui4_*.v` — the wizard's support wrappers, retargeted to the board's GT sites.

`hw_design/ZCU216/scripts/v49_build.tcl` sources `create_cmac_ip.tcl`; nothing
here is built on its own.
