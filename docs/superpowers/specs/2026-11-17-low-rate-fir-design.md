# Rates below the RFDC floor: FIR Compiler decimation / interpolation chains

Status: draft for approval (2026-11-17). Branch `feat-add-more-rate` in
uhd-rfsoc and uhd-rfsoc-bitstream.

## Intent

Today the per-channel rate is fs / F, F the RFDC Gen3 decimation (=
interpolation) factor, and F stops at 40: the lowest rate is 62.5 / 61.44 /
60 MS/s on the ZCU216 and 125 / 122.88 / 120 MS/s on the RFSoC 4x2. That is
too coarse for narrow-band work (LTE / NR 20 .. 1.4 MHz carriers, the
X310-class rates a UHD application expects). The user wants the ladder to
keep going down by putting AMD FIR Compiler filters in the TX and RX data
paths.

The user chose (conversation, 2026-11-17):

- **Halvings of the F40 rate**: extra ÷2 (RX) / ×2 (TX) stages below the
  RFDC's F = 40, down to ~1.92 MS/s: 30.72, 15.36, 7.68, 3.84, 1.92 MS/s at
  fs 2457.6 (and the same halvings of 62.5 / 60 at fs 2500 / 2400; of 125 /
  122.88 / 120 on the RFSoC 4x2).
- **Approach 1**: one run-time chain per direction in every design, used
  only at the RFDC's F = 40, the number of active stages a register, the new
  rates run-time rates of the existing templates (an in-place retune, no
  reload).
- Work on `feat-add-more-rate` in both repos, pushed when done.

## Goals

- Every ZCU216 and RFSoC 4x2 template serves, in addition to its current
  rates, fs / 40 / 2^k for k = 1 .. K, K = 5 on the ZCU216 (61.44 -> 1.92)
  and K = 6 on the RFSoC 4x2 (122.88 -> 1.92), at every channel count it has
  today (ZCU216 1/2/4/8/16, 4x2 1/2), in every clock family.
- A UHD `set_rx_rate` / `set_tx_rate` to one of them works like any other
  run-time rate (Protocol §8): met from below, RX = TX, retune in place,
  streaming stopped, readbacks checked, `ERR ... restored` on failure.
- With the chain at depth 0 the data path is today's, bit for bit (the
  existing rates are unchanged in content, latency and timing semantics).
- Timestamps, `num_done` bursts, timed TX, flow control, multi-channel phase
  alignment and the beamformers keep their Protocol meaning at the new rates:
  a tick is still one slot of the rate in force, a TSF still names the slot
  it stamps. The TX->RX latency (antenna to antenna, in samples) is constant
  for a given rate, as it is today for each RFDC factor (whose filters'
  delays also differ per factor); it is measured per depth, not removed.
- Every published template is rebuilt for PYNQ 2.7, 3.0 and 3.1
  (uhd-rfsoc-bitstream, `feat-add-more-rate`), timing-clean.

## Non-goals

- Rates other than F40 / 2^k (no ÷3, ÷5, no chain at F < 40: approach 2,
  rejected for duplicate rates and rate-list noise).
- Fixed-rate low-rate bitstreams (approach 3, rejected: a reload per rate,
  against "a new rate is a run-time factor of a template").
- ZCU111 / ZCU208 (they live on `feat-zcu111-zcu208`, not merged; the same
  chain can be ported there later).
- Compensating the chain's group delay in timestamps (RX and TX latency
  grow by a constant per depth, as they already do with the RFDC's own
  filters; it is measured and documented, not removed).
- Run-time coefficient reload, user-selectable filter shapes.
- The `ladder` (fixed-factor) builds: they get the chain too (every design
  carries it) but are not rebuilt or published.

## Anti-goals (would be failures even if it "works")

- Any change to the existing rates' samples, timing closure or protocol.
- Channel-to-channel skew introduced by the chain (MTS alignment lost).
- A host-visible protocol break: old bitstreams must still load and serve
  their rates with the new daemon; the new bitstreams must work with an
  unchanged host except where the host hard-codes something false (bandwidth
  text).
