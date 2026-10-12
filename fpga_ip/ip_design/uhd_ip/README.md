# uhd_ip — 100 GbE / UHD data-plane cores for the ZCU216

Sources, testbenches and packaging of the FPGA cores that make the ZCU216 a UHD
device (`rfsoc_lib/uhd`). Packaged IP goes to `hw_design/ip/uhd_ip`, which the
`zcu216_v49_<N>ch_qsfp` block designs import.

| core | job |
|---|---|
| `udp_streamer` | ADC samples → Ethernet/IPv4/UDP/VRT frames; timekeeper, stream commands, sc16/sc8/sc12/fc32 conversion |
| `udp_player` | UDP/VRT packets → DAC; 2 MiB buffer, timed playout, flow control, ARP, format conversion |
| `axis_pkt_arb` | merges the two frame sources into the CMAC TX |
| `ch_interleave` | channel-major ↔ wire (sample-major) slot order |
| `tx_beamformer` | TX ch0 × w[c] to every DAC, or bypass |
| `rx_beamformer` | RX ch0 = Σ x[c]·w[c], channels 1..N−1 raw, or bypass |

```
make sim sim-fmt sim-max sim-wide sim-interleave sim-bf sim-rbf   # xsim regressions
make package                                             # -> ../../ip/uhd_ip
```

Converter beats are 128, 256, 512 or 1024 bits; the 1024-bit beat (sc8max
8ch / 16ch builds) carries sc8 only, one wire word per clock.

Needs Vivado 2021.1 (`VIVADO_ROOT`, default `~/Xilinx/Vivado/2021.1`). Register
maps are in each source header; the wire contract is `rfsoc_lib/uhd/PROTOCOL.md`.
