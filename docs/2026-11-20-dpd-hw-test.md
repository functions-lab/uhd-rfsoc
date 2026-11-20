# TX DPD: merge with master and on-board check (2026-11-20)

`feat-adding-dpd` merged with `origin/master` (265b1eb; conflicts only in four READMEs).

Off-board, on this branch:
- `make -C fpga/ip/src/uhd_ip all` (every regression, `sim-dpd` included): PASS;
- every block design of the 21 templates (`templates STEP=bd`, both boards, every fs): OK;
- daemon unit tests (34, `test_dpd` included): OK; host module builds, `rfsoc_kernel_check` 0 mismatches;
- PYNQ 2.7 template builds: in progress, the first ones timing-clean (RFSoC 4x2 1ch / 2ch fs 4915.2:
  WNS +0.038 / +0.037 ns; ZCU216 1ch fs 2500 +0.014, 2ch fs 2457.6 +0.000).

On rfsoc4x2-1 (PYNQ 2.7, those two RFSoC 4x2 builds, daemon and host module of this branch),
TXk -> RXk cabled, carrier 1 GHz, `host/tools/rfsoc_dpd.py`:

| test | result |
|---|---|
| `--check` 1ch, 122.88 MS/s | PASS: identity -52.5 dB vs bypass (floor -52.1), strong set vs loop x model -53.0 dB (gain 1.000, -0.0 deg), statistics = model |
| `--check` 1ch, 245.76 MS/s | PASS: identity -51.6 dB (floor -43.9), model match -50.6 dB (gain 1.000, -0.1 deg), statistics = model |
| `--check` 2ch build, ch0 and ch1, 122.88 MS/s | PASS: model match -59.4 / -58.5 dB at the loop floor |
| `--fit 4 --keep` 1ch, 122.88 MS/s | runs end to end: NMSE -39.7 -> -50.6 dB (the cable's linear response), ACPR -58 dBc unchanged (a cable has no nonlinearity), identity kept as the best-ACPR set |
| rate change / reload | the daemon puts every channel back in bypass + identity (log) |
| `benchmark_rate` 1ch / 2ch at 122.88 MS/s | clean (2ch: 2 TX underruns, one event x 2 channels) |

At 1228.8 / 2457.6 MS/s full duplex the host drops samples heavily on this build, and equally on
the original bitstreams with the installed module (control): a host-throughput limit of this
setup, not the DPD.
