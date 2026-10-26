# AGENTS.md — host/benchmark

Real-hardware tests. Read `../AGENTS.md` first (the module, its device
arguments and the full-rate CPU layout); `README.md` here says which script
checks what.

## The oracle
- `oracle.sh` (robustness incl. the over-the-air format check, UHD
  compliance, 4T4R beamforming with phase calibration) is what decides
  whether a change works. Report its numbers as measured: no rounding up, no
  dropping a bad run, no re-running until it passes without saying so.
- A criterion is set before the measurement and changed only with a reason
  written next to it, never to make a result pass.
- `oracle_builds.txt` / `oracle_builds_rfsoc4x2.txt` list every (build,
  rate) with the wire formats the daemon accepts for it; a change to the
  builds (`fpga/boards/`) or to the link rule (Protocol §10) is a change here.

## How to run
- PC side: `sudo env PATH=$PATH uhd-rfsoc python3 benchmark/<script>.py --args
  type=rfsoc,addr=<board-ip>,channels=N ...` (from `host/`) with a daemon
  running on the board (`./run_daemon.sh` in the board's checkout).
  `bench_strict.sh`, `dpdk_rx_test.sh` and `rate_sweep.sh` call the wrapper
  themselves (installed `uhd-rfsoc`, else `../tools/uhd-rfsoc`).
- `oracle.sh` needs `BOARD=<user>@<board>` (passwordless ssh, and passwordless
  sudo on the board for `run_daemon.sh`) and takes the board over: it
  restarts the daemon per build and stops it at the end. Never run it on a
  board someone else is using.
- Board side: `loopback_test.py` (after `rfsoc/server/bringup.py --loopback`
  in the board's checkout).
- Full-rate runs: the layout, `tools/isolate_cpus.sh apply <housekeeping
  CPUs>` and governor `performance` (restore `powersave` afterwards); record
  all three with the result. No CPU number in a script is a default for every
  machine: `oracle.sh` takes `LAYOUT`, `APP_CPUS`, `HK_CPUS`.
- Rates in examples and defaults are rates the builds offer (1250, 625,
  312.5 MS/s ...); a request between two rates is served from below
  (Protocol §8), so an off-list rate silently tests a lower one.

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
- At 96 Gb/s each way (97 % of the link) full duplex can be at the host's
  limit in any wire format (rare mid-run collapses, all host-side);
  single-direction runs at that rate are clean. Size run counts accordingly:
  3 runs per case hide a 5-10 % failure rate.
- Over-the-air tests: keep tones <= -18 dBFS (the TX analog chain compresses
  near -6 dBFS: AM/AM + AM/PM look like beamformer errors). Bracket each case
  with fresh channel measurements (the air drifts); phase offsets are stable
  within a bring-up but change by up to ~18 deg across FPGA reloads
  (re-calibrate).
- The beamforming suite assumes channels 0-3 (tile 0) are cabled as an
  over-the-air 4T4R link; other channels are not part of it.

## Results
- Keep results and raw logs out of the repository (`oracle.sh` writes them
  under `OUT`, default `/tmp/uhd_rfsoc_oracle/<date-time>`).
- Record with a result the layout, CPU isolation and governor it ran with; a
  PC under interactive or build load breaks the cases near the link limit.