- Clock register files or rates invented without TICS Pro: none are needed
  here (fs, PL_CLK, SYSREF and the LMK/LMX plans do not change).

## Constraints found in the code

- **RX**: `udp_streamer` advances its timekeeper by BEAT_TICKS per *valid*
  beat (`now_d <= now_d + BEAT_TICKS` on `s_axis_tvalid`) and packs only valid
  beats. A decimator that emits full beats at 1/2^k of the cycles therefore
  gives a tick rate of N x the decimated rate with no core change.
- **TX**: `udp_player` emits a beat only when `m_axis_dac_tready` (its `adv`),
  `tvalid` always 1 (zeros when idle). An interpolator that pulls one beat
  every 2^k cycles works without a core change. Its timed start compares
  `adc_time` (the streamer's, now advancing only on RX valid beats) with a
  pipeline allowance of 2-3 beats; at depth k that allowance is in cycles, so
  a timed burst may start up to ~3 low-rate beats early. Measure it in
  simulation and document it (or correct the allowance if it is simple and
  keeps depth 0 cycle-identical).
- **Beat geometry**: the fabric carries spc complex samples per channel per
  beat. ZCU216 (spc = Data_Width/2): 4 at 1/2/4ch, 2 at 8ch, 1 at 16ch.
  RFSoC 4x2 (dual tiles, spc = the ADC Data_Width S, `boards/rfsoc4x2/AGENTS.md`):
  8 at 1ch and at 2ch fs 4915.2 / 4800 (F2 templates), 4 at 2ch fs 5000 (F4
  template). At F = 40 the converter clock is fs/40/spc: 15.36 .. 62.5 MHz.
  The chain's first log2(spc) stages see > 1 sample per clock (up to three
  SSR stages, 8 -> 4 -> 2 -> 1, on the 4x2); the rest <= 1.
- **Clock**: the chain runs on `adc_clk` (the converter AXIS clock). The
  template is timed at its top clock (312.5 / 307.2 / 300 MHz on the ZCU216,
  likewise on the 4x2), so the chain must close timing there although it is
  only *used* at F = 40. FIR Compiler's architecture depends only on the
  cycles-per-sample ratio, which at F = 40 is the same at any fs.
- **FIR Compiler 7.2** (in 2021.1, 2022.1, 2024.1): super-sample-rate (input
  > clock) is supported for single-rate, interpolation and integer
  decimation, not for half-band or with channel interleaving / coefficient
  reload (PG149, "Super Sample Rate Filters"). So stages at > 1 sample/clock
  are integer-rate ÷2 / ×2 polyphase filters with a half-band coefficient
  vector; stages at <= 1 sample/clock may be half-band.
- **Rules of `fpga/AGENTS.md`**: one self-contained `.tcl` per board and
  family (the chain's BD procs are written into each of the four designs,
  no sourcing between them); every `xilinx.com:ip` VLNV through `v49_vlnv`
  (`fir_compiler:7.2` exists in every release); the PS address map is fixed
  and checked by `verify_rate_variant`; after a change under
  `ip/src/uhd_ip/src/` its sims, then `make package` with 2021.1.
- The daemon's retune check measures the converter clock with the
  timekeeper (`_measure_fabric_mhz`): at depth k the timekeeper runs at
  1/2^k of it.
- Machine: one Vivado build at a time (30 GB RAM, another session also
  builds), always under `taskset -c 0-11`. 21 templates x 3 PYNQ versions =
  63 builds.

## Approaches considered

1. **Run-time chain at F40, depth by register (chosen).** One ÷2 cascade
   (RX) and ×2 cascade (TX) per design, active only when the RFDC is at
   F = 40; the depth register picks how many stages are in the path; the
   daemon lists fs/40/2^k as run-time rates of every template. A rate change
   inside the low-rate ladder is a register write plus a chain reset.
2. Same chain at every RFDC factor (fs/F/2^k). More rates, mostly duplicates
   or odd ones (F20÷2 = F40), a messy rate list and tie-break rules, little
   gain below the floor. Rejected.
