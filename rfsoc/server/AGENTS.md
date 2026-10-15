# AGENTS.md — rfsoc_lib/uhd/server (the board side)

Read `../AGENTS.md` first (environment, sharing rules, invariants). This file
is the detailed reference of the daemon; `README.md` is the short version.

## Rules for this directory
- Runs ON THE BOARD (PYNQ venv, root). Every FPGA address lives in
  `eth100g.py`, `tx_beamformer.py`, `rx_beamformer.py` (sources of truth: the
  RTL headers in `hw_design/ip_design/uhd_ip/src`). Never add a fallback
  address: blocks are found by name in the `.hwh`.
- Reuse `rfsoc_lib`: RFDC bring-up (`RfdcTask`, `rfdc_config`), clocks
  (`xrfclk/ZCU216`, `gt_refclk.py` for the 8A34001), beamformer weights
  (`dsp/beamformer.py`). Do not copy their logic here.
- No IP address in code: the FPGA data IP comes from the board's
  `zcu216_uhd.conf` (gitignored; template `zcu216_uhd.conf.example`), the
  management address from the incoming request.
- Tests run on the board (`../benchmark/`). A behaviour change also goes
  into `../PROTOCOL.md`.
- Hardware runs hold the board lock (see `../AGENTS.md`).

---

## Reference (former README)

`zcu216_uhd_daemon.py` makes a ZCU216 running a `zcu216_v49_<N>ch_qsfp` build
(N = 1, 2, 4, 8, 16 channels, PROTOCOL.md §9) look like a USRP to the UHD host
module (`type=zcu216`). The contract is `../PROTOCOL.md`.
The rules in `hw_design/ZCU216/CLAUDE.md` bind this code, in particular: the
RFDC comes up only through the proven `RfdcTask` pattern, at the factor
compiled into the block design. A **template** build (its `MTS_clk_wiz` has
dynamic reconfiguration) then changes the factor at run time, in one place
only: `HwBackend._retune_hw` (PROTOCOL.md §8). It must end with MTS locked,
the factor read back on every enabled block and the converter clock measured
within 1 %, or it is undone. Two resets inside MTS undo a retune and are put
back there: the clocking-wizard reset (MMCM -> build frequency) and the DAC
tile reset (interpolation -> build factor); ADC tiles keep theirs.

| file | what |
|---|---|
| `zcu216_uhd_daemon.py` | entry point: TCP control server (49710), UDP discovery (49700) |
| `protocol.py` | transport-free command parser/dispatcher, claim ownership, reply formats, §10 `otw=` options and the 100GbE rate cap (also vetting a rate change), §11 TX (`*_bf*`) and RX (`*_rbf*`) beamformer commands |
| `boards.py` | the boards served (ZCU216, ZCU208): bitstream prefix, channel map (IP slices vs xrfdc blocks on a dual ADC tile), tiles RfdcTask leaves unpowered, default build; `detect_board` (`--board`, `$UHD_BOARD`, bitstream names) |
| `board_config.py` | the board's settings file `zcu216_uhd.conf` (FPGA data IP/MAC, name): search path, parsing, the eth0-derived default MAC |
| `zcu216_uhd.conf.example` | template of that file (placeholders only; the real file is git-ignored) |
| `backend.py` | `Backend` interface; the v49 build table (`V49_GEOMETRY`), link checks (`link_problem`, `default_rate`), FC interval policy, TX/RX beamformer state and `steering_weights` (rfsoc_lib `Beamformer`) |
| `hw_backend.py` | `HwBackend`: build scan (`.hwh`: factor, beat, TICK_STEP, TX buffer, TX/RX beamformers), overlay, compiled-geometry bring-up, NCO/DSA/VOP, sensors |
| `tx_beamformer.py` | `eth100g/tx_beamformer` registers (0x80060000, N >= 2 builds; PROTOCOL.md §11), mapped only from the overlay's ip_dict |
| `rx_beamformer.py` | `eth100g/rx_beamformer` registers (0x80070000, the N >= 2 builds that carry it; §11), mapped only from the ip_dict; `beam_payload`, the bit-exact reference of the RX beam |
| `eth100g.py` | the 100G FPGA addresses (final, from `eth100g.tcl` + RTL headers): `udp_streamer` 0x80020000, `udp_player` 0x80030000, `cmac_gpio` 0x80040000 (ctl/status of `cmac_100g.v`), `cmac_freq` 0x80050000 (refclk / user clock kHz). Resolved by ip_dict name, addresses as fallback. No PG203 AXI4-Lite in this build. No DRAM path: the player is always the DAC source |
| `bringup.py` | step-by-step link bring-up for manual use (prints everything), `--status` read-only dump; its steps are also what `HwBackend` runs |
| `rx_cmdq.py` | the RX stream-command queue (PROTOCOL.md §4a) over the streamer's one command slot: FIFO, late markers, `num_more` chains, for `HwBackend` |
| `cmd_timer.py` | timed commands (§3c): `set_*_freq` / `set_*_gain` / `set_time` with `at=<ticks>`, grouped by time, run by the FPGA timekeeper |
| `vrt.py` | wire format of §4-7 packets, test pattern, async packets, the §10 reference conversions (`sc16_to_wire`, `wire_to_sc16`, `pack_sc12`) |
| `gt_refclk.py` | 8A34001 (U409, `/dev/i2c-10` @0x5B) GT refclk for Q7/Q11: `read_status()` (read-only by default), `program_gt_refclk(156.25, dry_run=...)` applies a register file after checking it gives the target on Q7/Q11 |
| `zcu216-uhd.service` | systemd unit template (hardware mode; not installed by anything) |
| `deploy.sh` | rsync to the board, no start |
| `tests/client_check.py` | end-to-end protocol check against a running daemon on the board (discovery, claim, RX/TX streams, OTW formats, beamformer registers) |

