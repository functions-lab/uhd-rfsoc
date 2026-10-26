# AGENTS.md — fpga/ip

- After ANY change in `src/uhd_ip/src/` (comments included): run the
  matching sims (`make -C src/uhd_ip all`), then `make -C fpga package`
  (writes `repo/uhd_ip`), commit `src/` and `repo/uhd_ip` together, rebuild
  the bitstreams. `src/uhd_ip/AGENTS.md` has the rules.
- `repo/uhd_ip` is generated: never hand-edit it.
- `repo/dual_*` (the RFSoC 4x2 I/Q joiners) are packaged in place: edit their
  `hdl/`, then re-run their `package_ip.tcl` in Vivado 2021.1 (`vivado -mode
  batch -source package_ip.tcl` in the IP's directory); their `tb/` are
  self-checking xsim / iverilog testbenches.
- `src/cmac_100g` is RTL added to the build project, not a packaged IP
  (`src/cmac_100g/AGENTS.md` says why); its port names are part of the
  contract with `fpga/flow/build.tcl` (`v49_gen_top`).
