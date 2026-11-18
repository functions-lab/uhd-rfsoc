# Rates Below the RFDC Floor (FIR Compiler chains) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every ZCU216 and RFSoC 4x2 template also serves fs/40/2^k (k = 1..K, K = 5 / 6, down to ~1.92 MS/s) through FIR Compiler ÷2 / ×2 chains selected at run time.

**Architecture:** per design, one RX chain (÷2 stages) and one TX chain (×2 stages) of FIR Compiler cells in the `eth100g` hierarchy, wired through two new packaged hub cores (`rx_rate`, `tx_rate`) that map beats to FIR lanes, tap / inject at the selected depth, round, saturate and repack. The depth is a register of `rx_rate` (AXI-Lite 0x8009_0000), used only with the RFDC at F = 40; the daemon lists the new rates as run-time rates of each template and retunes in place.

**Tech Stack:** Vivado 2021.1 / 2022.1 / 2024.1 (FIR Compiler 7.2, xsim, IP packager), Verilog-2001 + XPM, Tcl block designs, Python 3 (daemon, scipy for coefficients, unittest).

**Spec:** `docs/superpowers/specs/2026-11-17-low-rate-fir-design.md` (read it first; this plan argues from it).

## Global Constraints

- Branch `feat-add-more-rate` in uhd-rfsoc and uhd-rfsoc-bitstream; push both when done; never merge to master/main.
- Rates added: fs/40/2^k, k = 1..K; K = 5 on the ZCU216, K = 6 on the RFSoC 4x2; only at RFDC F = 40.
- Filter per stage: passband 0 .. 0.4 x output rate, ripple <= 0.05 dB; stopband from 0.6 x output rate, >= 80 dB; half-band, N = 3 + 4n taps; 18-bit coefficients.
- Depth 0 = today's data path bit for bit (content, handshake; latency +0 cycles unless timing forces the registered bypass of the spec's closure order, step 2).
- New register file: AXI-Lite `0x8009_0000`, 64 KiB, in every build; `0x8008_0000` stays free (feat-adding-dpd's `tx_dpd`).
- TX order with DPD later: `tx_beamformer -> tx_rate -> (tx_dpd) -> M_AXIS_DAC`.
- Gate 0 pass: whole design's chains (RX + TX) <= 1500 DSP48E2 and <= 10 % BRAM, 312.5 MHz OOC met, in 2021.1, 2022.1, 2024.1.
- Timing-closure order: multicycle 4 on chain paths (from the start) -> registered depth-0 bypass -> stronger strategy -> relaxed spec / lower K (README) -> back to the user.
- Vivado only through the Makefile for builds, always `taskset -c 0-11`, one build at a time; `make package` with 2021.1 only; every `xilinx.com:ip` VLNV through `v49_vlnv`.
- One self-contained `.tcl` + `.xdc` per board and family: the chain procs are written into each of the four designs (no sourcing between designs). Shared DATA (the coefficient file) may be read by all.
- uhd_ip rule: after a change under `src/`, its sims, then `make package`; commit `src/` and `fpga/ip/repo/uhd_ip` together.
- Old bitstreams (no `rx_rate` in the `.hwh`) are served exactly as today.
- Protocol source: `/home/wei/uhd-rfsoc-dpd/AGENTS.md` §3-§11 (read only).

## Review Focus

1. **Depth > 0 requested at F != 40** (a stale register after a retune, a reload with depth left set): expect the daemon to write depth 0 before any F change and refuse depth > 0 unless F = 40 — test in Task 7 (`test_depth_only_at_f40`).
2. **RX stage 1 stalling** (FIR Compiler deasserting `s_axis_data_tready` while the RFDC feeds it every cycle) silently drops samples: expect never — assertion in Task 3's chain sim (`ASSERT_RX_NO_STALL`).
3. **TX underrun of the DAC beat** at depth k (a bubble in `M_AXIS_DAC` while the player has data): expect a valid beat every cycle — assertion in Task 4's chain sim (`ASSERT_TX_CONTINUOUS`).
4. **Full-scale input / overshoot** (a full-scale tone or a step at the band edge): expect saturation to ±32767, never wrap — test vectors in Tasks 3 and 4 (`fullscale` and `step` stimuli).
5. **Changing depth mid-stream / chain reset** leaving stale samples or misaligned channels: expect the daemon to stop streaming, hold reset, write depth, release; the first beat after release has channels aligned — Task 3 sim case `depth_change`, Task 7 `test_retune_sequence_order`.

---

## File Structure

| file | responsibility |
|---|---|
| `fpga/ip/src/uhd_ip/rate/design_hb.py` | designs the half-band, checks the spec, writes `rate_hb.coe` (RX, gain 1) and `rate_hb_tx.coe` (TX, gain 2) |
| `fpga/ip/src/uhd_ip/rate/rate_hb.coe`, `rate_hb_tx.coe` | the committed coefficient vectors (one integer per line, 18-bit) |
| `fpga/ip/src/uhd_ip/rate/spike/` | Gate 0: `fir_spike.tcl` (OOC per configuration), `fir_spike.sh` (all releases), `RESULTS.md` |
| `fpga/ip/src/uhd_ip/rate/LANES.md` | FIR Compiler tdata lane layout and output scaling found in Gate 0 (the hubs' contract) |
| `fpga/ip/src/uhd_ip/src/rx_rate.v` | RX hub + AXI-Lite register file |
| `fpga/ip/src/uhd_ip/src/tx_rate.v` | TX hub |
| `fpga/ip/src/uhd_ip/sim/rate_fir_ip.tcl` | sim-side FIR Compiler instances (same stage configuration as the designs) |
| `fpga/ip/src/uhd_ip/sim/tb_rx_rate.sv`, `tb_tx_rate.sv`, `run_sim_rate.sh`, `check_rate.py` | chain sims + bit-exact Python model |
| `fpga/ip/src/uhd_ip/sim/run_sim.sh`, `run_sim_player.sh`, `tb_udp_streamer.sv`, `tb_udp_player.sv` | Gate 1: `GAP=<k>` gapped-handshake mode |
| `fpga/ip/src/uhd_ip/package_ip.tcl`, `Makefile`, `README.md`, `AGENTS.md` | package / sim targets for the two new cores |
| `fpga/boards/{zcu216,rfsoc4x2}/block_designs/*/*.tcl` + `.xdc` (4 designs) | `create_hier_cell_rate` procs, eth100g wiring, address, `verify_rate_variant`, multicycle XDC |
| `fpga/boards/{zcu216,rfsoc4x2}/board.tcl` | `board_rate_stages` (5 / 6) |
| `rfsoc/server/rate_chain.py` | driver of `rx_rate`'s registers |
| `rfsoc/server/hw_backend.py` | Variant depth, rate points, scan, retune, measurement |
| `rfsoc/server/tests/test_rate_chain.py` | daemon tests |
| `host/lib/rfsoc_device.cpp` | bandwidth comment |
| `README.md`, `fpga/README.md`, `fpga/AGENTS.md`, `rfsoc/server/README.md`, `fpga/ip/src/uhd_ip/README.md` | docs |

Stage indexing (both directions, used everywhere): **stage 1 is next to the RFDC** (highest rate). RX flows 1 -> K, depth k taps stage k's output. TX flows K -> 1, depth k enters at stage k, stage 1 feeds the DAC. Stage i's converter-side parallelism is p_i = spc / 2^(i-1) samples per clock per lane (fractional below 1: one sample every 2^(i-1)/spc cycles). Stage i is SSR when p_i > 1 on its converter side, half-band otherwise.

---

### Task 1: Coefficients and Gate 0 (FIR Compiler acceptance)

**Files:**
- Create: `fpga/ip/src/uhd_ip/rate/design_hb.py`, `rate_hb.coe`, `rate_hb_tx.coe`, `spike/fir_spike.tcl`, `spike/fir_spike.sh`, `spike/RESULTS.md`, `LANES.md`

**Interfaces:**
- Produces: `rate_hb.coe` / `rate_hb_tx.coe` (read by every design and by `sim/rate_fir_ip.tcl`); a Tcl proc `rate_stage_cfg {dir i spc nlanes}` -> dict of FIR Compiler CONFIG properties, written in `spike/fir_spike.tcl` and copied verbatim into the designs (Task 5/6) and `sim/rate_fir_ip.tcl` (Task 3); `LANES.md`: tdata layout per path / parallel sample, output width and binary point at each stage, the hub's shift to unity gain, FIR Compiler's path limit, whether 2N paths fit one instance.

- [ ] **Step 1: write `design_hb.py`** — `python3 design_hb.py [--check]`: remez half-band, smallest N = 3 + 4n meeting the Global Constraints filter spec after 18-bit quantisation; prints N, ripple, attenuation; writes both `.coe` files; `--check` exits non-zero if a committed `.coe` differs or misses the spec.
- [ ] **Step 2: run it** — `python3 design_hb.py && python3 design_hb.py --check`. Expected: `PASS` lines with ripple <= 0.05 dB and attenuation >= 80 dB, exit 0.
- [ ] **Step 3: write `fir_spike.tcl`** — args `<release-tag> <cfg>`; in-memory project, part `xczu49dr-ffvf1760-2-e`; `create_ip fir_compiler 7.2` with `rate_stage_cfg`; OOC synth + place + route at 3.2 ns; prints `SPIKE_RESULT cfg=<> dsp=<> bram=<> wns=<> ok=<0|1>`. Configurations: RX ÷2 at 8->4, 4->2, 2->1 (SSR) and half-band at 1, 1/2 .. 1/32 per clock; TX ×2 mirrors; lanes = 2N for N in {1,2,4,8,16}; plus one behavioural sim per type printing the tdata layout of a ramp.
- [ ] **Step 4: run all releases** — `taskset -c 0-11 spike/fir_spike.sh` (2021.1, 2022.1, 2024.1 from `fpga/flow/versions.txt`). Expected: every configuration `ok=1`, `fir_compiler:7.2` current in each catalog.
- [ ] **Step 5: sum per design** in `RESULTS.md`: for ZCU216 N = 1/2/4/8/16 (spc 4/4/4/2/1, K = 5) and 4x2 N = 1/2 (spc 8, and 4 for 2ch fs 5000; K = 6), RX + TX DSP and BRAM. Pass: every design <= 1500 DSP and <= 10 % BRAM (ZU49DR: 4272 DSP, 1080 BRAM36).
- [ ] **Step 6: if any design fails,** shorten the SSR stages only (they are final only at depths 1-2), record the looser spec in `RESULTS.md`, re-measure; if it still fails, STOP and report the numbers to the user.
- [ ] **Step 7: write `LANES.md`** from the sims of step 3.
- [ ] **Step 8: commit** — `git add fpga/ip/src/uhd_ip/rate && git commit -m "rate: half-band coefficients, FIR Compiler Gate 0 results"`.

### Task 2: Gate 1 — the existing cores with gapped handshakes

**Files:**
- Modify: `fpga/ip/src/uhd_ip/sim/tb_udp_streamer.sv`, `tb_udp_player.sv`, `run_sim.sh`, `run_sim_player.sh`, `fpga/ip/src/uhd_ip/Makefile` (target `sim-gap`)
- Modify only if a check fails: `src/udp_streamer.v`, `src/udp_player.v` (then `make package`)

**Interfaces:**
- Produces: `make sim-gap` (GAP = 1..6: streamer `s_axis_tvalid` 1 cycle in 2^GAP, player `m_axis_dac_tready` 1 in 2^GAP); the measured timed-start offset of the player per GAP in `fpga/ip/src/uhd_ip/rate/LANES.md` ("Timed start at depth k").

- [ ] **Step 1: add `GAP` plusarg/env** to both testbenches and scripts; GAP unset = today's stimulus exactly.
- [ ] **Step 2: run** `make sim-gap` (sc16, sc8, sc12, fc32 x widths 128/256/512; timed start, underflow, EOB cases). Expected: every existing checker `PASS` (`check_frames.py`, `check_player.py`); timestamps in ticks of valid beats.
- [ ] **Step 3: record the timed-start offset** (beats early/late vs the TSF) per GAP. If it is > 1 beat, change the player's `t_cmp` / `t_cmp4` allowance to count *advancing* beats (depth 0 cycle-identical: `make sim` and `make sim-fmt` must still PASS unchanged), else document it.
- [ ] **Step 4: run** `make all`. Expected: PASS everywhere.
- [ ] **Step 5: commit** (with `fpga/ip/repo/uhd_ip` if a core changed).

### Task 3: `rx_rate` hub + RX chain sim

**Files:**
- Create: `fpga/ip/src/uhd_ip/src/rx_rate.v`, `sim/rate_fir_ip.tcl`, `sim/tb_rx_rate.sv`, `sim/run_sim_rate.sh`, `sim/check_rate.py`
- Modify: `package_ip.tcl` (core `rx_rate`), `Makefile` (`sim-rate`, `all`)

**Interfaces:**
- Consumes: `LANES.md`, `rate_hb.coe`, `rate_stage_cfg` (Task 1).
- Produces: IP `user.org:uhd:rx_rate:1.0`, parameters `N_CH` (1..16), `SPC` (1,2,4,8), `K` (1..6), `G` (FIR instances per stage, 1 or 2, from LANES.md's path limit); interfaces `s_axis` (beat in, N_CH x SPC x 32 bits, channel-major, no tready used), `m_axis` (beat out), per stage i = 1..K and group g = 0..G-1: `m_st<i>g<g>` (to FIR in) and `s_st<i>g<g>` (from FIR out), widths per LANES.md, enabled when i <= K / g < G (`enablement_dependency`); `s_axi` (16-bit address); clocks `aclk`, `s_axi_aclk`; resets `aresetn`, `s_axi_aresetn`; output `depth_o[3:0]` and `fir_aresetn_o` (aclk) for `tx_rate` and the FIRs.
- Register map (header of `rx_rate.v`; `rate_chain.py` uses it):
  `0x00 ID RO 0x5A525431 'ZRT1'` · `0x04 CTRL RW [0] chain reset (1 = held; reset value 1)` · `0x08 DEPTH RW [3:0] 0..K` (a write > K is ignored, readback unchanged) · `0x0C INFO RO [3:0] K, [11:8] log2(SPC), [20:16] N_CH`. CTRL and DEPTH cross to aclk through XPM CDC; DEPTH is quasi-static.
- Behaviour: depth 0: `m_axis` = `s_axis` combinationally (tdata, tvalid). Depth k: lanes from `s_axis` to `m_st1g*` every cycle; `s_st<i>` -> `m_st<i+1>` pass-through; `s_st<k>` rounded/shifted per LANES.md, saturated to int16, packed SPC samples per channel into one beat, `m_axis_tvalid` once per 2^k cycles in steady state; channels in one beat always the same sample index.

- [ ] **Step 1: write `check_rate.py`** — model: `rx(x[N][n], k) -> y[N][m]` from the `.coe` and LANES.md arithmetic (integer, bit-exact); compares a tb dump; also checks the filter numbers on a tone sweep (passband ripple, alias attenuation) and channel alignment.
- [ ] **Step 2: write `tb_rx_rate.sv` + `run_sim_rate.sh`** — FIR IPs from `rate_fir_ip.tcl` (same `rate_stage_cfg`), every (N_CH, SPC, K) of the designs: (1,4,5) (2,4,5) (4,4,5) (8,2,5) (16,1,5) (1,8,6) (2,8,6) (2,4,6); depths 0..K; stimuli `ramp`, `tones`, `fullscale`, `step`, `depth_change`; assertion `ASSERT_RX_NO_STALL` (every FIR stage 1 `s_axis_data_tready` high whenever fed, after reset release); depth 0 compares output == input cycle for cycle.
- [ ] **Step 3: run** `make sim-rate DIR=rx`. Expected: FAIL (no `rx_rate.v`).
- [ ] **Step 4: implement `rx_rate.v`** per Interfaces.
- [ ] **Step 5: run** `make sim-rate DIR=rx`. Expected: `PASS` bit-exact at every geometry and depth, no assertion.
- [ ] **Step 6: package** `make package`, check `fpga/ip/repo/uhd_ip/rx_rate_1.0` appears and the other cores are unchanged (`git status`).
- [ ] **Step 7: commit** `src/rx_rate.v`, sims, `package_ip.tcl`, `Makefile`, `fpga/ip/repo/uhd_ip`.

### Task 4: `tx_rate` hub + TX chain sim

**Files:**
- Create: `fpga/ip/src/uhd_ip/src/tx_rate.v`, `sim/tb_tx_rate.sv`
- Modify: `sim/run_sim_rate.sh`, `sim/check_rate.py`, `sim/rate_fir_ip.tcl`, `package_ip.tcl`, `Makefile`

**Interfaces:**
- Consumes: Task 3's lane mapping and `depth_o` / `fir_aresetn_o`; `rate_hb_tx.coe`.
- Produces: IP `user.org:uhd:tx_rate:1.0`, parameters `N_CH SPC K G` as Task 3; `s_axis` (player beat, tready honoured), `m_axis` (to DAC; tready passed through at depth 0), `m_st<i>g<g>` / `s_st<i>g<g>` per stage (TX: data enters stage k, flows to stage 1), input `depth_i[3:0]` (aclk, from `rx_rate`), no AXI-Lite.
- Behaviour: depth 0: `m_axis` = `s_axis`, `s_axis_tready` = `m_axis_tready` (combinational). Depth k: one `s_axis` beat accepted per 2^k cycles in steady state (driven by stage k's input tready), unpacked to stage k's lanes; stage 1 output rounded/saturated to int16, packed to the DAC beat, `m_axis_tvalid` every cycle; full-scale in -> full-scale out (TX gain 2 per stage in the coefficients).

- [ ] **Step 1: extend `check_rate.py`** with `tx(x, k)` (bit-exact) and TX filter checks (image rejection >= 80 dB, passband ripple).
- [ ] **Step 2: write `tb_tx_rate.sv`** — source = a model of `udp_player` (tvalid always 1, advances on tready), same geometries / depths / stimuli as Task 3; assertion `ASSERT_TX_CONTINUOUS` (`m_axis_tvalid` every cycle after the chain fills); depth 0 cycle-identical.
- [ ] **Step 3: run** `make sim-rate DIR=tx`. Expected: FAIL (no `tx_rate.v`).
- [ ] **Step 4: implement `tx_rate.v`.**
- [ ] **Step 5: run** `make sim-rate` (both directions) and `make all`. Expected: PASS.
- [ ] **Step 6: package and commit** as Task 3.

### Task 5: ZCU216 designs (both families)

**Files:**
- Modify: `fpga/boards/zcu216/block_designs/zcu216_uhd_v49/zcu216_uhd_v49.tcl` + `.xdc`, `zcu216_uhd_v49_245m76/zcu216_uhd_v49_245m76.tcl` + `.xdc`, `fpga/boards/zcu216/board.tcl`, `fpga/boards/zcu216/AGENTS.md`

**Interfaces:**
- Consumes: `rx_rate` / `tx_rate` IPs, `rate_stage_cfg`, `.coe` files.
- Produces: in each design, `proc create_hier_cell_rate {parentCell nch spc K}` (instantiates `eth100g/rx_rate`, `eth100g/tx_rate`, `eth100g/rate/rx_fir_<i>_<g>` and `tx_fir_<i>_<g>` FIR Compiler cells via `[v49_vlnv xilinx.com:ip:fir_compiler:7.2]`), called from `create_hier_cell_eth100g`; hierarchy pin `S_AXI_RATE`; `v49_eth100g_slaves` appends `S_AXI_RATE` for every N; address `0x8009_0000` / 64K assigned explicitly; `board_rate_stages 5` in `board.tcl` (passed as `V49_RATE_K` like the other `V49_*` values, default 5 in the design when sourced alone); geometry dict gains `rate_k` and `spc`.
- Wiring: RX `S_AXIS_ADC -> rx_rate -> (rx_beamformer -> adc_c2s ->) udp_streamer`; TX `udp_player -> (dac_s2c -> tx_beamformer ->) tx_rate -> M_AXIS_DAC`.
- `verify_rate_variant` additions: `rx_rate`/`tx_rate` present with `N_CH = nch`, `SPC = spc`, `K = rate_k`; FIR cell count `2 x K x G`; `S_AXI_RATE` at `0x8009_0000`; the existing streamer/player width checks unchanged.
- XDC: `set_multicycle_path -setup 4` / `-hold 3` from and to the cells under `eth100g/rate/*` and the `rx_rate` / `tx_rate` lane registers (tap muxes), scoped by cell names; nothing on the depth-0 bypass path.

- [ ] **Step 1: edit both designs and `board.tcl`.**
- [ ] **Step 2: run** `taskset -c 0-11 make -C fpga BOARD=zcu216 templates STEP=bd` (then `FS=2457.6`, `FS=2400`). Expected: every N's BD validates, `verify_rate_variant` passes.
- [ ] **Step 3: one full build** — `taskset -c 0-11 make -C fpga BOARD=zcu216 bitstream N=4 FS=2457.6` (the strategy from `builds.txt`). Expected: timing met (WNS >= 0, WHS >= 0), utilization DSP within Gate 0's figure. If it misses, apply the closure order (Global Constraints) and record what was needed in `builds.txt` comments.
- [ ] **Step 4: same for `N=16 FS=2500`** (most FIR cells, G = 2). Expected: timing met.
- [ ] **Step 5: commit** the designs, `board.tcl`, `AGENTS.md`.

### Task 6: RFSoC 4x2 designs (both families)

**Files:**
- Modify: `fpga/boards/rfsoc4x2/block_designs/rfsoc4x2_uhd_v49/*.tcl` + `.xdc`, `rfsoc4x2_uhd_v49_245m76/*.tcl` + `.xdc`, `fpga/boards/rfsoc4x2/board.tcl` (`board_rate_stages 6`), `fpga/boards/rfsoc4x2/AGENTS.md`

**Interfaces:**
- Consumes / Produces: as Task 5 with `K = 6`, spc from the 4x2 geometry (S: 8, or 4 for 2ch fs 5000), the chain on the channel-major beat after the dual-tile I/Q joiners.

- [ ] **Step 1: edit both designs and `board.tcl`.**
- [ ] **Step 2: run** `taskset -c 0-11 make -C fpga BOARD=rfsoc4x2 templates STEP=bd` for FS 5000, 4915.2, 4800. Expected: PASS.
- [ ] **Step 3: full build** `N=1 FS=4915.2` (SSR 8, the worst case). Expected: timing met; else the closure order.
- [ ] **Step 4: commit.**

### Task 7: Daemon

**Files:**
- Create: `rfsoc/server/rate_chain.py`, `rfsoc/server/tests/test_rate_chain.py`
- Modify: `rfsoc/server/hw_backend.py`, `rfsoc/server/eth100g.py` (address table comment), `rfsoc/server/README.md`

**Interfaces:**
- Produces:
  - `rate_chain.RateChain.from_ip_dict(ip_dict) -> Optional[RateChain]` (None without an `rx_rate` entry; never a fallback address); `.k_max: int`, `.spc: int`, `.nch: int`, `.depth() -> int`, `.set_depth(k: int) -> None` (raises `ValueError` outside 0..k_max), `.hold(reset: bool) -> None`; constants `RATE_NAME = "rx_rate"`, `RATE_ID_VALUE = 0x5A525431`.
  - `hw_backend.HWH_CORES` += `"rx_rate"`; `Variant.rate_k: int` (0 without the chain), `Variant.depth: int` (0 for every existing rate); `Variant.run_points() -> List[Tuple[int, int]]` = `[(f, 0) for f in run_factors()] + [(40, k) for k in 1..rate_k]` when 40 is in `run_factors()`; `Variant.at_point(f: int, k: int) -> Variant` (rate = adc_rate / f / 2^k, fabric_mhz = adc_rate / f / spc, slot_rate / tick_rate from rate); `at_factor(f)` = `at_point(f, 0)`; `scan_bitstreams` lists every point.
  - `_retune_hw(v)`: depth 0 written (chain held) before any F change; F path as today when F changes; then hold, `set_depth(v.depth)`, release; checks add depth readback; `_measure_fabric_mhz` returns the converter clock: `(ticks/s) * 2^depth / beat_ticks`. A change of depth only (F = 40 both) skips MMCM / factor / MTS / NCO steps. Reload: depth 0 then the requested point.
- Tests (`test_rate_chain.py`, synthetic `.hwh`/ip_dict dicts like the existing tests):
  - `test_old_hwh_rates_unchanged` — a template without `rx_rate`: `run_points()` == today's factors with k = 0, rates identical.
  - `test_points_zcu216_2457p6` — 4ch template, K = 5: extra rates exactly `[30.72e6, 15.36e6, 7.68e6, 3.84e6, 1.92e6]`, tick_rate = 4 x rate, fabric 15.36 MHz for all.
  - `test_points_rfsoc4x2_4915p2` — 1ch, K = 6: lowest 1.92e6.
  - `test_depth_only_at_f40` — `at_point(24, 1)` raises `ValueError`.
  - `test_measure_scaling` — fake timekeeper advancing beat_ticks every 2^k cycles -> measured MHz == fabric_mhz within 1e-9.
  - `test_retune_sequence_order` — a fake backend records calls: F change -> `hold(True), set_depth(0)` first; depth-only change -> no MMCM/factor/MTS calls; ends `hold(False)`.
  - `test_coerce_new_rates` — `coerce_rate` on a 1ch fs 2457.6 list: 2e6 -> 1.92e6, 1e6 -> 1.92e6 (lowest), 31e6 -> 30.72e6.
  - `test_ratechain_bounds` — `set_depth(k_max + 1)` raises; `from_ip_dict({})` is None.

- [ ] **Step 1: write `test_rate_chain.py`** with the tests above.
- [ ] **Step 2: run** `cd rfsoc/server && python3 -m unittest discover -s tests`. Expected: the new tests FAIL (import / attribute errors), the old ones PASS.
- [ ] **Step 3: implement `rate_chain.py` and the `hw_backend.py` changes.**
- [ ] **Step 4: run the suite.** Expected: all PASS.
- [ ] **Step 5: run the scan on the existing published sets** — `python3 fpga/build/_port/scan_check.py` (or `hw_backend.scan_bitstreams` over `bitstreams/pynq3.1/zcu216`): the rate lists equal those before the change (no chain in old `.hwh`).
- [ ] **Step 6: commit.**

### Task 8: Host comment and docs

**Files:**
- Modify: `host/lib/rfsoc_device.cpp` (bandwidth comment: below fs/40 the half-band sets the width, value stays = rate), `README.md` (rate table: the new rates per board / fs / N, all in every format; a note on the filter), `fpga/README.md`, `fpga/AGENTS.md` (map rows for `rate/`, `rx_rate`, `tx_rate`; rule: the chain is in every design; address 0x8009_0000), `fpga/ip/src/uhd_ip/README.md` (+ cores, `make sim-rate`, `sim-gap`), `fpga/ip/src/uhd_ip/AGENTS.md`, `rfsoc/server/README.md`
- Create: `docs/superpowers/specs/2026-11-17-low-rate-fir-protocol-changes.md` (the list for the user's Protocol copy: §8 points and retune, the new core's address, §4/§6 timed start at depth k, §9 rate tables)

- [ ] **Step 1: edit.** Rate rows generated from `Variant.run_points` so the table matches the daemon (extend `fpga/build/_port/readme_rows.py` if it exists, else compute in a one-off).
- [ ] **Step 2: build the host lib** (`cmake --build` of `host/` as its README says). Expected: compiles.
- [ ] **Step 3: commit.**

### Task 9: Bitstream sets and push

**Files:**
- uhd-rfsoc-bitstream: `pynq{2.7,3.0,3.1}/{zcu216,rfsoc4x2}/*` (21 templates each: `.bit`, `.hwh`, timing and utilization reports), `manifest.json`, `SHA256SUMS`, `README.md`
- uhd-rfsoc: `fpga/boards/*/builds.txt` (strategies if changed)

- [ ] **Step 1: build** for each PYNQ in 2.7, 3.0, 3.1 and board in zcu216, rfsoc4x2: `taskset -c 0-11 make -C fpga BOARD=<b> PYNQ=<v> templates` (one at a time; `SKIP_EXISTING=1` to resume). Expected: every build in `bitstreams/`, none in `bitstreams_timing_fail/`.
- [ ] **Step 2: check** each build's WNS/WHS >= 0 and the daemon scan of each output directory lists today's rates plus the K new ones per template.
- [ ] **Step 3: copy into uhd-rfsoc-bitstream**, regenerate `manifest.json` / `SHA256SUMS` (`fpga/build/_port/gen_manifest.py`), README rows (new rates, DSP use, Vivado per set).
- [ ] **Step 4: commit both repos; push** `git push -u origin feat-add-more-rate` in each. Expected: both branches on `origin` (functions-lab).
- [ ] **Step 5: final report** to the user: what changed, the measured filter numbers, DSP use, timing per build, the Protocol change list, the hardware test list (`host/benchmark/rate_sweep.sh` over the new rates, `rate_bandwidth.py` per depth, `rate_loopback.py` delay per depth, multi-channel phase at 1.92 MS/s).
