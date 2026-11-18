# Protocol changes for the low-rate chains

For the Protocol in the (untracked) top-level `AGENTS.md`. Section numbers are
those of the copy in `/home/wei/uhd-rfsoc-dpd/AGENTS.md`. Nothing on the wire
changes: no packet format, command, reply or register of an existing core.

## "Variable sample rate (bandwidth)"

- The per-channel rate is fs / F at depth 0, and fs / 40 / 2^k at depth k of
  the low-rate chains (k = 1..K; K = 5 on the ZCU216, 6 on the RFSoC 4x2).
- The bandwidth is still reported as the rate. Below fs/40 the half-band
  stages set the response: flat to 0.4 x the rate (0.001 dB), -6 dB at
  0.5 x, aliases (RX) and images (TX) at least 88 dB down from 0.6 x.
- Add a row to the chain table: `rate_chain.py` drives `eth100g/rx_rate`'s
  DEPTH (`hw_backend.py` `Variant.run_points` / `at_point`, `_retune_hw`).

## §1 Addresses / §11

- New: `0x8009_0000 eth100g/rx_rate`, in every build that has the chains.
  The register map is in `fpga/ip/src/uhd_ip/src/rx_rate.v` and
  `rfsoc/server/rate_chain.py`. `0x8008_0000` stays `eth100g/tx_dpd` (§12).
- The datapath order: `rfdc -> rx_rate -> rx_beamformer -> adc_c2s ->
  udp_streamer` and `udp_player -> dac_s2c -> tx_beamformer -> tx_rate ->
  (tx_dpd ->) rfdc`. The beamformers therefore run at the decimated rate.

## §4 Data plane (FPGA -> host)

- The TSF counts ticks of the rate in force. At depth k the timekeeper
  advances one beat per output beat, so a tick is still one slot of the
  per-channel rate: tick_rate = N x fs / 40 / 2^k.
- The RX latency grows by a constant per depth (the half-band group delay).
  TX->RX latency is constant for a given rate, as it already is for each
  RFDC factor.

## §6 Data plane (host -> FPGA): timed TX

- A timed burst starts on the fabric beat containing its TSF at every depth.
  Change to `udp_player`: the start and event TSFs (BURST_ACK, UNDERFLOW,
  TIME_ERROR) use adc_time of the current cycle + 1 beat. That is identical
  to the old "+2 beats of pipeline" whenever time advances every cycle, and
  correct behind the chains.
- Flow control, the 2 MiB buffer and the untimed-start gate are unchanged.
  At 1.92 MS/s the buffer holds seconds of samples.

## §8 Sample-rate variants

- A build whose `.hwh` has `rx_rate` + `tx_rate` (`N_CH SPC K G`, both alike,
  N_CH = the build's N, SPC its samples per channel per beat) also serves
  fs / 40 / 2^k, k = 1..K, provided F = 40 is one of its run-time factors
  (every template; a fixed F40 build too). They are listed in
  `get_rx_rates` / `info rx_rates=` like any rate, are met from below, and
  fit every wire format.
- A rate change to one of them is an in-place retune:
  1. streaming stops;
  2. the chains are held at depth 0;
  3. if F changes, the §8 MMCM / factor / MTS / NCO sequence runs to F = 40;
  4. DEPTH = k is written and the chains are released;
  5. the retune checks the factor readback, MMCM lock, the depth readback,
     no lost samples (rx_rate STATUS), and the converter clock measured by
     the timekeeper within 1 %. The measurement is scaled by 2^k.
- A change of depth alone (F = 40 on both sides) touches neither the
  converters nor the clocks.
- Every load (bring-up, reload) comes up at depth 0 with the chains held.
  A build without the chains serves exactly the rates it did before.

## §9 Rate tables

Add the new rates per board, fs and N (README "Rates per board and channel
count"):
- ZCU216:
  - fs 2500: 31.25, 15.63, 7.81, 3.91, 1.95 MS/s
  - fs 2457.6: 30.72, 15.36, 7.68, 3.84, 1.92 MS/s
  - fs 2400: 30, 15, 7.5, 3.75, 1.88 MS/s
- RFSoC 4x2: the same values of its fs / 40 (125 / 122.88 / 120 MS/s), plus
  one more halving each.

## §12 DPD (when merged)

`tx_dpd` stays the last block before the DACs, after `tx_rate`: it runs at
the converter rate.
