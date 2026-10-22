# fpga_board/zcu216 — the ZCU216 as a UHD device over 100 GbE

`block_designs/zcu216_uhd_v49/zcu216_uhd_v49.tcl` + `.xdc`: the whole design, for
every build (V49_NCH channels, V49_FACTOR, V49_FS). `scripts/v49_build.tcl`
makes a project, adds the CMAC (`../../fpga_ip/ip_design/cmac_100g`) in a
generated RTL top, builds and keeps the bitstream; `scripts/v49_ladder.sh`
builds the whole list. See `../README.md` for the commands and
`AGENTS.md` for the design rules.

Each bitstream is also a run-time-rate template: the daemon retunes it to
every lower factor of its channel count (1ch F2: 1250 .. 62.5 MS/s, ~1 s per
change, MTS re-locked each time). `make v49-templates` builds the five that
cover every fs 2500 rate (1, 2, 4ch F2, 8ch F4, 16ch F8).
