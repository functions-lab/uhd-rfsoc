# AGENTS.md — rfsoc/server (the board daemon)

Read the top `AGENTS.md` first: its Protocol is the contract this daemon
serves, and a behaviour change here is a change there. `README.md` is the
short version for people; this file is the reference for the code.

## Rules
- Runs ON THE BOARD (PYNQ venv, root). Every FPGA address of the data plane
  lives in `eth100g.py`, `tx_beamformer.py`, `rx_beamformer.py` (sources
  of truth: the RTL headers in `fpga/ip/src/uhd_ip/src`). Blocks are
  found by name in the overlay's `ip_dict`; the beamformers are never
  mapped from a fallback address (an AXI access to an unmapped address can
  hang the PS).
- Reuse `../rfsoc_lib` (its rules: `../rfsoc_lib/AGENTS.md`): the RFDC
  comes up only through `RfdcTask` at the factor compiled into the build,
  then MTS (`_mts_lock`, which must end locked), then the NCOs. The one
  place that changes the factor afterwards is `HwBackend._retune_hw`.
- No address in code: the FPGA data IP / MAC come from `uhd_rfsoc.conf`
  (`board_config.py`), the management address from each incoming request.
- `hw_backend.py` names no board: everything board-specific (bitstream
  prefix, channel map, dual-ADC slice numbering, unpowered tiles, MTS tiles,
  GT refclk source, default build, clock limits) is a `Board` in
  `boards.py`, plain data, passed on to `rfsoc_lib` as arguments. A new
  board is a new entry there (with its case in `tests/test_boards.py`).
- Tests: `python3 -m unittest discover -s tests` must pass without a board
  (`test_protocol.py` drives `protocol.py` against a `Backend` with the
  hardware stubbed; add a case for every new command or rule);
  `tests/client_check.py` against a running daemon; `host/benchmark/` from
  the host. Never leave the daemon running or load a bitstream on a board
  unasked.

## Files
| file | what |
|---|---|
| `uhd_rfsoc_daemon.py` | entry point: argument parsing, board detection, backend bring-up, the TCP control server (49710) and UDP discovery server (49700); a missing board setup step (`SetupError`) is one log line, any other bring-up failure a traceback |
| `protocol.py` | `ControlCore`: the §3 command parser / dispatcher, claim ownership, the §10 `otw=` options and the rate / format vetting before any reload, the §11 commands; transport-free |
| `backend.py` | the `Backend` interface and everything that needs no hardware: rate selection (`coerce_rate`, `default_rate`), link checks (`link_problem`), the §3b tune plan, the §11 beamformer state, sensor helpers, `find_lib_root` |
| `hw_backend.py` | `HwBackend`: the `.hwh` scan (`scan_bitstreams`, `Variant`, `Geometry`), the full bring-up, run-time retune (`_retune_hw`) and reload (`_switch_to`), NCO / DSA / VOP, streaming, sensors |
| `boards.py` | `Board` (ZCU216, RFSoC 4x2: data only) and `detect_board` |
| `board_config.py` | `uhd_rfsoc.conf`: search path, parsing, the eth0-derived default MAC |
| `eth100g.py` | `Eth100G`: udp_streamer, udp_player, CMAC ctl / status GPIO, clock meters |
| `tx_beamformer.py`, `rx_beamformer.py` | the §11 register files (`eth100g/tx_beamformer` 0x8006_0000, `eth100g/rx_beamformer` 0x8007_0000); `rx_beamformer.beam_payload` is the bit-exact reference of the RX beam |
| `bringup.py` | the 100G link steps (`link_bringup`, shared with `HwBackend`) and a CLI to run them by hand or dump the status |
| `rx_cmdq.py` | the §4a RX stream-command queue over the streamer's one command slot |
| `cmd_timer.py` | the §3c timed commands, run by the FPGA timekeeper |
| `vrt.py` | the §4-7 packet formats, the §5 pattern, the §10 reference conversions; also imported by `host/tools/check_pattern_file.py` |
| `uhd_rfsoc.conf.example` | template of the board's settings file (the real one is gitignored) |
| `uhd-rfsoc.service` | systemd unit template; nothing installs it |
| `tests/` | `test_protocol.py`, `test_boards.py`, `test_xrfdc_mts_patch.py` (no board), `client_check.py` (against a daemon) |