### ZCU208 (built, not board-tested)

`HwBackend` names no board; `boards.py` does. A ZCU208 (`zcu208_v49_<N>ch_qsfp`,
N = 1, 2, fs 5000) differs in three ways the code handles from the `Board`
and the `.hwh` (`C_High_Speed_ADC`): its RF-ADC tiles are dual, so one ADC
slice carries I or Q alone at Data_Width samples per clock (the fabric check
and the beat use that); a channel's ADC is two IP slices but ONE xrfdc block
(ch1 = `adc_tiles[0].blocks[1]`); and tiles 1 and 3 are left unpowered by
RfdcTask, so the readback lists their blocks without reading them. `rx_chans`
and `tx_chans` are therefore different lists. rfdc.py reads the global
`ZCU216_CONFIG` on every board, so `HwBackend` copies the board's clock limits
(`ZCU208_MIN_MAX_CONFIG`) and NEW_CONFIG into it. Discovery reports
`product=zcu208` (type stays `zcu216`, the protocol). What a first board run
must confirm: `hw_design/ZCU208/CLAUDE.md` "v49".

## Addresses (PROTOCOL.md §1)

Nothing in the code holds an IP address. The board's LAN address is learned
per request: a discovery reply carries the address the request arrived on
(IP_PKTINFO, else the route back to the asker), an `info` reply the local
address of its TCP connection, so a DHCP change needs no restart (`--mgmt-ip`
overrides both). The FPGA's 100G identity is configuration, in
`zcu216_uhd.conf` (searched: `$ZCU216_UHD_CONF`, this directory,
`/etc/zcu216_uhd.conf`; `--config FILE`):

    data_ip  = <fpga-data-ip>    # required in hardware mode: on the subnet of the PC's 100G port
    data_mac = <fpga-data-mac>   # optional: default = the eth0 MAC, locally administered
    name     = zcu216-0          # optional

`--data-ip` / `--data-mac` / `--name` override the file. Without a data IP
the hardware daemon exits with a message saying where to put it.
`cp zcu216_uhd.conf.example zcu216_uhd.conf` and edit; `deploy.sh` never
copies or deletes that file on the board.

## Running

Hardware (root, PYNQ venv; downloads the bitstream unless `--no-load`):

    sudo bash -c 'source /etc/profile.d/pynq_venv.sh && \
        python3 zcu216_uhd_daemon.py [--bitstream-dir DIR] [--bitstream X.bit]'

