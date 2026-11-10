# AGENTS.md — fpga/ip/src/uhd_ip

Working directory of the UHD data-plane IP (ZCU216 and RFSoC 4x2). Read before
touching `src/`.

## Layout and flow
- `src/<core>.v` — the RTL (Verilog-2001 + XPM). One module per file, no
  sub-modules, EXCEPT `tx_beamformer.v`, which instantiates the beamformer_1.0
  datapath `src/{beamformer_v1_0,beamformer_channel}.sv` (packaged together
  with it; keep those two unmodified: PIPE=1 is tx_beamformer.v's own
  re-pipelined, bit-identical copy of their arithmetic), and `tx_dpd.v`,
  whose datapath is `src/dpd_*.sv` (SystemVerilog, one module per file,
  packaged with it; `dpd_mpl_core.sv` has the stage plan). The register map
  is in each file's header.
- `sim/` — xsim testbenches + Python checkers. Every regression replays a log
  against an exact Python model; "PASS" means bit-exact, not "looks right".
  - `run_sim.sh` (streamer) / `run_sim_player.sh` (player, and with `-d INTEG`
    streamer + player + arbiter): env knobs `FMTS` (0 sc16 1 sc8 2 sc12 3
    fc32), `WIDTHS` (128 256 512 1024), `TICK_STEPS`, `FAST`, `TXBW`, `CHAIN`.
    `run_sim_interleave.sh`, `run_sim_bf.sh` (TX beamformer, PIPE 0 and 1),
    `run_sim_rbf.sh` (RX beamformer), `run_sim_dpd.sh` (TX DPD: every
    geometry against `rfsoc/rfsoc_lib/dsp/dpd.py`, atomic switching searched
    beat by beat, statistics, two clock ratios), `run_sim_arb.sh` (axis_pkt_arb against
    its previous skid-buffer form `sim/axis_pkt_arb_skid_ref.v`, every port
    every cycle). Make targets: `sim sim-fmt sim-max sim-wide sim-interleave
    sim-bf sim-rbf sim-dpd sim-arb` (`all` runs them all).
  - `otw_ref.py` = reference sc8/sc12/fc32 converters (shared with the checkers;
    the daemon's `rfsoc/server/vrt.py` is the other reference).
- `package_ip.tcl` (`make package`) → `../../repo/uhd_ip/<core>_1.0`
  (`user.org:uhd:<core>:1.0`), the HDL copied into each IP. It refuses to save
  a core whose bus interfaces, user parameters or AXI-Lite block (`reg0`)
  differ from what the block designs connect. HDL with `[` `]` inside a Tcl
  description string breaks it (command substitution): avoid brackets there.
- `ooc_timing.tcl` (`make ooc`) — out-of-context timing for streamer / player
  / tx_dpd at the deployed beat widths.

## Rules
- After ANY change in `src/` (comments included: the packaged copy must stay
  identical): run the matching sims, then `make package`, and commit `src/`
  together with `fpga/ip/repo/uhd_ip`. A bitstream built from a stale package
  silently carries the old RTL.
- Never edit `fpga/ip/repo/uhd_ip` by hand — it is generated.
- Block designs instantiate the packaged IP, never this RTL as module
  references (rule: a block-design directory holds only `.tcl` + `.xdc`).
- The geometries that matter (N_CH, BEAT_W, converter clock) are the
  `v49_geometry` rows of the four block designs; the beamformer sims'
  `COMBOS` lists cover them — keep them in step.
- Contract changes (registers, wire format) go into the Protocol (top
  `AGENTS.md`) and the board driver (`rfsoc/server/`) in the same change.

## Key facts
- axis_pkt_arb feeds the CMAC TX, whose tready is the hard block's tx_rdy:
  late at 322 MHz. It must stay off wide enables: the output is a two-entry
  FIFO whose entries are written from the arbiter side only, tready moves just
  the read pointer and count. (An output+skid register form missed timing by
  ~0.2 ns on ~860 CE endpoints, placement-dependent.)
- RX beamformer: ch0 = sat16((Σ x_c·w_c + 2^(14+SHIFT)) >> (15+SHIFT)); SHIFT
  reset log2(N); LOAD applies W[] and SHIFT atomically; latency 7+log2(N).
  The §5 test pattern is inserted AFTER it (a pattern capture is never beamformed).
- TX beamformer: PIPE=1 (5-cycle) above a 150 MHz converter clock (every
  template), PIPE=0 (beamformer_v1_0 as is, 3-cycle) otherwise; the IP's math
  WRAPS (no saturation) — keep |x|·|w| ≤ 1.
- TX DPD (`tx_dpd`): the last block before the DACs in every build (after the
  TX beamformer), N_CH x SSR lanes (SSR = BEAT_W / N_CH / 32: 4 at 1/2/4
  channels on the ZCU216, 2 at 8, 1 at 16, 8 on the RFSoC 4x2). Fixed
  latency 32 (every DSP multiplier has its own input registers; the final
  delay line takes the slack), no backpressure. Its registers live on
  s_axi_aclk: messages to aclk through one xpm_cdc_handshake acknowledged
  only once applied, statistics back round-robin, so no AXI access waits on
  the converter clock. 16 lanes need ~860 DSPs.
- Format converters (FMT register) sit after the TX buffer / before the RX
  FIFO; sc16 is the unconverted path (bypass). TICK_STEP is 1 on every build
  (one tick per 32-bit slot, Protocol §9).
- Beat widths 128 / 256 / 512 carry every format the rate allows (RX fc32
  not at 512: it would need two FIFO words per clock). The cores also accept
  a 1024-bit beat, which carries sc8 ONLY (one 32-slot beat = one wire word
  per clock); no v49 build has one (Protocol §10), `make sim-wide` keeps it
  working: the streamer drops (and counts) every packet of another FMT and
  the player holds play-out.