## Bring-up (every load: at start and after a reload)

`HwBackend._bring_up`, printed step by step (`[c]`, `[m]`, `[b]` ... lines
in the log):

1. `RFSoCOverlay(bitstream)`; the compiled RFDC geometry from the overlay's
   parameters (`Geometry`): refused if factors differ between enabled
   slices, if ADC and DAC want different LMX frequencies, or if
   `Fabric_Freq != fs / F / (samples per clock)`.
2. `NEW_CONFIG` (fs, reference, PL clock, factor, initial NCOs) into
   `rfsoc_lib`'s `RFDC_CONFIG`; `RfdcTask.start()` / `join()` (an
   exception on the task thread is captured and re-raised). The clock plan
   programmed is logged: `[c] clocks: LMK... + LMX...`.
3. MTS on every DAC and ADC tile (`_mts_lock`: `MyMTS.init()` up to
   `MTS_ATTEMPTS` = 10 times; an attempt can fail its DAC alignment and the
   next locks). Must end locked or the daemon refuses to serve. The
   compiled fabric word counts are read first and held across retunes.
4. NCOs of every streamed channel, then one phase reset per direction
   (§3d). The readback is printed: factor of EVERY enabled block against
   the compiled one (a block at the wrong factor resamples silently),
   NyquistZone, NCO, and the tile clock of every tile with a streamed
   channel ("good" = PLL locked, or with the PLL bypassed `TileState` 15).
   A factor mismatch refuses; a tile clock not good refuses unless
   `--allow-unlocked` (`run_daemon.sh` passes it: the test pattern works
   without converter clocks).
5. The 100G path (`bringup.link_bringup`): the ZCU216's 8A34001 GT refclk
   (programmed only if its status says unconfigured; the RFSoC 4x2's Si570
   is fixed), the clock meters (refclk 156250 kHz, user clock 322266 kHz),
   GT reset with the ctl bits (RS-FEC, polarities, LPM / DFE, loopback),
   wait for rx aligned (status decoded every 0.5 s). A link that does not
   align is NOT fatal: the daemon serves and reports it (`cmac_aligned`).
   Then FPGA MAC / IP into streamer and player, the player enabled and
   selected as the DAC source (ARP answered from the start), the §10 FMT
   registers probed, both beamformers put in bypass with unity weights.

### Builds and rates (Protocol §8, §9)

`scan_bitstreams` reads every `<board>_v49_<N>ch_qsfp*.bit` with a `.hwh`
in `--bitstream-dir` (default: this directory): N from the name; from the
`.hwh` F, fs and its reference, the fabric clock and Data_Width of every
enabled slice (the ADC and DAC slices of channels 0..N-1 must be enabled),
the beat (checked against udp_streamer `S_WIDTH`), `TICK_STEP`,
`TX_BUF_WORDS`, the beamformers, and whether the MTS clocking wizard has
dynamic reconfiguration (a template: one `Variant` per run-time factor,
`run_factors`, those whose converter clock the MMCM makes exactly and that
is >= 10 MHz). A build without the register files of its clock plan in
`../rfsoc_lib/xrfclk/<board>/` is skipped. Two builds of one (N, rate)
resolve to the one carrying more wire formats; the loaded bitstream's own
run-time rates always win (they retune instead of reloading). The rate
tables are the top `README.md` and Protocol §9.

