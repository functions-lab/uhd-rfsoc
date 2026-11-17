# AGENTS.md — fpga/boards/zcu111

Design rules and board facts of the ZCU111 builds; the flow rules are in
`../../AGENTS.md`. The ZCU111's xczu28dr is a **Gen1** RFSoC with the
ZCU208's data-path shape (four DUAL RF-ADC tiles) but two RF-DAC tiles: the
data path follows `../zcu208/AGENTS.md`, with the Gen1 limits below.
**Block design checked (`STEP=bd`), not yet implemented or run on a board**:
every fact comes from a primary source, none from a board. The probes, the
register decoders and the full research with line-level citations
(`zcu111_facts.md`) are local, in the gitignored `fpga/build/_port/`.

## Sources
- BF: Vivado's board files `xilinx.com:zcu111:part0:1.4` (2021.1 = 2022.1;
  `board.xml`, `part0_pins.xml`, `preset.xml`); Vivado's package pin
  functions of `xczu28dr-ffvg1517-2-e`.
- UG1271 v1.4 (ZCU111 user guide): clock tree Fig 3-18, Tables 3-17..3-19,
  SFP28 p.59-60 / Fig 3-29, XM500 Appendix D.
- PG269 v2.5 and DS926 (Gen1 limits); Vivado 2021.1 probes of the RFDC IP
  on this part (`fpga/build/_port/zcu111_probe{,2..6}.tcl` + logs).
- TI SNAS684 (LMK04208), SNAS696C (LMX2594); PYNQ's xrfclk ZCU111 register
  files (identical in PYNQ 2.7 and RFSoC-PYNQ 3.x).

## Facts
- Part `xczu28dr-ffvg1517-2-e`, board part `xilinx.com:zcu111:part0:1.4`,
  Vivado's own board files. PS: the board preset plus HPM0_LPD 128 bit,
  pl_clk0 100 MHz, one fabric reset, IRQ0/1 (the preset is the ZCU216's but
  for DDR4 timing). Fabric as the xczu48dr: 80 URAM288, 1080 RAMB36, so
  `v49_tx_buffer` is unchanged.
- RFDC Gen1 (`C_IP_Type 0`): ADC tiles 0..3 (224..227), dual, inputs
  `vin<t>_01` / `vin<t>_23`, 1.0..4.096 GS/s with the PLL bypassed; DAC
  tiles 0..1 (228, 229), four outputs each `vout<t>0..3`, 0.5..6.554 GS/s.
  The IP refuses DAC tiles 2/3. Gen1 in the IP: decimation 1/2/4/8,
  interpolation of I/Q data 2/4/8 (no F = 1 TX) → factors {2, 4, 8}; ADC
  Data_Width ≤ 8, DAC ≤ 16; `ADC_CalOpt_Mode` takes 0/1 on converter slices
  0/2 only (left at the default 1); `DAC_Coarse_Mixer_Freq` is disabled with
  the fine mixer; `DAC_VOP_Mode` reads 1 and silently ignores 0 (there is no
  VOP on Gen1: the daemon must not call `SetDACVOP`).
- No on-chip clock distribution on Gen1: every tile has its own clock pin
  (`adc0_clk`..`adc3_clk`, `dac0_clk`, `dac1_clk`; the IP's Gen1 default
  `Clock_Source` = the tile itself, `Clock_Dist 0`). Three LMX2594s each
  drive two tiles from RFoutA and RFoutB (UG1271 Table 3-18: U102 → 224/225,
  U103 → 227/226, U104 → 228/229; the U103 A/B order and U103/U104 roles are
  inconsistent within UG1271), so the register files drive both outputs.
- Sample rates: exactly two, 4000 MS/s (the top rate) and 3932.16 MS/s =
  8 x 491.52 (the 3GPP rates: 1966.08 / 983.04 / 491.52 per channel at F 2 /
  4 / 8). Gen1 decimates by 2, 4, 8 only, so 122.88 / 61.44 MS/s are not
  reachable in the converters.
- Every register file is a TICS Pro (1.7.7) export (File > Export hex
  register values; byte for byte, CRLF), driven over its TCP server from
  the ticspro-container VM; scripts in `fpga/build/_port/tics/`. The
  baseline of each is PYNQ's ZCU111 file loaded into TICS Pro (TICS Pro's
  export of PYNQ's `LMK04208_122.88.txt` reproduces it byte for byte, so
  PYNQ's files are TICS exports too). LMK04208 (U90): 12.8 MHz TCXO on
  CLKin0 (SMA ref on CLKin1, auto mode, also 12.8 MHz), 122.88 MHz VCXO,
  PLL1 unchanged in both families.