3. Fixed-ratio low-rate bitstreams. Simplest hardware, but one bitstream
   and a reload per rate, against the repo's template rule. Rejected.

## Design

### Placement

In the `eth100g` hierarchy of every design, at its edge, on the
channel-major beat (each channel its own spc slots, as the RFDC combiner
gives them):

```
RX: S_AXIS_ADC -> rx_rate (÷2^k) -> [rx_beamformer -> adc_c2s] -> udp_streamer
TX: udp_player -> [dac_s2c -> tx_beamformer] -> tx_rate (×2^k) -> M_AXIS_DAC
```

(1-channel builds have no beamformer / interleave: the chain sits directly
between the pin and the core.) The beamformers already honour gapped
`tvalid` and `tready` (one clock enable each) and so run at the low rate.

### The chains

- K stages per direction (5 ZCU216, 6 RFSoC 4x2; a board fact in
  `board.tcl`, e.g. `board_rate_stages`). Stage i (1-based, highest rate
  first on RX, last on TX) runs at spc/2^(i-1) input samples per clock on RX.
- Stages at > 1 sample/clock: FIR Compiler integer-rate ÷2 / ×2 with super
  sample rate. Stages at <= 1 sample/clock: FIR Compiler half-band ÷2 / ×2,
  oversampled (the clock / sample ratio grows 2x per stage, so they share
  DSPs).
