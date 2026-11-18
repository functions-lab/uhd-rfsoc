# uhd_ip — the 100 GbE / UHD data-plane cores

The FPGA cores that, with `host/` and `rfsoc/server/`, make an RFSoC board
a UHD device: sources (`src/`), testbenches (`sim/`) and packaging.

| core | job | Protocol |
|---|---|---|
| `udp_streamer` | ADC samples to UDP packets: timekeeper, stream commands, wire-format conversion | §4, §5, §10 |
| `udp_player` | UDP packets to the DAC: 2 MiB buffer, timed play-out, flow control, ARP, status packets, wire-format conversion | §6, §7, §10 |
| `axis_pkt_arb` | merges the streamer's and the player's frames into the 100G MAC | |
| `ch_interleave` | reorders the channels of a multi-channel beat to and from the wire order | §9 |
| `tx_beamformer` | TX channel 0 to every DAC, each with its own weight; or bypass | §11 |
| `rx_beamformer` | RX channel 0 = the weighted sum of all channels, the others unchanged; or bypass | §11 |
| `rx_rate` | the RX low-rate chain's hub: K FIR Compiler half-band ÷2 stages after the RF-ADC's ÷40 (rates fs/40/2^k), DEPTH register at 0x8009_0000; depth 0 = bypass | §8 |
| `tx_rate` | the TX low-rate chain's hub: K ×2 stages before the RF-DAC; depth and reset from `rx_rate` | §8 |

## Use

```sh
make all        # every xsim regression
make sim        # streamer and player only; also: sim-fmt sim-max sim-wide sim-interleave sim-bf sim-rbf sim-arb sim-gap sim-rate
make package    # write the cores as Vivado IP to ../../repo/uhd_ip
make ooc        # out-of-context timing of the streamer and the player
```

Each regression compares the simulation with an exact Python model
(`sim/check_*.py`, `sim/otw_ref.py`): PASS means bit-exact.

Needs Vivado 2021.1, on PATH or as `VIVADO_ROOT=<install dir>`.

## Where to look

- Register maps: the header of each source file.
- The wire contract: the Protocol in the top `AGENTS.md`.
- Rules for changing the cores: `AGENTS.md` here.
