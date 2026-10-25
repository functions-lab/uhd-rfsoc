# fpga_board/zcu216 — the ZCU216 as a UHD device over 100 GbE

Two block designs, one per clock family, each for N = 1, 2, 4, 8 or 16
channels (block design name `zcu216_v49_<N>ch_qsfp`):

| design | fs (MS/s) | templates (`make v49-templates[-245m76]`) | per-channel rates |
|---|---|---|---|
| `block_designs/zcu216_uhd_v49/` | 2500 | 1/2/4ch F2, 8ch F4, 16ch F8 | 1250 .. 62.5 (1, 2, 4ch), 625 .. 62.5 (8ch), 312.5 .. 62.5 (16ch) |
| `block_designs/zcu216_uhd_v49_245m76/` | 2457.6 | 1/2/4ch F2, 8ch F4, 16ch F8 | 1228.8 .. 61.44, 614.4 .. 61.44, 307.2 .. 61.44 |

The top rates of the 4, 8 and 16-channel templates carry `sc8` (and `sc12`)
only; sc16 starts at 625 / 312.5 / 156.25 MS/s (Protocol §9).

```sh
make v49-package                 # once: the UHD cores (../../fpga_ip/ip/uhd_ip)
make v49-templates               # the five fs 2500 templates
make v49-templates-245m76        # the five fs 2457.6 templates
make v49 N=4 F=2 FS=2500         # one build; FS=2457.6 picks the other family
make v49-ladder                  # every fixed-factor build (host/benchmark/oracle_builds.txt)
```

The 100 GbE link is the four zSFP28 cages (one CAUI-4 lane each, GTY quads
128 and 129); its reference clock is the board's 8A34001, which the daemon
programs at bring-up. Output `build/v49_qsfp/bitstreams/`; see `../README.md`
for the flow and `AGENTS.md` for the design rules and board facts.