The build loaded at start: `--bitstream`, else the board's default
(`Board.default_bitstream`: the 1ch template) if present, else the
highest-rate build with the fewest channels. `set_channels N` loads N's
sc16-max build (`backend.default_rate`). `set_rx_rate` / `set_tx_rate`
pick, among the loaded N's builds that carry the client's formats, the
highest rate at or below the request (`coerce_rate`, `protocol._set_rate`);
a request for the rate in effect does nothing; a rate no installed build
can carry in the client's formats is refused before anything is reloaded.

* **Retune in place** (`_retune_to` / `_retune_hw`, a run-time factor of
  the loaded template, ~1-1.5 s): quiesce, MMCM to fs/F/spc over clk_wiz
  DRP, the factor on every enabled block with the compiled fabric words put
  back, MTS with its clock-wizard and DAC-tile resets undone inside it
  (`after_clkwiz_reset`, `after_dac_reset`), NCOs re-programmed and
  phase-reset, then checked: factor readback, MMCM locked, converter clock
  measured by the timekeeper within 1 %. Failure: the old factor is retuned
  back, else the old build reloaded, else the device is `_Unusable` until
  the daemon is restarted; the reply is `ERR ... restored`.
* **Reload** (`_switch_to` / `_reload`, another bitstream or channel
  count): quiesce, the whole bring-up above (a template's non-built factor
  is then retuned), restore, then `UHD_RFSOC_RELOAD_SETTLE_S` (4 s) for the
  far-end NIC to relink before replying. Failure: the previous build is
  reloaded (`ERR ... restored`); if that fails too, `_Unusable`.
* **Restored after both** (`_restore`): per-channel NCOs (and §3b DSP
  parts) and client-set gains for the channels the new build has,
  `stream_setup` and `stream_setup_tx` (the TX consumed-word baseline is
  new: the reply's third token), the beamformer state (§11), the time (0,
  or carried over in the new tick rate if a client had called `set_time`).
  Not restored: a running stream, the RX command queue, pending timed
  commands.

## Choices made where the Protocol is silent

