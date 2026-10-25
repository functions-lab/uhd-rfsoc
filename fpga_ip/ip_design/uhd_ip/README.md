# uhd_ip — the 100 GbE / UHD data-plane cores

Sources, testbenches and packaging of the FPGA cores that make a ZCU216 or an
RFSoC 4x2 a UHD device (with `host/` and `rfsoc/server/`). `make package`
writes them as Vivado IP (`user.org:uhd:<core>:1.0`) to `../../ip/uhd_ip`,
the repository the block designs in `fpga_board/<board>/block_designs/`
import.

| core (`src/`) | job |
|---|---|
| `udp_streamer` | ADC samples -> Ethernet/IPv4/UDP/VRT frames; timekeeper, stream commands, sc16/sc8/sc12/fc32 conversion (Protocol §4, §5, §10) |
| `udp_player` | UDP/VRT packets -> DAC; 2 MiB buffer, timed play-out, flow control, ARP, async status, format conversion (§6, §7, §10) |
| `axis_pkt_arb` | merges the streamer's and the player's frames into the CMAC TX |
| `ch_interleave` | channel-major <-> sample-major (wire) slot order of a multi-channel beat (§9) |
| `tx_beamformer` | TX ch0 x w[c] to every DAC, or bypass (§11; datapath `beamformer_v1_0.sv`, `beamformer_channel.sv`) |
| `rx_beamformer` | RX ch0 = sum of x[c] w[c], channels 1..N-1 raw, or bypass (§11) |

```sh
make sim sim-fmt sim-max sim-wide sim-interleave sim-bf sim-rbf sim-arb   # xsim regressions (`make all`)
make package                                                           # -> ../../ip/uhd_ip
make ooc                                                               # out-of-context timing of streamer / player
```

Every regression replays the simulation against an exact Python model
(`sim/check_*.py`, `sim/otw_ref.py`): PASS means bit-exact. Needs Vivado
2021.1 (`vivado` on PATH, or `VIVADO_ROOT=<install dir>`). Register maps are
in each source's header; the wire contract is the Protocol in the top
`AGENTS.md`; rules for changing the cores are in `AGENTS.md` here.
