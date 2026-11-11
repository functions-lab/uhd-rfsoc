# cmac_100g — the 100 GbE MAC

An RTL wrapper around the Xilinx 100G MAC (`cmac_usplus`, CAUI-4, RS-FEC)
and its GTY transceivers. Every `<board>_v49_<N>ch_qsfp` design uses it, in
the generated RTL top rather than in the block design.

| board | port | lanes | `CMAC_LANES` |
|---|---|---|---|
| ZCU216 | the four zSFP28 cages | quads 128 and 129 | `zsfp` (default) |
| RFSoC 4x2 | the QSFP28 | quad 128 | `qsfp128` |

| file | what |
|---|---|
| `cmac_100g.v` | the top: MAC, transceivers, clocking, control / status words, clock frequency counters (bits documented in its header) |
| `create_cmac_ip.tcl` | creates the MAC and transceiver IP in the current project and adds the RTL |
| `cmac_caui4_*.v` | the transceiver wizard's support wrappers, retargeted to the board's GT sites |
| `refclk_156.25/`, `refclk_161.1328125/` | the variants per reference clock: `CMAC_REFCLK` picks one (default 156.25 MHz) |

Nothing here is built on its own: `fpga/flow/build.tcl` sources
`create_cmac_ip.tcl` for every build.