- One FIR Compiler instance per stage carries all of a design's paths
  (2 x N: I and Q of every channel, "number of paths"), so every channel
  sees the same filter at the same cycle (no skew); if a stage cannot hold
  2N paths (FIR Compiler's path limit, SSR restrictions), identical
  instances fed and enabled identically, checked cycle-aligned in sim.
- Every stage is "final quality", because any of them can be the last one:
  passband 0 .. 0.4 x its output rate (80 % of the new rate, like the
  RFDC's own decimation filters) with <= 0.05 dB ripple, stopband from
  0.6 x the output rate with >= 80 dB attenuation (the alias that folds into
  the band). Coefficients designed offline (scipy, remez half-band,
  `N = 3 + 4n` taps), quantised to 18 bits, committed with the script that
  makes them; the same vector in every stage and both directions.
- Data: 16-bit I/Q in; FIR Compiler full-precision output; the glue rounds
  (round half away from zero, or convergent: one rule, modelled) and
  saturates to 16 bits with unity passband gain on RX; TX the same, its
  ×2 stage gain of 2 folded into the coefficients (or a shift) so a
  full-scale tone stays full scale.
- Small packaged RTL glue in `uhd_ip` (new cores, xsim'ed bit-exact against
  a Python model like the existing ones):
  - RX: per stage output, a packer from the stage's sample stream back into
    full channel-major beats (spc samples per channel), a depth mux that
    selects the input beat (depth 0) or stage k's packed beats, `tvalid` 1
    every 2^k cycles in steady state;
  - TX: an unpacker from player beats into the chain's entry stage (the
    entry is stage K-k+1 for depth k), backpressure to the player through
    `tready`, and an output mux that drives `M_AXIS_DAC` every cycle
    (depth 0 = the input beat, `tready` passed through).
- Depth 0 is a pure combinational pass of the beat and handshake (no added
  register), so today's builds' paths are cycle-identical; the mux select is
  quasi-static (changed only while streaming is stopped).

### Control

- The RX glue core carries a small AXI4-Lite register file (like the
  beamformers: `s_axi_aclk`, crossings through XPM CDC, because the PS and
  converter clocks are timed as related in these designs and an AXI GPIO's
  outputs would be unconstrained crossings): ID, DEPTH (k, 0..K), CTRL
  [0] chain reset, RO K and spc. It drives the TX glue's depth on a wire in
  `adc_clk`. AXI-Lite at a fixed **`0x8009_0000`** in every build (appended to
  `v49_eth100g_slaves`, explicitly assigned, checked by
  `verify_rate_variant`). `0x8008_0000` is left free: the unmerged
  `feat-adding-dpd` branch puts `eth100g/tx_dpd` there.
- With DPD merged later, `tx_dpd` stays the last block before the DACs (it
  must run at the converter rate): `... tx_beamformer -> tx_rate -> tx_dpd ->
  M_AXIS_DAC`.
- The `.hwh` carries the chain (its cells / the GPIO); the daemon detects it
  there. A bitstream without it is served exactly as today (no low rates).

### Daemon (`rfsoc/server`)

- `Variant` gains a depth k (0 for every existing rate) and the build's K:
  rate = fs / F / 2^k, fabric = fs / F / spc (unchanged by k), tick rate =
  N x rate. A template whose run-time factors include 40 and whose `.hwh` has
  the chain lists fs/40/2^k, k = 1..K, as extra run-time rates
  (`scan_bitstreams`, `get_rx_rates`, `info rx_rates=`, the link/format check
  as for any rate).
- Retune (`_retune_hw`): to (F, k): if F changes, today's MMCM / factor /
  MTS / NCO sequence to F (40 for any k > 0); then the chain reset asserted,
  the depth written, reset released; checks: factor readback, MMCM locked,
  depth read back, the converter clock measured by the timekeeper within 1 %
  (the timekeeper now advances BEAT_TICKS per *output* beat:
  measured x 2^k). A change of k alone at F = 40 skips the RFDC / MMCM / MTS
  steps.
- Reload / bring-up: depth 0 on every load; then the requested (F, k).
- `coerce_rate`, defaults per N, sc8/sc12/sc16 link rules: unchanged (the new
  rates are low, every format fits).

### Host (`host/lib`)

- Rates come from the daemon: no change for the rate itself.
- The bandwidth comment / value: at a chain rate the -3 dB width is set by
  the half-band, not 0.96 x rate. Keep `bandwidth = rate` (Protocol), fix the
  comment, and note the measured figure in the README.

### Docs

README rate table (new rates per board / family / N), QUICK_START if it
lists the lowest rate, `fpga/README.md` + `fpga/AGENTS.md` (the chain, its
address, the rule that it is in every design), `uhd_ip/README.md` (new
cores), `rfsoc/server/README.md` (the depth in a variant). The Protocol (the
top `AGENTS.md`, local and untracked) is not in this checkout. The closest
copy is `/home/wei/uhd-rfsoc-dpd/AGENTS.md` (the DPD work tree: the same
Protocol plus §12 DPD); read §3-§11 there as the contract. The user's own
copy is theirs to update: list the Protocol changes (§8 rates and retune,
the new core's address, §4/§6 timed-start note) in the final report.

### Verification (no boards here: the user tests on hardware)

- **Gate 0, before any design work: the FIR Compiler spike as an acceptance
  test.** Out of context, in 2021.1, 2022.1 and 2024.1 (confirm
  `fir_compiler:7.2` is current in each catalog), the worst configurations:
  ÷2 at 4->2 and 2->1 samples/clock with 2N paths, ×2 at 1->2 and 2->4,
  half-band at <= 1 sample/clock with 2N paths; ZCU216 4ch, 8ch, 16ch chains
  and RFSoC 4x2 1ch (SSR 8) and 2ch chains (RX + TX) at 312.5 MHz. Pass: every configuration generates and simulates,
  closes 312.5 MHz OOC, and a whole design's chains (RX + TX) use <= 1500
  DSP48E2 (35 % of the ZU49DR's 4272) and <= 10 % of its BRAM. Fail: shorten
  the SSR stages (they are "final" only at depths 1 and 2), then re-measure;
  if still over, bring the numbers back to the user before going on.
- **Gate 1: the existing cores with gaps.** The current `udp_streamer` /
  `udp_player` xsim regressions rerun with a 1-in-2^k `s_axis_tvalid` /
  `m_axis_dac_tready` pattern (k = 1..6) against their Python models, for
  sc16/sc8/sc12/fc32, timed start, underflow and EOB. Any failure is a core
  change, made with the cores' own rules (sims, `make package`).
- **Invariants, asserted in the chain sims:** no RX stage ever deasserts
  `s_axis_tready` while fed (the ADC ignores it: a stage that needs one cycle
  too many would lose samples silently; each stage's oversampling is set to
  the exact period); the TX chain presents a valid beat to the DAC every
  cycle in steady state.

- uhd_ip: the glue cores bit-exact vs the Python model; a chain-level sim
  (FIR Compiler behavioural model + glue + streamer/player where practical)
  at every depth: frequency response (pass / stop), unity gain, channel
  alignment, gapped-beat timestamps, TX backpressure, depth 0 identical to
  the input.
- Every design: `make templates STEP=bd` (geometry and address checks),
  then all 21 templates per PYNQ version built timing-clean; resource use
  (DSP, BRAM) recorded in the build notes and in the bitstream README.
- Daemon: unit tests for the new rate list, `at_factor`/depth, measurement
  scaling, and old `.hwh` files (no chain) giving today's rates exactly; the
  bitstream-repo manifests regenerate, the old manifests' daemon scan
  unchanged.
- A hardware test list for the user (`host/benchmark/rate_sweep.sh` over the
  new rates, `rate_bandwidth.py` at each depth, multi-channel phase at 1.92).

## Left to the builder

- Exact tap counts per stage (the shortest that meet the spec; one vector
  or one per stage), coefficient width, rounding rule, whether the SSR stages
  infer the half-band zeros.
- Whether stage instances carry all 2N paths or one per channel (alignment
  proven either way).
- Whether the timed-start allowance in `udp_player` is corrected or only
  documented (Gate 1 measures it); whether the daemon reports a per-depth
  latency (`info`) for `rate_loopback.py`, which measures the TX->RX delay
  but asserts no tolerance.
- Build order, strategies per build (`Performance_ExtraTimingOpt` where the
  current templates use it; others as timing requires).

### Timing closure (calls made here, in this order)

The chain is clocked by `adc_clk` at every factor but its output is only
selected at F = 40, where `adc_clk` <= 62.5 MHz (>= 5x the templates' top
period); the daemon never sets depth > 0 at another factor (it refuses to).
The published templates close with almost no margin (WNS 0.000-0.05 ns).
So:

1. **Multicycle constraints on the chain**, from the start (XDC in each
   design, scoped to the chain's cells and its paths into the RX / TX output
   muxes): setup multicycle 4 with the matching hold, valid because those
   paths only carry data when `adc_clk` is <= 1/4 of the timed clock.
2. **A registered depth-0 bypass** (one constant `adc_clk` cycle more on the
   existing rates: invisible to the Protocol, which promises no absolute
   latency) if the combinational mux on the 128-512-bit beat is what fails.
3. **A stronger strategy** for that build (as `builds.txt` already does).
4. **The spec relaxed on that board / N** (fewer taps, 70 dB) or K lowered,
   recorded in the README.
5. Last resort, back to the user: publish that template without the chain.

## Risks

- **DSP budget at spc = 4 (ZCU216 4ch) and spc = 8 (4x2).** An SSR ÷2 at 4 samples/clock with a ~40-50 tap
  vector costs ~2 x taps multipliers per path unless FIR Compiler exploits
  the half-band zeros and symmetry; 4 channels x I/Q x RX+TX could approach
  half of the ZU49DR's 4272 DSPs. First plan task: a FIR Compiler spike
  (1 path, spc 4 / 2 / 1) measuring DSP and timing at 312.5 MHz. If it does
  not fit, fall back to a shorter first stage (it is only "final" at depth 1:
  a looser stop band there, recorded as a limitation of 30.72 MS/s).
- **Timing** at the templates' top clock, where the 512-bit builds already
  need `Performance_ExtraTimingOpt`.
- **Build time**: 63 builds one at a time, ~20-60 min each (ZCU216 16ch
  longest): about 1.5-2 days of wall clock for the bitstream sets.