- 122.88 MHz family (fs 3932.16):
  - `LMK04208_12.8_122.88_122.88_7.68.txt` = PYNQ's `LMK04208_122.88.txt`
    unchanged: PLL2 61.44 MHz phase detector, VCO 3072, CLKout0 PL SYSREF /
    CLKout1 RFSoC SYSREF 7.68, CLKout2 PL_CLK 122.88, CLKout4 = OSCin 122.88
    to the LMX2594s, all LVDS.
  - `LMX2594_122.88_3932.16.txt` (TICS Pro): fPD 122.88, N 64 integer mode
    (MASH 0, PFD_DLY_SEL 1), VCO 7864.32 / CHDIV 2, SEG1_EN 0, RFoutA and
    RFoutB on, power 12 (PYNQ's), FCAL_HPFD_ADJ 1, CAL_CLK_DIV 0,
    ACAL_CMP_DLY 12, VCO assist (TICS "Estimate Settings") VCO1 / 114 / 279.
- 320 MHz family (fs 4000):
  - `LMK04208_12.8_320.0_320.0_5.0.txt` (TICS Pro): PLL2 moved to a 2880
    MHz VCO (122.88 / R 16 = 7.68 MHz phase detector, P 3, N 125; PYNQ's is
    61.44 MHz / VCO 3072), CLKout4 = VCO / 9 = 320 MHz to the LMX2594s,
    CLKout2 = VCO / 9 = PL_CLK 320, CLKout0 / 1 = VCO / 576 = SYSREF 5 MHz;
    PLL2's internal loop filter (R3 / C3 / R4 / C4) and charge pump kept as
    PYNQ's. Why 2880: a SYSREF for fs 4000 must divide 4000 / 16 = 250 and
    the fabric clocks, so it is made of 2s and 5s; 3072 MHz / (divider <=
    1045) cannot make one, and 2880 is the VCO with the highest PLL2 phase
    detector (gcd with 122.88) that can.
  - `LMX2594_320.0_4000.0.txt` (TICS Pro): pre-R 2 (PLL_R takes <= 250 MHz)
    -> fPD 160, N 50 integer mode (N 25 at fPD 320 is below the integer-mode
    minimum 28), VCO 8000 / CHDIV 2, SEG1_EN 0, FCAL_HPFD_ADJ 2, CAL_CLK_DIV
    1, ACAL_CMP_DLY 16, VCO assist VCO1 / 95 / 272.
  - Not tested on a board: PLL2 at a 7.68 MHz phase detector with the
    board's external PLL2 loop-filter components (unknown, schematic not
    public) sized for PYNQ's 61.44 MHz. If the LMK04208 does not lock
    (`Status`/LD), this is the first suspect.
- No external-reference variant in either family (a 10 MHz reference needs
  new PLL1 dividers); the daemon runs the ZCU111 on its own oscillator.
- MTS: all four ADC and both DAC tiles, reference tile 0 of each (PG269:
  tile 0 must be active; the analog SYSREF enters bank 228). PG269's rule
  (SYSREF divides fs/16, PL_CLK and the converter clock): 7.68 MHz meets it
  at every 3932.16 rate; 5 MHz at 4000 for F2 / F4 (250 / 125 MHz) but not
  for the 1 / 2-channel F8 run-time rate (62.5 MHz; no SYSREF the LMK04208
  can make divides it), whose MTS alignment is unproven.
  `verify_rate_variant` checks the rule for every built template. The three
  LMX2594s are not phase-synchronised (VCO_PHASE_SYNC 0, CLKout3 / LMX SYNC
  off), as in PYNQ.
- PL_CLK AL16/AL15 (IO_L13P/N_GC_QBC_64), PL_SYSREF AK17/AK16 (IO_L14P/N_GC_64),
  HP bank 64 at 1.8 V (UG1271 Table 3-17). **UNCONFIRMED**: termination /
  bias (UG1271: "series capacitor coupled"; no master XDC found). The XDC
  uses LVDS + DIFF_TERM_ADV TERM_100 + DQS_BIAS. GC pins → BUFG → MMCM:
  only the BUFG ANY_CMT_COLUMN setting (`board_xdc_nets`).