Builds (PROTOCOL.md §8, §9): every `zcu216_v49_<N>ch_qsfp*.bit` with a `.hwh`
next to it in `--bitstream-dir` (default: this directory) is one (channel
count, rate). N comes from the name; from the `.hwh`: F, the converter rate
fs and its reference clock, the fabric clock and data width (every enabled
slice; the ADC and DAC slices of channels 0..N-1 -- channel c = tile c//4,
block c%4 -- must be enabled), the fabric beat (N x Data_Width/2 slots,
checked against udp_streamer `S_WIDTH`), `TICK_STEP` of udp_streamer (=
udp_player's), `TX_BUF_WORDS` and whether a `tx_beamformer` and an
`rx_beamformer` (each N_CH = N) are present. TICK_STEP is 1 on every build,
so **a build's tick rate is its aggregate slot rate** (N x per-channel rate);
it differs per build, never one value per N. Files that are inconsistent,
lack a `.hwh` or duplicate an (N, rate) are logged and skipped.

The builds (`hw_design/ZCU216/scripts/v49_ladder.sh`; the full list, with
the wire formats each carries, is `../benchmark/oracle_builds.txt`; names
`zcu216_v49_<N>ch_qsfp_f<F>[_fs<fs>]`, `_fs` when fs != 2400):

| family | N | fs (MS/s) | factors F (one build each) | per-channel rate | beat | wire formats |
|---|---|---|---|---|---|---|
| normal | 1 | 2500 | 2 3 4 5 6 8 10 12 16 20 24 40 | 1250 .. 62.5 MS/s | 128 b | sc16 sc12 sc8 fc32 |
| normal | 2 | 2500 | 2 3 4 5 6 8 10 12 16 20 24 40 | 1250 .. 62.5 | 256 b | sc16 sc12 sc8; fc32 from F4 |
| normal | 4 | 2250 | 3 4 5 6 8 10 12 16 20 24 40 | 750 .. 56.25 | 512 b | sc16 sc12 sc8 |
| normal | 8 | 2250 | 6 8 10 12 16 20 24 40 | 375 .. 56.25 | 512 b | sc16 sc12 sc8 |
| normal | 16 | 2250 | 12 16 20 24 40 | 187.5 .. 56.25 | 512 b | sc16 sc12 sc8 |
| sc8max | 4 | 2500 | 2 | 1250 | 512 b | **sc8 only** |
| sc8max | 8 / 16 | 2250 | 3 / 6 | 750 / 375 | 1024 b | **sc8 only** |

The normal family's top factor is the highest rate whose sc16 stream fits
the link (97 % of it at 4-16 channels); sc8max doubles the per-channel rate in
sc8 at 8 and 16 channels (6.0 GS/s, the same 96 Gb/s) and reaches the ADC's
1250 MS/s at 4 (1.67x). A wire format is offered when N x rate x bytes/sample fits the 100GbE
payload rate (`backend.link_problem`); RX fc32 is never offered on a
512-bit-beat build (udp_streamer would need two FIFO words per clock), and a
1024-bit-beat build carries sc8 only (one sc8 wire word per clock). The
converters' LMX2594 is programmed from the `.hwh` reference clock:
`rfsoc_lib/xrfclk/ZCU216/LMX2594_250.0_<fs>.0.txt` must exist for every fs
(2250, 2500; `deploy.sh` FORCE=1 checks).

The one loaded at start is `--bitstream`, else `<dir>/zcu216_v49_1ch_qsfp.bit`
(not part of the ladder), else the highest-rate build with the fewest channels
(1ch F2 fs2500). `set_channels N` loads N's default build = the highest rate
whose sc16 stream fits the link. `set_rx_rate`/`set_tx_rate` pick, among the
loaded N's builds that carry the client's OTW formats, **the highest rate at
or below the request** (1 ppm tolerance; below every rate, the lowest) --
`backend.coerce_rate`, `protocol._set_rate`; if no build carries them the
request is refused before any reload (PROTOCOL.md §3, §10). A request for the
rate in effect never reloads. Otherwise both stop streaming, reload that
overlay and redo the FULL bring-up below (8A34001 only if its status says
unconfigured), wait `ZCU216_RELOAD_SETTLE_S` (4 s) for the far-end NIC, then
restore per-channel NCOs and client-set gains (for the channels the new build
has), `stream_setup`/`stream_setup_tx`, the TX and RX beamformer state and the
time (0, or carried over and converted to the new build's tick rate if a
client had called `set_time`) -- `HwBackend._switch_to`. Both replies carry
the new tick rate. If the new build fails, the previous one is reloaded; if
that fails too the backend refuses every PL access until the daemon is
restarted.

TX flow control: the v49 buffer is 2 MiB (`tx_buf_words` 32752). The daemon
programs `fc_interval` = 512 words (an async credit update every 32 KiB
consumed, 1.6 % of the credit; 1/8 of the buffer if that is smaller);
`ZCU216_FC_INTERVAL=<words>` in the daemon's environment overrides it.

MTS is not optional: every bitstream load runs multi-tile sync on all DAC and
ADC tiles (`HwBackend._mts_lock`: rfsoc_lib `MyMTS.init()` -- tile-sync reset,
MTS clocking-wizard MMCM lock, `mts_dac`, `mts_adc`) after the RfdcTask
bring-up and before the NCOs. It must end locked or the daemon refuses to
serve; it runs up to `MTS_ATTEMPTS` (10) times, because an attempt can fail
(the first after a board reboot on zcu216-0; on the templates, DAC alignment
"delay 31 exceeds maximum" at some factors) and the next locks. The log line `[m] MTS LOCKED
(attempt n)` carries the per-tile latency and offset; the mboard sensor
`mts_locked` reports it (and that the MMCM is still locked) to the host.

Useful hardware flags: `--allow-unlocked` (serve even if a converter tile
clock is not good — enough for `pattern=1` tests), `--rx-freq/--tx-freq` (initial NCOs, default
600 MHz like the donor notebook), `--lib-root` (dir holding `rfsoc_lib/`;
searched upward from this file by default), `--nco-phase-reset all|tuned|off`
(default `all`: after NCOs change, reset the NCO phase of every streamed
channel of that direction together, one update event per tile -- PROTOCOL.md
§3d; `off` if it misbehaves). Both backends: `--chain-grace-ms` (default 1:
how long an open `num_more` chain streams past its end before the daemon
stops it, §4a).

100G link flags (daemon and `bringup.py`): `--no-refclk` (skip the 8A34001),
`--rsfec 0|1` (must match the NIC, default 1), `--rxpol MASK` / `--txpol MASK`
(lane 0 = bit 0 = SFP0), `--dfe` (DFE instead of LPM), `--loopback` (near-end
PMA loopback, aligns without the NIC), `--cmac-timeout S`.

Manual bring-up on the board (root, PYNQ venv):

    python3 bringup.py --status                 # read-only; refuses unless v49 is loaded
    python3 bringup.py                          # overlay + RFDC + link, prints everything
    python3 bringup.py --link-only --rsfec 0    # v49 already loaded: redo steps b-e only
    python3 bringup.py --stream-host-ip <host-data-ip> --stream-host-mac <cx5 mac> --seconds 10
        # + on the PC: watch the NIC count it (nothing needs to receive it):
        #   ethtool -S <100g-iface> | grep -E "rx_vport_unicast_(packets|bytes)|rx_out_of_buffer"
        # for a byte-level check use the daemon and host/tools/dpdk_rx_test.sh

Deploy: `./deploy.sh [xilinx@zcu216-0] [/home/xilinx/jupyter_notebooks/SPEAR-qsfpv]`
(`BIT_DIR=<dir>[:<dir>...]` also copies every `zcu216_v49_*ch_qsfp*.bit` + `.hwh` build, `NO_LIB=1` skips `rfsoc_lib`).

Tests:

    python3 tests/client_check.py --addr <board-ip> [--tx] [--rate 6e8] [--channels N] \
        [--otw sc16|sc8|sc12|fc32] [--bf]

## Hardware bring-up, step by step

1. `RFSoCOverlay(bitstream)` (xrfdc imported first so the RFDC driver binds).
2. Compiled geometry from the hwh (`C_ADC_Decimation_Modetb`,
   `C_DAC_Interpolation_Modetb`, `C_ADCt_Sampling_Rate`, `C_ADCt_Refclk_Freq`,
   `C_ADC_Data_Widthtb`, `C_ADCt_Fabric_Freq`, … for every enabled slice).
   Refused if factors differ between slices, if DAC/ADC ask for different LMX
   frequencies, or if `Fabric_Freq != fs/factor/(Data_Width/2)`.
3. `NEW_CONFIG` = that geometry → `ZCU216_CONFIG.update()` → `RfdcTask(...)`
   `.start()/.join()` (exceptions from the task thread are captured, not lost).
4. NCOs for the initial frequencies (per streamed channel), then the readback
   is PRINTED: EVERY enabled block's interpolation/decimation vs. compiled
   (streamed or not), NyquistZone, NCO, and the `TileState`,
   `PLLConfig.Enabled`, `PLLLockStatus` of every tile holding a streamed
   channel. Refused if any factor differs or cannot be read. Tile clock "good" = `PLLLockStatus == 2` for a tile whose PLL
   is enabled; for a bypassed tile (fs fed straight from the LMX2594,
   `PLL_Enable false`) there is no PLL, so `TileState == 15` is the
   only on-chip evidence. Not good → refuse unless `--allow-unlocked`.
5. `Eth100G`: ID checks (`ZS01`, `ZP01`; the constructor only reads). Then
   `bringup.link_bringup()`:
   b. `gt_refclk.program_gt_refclk(156.25)` (unless `--no-refclk`); a failure
      is printed and bring-up continues so the rest can be debugged;
   c. `cmac_freq`: refclk must read 156250 ± 50 kHz; if not, the ratio
      measured/156.25 MHz is printed (= the 8A34001 crystal assumption error);
      user clock 322266 kHz once the GT TX PLL runs;
   d. write ctl (RS-FEC, polarities, LPM/DFE, loopback) with GT sys_reset held,
      release it, wait up to `--cmac-timeout` for status bit0 (rx aligned),
      printing the status decoded field by field every 0.5 s (RS-FEC AM lock
      per lane, power-good, reset-dones, local/remote fault, hi BER, ...) and
      hints if it fails. The RTL controller does RX/RS-FEC on, send RFI, TX enable.
   e. FPGA MAC/IP (from `zcu216_uhd.conf`) into streamer and player; player
      enabled AND selected as the DAC source (`dac_src = 1`: the DRAM/DMA path
      no longer exists; an idle player outputs zeros), so ARP is answered
      from the start. Then the §10 FMT registers are probed (write each code,
      read back; a bitstream from before §10 reads 0): `info otw_formats=`.
      On an N >= 2 build the `tx_beamformer` (ID `ZB01`, NCH = N) is put in
      bypass with unity weights, and the `rx_beamformer` (ID `ZR01`, NCH = N;
      only if the `.hwh` lists it) in bypass with unity weights and SHIFT
      log2(N); then the kept §11 state is re-applied.
   A link that does not align is reported (`get_sensor cmac_aligned` = status
   bit0, `refclk_khz`, `usrclk_khz`), not fatal.

## Semantics chosen where PROTOCOL.md is silent

* Rates: the highest build rate at or below the request among the builds
  that carry the client's OTW formats (else the lowest); RX and TX are one
  rate. A request for the current rate never reloads.
* `set_rx_freq`: RF frequency f → Nyquist zone parity from f vs fs/2; NCO =
  `-(f mod fs)` (rfsoc_lib real→I/Q convention, `config_adc_nco`), the driver
  folds and handles even-zone inversion. Reported value = f rounded to the
  48-bit NCO step. RX and TX range 0–fs/2 (first Nyquist zone only: 0–1250 MHz
  at fs 2500, 0–1125 MHz at 2250); a request outside is clamped. With `dsp=` (§3b) the NCO is
  rf − dsp (RX) / rf + dsp (TX), clamped the same way. After every NCO change
  (and after the bring-up's) the NCO phases are reset per §3d.
* `get_rx_lo_locked <ch>`: the tile of channel ch, judged like the bring-up
  readback (PLL locked, or PLL bypassed and `TileState == 15`). `temp` /
  `pl_temp` without the AMS sysmon read `string n/a -`; `pps_present` is
  always false (no PPS input in any build).
* RX gain = −DSA attenuation, 0…27 dB in 1 dB (Gen3 production silicon), read
  back after writing. TX gain = 20·log10(VOP µA / 40500) in [−25.1, 0] only if
  the IP has `C_DAC_VOP_Mode=1`; otherwise range `0 0 0` and fixed 0.
* `get_sensor` bool replies carry a unit word (`locked`/`unlocked`,
  `aligned`/`unaligned`); an empty unit would be sent as `-`.
* `stream_setup` refuses while streaming; `spp` (slots) floored to whole
  64-byte words of the OTW format (16 sc16, 32 sc8, 64 sc12, 8 fc32 slots)
  and a multiple of N, at most 8192 payload bytes (the hw reply is the SPP
  register read back, FMT written first). `num_done`/`num_more` (slots: the
  host multiplies by N) are rounded up to that granule by the daemon before
  the FPGA sees them; `num_samps=0` is an error for those modes.
* `otw=<fmt>` (§10) on `stream_setup` / `stream_setup_tx` writes the
  streamer's / player's FMT register (idle: before SPP, during the player's
  flush) and verifies it reads back; refused for a format the bitstream does
  not convert, whose wire rate (N × rate × bytes/slot) exceeds 12.38 GB/s, or
  (RX) fc32 on a 512-bit-beat build. `info` lists `otw_formats` (both
  directions), `rx_otw_formats`, `tx_otw_formats` and, per rate of this N,
  `rate_otw=<rate>:<fmt>+<fmt>,...`.
  Stream commands accept any valid `<ch>` and ignore
  it; the SIDs are always `0x5A160000` / `0x5A170000`.
* `set_channels N` to the loaded N does not reload unless the loaded build
  cannot carry the current OTW format (e.g. an sc8-only build left by the
  previous client, whose format was reset to sc16 on release): then N's
  default build is loaded. Another N loads that N's sc16-max build.
  `get_channels` -> `OK <N> <tick_rate>`.
* The client's current OTW format is the last `otw=` it sent (`stream_setup`,
  `stream_setup_tx`, or `set_rx_rate <ch> <hz> otw=<fmt>`), sc16 after a claim.
  A rate change must fit it and the format of every stream setup a reload
  re-applies; after `set_channels`, a setup the new build cannot carry is
  dropped (the next `stream_cmd` asks for a new `stream_setup`).
* Beamformers (§11): `set_bf_angle` / `set_rbf_angle` compute the weights with
  `rfsoc_lib/dsp/beamformer.py` (`Beamformer(num_channels=N, element_spacing,
  carrier_freq).compute_weights_fixed_point(angle)`; the same weights for RX,
  no conjugate) and write W[0..N-1], (RX) SHIFT, LOAD, CTRL. TX and RX keep
  separate state, which survives reloads (an angle is recomputed for a new N;
  raw weights of another N fall back to unity, an RX SHIFT set for another N
  to log2(N)) and is reset to bypass, unity weights, SHIFT log2(N) and the
  default geometry (135 GHz, 1.07 mm) when the claim is released. On N = 1
  every `*_bf*` command is `ERR`; every `*_rbf*` command is `ERR` on a build
  without the RX beamformer (N = 1, or an older bitstream: `info rbf=0`).
* Stream commands are queued (`rx_cmdq.py`, PROTOCOL.md §4a): the next one is
  issued when the streamer is idle (STATUS bit 0, which counts as busy for
  2 ms after a command was accepted, so a short burst is not taken for
  finished before its status bit crossed from adc_clk); a running `start_cont`
  is stopped by the next start once it has sent a packet (STR_PKTS advanced);
  a late timed command becomes a 16-slot `num_done` marker issued now; an
  open `num_more` chain streams as `start_cont` and is stopped once the
  timekeeper passes its end + `--chain-grace-ms`. Acceptance is checked by
  the streamer's CMDS counter advancing. No EOB is emitted on `stop_cont`
  between packets; `num_more` ends without EOB. A reload forgets the queue.
* `stream_setup_tx` replies `OK <tx_buf_words> <fc_interval> <consumed>`: the
  third token is the player's consumed-word count, which is free-running (only
  a reset clears it, `rtl/udp_player.v`), so the host must use it as its
  flow-control baseline. Hosts that read only two tokens still parse it.
  `stream_stop_tx` flushes (flushed words count as consumed) and leaves the
  player as the DAC source, idle, so the DAC outputs zeros.
* Owner disconnect or `unclaim` stops RX streaming and TX playback and resets
  both beamformers.
* `ref_locked`: the LMK04828/LMX2594 are write-only through xrfclk, so it is
  the AND of the ADC and DAC tile-clock checks. `set_clock_source external` is
  refused (no LMK register file selecting CLKin0 exists yet).
