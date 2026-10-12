# AGENTS.md — fpga_ip

- After ANY change in `ip_design/uhd_ip/src/`: run the matching sims, then
  `make package` there (writes `ip/uhd_ip`), commit `src/` and `ip/uhd_ip`
  together, rebuild the bitstreams. `ip_design/uhd_ip/AGENTS.md` has the rules.
- `ip/uhd_ip` is generated: never hand-edit it.
- These files come from SPEAR (`sync/manifest`): push changes back with
  `sync/spear_sync.py push`.