- 100 GbE: no QSFP; four SFP28 cages SFP0..3 = GTY X0Y4..X0Y7 (quad 128,
  CMACE4_X0Y0; UG1271 Fig 3-29, BF sfp0..3), a QSFP28 → 4 x SFP28 breakout
  to the NIC. Refclk: the user MGT Si570 U49 on MGTREFCLK1_129 (V31/V32),
  156.25 MHz at power-up (UG1271 p.48, BF `user_mgt_si570_clock`): nothing
  programs it (`gt_refclk "si570"`), and the ZCU111 device trees of every
  PYNQ image leave it at 156.25 MHz (`si570_mgt` u49: factory-fout =
  clock-frequency = 156250000 in linux-xlnx zynqmp-zcu111-revA.dts at
  xilinx-v2020.2 (PYNQ 2.7), v2022.1 (3.0) and v2024.1 (3.1), and in
  device-tree-xlnx's zcu111-reva.dtsi; PYNQ's ZCU111 BSP overlay does not
  touch it). `CMAC_LANES sfp128` =
  qsfp128's lanes and one-quad QPLL0 (`CMAC_ONE_QUAD`) with `REFCLK_SOURCE
  clk1+1`; the GT wizard's port list is identical to qsfp128's (probe6).
  Quad 128's QPLL0 fed from quad 129's refclk1 (the ZCU216 routes the other
  way, clk1-1) places, routes and meets timing (the 1ch build); a lock on a
  board is still unproven. MGTREFCLK0/1_128 are the
  Si5382 clock-recovery path (state unknown): not used. TX_DISABLE are
  jumpers (UG1271 Table 3-21): `board_top_ties {}`.
- LEDs: `led[7:0]` = GPIO_LED_0..7 (AR13 AP13 AR16 AP16 AP15 AN16 AN17 AV15,
  LVCMOS18, BF `led_8bits`).
- XM500 SMAs (UG1271 Table D-1): ADC 224/225 and DAC 229 have baluns
  (single-ended SMAs); ADC 226/227 and DAC 228 are differential pairs.
- PYNQ: images 2.7, 3.0.1, 3.1.1 exist; `$BOARD` = `ZCU111`; no ZCU111 base
  overlay exists upstream.

## Design
- Two designs (`board_families {320.0 zcu111_uhd_v49_320m 122.88
  zcu111_uhd_v49_122m88}`): `block_designs/zcu111_uhd_v49_320m/` (PL_CLK
  320, SYSREF 5, fs 4000, the default) and `block_designs/zcu111_uhd_v49_122m88/`
  (PL_CLK 122.88, SYSREF 7.68, fs 3932.16). Non-Xilinx IP:
  `fpga/ip/repo/uhd_ip` and `dual_rf_adc_iq_merger` (`board_ip_repos`).
- Channel map (`v49_channel_slices`): channel c = ADC tile c/2 converter
  c%2 (IP slices 2(c%2) I / 2(c%2)+1 Q, API block c%2) and DAC tile c/4
  slice c%4. Every N includes the MTS reference tiles.
- Geometry (`v49_geometry`): rows 1/2ch S 8 (256 / 512-bit beat), 4ch S 4,
  8ch S 2 (512), F in {2, 4, 8}; rows whose fabric fs/F/S exceeds 312.5 MHz
  are not built at that fs: templates 1/2ch F2, 4ch F4, 8ch F8 at both fs
  (fabric 250 MHz at 4000, 245.76 at 3932.16).
- `verify_rate_variant` also checks: Gen1 factor, 16 + 8 slices and no DAC
  tile 2/3, per tile PLL bypassed / Refclk = fs / own Clock_Source / no
  Clock_Dist / its clock pin wired to the board port, MTS on tile 0, the
  SYSREF rule, the PL_CLK / PL_SYSREF port frequencies.
- Implementation strategy: Performance_ExtraTimingOpt on every template.
- Vivado 2024.1 (PYNQ 3.1) builds report 2 register pins with no clock in
  check_timing: `INTERNAL_CLK_DIG` of the two Gen1 RF-DAC primitives
  (`rfdc/.../tx0_u_dac`, `tx1_u_dac`), a hard-block pin 2024.1's RFDC IP
  leaves without a clock for Gen1 (2021.1 / 2022.1 define one). Nothing
  fabric-side is untimed: 0 unconstrained endpoints, 0 inputs without delay.
