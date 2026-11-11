# rfsoc_lib — the board library

The Python code the daemon (`../server`) brings an RFSoC board up with, on
top of PYNQ's `pynq`, `xrfdc` and `xrfclk`.

It is not a package to install: the daemon finds this directory next to its
own and runs from it (the clock register files are found relative to it).

## Modules

| module | what |
|---|---|
| `rfsoc_overlay.py` | `RFSoCOverlay`: a pynq `Overlay` of one of the repository's bitstreams |
| `overlay_task.py` | `OverlayTask`: a bring-up step run on its own thread |
| `rfdc_task.py` | `RfdcTask`: the converter bring-up. Programs the clock chips, powers up the tiles, configures every block, sets the NCOs |
| `rfdc.py` | `MyRFdc`: the RFDC driver calls (tile power-up, block configuration, NCOs, attenuators) and status readbacks |
| `rfdc_config.py` | `RFDC_CONFIG`: the one configuration dict the two above read; the converters' clock limits per board |
| `rfdc_type.py` | the RFDC power-on states, for error messages |
| `clocks.py` | `clock_plan`: which clock register files a build needs; `program_clocks`: writes them |
| `clk_wiz.py` | `ClkWiz`: retunes a Clocking Wizard at run time (the daemon's in-place rate change) |
| `mts.py` | `MyMTS`: multi-tile synchronisation of the DAC and ADC tiles |
| `gt_refclk.py` | the ZCU216's 8A34001: status and programming of the 100G reference clock (156.25 MHz). Also a CLI: `python3 gt_refclk.py --status` |
| `dsp/beamformer.py` | `Beamformer`: steering weights of a uniform linear array (Protocol §11); pure numpy |
| `dsp/phase_search.py` | phase search for array calibration (`host/benchmark/phase_cal.py`); pure numpy |
| `xrfclk/<board>/` | the clock chips' register files, one directory per board (`ZCU216`, `RFSoC4x2`) |

## Clock register files

Each build needs a pair of register files, which `clocks.clock_plan` picks
from the build's `.hwh`:

| file | chip | meaning of the name (MHz) |
|---|---|---|
| `LMK04828_<in>_<ref>_<pl_clk>_<sysref>.txt` | LMK04828 | from `<in>`: `<ref>` to the LMX2594, the PL clock, SYSREF; the board's own oscillator as input |
| `LMK04828_<in>_<ref>_<pl_clk>_<sysref>_ext.txt` | LMK04828 | the same, but the reference input (a 10 MHz GPSDO) as input, the oscillator as fallback |
| `LMX2594_<ref>_<fs>.txt` | LMX2594 | from `<ref>`: `<fs>` to the converters |

The board setting `clock_source` (`external`, the default, or `internal`)
chooses between the two LMK04828 files at every bring-up. Two clock
families exist (Protocol §8a):

| family | LMX2594 reference | PL clock | SYSREF |
|---|---|---|---|
| 250 MHz | 250 | 300 | 10 |
| 245.76 MHz | 245.76 | 122.88 | 7.68 |

To add a converter rate, add its `LMX2594_<ref>_<fs>.txt` here. The FPGA
build picks its block design from the same file (`fpga/AGENTS.md`). The
files are TICS Pro register exports, one `R<n>\t0x<hex>` line per register.
