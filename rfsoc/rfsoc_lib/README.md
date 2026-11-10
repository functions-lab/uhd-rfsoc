# rfsoc_lib — the board library

The Python the daemon (`../server`) brings an RFSoC board up with, on top
of PYNQ's `pynq`, `xrfdc` and `xrfclk`. Not a package to install: the daemon
puts this directory's parent on `sys.path` and runs with it as the current
directory (the clock register files are found relative to it).

| module | what |
|---|---|
| `rfsoc_overlay.py` | `RFSoCOverlay`: a pynq `Overlay` of one of the repository's bitstreams |
| `overlay_task.py` | `OverlayTask`: a bring-up step run on its own thread (`start()` / `join()`) |
| `rfdc_task.py` | `RfdcTask`: program the clock chips, power the converter tiles up, configure every block, set the NCOs, as `rfdc_config.RFDC_CONFIG` says; `relock_pl_mmcm` for a clock-family change |
| `rfdc.py` | `MyRFdc`: the RFDC driver calls (tile power-up with the PLL bypassed, block configuration, NCOs, DSA) and the status readbacks |
| `rfdc_config.py` | `RFDC_CONFIG`, the one configuration dict the two above read (the daemon fills it with the loaded build's geometry); the converters' clock limits per board |
| `rfdc_type.py` | the RFDC power-on sequence states, for error messages |
| `clocks.py` | `clock_plan`: which LMK04828 + LMX2594 register files a build needs; `program_clocks`: write them through `xrfclk` |
| `clk_wiz.py` | `ClkWiz`: retune a Clocking Wizard MMCM at run time over its AXI dynamic-reconfiguration port (the daemon's in-place rate change) |
| `mts.py` | `MyMTS`: multi-tile synchronisation of the DAC and ADC tiles (`xrfdc`'s `mts_dac` / `mts_adc`), with the MTS clocking wizard checked |
| `gt_refclk.py` | the ZCU216's 8A34001 (U409): read its status, program the 100G GT reference clock (156.25 MHz) from a register file; also a CLI (`python3 gt_refclk.py --status`) |
| `dsp/beamformer.py` | `Beamformer`: Q1.15 steering weights of a uniform linear array (Protocol §11); pure numpy |
| `dsp/dpd.py` | the TX DPD (Protocol §12): the bit-exact model of `tx_dpd` (`dpd_fx`), coefficient words and checks, the safety gate, the indirect-learning fit and its metrics; pure numpy, the one reference of the sims, the daemon and `host/tools/rfsoc_dpd.py` |
| `dsp/phase_search.py` | pairwise phase search for array calibration (`host/benchmark/phase_cal.py`); pure numpy |
| `xrfclk/<board>/` | the clock chips' register files (TICS Pro exports), one directory per board (`Board.name`: `ZCU216`, `RFSoC4x2`) |

## Clock register files

`clocks.clock_plan` picks, for a build, the pair

    LMK04828_<in>_<ref>_<pl_clk>_<sysref>.txt    LMK04828 from <in> MHz: <ref> MHz to the
                                                 LMX2594, <pl_clk> MHz PL clock, <sysref> MHz SYSREF
    LMX2594_<ref>_<fs>.txt                       LMX2594 from <ref> MHz: <fs> MHz to the converters

from the build's `.hwh` (converter `Refclk_Freq` = fs, MTS clocking wizard
`PRIM_IN_FREQ` = the PL clock). Two clock families exist (Protocol §8a):
250 MHz reference with PL clock 300 / SYSREF 10, and 245.76 MHz with
122.88 / 7.68. Shipped: `LMK04828_10.0_250.0_300.0_10.0.txt`,
`LMK04828_10.0_245.76_122.88_7.68.txt` (both boards),
`LMX2594_250.0_{2400,2500}.0.txt` (ZCU216), `LMX2594_250.0_{4800,5000}.0.txt`
(RFSoC 4x2), `LMX2594_245.76_{1638.4,2457.6}.txt` (both),
`LMX2594_245.76_4915.2.txt` (RFSoC 4x2). A new converter rate is a new
`LMX2594_<ref>_<fs>.txt` here (the FPGA build picks its block design from
the same file, `fpga/AGENTS.md`); the file is a TICS Pro register
export, one `R<n>\t0x<hex>` line per register.
