# uhd_ip — 100 GbE / UHD data-plane cores

Sources, testbenches and packaging of the FPGA cores that make a ZCU216 or an
RFSoC 4x2 a UHD device (with `host/` and `rfsoc/server/`). Packaged IP goes to
`fpga_ip/ip/uhd_ip`, which the v49 block designs
(`fpga_board/zcu216/block_designs/zcu216_uhd_v49`,
`fpga_board/rfsoc4x2/block_designs/rfsoc4x2_uhd_v49`) import.

| core | job |
|---|---|
| `udp_streamer` | ADC samples → Ethernet/IPv4/UDP/VRT frames; timekeeper, stream commands, sc16/sc8/sc12/fc32 conversion |
| `udp_player` | UDP/VRT packets → DAC; 2 MiB buffer, timed playout, flow control, ARP, format conversion |
| `axis_pkt_arb` | merges the two frame sources into the CMAC TX |
| `ch_interleave` | channel-major ↔ wire (sample-major) slot order |
| `tx_beamformer` | TX ch0 × w[c] to every DAC, or bypass (datapath: `beamformer_v1_0.sv`, `beamformer_channel.sv`) |
| `rx_beamformer` | RX ch0 = Σ x[c]·w[c], channels 1..N−1 raw, or bypass |

```
make sim sim-fmt sim-max sim-wide sim-interleave sim-bf sim-rbf sim-arb   # xsim regressions
make package                                             # -> ../../ip/uhd_ip
```

Converter beats are 128, 256, 512 or 1024 bits; the 1024-bit beat (sc8max
8ch / 16ch builds) carries sc8 only, one wire word per clock.

Needs Vivado 2021.1 (the `vivado` on PATH, or `VIVADO_ROOT=<install dir>`). Register
maps are in each source header; the wire contract is the Protocol (top
`AGENTS.md`).