* `set_rx_freq`: NCO = `-(f mod fs)` (rfsoc_lib's real -> I/Q convention),
  Nyquist zone parity from f vs fs/2, the driver folds and handles the
  even-zone inversion; the value reported is f on the 48-bit NCO grid; the
  range is the first Nyquist zone of the loaded build, 0 .. fs/2, a request
  outside is clamped. After every NCO change the phases of the direction's
  channels are reset together (§3d; `--nco-phase-reset`).
* `get_*_lo_locked`: the channel's tile judged like the bring-up readback.
  `ref_locked` = ADC and DAC tile clocks good (the LMK04828 / LMX2594 are
  write-only through xrfclk). `temp` / `pl_temp` without the AMS sysmon
  read `string n/a -`. `pps_present` is always false. `mts_locked` =
  bring-up locked it and the MTS MMCM is still locked.
* RX gain = -DSA attenuation, 0 .. 27 dB in 1 dB steps, read back after
  writing; fixed 0 if the DSA is unreadable. TX gain = 20 log10(VOP uA /
  40500) in [-25.1, 0] only on a build with `C_DAC_VOP_Mode = 1`
  (the RFSoC 4x2's), otherwise range `0 0 0`.
* `set_clock_source external` is refused: no LMK04828 register file selects
  CLKin0 (the CLK104's REF IN) yet.
* `stream_setup` refuses while streaming; `spp` (slots) is floored to whole
  64-byte words of the format and a multiple of N, at most 8192 payload
  bytes; `num_done` / `num_more` counts (slots) are rounded up to that
  granule; `num_samps = 0` is an error for those modes. The streamer's
  destination-port counter is brought back to 0 at every setup (one
  16-slot packet to UDP port 9). `stream_cmd` / `stream_setup*` accept any
  valid `<ch>` and ignore it; the SIDs are always `0x5A160000` /
  `0x5A170000`.
* `otw=` on `stream_setup` / `stream_setup_tx` writes the FMT register
  while idle and verifies the readback; refused for a format the bitstream
  does not convert, whose aggregate wire rate exceeds 12.38 GB/s, or RX
  fc32 on a 512-bit-beat build. The client's current otw is the last one
  it sent (any of the three commands), `sc16` after a claim.
* `set_channels N` to the loaded N reloads only if the loaded build cannot
  carry the current otw (an sc8-only rate left by a previous client); a
  stream setup the new build cannot carry is dropped after a build change.
* Stream commands are queued (`rx_cmdq.py`, §4a): the next is issued when
  the streamer is idle (STATUS bit 0, counted busy for 2 ms after a command
  was accepted, since it crosses from adc_clk); a running `start_cont` is
  stopped by the next start once it has sent a packet; a late timed
  command becomes a one-granule `num_done` marker; an open `num_more`
  chain streams as `start_cont` and is stopped past its end +
  `--chain-grace-ms`. Acceptance = the streamer's CMDS counter advancing.
* `stream_setup_tx` replies the free-running consumed-word count as its
  third token (the host's flow-control baseline); `stream_stop_tx` flushes
  and leaves the player as the DAC source, so the DAC outputs zeros. The
  untimed-start gate (USTART / UTIMEOUT, §6) is written at every setup.
  `fc_interval` = 512 words (1/8 of a smaller buffer);
  `UHD_RFSOC_FC_INTERVAL` overrides it.
* The claim's release (unclaim or disconnect) stops RX streaming and TX
  playback, resets both beamformers and the client's formats and `spp`.
* `set_bf_angle` / `set_rbf_angle` use `rfsoc_lib/dsp/beamformer.py`
  (the same weights for RX, no conjugate); the kept state and the reset
  rules are Protocol §11.

## Flags worth knowing

Hardware: `--bitstream`, `--bitstream-dir`, `--board` (else `$UHD_BOARD`,
else the bitstream names), `--no-load` (attach to the loaded bitstream),
`--allow-unlocked`, `--rx-freq` / `--tx-freq` (initial NCOs, 600 MHz),
`--nco-phase-reset all|tuned|off`, `--lib-root`. Link (daemon and
`bringup.py`): `--no-refclk`, `--rsfec 0|1` (must match the NIC, default
1), `--rxpol` / `--txpol` (lane masks), `--dfe`, `--loopback` (near-end PMA
loopback, aligns without a NIC), `--cmac-timeout`. Protocol: `--port`,
`--disc-port`, `--bind`, `--mgmt-ip`, `--chain-grace-ms`, `--config`,
`--data-ip` / `--data-mac` / `--name`, `--serial`. Environment:
`UHD_RFSOC_CONF`, `UHD_RFSOC_RELOAD_SETTLE_S`, `UHD_RFSOC_FC_INTERVAL`,
`RFSOC_MTS_TARGET` (`../rfsoc_lib/AGENTS.md`).

## Boards

Every board is served by the same code through its `Board`: the ZCU216
(`zcu216_v49_<N>ch_qsfp*`, N = 1 .. 16, quad RF-ADC tiles, channel c = tile
c // 4, block c % 4, 8A34001 GT refclk programmed at bring-up) and the
RFSoC 4x2 (`rfsoc4x2_v49_<N>ch_qsfp*`, N = 1 or 2). The 4x2's RF-ADC tiles
are dual (`.hwh` `C_High_Speed_ADC`): a converter's I and Q are two IP
slices of Data_Width samples per clock each but ONE xrfdc block
(`Board.adc_slices` / `adc_block` / `api_block`), ch1's ADC is
`adc_tiles[0].blocks[1]`, tiles 1 and 3 stay unpowered (`masked_tiles`: the
readback lists their blocks without reading them) and out of MTS
(`mts_tiles` 0b0101, reference tile 2), a bypassed ADC tile takes up to
5000 MHz (`RFSOC4X2_MIN_MAX_CONFIG`), and the GT refclk is a Si570 running
from power-up (`gt_refclk = "si570"`: never programmed). Discovery reports
the board as `product=` (`Board.prefix`); `type` is always `rfsoc`.
