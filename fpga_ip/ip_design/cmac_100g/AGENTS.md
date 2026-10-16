# AGENTS.md — fpga_ip/ip_design/cmac_100g

100 GbE MAC wrapper for the v49 designs (ZCU216 zSFP28, RFSoC 4x2 QSFP28 with
`CMAC_LANES qsfp128`). Not a packaged IP on purpose.

## Why it is RTL in the top, not IP in the block design
- `cmac_usplus` and `gtwizard_ultrascale` may not sit inside a block-design
  module reference (Vivado filemgmt 56-181), and the IP's "GT in core" mode
  cannot reach the GT sites the zSFP28 cages use (GTY X0Y4, X0Y5 in quad 128,
  X0Y8, X0Y9 in quad 129). So `v49_build.tcl` sources `create_cmac_ip.tcl`
  (creates both IPs in the project + adds this RTL) and generates an RTL top
  (`v49_gen_top`) = BD wrapper + `cmac_100g`. The BD exports the CMAC-side
  ports (`cmac_usr_clk/rstn`, `cmac_tx/rx`, `cmac_ctl/status`,
  `cmac_init_clk`, `cmac_refclk_khz/usrclk_khz`); `v49_gen_top` maps them.

## Facts that cost board time
- ZCU216: GT refclk = Renesas 8A34001 (U409) Q11 → MGTREFCLK1_128. It boots
  UNCONFIGURED: software must program it after every power-up
  (`rfsoc/rfsoc_lib/gt_refclk.py`, register file in `rfsoc/rfsoc_lib/xrfclk/ZCU216/`),
  otherwise there is no refclk and the link never comes up. Measured 156.233 MHz.
  (RFSoC 4x2: a Si570 on MGTREFCLK0_128, 156.25 MHz from power-up.)
- `ctl` bit 0 only TRIGGERS a GT reset pulse; it does not hold the link down.
- RS-FEC on, no autoneg/link training (licensed AN/LT block absent): the far
  end (ConnectX-5) must be forced to 100G, RS-FEC, autoneg off.
- `refclk_khz` / `usrclk_khz` counters: expect ~156250 and ~322266 once the
  8A34001 runs and the GT TX PLL is up.

## Rules
- Keep the GT site constraints in the design XDCs and the wrapper in sync.
- Changing a port name here means changing `v49_gen_top` in
  `fpga_board/zcu216/scripts/v49_build.tcl` and
  `fpga_board/rfsoc4x2/scripts/v49_build.tcl`.
