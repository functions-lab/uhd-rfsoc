# AGENTS.md — hw_design/ip_design/uhd_ip

Working directory of the ZCU216 UHD data-plane IP. Read before touching `src/`.

## Layout and flow
- `src/<core>.v` — the RTL (Verilog-2001 + XPM). One module per file, no
  sub-modules, EXCEPT `tx_beamformer.v`, which instantiates the v47 beamformer
  datapath `hw_design/ip/iprepo/beamformer_1.0/hdl/{beamformer_v1_0,beamformer_channel}.sv`
  (packaged together with it). The register map is in each file's header.
- `sim/` — xsim testbenches + Python checkers. Every regression replays a log
  against an exact Python model; "PASS" means bit-exact, not "looks right".
  - `run_sim.sh` / `run_sim_player.sh` (FMTS, WIDTHS 128..1024, TICK_STEPS, FAST, TXBW env knobs),
    `run_sim_interleave.sh`, `run_sim_bf.sh` (TX beamformer, PIPE 0/1),
    `run_sim_rbf.sh` (RX beamformer), `run_sim_arb.sh` (axis_pkt_arb against
    its previous skid-buffer form `sim/axis_pkt_arb_skid_ref.v`, every port
    every cycle). Make targets: `sim sim-fmt sim-max sim-wide sim-interleave
    sim-bf sim-rbf sim-arb` (`all` runs them all).
  - `otw_ref.py` = reference sc8/sc12/fc32 converters (shared with the checkers).
- `package_ip.tcl` (`make package`) → `../../ip/uhd_ip/<core>_1.0`
  (`user.org:uhd:<core>:1.0`). It refuses to save a core whose bus interfaces,
  user parameters or AXI-Lite block (`reg0`) differ from what
  `hw_design/ZCU216/block_designs/zcu216_v49_qsfp/zcu216_v49_qsfp.tcl` connects. HDL with `[` `]` inside a
  Tcl description string breaks it (command substitution) — avoid brackets there.
- `ooc_timing.tcl` (`make ooc`) — out-of-context timing for streamer/player.

## Rules
- After ANY change in `src/`: run the matching sims, then `make package`, and
  commit `src/` together with `hw_design/ip/uhd_ip`. A bitstream built from a
  stale package silently carries the old RTL.
- Never edit `hw_design/ip/uhd_ip` by hand — it is generated.
- Block designs must not reference RTL here as module references; they
  instantiate the packaged IP (rule: a block-design dir holds only .tcl + .xdc).
- Geometries that matter (N_CH:BEAT_W:clock) are the `v49_geometry` rows in
  `zcu216_v49_qsfp.tcl`; the bf sims' COMBOS list mirrors them — keep in sync.
- Contract changes (registers, wire format) go into `rfsoc_lib/uhd/PROTOCOL.md`
  and the board driver (`rfsoc_lib/uhd/server/`) in the same change.

## Key facts
- axis_pkt_arb feeds the CMAC TX, whose tready is the hard block's tx_rdy:
  late at 322 MHz. It must stay off wide enables: the output is a two-entry
  FIFO whose entries are written from the arbiter side only, tready moves just
  the read pointer and count. (The previous output+skid register form missed
  timing by ~0.2 ns on ~860 CE endpoints, placement-dependent.)
- RX beamformer: ch0 = sat16((Σ x_c·w_c + 2^(14+SHIFT)) >> (15+SHIFT)); SHIFT
  reset log2(N); LOAD applies W[] and SHIFT atomically; latency 7+log2(N).
  The §5 test pattern is inserted AFTER it (a pattern capture is never beamformed).
- TX beamformer: PIPE=1 (5-cycle) on 300 MHz builds, PIPE=0 (the v47 IP, 3-cycle)
  otherwise; the IP's math WRAPS (no saturation) — keep |x|·|w| ≤ 1.
- Format converters (FMT register) sit after the TX buffer / before the RX FIFO;
  sc16 is the unconverted path (bypass).
- Beat widths 128 / 256 / 512 carry every format the rate allows; 1024 (the
  sc8max 8ch F3 / 16ch F6 builds, 187.5 MHz) carries sc8 ONLY: one 32-slot
  beat is one sc8 wire word per clock. There the streamer drops (and counts)
  every packet of another FMT and the player holds play-out; `make sim-wide`.
