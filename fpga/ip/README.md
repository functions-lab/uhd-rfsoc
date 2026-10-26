# fpga/ip — the custom FPGA IP

| path | what |
|---|---|
| `src/uhd_ip/` | the UHD data-plane cores (udp_streamer, udp_player, axis_pkt_arb, ch_interleave, tx/rx_beamformer): RTL, xsim testbenches, packaging |
| `repo/uhd_ip/` | those cores packaged (`user.org:uhd:<core>:1.0`): written by `make -C fpga package`, never edited |
| `src/cmac_100g/` | the 100G CMAC + GT wrapper RTL; instantiated in each build's generated RTL top, not in the block design |
| `repo/dual_rf_adc_iq_merger_1.0`, `repo/dual_channel_rf_adc_iq_packer_1.0` | the RFSoC 4x2's dual RF-ADC I/Q joiners, packaged in place (HDL in `hdl/`, testbench in `tb/`, `package_ip.tcl`) |

`repo/` is what the block designs import (`fpga/flow/build.tcl` adds
`repo/uhd_ip` and the board's `board_ip_repos`). Everything here needs only
Vivado 2021.1. Each subdirectory's `README.md` / `AGENTS.md` has the details.
