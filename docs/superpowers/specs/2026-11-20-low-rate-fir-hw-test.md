# Low-rate chains: on-board test (2026-11-20)

uhd-rfsoc `feat-add-more-rate` 03f2924 (daemon and host module built from it), uhd-rfsoc-bitstream
`feat-add-more-rate` 92108ad, PYNQ 2.7 sets, on zcu216-0 and rfsoc4x2-1 over 100 GbE. Every test: RX + TX.

## benchmark_rate, 10 s per run

| board | channels | rates (MS/s) | result |
|---|---|---|---|
| ZCU216 | 1, 2, 4, 8, 16 | 30.72, 15.36, 7.68, 3.84, 1.92 (fs 2457.6) | 25/25 runs clean except 16ch at 30.72 |
| ZCU216 | 1, 16 | 31.25, 1.953 (fs 2500); 30, 1.875 (fs 2400) | clean except 16ch at 31.25 |
| RFSoC 4x2 | 1, 2 | 61.44, 30.72, 15.36, 7.68, 3.84, 1.92 (fs 4915.2) | 12/12 clean |
| RFSoC 4x2 | 1, 2 | 62.5, 1.953 (fs 5000); 60, 1.875 (fs 4800) | clean except 2ch at 62.5 |

Received sample counts were rate x 10 s x N in every run. The three exceptions were 1 or 2 TX
underrun events per run (counted once per channel: 2 / 16 / 32), and once 645 888 RX drops, at
the highest aggregate rates (~0.5 GS/s each way on the ZCU216, ~1.25 GS/s on the 4x2). The
existing rates without the chain show the same at the same aggregate (ZCU216 8ch at 61.44: 8
underruns; 16ch at 61.44: 18.5 M drops): a host-throughput limit, not the chain.

## rate_sweep.sh (in-place retune, TX -> RX pulse), 1ch

| board | rates (MS/s) | pulse (dB) | TX -> RX delay (samples) |
|---|---|---|---|
| ZCU216 | 61.44, 30.72, 15.36, 7.68, 3.84, 1.92 | 83-96 | 105, 202, 191, 163-167, 134-138, 116 |
| RFSoC 4x2 | 122.88, 61.44, 30.72, 15.36, 7.68, 3.84, 1.92 | 88-101 | 154, 340, 319, 249, 202, 156-164, 131 |

All PASS. A 2e6 request on the ZCU216 is met from below with 1.953125 MS/s, as specified.

## rate_bandwidth.py, 1ch

| board | rate (MS/s) | RX / TX -3 dB bandwidth (MHz) | RX stopband |
|---|---|---|---|
| ZCU216 | 30.72 | 29.54 / 29.63 | -86.0 dB |
| ZCU216 | 7.68 | 7.38 / 7.41 | -91.3 dB |
| ZCU216 | 1.92 | 1.84 / 1.85 | -92.7 dB |
| RFSoC 4x2 | 61.44 | 59.07 / 59.26 | -82.6 dB |
| RFSoC 4x2 | 7.68 | 7.38 / 7.41 | -85.6 dB |
| RFSoC 4x2 | 1.92 | 1.85 / 1.85 | -91.9 dB |

All PASS: -3 dB at 0.96 x the rate (UHD reports bandwidth = rate).

## Multi-channel phase (straight TXk -> RXk cabling, tone 0.15 x rate)

| board, rate | ch k vs ch0 (deg) | spread |
|---|---|---|
| ZCU216 4ch, 1.92 MS/s | +8.6, +3.3, -6.4 | <= 0.37 deg over 8 retunes |
| ZCU216 4ch, 61.44 MS/s (existing) | +11.0, +3.3, -6.8 | <= 0.18 deg over 8 retunes |
| RFSoC 4x2 2ch, 1.92 MS/s | -26.6 | 0.00 deg over 8 repeats |
| RFSoC 4x2 2ch, 122.88 MS/s (existing) | +155.0 | 0.01 deg over 8 repeats |

ZCU216 channels 0-3 share a converter tile: their phase holds across retunes at the new rates as
at the existing ones. The 4x2's two channels are on different tiles (ch0 tile 2, ch1 tile 0):
their relative phase changes on every retune at every rate, existing ones included (134 deg at
1.92, 167 deg at 122.88), and is stable within one tuning.
