# AGENTS.md — rfsoc_lib/uhd/benchmark

Real-hardware measurements. Read `../AGENTS.md` first (board/PC access and the
sharing rules: board lock, PC flock, governor).

## The oracle
- `oracle.sh` (robustness incl. the over-the-air format check, UHD
  compliance, 4T4R beamforming with phase calibration) is what decides
  whether a change works. Report its numbers as measured: no rounding up, no
  dropping a bad run, no re-running until it passes without saying so.
- A criterion is set before the measurement and changed only with a reason
  written next to it, never to make a result pass.

## How to run
- PC side: `sudo env PATH=$PATH zcu216-uhd python3 benchmark/<script>.py --args
  type=zcu216,addr=<board-ip>,channels=N ...` with a daemon running on the
  board. `bench_strict.sh` and `dpdk_rx_test.sh` call the wrapper themselves
  (installed `zcu216-uhd`, else `../host/tools/zcu216-uhd`).
- Board side: `loopback_test.py` (after `../server/bringup.py --loopback`).
- Set the PC governor to `performance` for throughput runs and restore
  `powersave` afterwards; record it with the result.

## Reading results correctly
- `benchmark_rate` exits 0 even with errors unless every threshold is 0:
  `bench_strict.sh` passes `--overrun/--underrun/--drop/--seq-threshold 0`.
- Attribute losses: `ethtool -S <iface> | grep -E "rx_discards_phy|rx_out_of_buffer"`
  (NIC/PCIe) vs. the module's "DPDK RX closed" line (ring-full polls,
  overflows, imissed = host) vs. the FPGA (daemon `stats`: udp_streamer
  `overflows`, udp_player `tx_underflows` -- an underflow there is the host
  not sending in time). PCIe Gen3 x8 caps at ~7 GB/s: check `LnkSta`.
- Cold start vs sustained rate: a one-off RX overflow in the first second of
  device time (the "RX: gap: expected TSF" warning / tick rate) followed by a
  clean stream is a cold-start loss and does not count; a later loss, or a
  start-up loss the host never recovers from, does. `classify_runs.py` does
  this over a log tree. Report the counts by class, not only PASS/FAIL.
- At 96 Gb/s each way (97 % of the link) full duplex is at the PC's limit in
  any wire format (rare mid-run collapses, all host-side); single-direction
  runs at that rate are clean. Size run counts accordingly: 3 runs per case
  hide a 5-10 % failure rate.
- Over-the-air tests: keep tones <= -18 dBFS (the TX analog chain compresses
  near -6 dBFS: AM/AM + AM/PM fake beamformer errors). Bracket each case with
  fresh channel measurements (the air drifts); phase offsets are stable within
  a bring-up but change by up to ~18 deg across FPGA reloads (re-calibrate).
- Only antennas on tile 0 (channels 0-3) form the over-the-air 4T4R link on
  zcu216-0; other channels are not heard.

## Results
- `results/README.md` is the one results file: what was measured, how, and the
  per-build table (the sc8max section holds the duplex classification).
  `classify_runs.py` over the whole log tree also counts the surviving
  last-run log of each oracle session from before per-run logs (one per
  session), so its totals can exceed the README's by a run or two. Replace it (do not add dated files next to it) when a new
  full run supersedes it; keep raw logs out of the repo.
- Full-rate runs need the layout, CPU isolation and governor recorded there; a
  PC under interactive or build load breaks the cases near the link limit.
