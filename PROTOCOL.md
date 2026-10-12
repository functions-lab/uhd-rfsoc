# uhd_zcu216 — interface contract

The ZCU216 is exposed to UHD as a device of `type=zcu216`. Three parts talk to
each other, and this file is the only place their contract is written down:

```
  PC (wei-duke-wsp5)                              ZCU216 (zcu216-0)
 ┌─────────────────────────┐   1GbE LAN (TCP)    ┌──────────────────────────┐
 │ libuhd 4.6              │ ──── control ─────► │ zcu216_uhd_daemon.py     │
 │  + libuhd_zcu216.so     │ ◄──────────────────  │  (PYNQ, root)            │
 │    (UHD device module)  │                      │   AXI-Lite ▼             │
 │                         │   100GbE (UDP)       │ FPGA: RFDC ─► packetizer │
 │  ConnectX-5 port 1      │ ◄──── samples ────── │   ─► UDP/IP/Eth ─► CMAC  │
 └─────────────────────────┘                      └──────────────────────────┘
```

The control plane uses the 1GbE management LAN, not the 100G link, so the
device can be found and configured even while the 100G link is down. That is
how a failed CMAC bring-up gets reported (`sensor cmac_aligned`).

## 1. Addresses

No IP address is fixed by this contract or written into the code: the LAN
address of the board is whatever DHCP (or the admin) gives it, and the 100G
link's two ends are configured once per installation.

| what | value | where it comes from |
|---|---|---|
| board management IP (control) `<board-ip>` | board eth0 (LAN), e.g. DHCP | NOT configured: the daemon answers each discovery request with the address the request arrived on (IP_PKTINFO, else the route back to the asker) and each control connection with its local address; `--mgmt-ip` overrides. Hosts find it by discovery (§2) or take it as `addr=` |
| control TCP port | 49710 | daemon `--port` |
| discovery UDP port | 49700 | daemon `--disc-port` |
| FPGA data IP `<fpga-data-ip>` | on the subnet of the PC's 100G port | board config file `zcu216_uhd.conf`, key `data_ip` (`server/zcu216_uhd.conf.example`), or daemon `--data-ip`; written to the FPGA, reported as discovery/`info` `data_ip=`. The daemon refuses to start in hardware mode without one |
| FPGA data MAC | locally administered | `zcu216_uhd.conf` `data_mac`, or `--data-mac`; default derived from the board's eth0 MAC (first octet: bit 1 set, bit 0 clear); reported as `info data_mac=` |
| FPGA data UDP source port | 49800 | fixed |
| host data IP `<host-data-ip>` | the PC's 100G port (`host/setup_cx5.sh <iface> <host-data-ip>/<prefix>`) | the host module routes to `data_ip` and sends its source address in `stream_setup` (`host_data_ip=` overrides) |
| host data UDP port base | 49810 | host module (`recv_port` device arg) |

Example (an example only, not a default): board LAN `192.168.0.132` from DHCP,
PC 100G port `192.168.5.1/24`, `data_ip = 192.168.5.2` in the board's
`zcu216_uhd.conf`.

## 2. Discovery (UDP 49700)

Host sends the ASCII datagram `ZCU216-DISC?` to either the broadcast address
or to `addr` if given. The daemon replies to the sender with one ASCII line:

```
ZCU216-DISC type=zcu216;product=zcu216;serial=<s>;name=<n>;addr=<mgmt ip>;data_ip=<fpga ip>;claimed=<0|1>;fpga=<bitstream name>;version=<proto ver>
```

`addr` is the board address the request arrived on (§1): a board on two
networks answers each with its address there, and a DHCP change shows up in
the next reply.

The host module turns it into a `uhd::device_addr_t` (split on `;`, `=`).
`version` is the protocol version, currently `1`.

## 3. Control (TCP 49710)

Line-oriented ASCII, one request per line, one reply per line, UTF-8, `\n`
terminated. Tokens are separated by single spaces. Numbers are decimal,
floats in `%.17g` form.

```
request:  <cmd> [arg ...]\n
reply:    OK [value ...]\n     |    ERR <message>\n
```

A connection that sends `claim` owns the device until it closes or sends
`unclaim`; `claim` from a second connection while one is held gets
`ERR claimed`. Every command other than `ping`, `info`, `claim` needs the claim.
Channel numbers `<ch>` are 0-based UHD channels, `0..N-1` of the loaded
N-channel build; channel c = ADC / DAC tile c/4, block c%4 (§9).

| command | reply | meaning |
|---|---|---|
| `ping` | `OK pong` | liveness |
| `info` | `OK key=value;key=value...` | same keys as discovery (`addr` = the local address of this connection), plus `num_rx=`, `num_tx=` (= N), `tick_rate=` (of the LOADED build, §8: N x per-channel rate), `tick_step=` (ticks per slot: 1), `beat_slots=` (slots per fabric beat: a timed start begins on one), `adc_rate=`, `dac_rate=`, `rx_rates=r1,r2,..` / `tx_rates=` (per-channel rate of every installed build with THIS N, descending), `tick_rates=t1,t2,..` (the tick rate of each of those builds, same order), `rate_otw=r1:f+f,r2:f+..` (per rate of THIS N, the §10 formats its build can stream in both directions), `channel_counts=1,2,..` (every N some installed build offers), `spp=` (sc16 slots), `mtu=`, `data_mac=`, `tx_buf_words=`, `fc_interval=`, `otw_formats=sc16,..` (§10: the formats the loaded bitstream converts whose stream fits, both directions; absent = sc16 only), `rx_otw_formats=`, `tx_otw_formats=` (per direction: RX excludes fc32 on a 512-bit beat), `bf=0\|1` (§11 TX beamformer present), `rbf=0\|1` (§11 RX beamformer present; absent = 0) |
| `claim` / `unclaim` | `OK` | ownership |
| `set_channels <N> [otw=<fmt>]` | `OK <N> <tick_rate>` | switch to N's DEFAULT build, the sc16-max one (§9). `otw=` first declares the client's format (it becomes the current otw, as with `set_*_rate`), so a loaded build only that format fits, e.g. sc8-max with `otw=sc8`, is kept. **If N is not the loaded build's -- or it is, but at a rate the current otw cannot carry -- the daemon reloads the FPGA and redoes the full bring-up exactly as for a rate change (§8): SECONDS, budget 60 s, streaming stops.** The tick rate is that build's: re-read it. `ERR` if no N-channel build is installed |
| `get_channels` | `OK <N> <tick_rate>` | the loaded build's channel count |
| `get_rx_rates <ch>` | `OK r1 r2 ...` | the sample rates the installed bitstream variants deliver (Hz, descending; §8) |
| `set_rx_rate <ch> <hz> [otw=<fmt>]` | `OK <actual hz> <tick_rate>` | coerces to the highest rate of this N at or below `<hz>` (1 ppm tolerance) among the builds that carry the client's formats; below every one of them, the lowest (§8). **If that is not the loaded build's rate the daemon reloads the FPGA and redoes the full bring-up: this takes SECONDS (budget 60 s) and stops streaming** (§8). RX and TX change together. The 2nd token is the new build's tick rate (it can differ between builds of one N): the host must take it. `otw=` declares the format the client will stream (§10) and becomes the current otw (otherwise: the last `otw=` of a stream setup or rate request, `sc16` after `claim`). Refused BEFORE any reload, with `ERR set_rx_rate <hz> refused: ...`, only if no build of this N carries the current otw and the formats of the existing stream setups at 100GbE. E.g. 4ch, `set_rx_rate 0 1.25e9` gives 750 MS/s (the fastest sc16 build); `set_rx_rate 0 1.25e9 otw=sc8` gives 1250 MS/s (sc8max) |
| `get_rx_rate <ch>` | `OK <hz>` | |
| `set_rx_freq <ch> <hz> [dsp=<hz>] [at=<ticks>]` | `OK <actual hz>` (`OK <rf> <dsp>` with `dsp=`) | RF centre: programs the ADC fine-mixer NCO (`-hz` sign convention handled in daemon). `dsp=`: the DSP part of a UHD tune request, folded into the same NCO (§3b). `at=`: applied when the timekeeper reaches `<ticks>`, replying at once with the values it will set (§3c) |
| `get_rx_freq <ch>` | `OK <hz>` | the RF part (= the NCO frequency when the DSP part is 0) |
| `get_rx_dsp_freq <ch>` | `OK <hz>` | the DSP part (§3b); 0 unless a `dsp=` set it |
| `get_rx_lo_locked <ch>` / `get_tx_lo_locked <ch>` | `OK bool <true\|false> <locked\|unlocked>` | the clock of that channel's converter tile (the NCO runs on it): PLL locked, or with the PLL bypassed the tile's power-up state machine done -- the bring-up readback's rule. The host's `lo_locked` sensor |
| `get_rx_freq_range <ch>` | `OK <start> <stop>` | `0 fs/2` of the loaded build's converter rate (first Nyquist zone; `0 1125000000` at 2250 MS/s); `set_*_freq` clamps to it |
| `set_rx_gain <ch> <db> [at=<ticks>]` | `OK <actual db>` | ADC DSA: gain = -attenuation, range reported below; `at=` §3c |
| `get_rx_gain <ch>` / `get_rx_gain_range <ch>` | `OK <db>` / `OK <min> <max> <step>` | |
| `set_rx_antenna <ch> <name>` / `get_rx_antenna <ch>` | `OK <name>` | one port per channel, `RX` (`TX` for `set_tx_antenna`); the usual USRP names select it too -- `RX1 RX2 TX/RX RX/TX TRX IN RF A` (TX: `TX1 TX2 TX/RX RX/TX TRX OUT RF A`), case-insensitive -- and the reply names the real port |
| `set_tx_freq`, `get_tx_freq`, `get_tx_dsp_freq`, `get_tx_freq_range`, `set_tx_rate`, `get_tx_rate`, `get_tx_rates`, `set_tx_gain`, `get_tx_gain`, `get_tx_gain_range` | as RX | DAC NCO / VOP. `set_tx_rate` is the same operation as `set_rx_rate` (one converter factor for both directions). TX folds the DSP part with UHD's TX sign (§3b) |
| `set_time <ticks> [at=<ticks>]` | `OK` | set the FPGA timekeeper now (ticks of the loaded build's tick rate); `at=`: the timekeeper reads `<ticks>` at the instant it reaches `at=` (§3c; the host's emulated PPS edge) |
| `get_time` | `OK <ticks>` | read the FPGA timekeeper |
| `stream_setup <ch> <host_ip> <host_mac> <port_base> <nports> <spp> [pattern=0\|1] [otw=<fmt>]` | `OK <spp> <nports>` | programme the FPGA headers; `host_mac` as `aa:bb:cc:dd:ee:ff`; options in any order; `otw` §10 (default `sc16`), `spp` coerced to that format's granule |
| `stream_cmd <ch> <mode> <num_samps> <now> <time_ticks> [cont=0\|1]` | `OK` \| `OK cont` | `mode` ∈ `start_cont`, `stop_cont`, `num_done`, `num_more`; `now` 0/1. Commands are queued and run in order (§4a). `cont=1`: the host means it as the continuation of its open `num_more` chain; the reply `OK cont` says it joined the chain (no new SOB), plain `OK` that it is a burst of its own |
| `get_sensor <name>` | `OK <type> <value> <unit>` | `type` ∈ `bool`,`real`,`int`,`string`; names from `list_sensors`. A sensor that cannot be read answers a value, not `ERR`: `string n/a -` (e.g. `temp`/`pl_temp` without the AMS sysmon), so a client listing every sensor never aborts |
| `list_sensors` | `OK name1 name2 ...` | at least `cmac_aligned`, `adc_pll_locked`, `dac_pll_locked`, `ref_locked`, `temp`, `pps_present` (`bool false absent`: no build wires a PPS input to the timekeeper), `mts_locked` (multi-tile sync locked at bring-up and the MTS MMCM still locked; a hardware daemon that could not lock MTS does not serve) |
| `get_clock_sources` / `set_clock_source <s>` / `get_clock_source` | `OK ...` | `internal` (CLK104 TCXO), `external` (CLK104 REF IN) |
| `get_time_sources` / `set_time_source <s>` / `get_time_source` | `OK ...` | `internal` only today |
| `get_bf`, `set_bf_enable <0\|1>`, `set_bf_params <carrier_hz> <spacing_m>`, `set_bf_angle <deg>`, `set_bf_weights <re0> <im0> ...` | §11 | TX beamformer of the N >= 2 builds; `ERR` on N = 1 |
| `get_rbf`, `set_rbf_enable <0\|1>`, `set_rbf_params <carrier_hz> <spacing_m>`, `set_rbf_angle <deg>`, `set_rbf_weights <re0> <im0> ...`, `set_rbf_shift <0..15>` | §11 | RX beamformer of the N >= 2 builds that carry it (`info rbf=1`); `ERR` otherwise |
| `stats` | `OK key=value;...` | FPGA counters: `pkts=`, `overflows=`, `fifo_hwm=`, `cmac_aligned=`, `cmac_tx_pkts=`, the player's as `tx_<name>=` (`tx_underflows=`, `tx_untimed_starts_gated=`, `tx_untimed_gate_timeouts=` ...) |

### 3b. Tune requests: RF part + DSP part in one NCO

A UHD tune request has an RF part (the frontend's LO, `rf_fe/freq/value`)
and a DSP part (the DDC/DUC CORDIC offset, `dsps/<i>/freq/value`). The RFDC
has ONE mixer per channel, the fine NCO, so the daemon keeps both parts per
channel and programs the NCO to the frequency they make together, with the
signs of UHD's tune helper (`multi_usrp.cpp: tune_xx_subdev_and_dsp`):

    RX: NCO centre = rf - dsp            TX: NCO centre = rf + dsp

* `set_<rx|tx>_freq <ch> <rf> dsp=<dsp>` replies `OK <rf> <dsp>` with the
  parts in effect: rf clamped to the frontend range `0 .. fs/2`; dsp clipped
  to `±rate/2` (the host's `dsps/<i>/freq/range`); the centre clamped to
  `0 .. fs/2` (first Nyquist zone, as always) and put on the NCO's 48-bit
  grid. The dsp reported back is whatever makes `rf ∓ dsp` equal the centre
  actually programmed, so UHD's `get_rx_freq()` (= rf - dsp) / `get_tx_freq()`
  (= rf + dsp) and the tune result report the frequency the converter really
  mixes to. Without `dsp=` the request is the old one: dsp = 0, rf IS the NCO
  frequency, one reply token.
* `get_<dir>_freq` returns rf, `get_<dir>_dsp_freq` dsp. Both survive a
  reload like the NCO (§8).
* A UHD `tune_request_t(f, lo_off)` therefore gives rf = f + lo_off, dsp =
  lo_off (RX) / -lo_off (TX), NCO = f; with lo_off beyond ±rate/2 the DSP
  part is clipped, as on a USRP.

### 3c. Timed commands (UHD `set_command_time`)

`set_*_freq`, `set_*_gain` and `set_time` take `at=<ticks>`. The daemon
answers at once (for tunes and gains with the value that WILL be in effect)
and applies the request when the FPGA timekeeper reaches `<ticks>`:

* **Timing source and accuracy.** A daemon thread reads the timekeeper
  (`get_time`) and sleeps on the PS clock, re-reading the FPGA time as the
  moment approaches; it fires typically 0.1-1 ms after `<ticks>` (Python on the
  A53, then the AXI writes). The update itself is NOT sample-synchronous --
  nothing in the fabric times it. A time already past executes at once.
* **Grouping.** Every request with the same `<ticks>` is one group, executed
  together: a `set_time` first (written as `<value> + (time now - <ticks>)`, so
  the timekeeper reads `<value>` AT `<ticks>` to within the AXI write latency),
  then the tunes of each direction as ONE NCO batch (all NCOs, then the phase
  reset and update events of §3d), then the gains. A multi-channel
  `set_command_time()` + per-channel tune loop thus retunes all channels in one
  batch.
* Untimed requests do not wait for pending timed ones. Pending timed requests
  are dropped when their time base goes away: an FPGA reload (`set_channels`,
  a rate change) and the release of the claim.
* The host sends `at=` while a command time is set (`set_command_time`), and
  emulates `set_time_next_pps(t)` as `set_time t at=<next whole second of
  device time>` (there is no PPS input, `pps_present` = false).

### 3d. NCO phase after a tune (multi-channel coherence)

The §11 TX and RX beamformers' weights -- and any host-side combining -- assume a
FIXED phase between channels. Two NCOs at the same frequency started at
different instants differ by an arbitrary phase, so after NCOs change the
hardware daemon resets the NCO phase accumulators of a direction TOGETHER:
`XRFdc_ResetNCOPhase` on every block, then ONE `XRFdc_UpdateEvent(EVENT_MIXER)`
per tile (the mixers' event source is the tile event, `EVNT_SRC_TILE`, so one
event applies all four blocks of a tile on the same clock edge). After every
tune the channels of one tile (N <= 4) restart in phase.

* Daemon option `--nco-phase-reset all|tuned|off` (default `all`): every
  streamed channel of the direction (so a per-channel tune loop leaves all
  channels reset together by its last tune), only the channels of the batch,
  or never. Done after every NCO change (single tunes, §3c batches, the
  bring-up) for RX (ADC) and TX (DAC) separately.
* Across tiles (N = 8, 16) the per-tile events are software writes
  microseconds apart: the inter-tile phase is NOT deterministic. That needs
  SYSREF-timed update events. The daemon locks multi-tile sync at every
  bring-up (sensor `mts_locked`), which aligns the tiles' data latency, but
  the NCO update events are still per-tile software writes.
* Guarded: a driver without `ResetNCOPhase` disables the reset (logged once);
  any other failure is logged and the tune stands. Not verified on hardware
  yet (no board access when written); the software device has no phase.

## 4. Data plane (UDP, FPGA → host)

Each sample packet is one Ethernet frame, Ethernet II / IPv4 (no options,
DF set, TTL 64, header checksum valid) / UDP (checksum 0):

```
src   <fpga ip>:49800   dst   <host ip>:(port_base + k)
k = packet_index mod nports      (round-robin across nports host ports = NIC RX queues)
```

udp_streamer keeps its port counter k across stream setups, so the daemon
brings it back to 0 at every `stream_setup`: it first sends one 16-slot sc16
packet with NPORTS = 1 to UDP port 9 (discard) of the host, which wraps k.
Every stream's first packet therefore goes to `port_base`.

UDP payload = one VITA-49-style IF data packet, **all 32-bit words little-
endian** (parse with `uhd::transport::vrt::if_hdr_unpack_le`):

| word | contents |
|---|---|
| 0 | `[31:29]=0` IF data w/ SID · `[28]=1` SID present · `[27]=0` · `[26]=0` no trailer · `[25]` SOB · `[24]` EOB · `[23:22]=0` no TSI · `[21:20]=1` TSF present (VITA "sample count" type; the unit is ticks, see below) · `[19:16]` packet count mod 16 · `[15:0]` packet length in 32-bit words (= 4 + spp) |
| 1 | stream ID = `0x5A160000 | ch` |
| 2 | TSF high 32 bits |
| 3 | TSF low 32 bits — timestamp of the FIRST sample in the packet, in ticks of the loaded build's tick rate (§8; one tick per slot); slot k of the packet is at `TSF + k` |
| 4.. | `spp` samples, each one 32-bit word = int16 I (bytes 0-1, LE) then int16 Q (bytes 2-3, LE) — i.e. `std::complex<int16_t>` / UHD `sc16` wire format "sc16_chdr" |

* `spp` defaults to 2048 (8 192 B of samples, 8 208 B UDP payload, 8 250 B
  frame) and is a multiple of 16 (the FPGA packs four 128-bit ADC beats into
  one 512-bit CMAC word); the last packet of a `num_done` burst may be
  shorter (still a multiple of 16) and carries EOB.
* **TSF units.** The TSF and every `time_ticks`/`set_time`/`get_time` value
  count ticks of the LOADED build's `tick_rate` (`info tick_rate=`, also in the
  `set_channels` / `set_rx_rate` replies). Every build counts one tick per
  32-bit slot (TICK_STEP = 1): tick_rate = N x per-channel rate, and a
  sample spans `tps = N` ticks (§9). On a 1-channel build the TSF is the
  sample count.
* Granularity: the FPGA works in 16-sample units. A `num_done` burst is
  rounded UP to a multiple of 16 samples and a timed start begins at the
  fabric beat (`beat_slots` ticks, §9) containing the requested time. The host
  module trims: it drops the leading `(requested_time - TSF) / tps` samples
  of the first packet and anything beyond the requested count, so the
  application sees exactly what it asked for.
* The TSF is a free-running 64-bit tick counter; a packet whose TSF ≠
  previous TSF + previous spp × tps means samples were dropped (the FPGA
  dropped them on overflow, or the host missed packets). The host reports
  that as `ERROR_CODE_OVERFLOW` and resyncs; it is the ONLY loss indicator —
  the 4-bit count only disambiguates reordering.
* SOB is set on the first packet after a stream command starts streaming
  (§4a: one per FPGA command; a joined `num_more` continuation has none).
* With `nports > 1`, packets of one stream are spread across ports and can
  be reordered between them; the host orders them by TSF.

### 4a. RX stream commands: queue, late commands, num_more chains

The FPGA streamer (`hw_design/ip_design/uhd_ip/src/udp_streamer.v`) holds ONE command: a start while it
is armed or streaming is rejected, a finite burst returns it to idle, a late
timed start begins at once. The daemon gives it a USRP's command semantics
(`server/rx_cmdq.py`, the same code in the software device and the host
emulator):

* **FIFO.** Commands run in arrival order. The next one is issued when the
  streamer is idle; a timed one is armed then and starts on the beat that
  contains its time. Issuing takes the daemon's poll latency (~1 ms): timed
  commands meant back to back must be at least a few ms apart, or the later
  one is late.
* **stop_cont** clears the queue and stops the streamer at once.
* **start_cont** runs until `stop_cont` or the next start command: once it has
  produced at least one packet (so the host has seen its SOB), it is stopped
  and the next command issued.
* **Late commands.** A timed command whose time has passed when it is issued
  (time ≥ its beat + one beat) is not streamed: the daemon issues a one-granule
  `num_done` NOW instead (a "late marker"). The host sees a burst whose SOB
  TSF is later than the beat-floored requested time -- exactly what the RTL
  produces for a late start -- reports `ERROR_CODE_LATE_COMMAND` with no
  samples (`time_spec` = that TSF) and drops the burst to its EOB.
* **num_more chains.** `num_more` followed by continuations: commands the host
  flags `cont=1` -- stream_now, or timed at exactly the chain's end (known when
  the chain head was timed). The FPGA cannot extend a finite burst, so an OPEN
  chain (last link `num_more`) streams as `start_cont`, and the daemon stops it
  once the stream has passed the chain's end plus a grace (`--chain-grace-ms`,
  default 1 ms; the host trims the excess). A continuation that arrives before
  that joins the chain (reply `OK cont`): no new SOB, the samples continue
  seamlessly. Links queued before the chain is issued are merged into ONE FPGA
  command (`num_done` of the sum when the chain ends in `num_done`: an exact
  burst with EOB). A continuation that arrives later is a burst of its own
  (reply `OK`, a new SOB after the chain's end). A `cont=0` start command
  closes an open chain (it still ends at its end; the new command runs next).
* **Host side** (`zcu216_rx_streamer.cpp`): every accepted command is a pending
  burst, in order; a joined one continues the current burst. A `num_more`
  count is delivered exactly (no EOB); at its end the next pending command
  continues the stream if it joined, otherwise `ERROR_CODE_BROKEN_CHAIN` is
  reported on the next `recv()` (no samples) when no command followed or the
  one that followed was meant as a continuation but came too late. A
  deliberately separate (timed) command after a chain is no error, as on a
  USRP. Packets after a chain's end are discarded up to the next SOB.
* An FPGA burst whose SOB packet is lost (overflow) cannot be matched to its
  command; the host's bookkeeping then drifts until the next `stop_cont`. This
  was already so before the queue.

## 5. Test pattern

`stream_setup` accepts an optional 7th argument `pattern=1` which makes the
FPGA replace ADC samples by a counter keyed to the sample's TIMESTAMP: the
sample whose timestamp is `t` (packet TSF + index in packet × tps, §4) is
`I = (t & 0xFFFF) as int16`, `Q = ~I` (bitwise NOT of the 16-bit I): I steps
by one per slot. Keyed to
the timestamp, not to a per-stream count, so a dropped packet cannot
desynchronise the check. Every byte of every packet can then
be checked on the host independent of the (possibly broken) ADC clock — see
CLAUDE.md: zcu216-0's ADC reference clock was dead as of 2026-09-01.

## 6. Data plane, host → FPGA (TX, DAC)

The host sends sample packets as UDP datagrams to `<fpga data ip>:49900`
(`tx_port`, fixed) from any source port. The FPGA answers ARP requests for its
data IP, so ordinary kernel sockets work (no static neighbour entry needed).

UDP payload: the SAME 4-word little-endian VRT-style header as §4, then samples.
The header is ALWAYS 4 words, TSF words included, even for an untimed packet
(`[21:20]=0`): pack it by hand — `vrt::if_hdr_pack_le` would drop the TSF
words and the FPGA would count the packet as malformed.


| word | contents |
|---|---|
| 0 | `[31:28]=0x1` · `[25]` SOB · `[24]` EOB · `[21:20]` = 1 if the packet carries a start time (only honoured on the first packet of a burst), 0 = play as soon as possible · `[19:16]` packet count mod 16 (the FPGA checks continuity) · `[15:0]` packet length in words = 4 + nsamps |
| 1 | stream ID = `0x5A170000 | ch` |
| 2, 3 | TSF hi, lo: start time of the burst in ticks (any value if `[21:20]=0`) |
| 4.. | nsamps samples, sc16 LE, I then Q — same as §4 |

* `nsamps` must be a multiple of 16, 16..2048. The host pads the last packet
  of a burst with zeros up to a multiple of 16 (an empty EOB = 16 zeros).
* The FPGA holds at most 2040 packets in flight regardless of size, so
  packets below ~144 samples can exhaust that before the word credit.
* The FPGA ignores UDP to any other port (the host may send a one-byte probe
  to port 9 to prime ARP).
* A burst is the packets from one with SOB up to one with EOB. After EOB the DAC
  outputs zeros. Samples inside a burst play back-to-back at the sample rate
  (tps ticks apart, §4); a timed burst starts on the fabric beat
  (`beat_slots` ticks, §9) containing its TSF.
* An untimed burst does not start on its first packet: the FPGA holds it until
  4096 words (256 KiB; at most half of `tx_buf_words`) are buffered, its EOB
  packet has arrived, or 100 us have passed, then plays it back-to-back. At
  full rate the host refills barely faster than the DAC drains (a packet plays
  in hardly more time than it takes on the wire), so a burst started on its
  first packet underflowed within a few packets. udp_player registers:
  `0x78 USTART` (words; 0 = gate off), `0x7C UTIMEOUT` (tx_clk cycles; 0 = no
  limit), `0x80 UGATED` / `0x84 UTIMEOUTS` (RO: starts the gate held / of
  them released by the timeout). The daemon writes USTART = min(4096,
  tx_buf_words / 2) and UTIMEOUT = 32227 (100 us at 322.27 MHz) at
  `stream_setup_tx`.

### Flow control

The FPGA buffers TX samples in `tx_buf_words` 64-byte words (`info
tx_buf_words=`). The host may have at most that many words **sent but not
yet consumed** (one packet of nsamps occupies nsamps/16 words). The FPGA
reports consumption in every async status packet (§7), and sends one at least
every `fc_interval` consumed words (`info fc_interval=`; the daemon programs
512 words = 32 KiB, 1/8 of the buffer if that is smaller, overridable with
`ZCU216_FC_INTERVAL` in the daemon's environment) while a burst plays, so the
host always has fresh credit. Every build has a 2 MiB URAM buffer:
`tx_buf_words` = 32752. Behind it udp_player's play-out chain (8 x 4096
block-RAM words, 2 MiB, credited back as the mover fills it) and a 32 KiB
crossing FIFO: about 4 MiB of samples in all (~350 us at 96 Gb/s) against
host stalls; the credit counts the URAM only.

## 7. Async status, FPGA → host

Sent from `<fpga data ip>:49801` to `<host ip>:<async_port>` (from
`stream_setup_tx`, default port_base + 16 = 49826), UDP payload of 6
little-endian 32-bit words:

| word | contents |
|---|---|
| 0 | `0x5A17A5C0` magic |
| 1 | stream ID `0x5A170000 | ch` |
| 2, 3 | TSF hi, lo: FPGA time when the event happened |
| 4 | event code, UHD `async_metadata_t::event_code_t` values: `0x1` burst ACK (EOB played out), `0x2` underflow, `0x4` sequence error (bad packet count), `0x8` time error (late start), `0x10` underflow in packet, `0x20` sequence error in burst, `0x0` = flow-control update only |
| 5 | consumed words: free-running, monotonic 32-bit count of 64-byte TX words retired from the buffer (played, flushed, or belonging to a packet the FPGA dropped). It never resets except at FPGA reset; take the baseline from the `stream_setup_tx` reply |

(Host side: the module steers `<host ip>:<async_port>` into a DPDK queue of
the 100G port, polled by its TX lcore, so status packets never reach the
kernel; nothing changes for the FPGA. One stream carries every channel, so the
FPGA reports each event once; `recv_async_msg()` returns it once per channel
of the TX streamer, `md.channel` = the channel's index in the streamer, as a
multi-channel USRP does.)

Control commands for TX:

| command | reply | meaning |
|---|---|---|
| `stream_setup_tx <ch> <host_ip> <host_mac> <async_port> [otw=<fmt>]` | `OK <tx_buf_words> <fc_interval> <consumed_baseline>` | program the async/FC destination, switch the DAC source to the UDP player; `consumed_baseline` is the current value of the monotonic consumed-word count (in-flight = sent − (consumed − baseline)). `tx_buf_words` = 32752 on every build |
| `stream_stop_tx <ch>` | `OK` | flush the TX buffer, DAC back to zeros (the player stays the DAC source: no build has a DRAM/DMA DAC path any more) |

## 8. Sample-rate variants (one bitstream per rate)

The RFDC decimation/interpolation factor F is compiled into the block design;
it is never a run-time setting (`hw_design/ZCU216/CLAUDE.md`). Each sample
rate is therefore a separate bitstream, all with the same register map and
the same 100G path. Names: `zcu216_v49_<N>ch_qsfp_f<F>[_fs<fs>].bit` (+
`.hwh`), `_fs<fs>` when the converter rate fs (MS/s, ADC = DAC, every tile)
is not 2400. Per-channel rate = fs / F (§9). The board needs
`rfsoc_lib/xrfclk/ZCU216/LMX2594_250.0_<fs>.0.txt` for each fs it serves
(`server/deploy.sh` checks).

* The daemon scans `--bitstream-dir` for `zcu216_v49_<N>ch_qsfp*.bit` with a
  `.hwh` next to it and reads from each `.hwh`: fs, F and the fabric clock (every
  enabled slice; `Fabric_Freq = fs / F / (Data_Width/2)` must hold, and
  decimation must equal interpolation), the fabric beat (N x Data_Width/2
  slots = udp_streamer `S_WIDTH`), udp_streamer/udp_player `TICK_STEP`, the
  TX buffer and the `tx_beamformer`. `get_rx_rates`/`get_tx_rates`/`info
  rx_rates=` list the rates of the loaded N. Only the files present count.
* **Tick rate per build** = aggregate slot rate x TICK_STEP, TICK_STEP read
  from the `.hwh` (1 on every build): N x the per-channel rate, so two builds
  of one N tick differently. `set_channels` and `set_rx_rate` reply with the
  new tick rate and `info` has it; a host re-reads it after either.
* **Rate selection.** A requested rate is met from below: the highest
  installed rate of this N at or below the request (1 ppm tolerance), among
  the builds that carry the client's formats (§10); below every one of them,
  the lowest. So the bandwidth never exceeds what the client asked for.
* RX and TX run at the same rate (one factor, one AXIS clock). Setting either
  sets both; the reply is the rate now in effect.
* A rate whose build cannot carry the client's OTW format (§10: link
  capacity) is not chosen; if no build of this N carries it, the request is
  refused before anything is reloaded (§3). The sc8max builds (§9) are chosen
  only with `otw=sc8`.
* `set_rx_rate`/`set_tx_rate` to another build's rate **reloads the FPGA**:
  streaming (RX and TX) stops, the overlay is loaded and the whole bring-up is
  redone (RFDC with that bitstream's compiled geometry and its readbacks; the
  8A34001 is programmed only if its status says it is unconfigured; GT reset
  and wait for CMAC alignment; FPGA MAC/IP; the UDP player as DAC source). It
  takes seconds (overlay download, RFDC tile power-up, CMAC alignment, then a
  4 s wait for the far-end NIC to relink, `ZCU216_RELOAD_SETTLE_S`); give
  this one request a control timeout of 60 s. UHD applications set the rate
  before streaming, which is when this is meant to happen. If the new build
  fails to come up the daemon reloads the previous one and replies
  `ERR ... restored`.
* Carried across a reload: RX/TX NCO frequencies (and the DSP parts of
  §3b), gains the client set, the
  last `stream_setup` (so `stream_cmd` works without a new setup) and
  `stream_setup_tx` (each with its `otw`), the FPGA MAC/IP, the TX and RX
  beamformer state (§11). **Not** carried: a running stream (it is stopped; issue a new
  `stream_cmd`), and the TX flow-control baseline -- the reloaded FPGA's
  consumed-word count starts again at 0, so a host that had called
  `stream_setup_tx` before the rate change must call it again and take the
  new baseline from its reply.
* Timekeeper after a reload: set to 0, unless some client had called
  `set_time` since the daemon started; then it continues from where it was
  plus the wall-clock time the reload took, converted to the new build's tick
  rate (the carry-over is only ~ms-accurate: re-issue `set_time` after a rate
  change when alignment matters).

## 9. Multi-channel builds (N = 1, 2, 4, 8, 16)

Each channel count is its own set of bitstreams (the RFDC factor and the
number of enabled converter streams are block-design parameters). All N
channels share ONE stream in each direction: the aggregate converter rate is
split evenly and the channels are phase-aligned (MTS), like a multi-channel
USRP.

The builds (`hw_design/ZCU216/block_designs/zcu216_v49_qsfp/zcu216_v49_qsfp.tcl` `v49_geometry`, built
by `make v49-ladder`; the full list with rates and wire formats is
`benchmark/oracle_builds.txt`). Every build: the 2 MiB + 2 MiB TX buffer of §6,
§10 converters, no DRAM path; N >= 2: §11 TX and RX beamformers.

| family | N | fs (MS/s) | factors F | per-channel rate fs/F | Data_Width | fabric beat | fabric clock fs/F/(DW/2) | tick_rate | wire formats |
|---|---|---|---|---|---|---|---|---|---|
| normal | 1 | 2500 | 2 3 4 5 6 8 10 12 16 20 24 40 | 1250 .. 62.5 MS/s | 8 | 128 b | 312.5 .. 15.6 MHz | 1.25 .. 0.0625 GHz | sc16 sc12 sc8 fc32 |
| normal | 2 | 2500 | 2 3 4 5 6 8 10 12 16 20 24 40 | 1250 .. 62.5 MS/s | 8 | 256 b | 312.5 .. 15.6 MHz | 2.5 .. 0.125 GHz | sc16 sc12 sc8; fc32 at F >= 4 |
| normal | 4 | 2250 | 3 4 5 6 8 10 12 16 20 24 40 | 750 .. 56.25 MS/s | 8 | 512 b | 187.5 .. 14.1 MHz | 3.0 .. 0.225 GHz | sc16 sc12 sc8 (TX fc32 at F >= 6) |
| normal | 8 | 2250 | 6 8 10 12 16 20 24 40 | 375 .. 56.25 MS/s | 4 | 512 b | 187.5 .. 28.1 MHz | 3.0 .. 0.45 GHz | sc16 sc12 sc8 (TX fc32 at F >= 12) |
| normal | 16 | 2250 | 12 16 20 24 40 | 187.5 .. 56.25 MS/s | 2 | 512 b | 187.5 .. 56.3 MHz | 3.0 .. 0.9 GHz | sc16 sc12 sc8 (TX fc32 at F >= 24) |
| sc8max | 4 | 2500 | 2 | 1250 MS/s | 8 | 512 b | 312.5 MHz | 5.0 GHz | sc8 only |
| sc8max | 8 | 2250 | 3 | 750 MS/s | 8 | 1024 b | 187.5 MHz | 6.0 GHz | sc8 only |
| sc8max | 16 | 2250 | 6 | 375 MS/s | 4 | 1024 b | 187.5 MHz | 6.0 GHz | sc8 only |

* **Wire formats** are those whose aggregate N x rate x bytes/slot fits the
  100GbE payload (12.38 GB/s, §10), except RX fc32, which no 512-bit-beat
  build (every 4, 8 and 16-channel build) streams. The duplex formats are
  what `info rate_otw=` reports.
* **default** (what `set_channels N` loads) is the normal family's highest
  rate, F2 at 1 and 2 channels, F3 / F6 / F12 at 4 / 8 / 16: 3.0 GS/s
  aggregate at 4-16 channels, 96 Gb/s of sc16, 97 % of the link. The sc8max
  builds stream sc8 only, at twice the normal maximum per channel at 8 and 16
  channels (6.0 GS/s, 96 Gb/s of sc8) and at 1250 MS/s at 4 channels
  (5.0 GS/s, 80 Gb/s; 2x would be 1500 MS/s, beyond a 2.5 GS/s ADC at its
  minimum factor 2). Their 1024-bit beat (8 and 16 channels) is exactly one
  sc8 wire word: the FPGA moves one per clock and converts no other format
  (§10).
* Each (N, rate) is served by one file (a second one is skipped with a
  warning).

Channel c (0-based) is RFDC ADC/DAC tile c/4, block c%4 (N=8 uses tiles 0-1,
N=16 all four tiles), the same mapping as hw_design/ZCU216/CLAUDE.md.

**Slots.** The payload is a sequence of 32-bit *slots* (sc16, I then Q, LE as
in §4; other widths per §10), interleaved sample-major: slot `i` of a packet
is channel `c = i % N`, sample `s = i / N`. `spp` counts slots (a multiple of
the §10 granule and of N), so a packet carries `spp / N` samples of every
channel. VRT word 0 `[15:0]` = 4 + payload words. SID = `0x5A160000` (RX) /
`0x5A170000` (TX) — one stream, all channels.

**Time.** On N > 1 builds one tick = one slot time: tick_rate = N x
per-channel rate, the build's own (table above; `info tick_rate=`). TSF is the
tick of the packet's first slot (channel 0, sample 0); channel c sample s of
the packet is at tick `TSF + s*N` (all channels of a sample share its time;
the `+c` offset exists only in the slot numbering). A fabric beat carries
`beat_slots` slots (`info beat_slots=`: N x Data_Width/2) and advances the
timekeeper by that many ticks; a timed start begins on the beat containing
the requested tick.

**Test pattern (§5) with channels.** Slot i carries `I = (TSF + i) & 0xFFFF`,
`Q = ~I` — i.e. channel c of the sample at tick t has `I = t + c`. One check
verifies timing, channel order and loss together.

**Granularity.** RX `num_done` counts samples PER CHANNEL on the host side;
the FPGA counts slots (the §10 granule) — the host requests `num_samps * N`
slots (rounded up) and trims. TX: packets carry whole samples (all N
channels), `spp` a multiple of the granule and N.

**Control.** `info` reports `num_rx=N num_tx=N`, `tick_rate=`, per-channel
`rx_rates=` (this N's only) with their `tick_rates=` and `rate_otw=`, and
`channel_counts=`. Per-channel commands (`set_rx_freq <ch>`, gains, NCOs)
address each converter; stream commands (`stream_setup`, `stream_cmd`,
`stream_setup_tx`, `stream_stop_tx`) accept any valid `<ch>` and ignore it
(one stream for all channels). The host module picks the build with device
arg `channels=N` (default 1) and sends `set_channels N` after `claim`; the
daemon loads N's default build if another N is loaded, or if this N is loaded
at a rate the client's current otw cannot carry (an sc8-only build left by an
earlier client; the current otw is sc16 after `claim`). Reload rules of §8:
NCOs and client-set gains are restored per channel for every channel the new
build has; a channel never tuned gets the daemon's initial frequency; a
timekeeper carried over is converted to the new tick rate; a stream setup
whose format the new build cannot carry is dropped. Rate changes are only
offered within the same N. Bitstreams are found as
`zcu216_v49_<N>ch_qsfp*.bit`; N is taken from the name and the `.hwh` must
enable the ADC and DAC slices of channels 0..N-1.

## 10. Over-the-wire (OTW) sample formats — converted in the FPGA

The FPGA converts between the converters' native int16 (sc16) samples and the
wire format, so the host CPU does no per-sample work when the application's
CPU format equals the OTW format (or only UHD's SIMD converters otherwise).
The format is chosen per stream by the host (UHD `stream_args.otw_format`) and
sent with `stream_setup` / `stream_setup_tx` as an extra token `otw=<fmt>`
(default `sc16`). FPGA registers: udp_streamer `0x78 FMT`, udp_player
`0x74 FMT` (0 sc16, 1 sc8, 2 sc12, 3 fc32); written by the daemon while idle.

| otw | bytes / slot | slots per 64-byte FIFO word | UHD converter the host uses | layout in the UDP payload | max aggregate on 100GbE |
|---|---|---|---|---|---|
| `sc16` | 4 | 16 | `sc16_chdr` | int16 I, int16 Q, little-endian (today's format) | 3.09 GS/s |
| `sc8` | 2 | 32 | `sc8_item32_be` (bytes identical to `sc8_chdr`) | int8 I0, Q0, I1, Q1, ... | 6.19 GS/s |
| `sc12` | 3 | 64 slots per 3 words | `sc12_item32_le` | UHD sc12 packing: 4 samples in 3 LE 32-bit words (`w0={I0,Q0,I1[11:4]}`, `w1={I1[3:0],Q1,I2,Q2[11:8]}`, `w2={Q2[7:0],I3,Q3}`, MSB-first fields after the LE load), 12-bit two's complement | 4.13 GS/s |
| `fc32` | 8 | 8 | memcpy (`fc32_chdr`) | float32 I, float32 Q, little-endian, normalised: value = int16 / 32768 (exact: the FPGA only adjusts the exponent) | 1.55 GS/s |

* RX (ADC → wire): sc8 = round-half-up(int16 / 256) saturated to [-128, 127]
  (keeps the 8 MSBs: ~48 dB SQNR); sc12 = round-half-up(int16 / 16) saturated
  to 12 bits (the ADC is 14-bit, so 2 LSBs are lost); fc32 exact.
* TX (wire → DAC): sc8 → int16 = v * 256; sc12 → int16 = v * 16; fc32 →
  int16 = round(v * 32768) saturated to [-32768, 32767] (NaN → 0).
* Granularity: a packet holds a whole number of 64-byte FIFO words, so `spp`
  (slots) is a multiple of 16 (sc16), 32 (sc8), 64 (sc12, = 3 words) or 8
  (fc32), and of N; the payload is at most 8192 bytes (sc12: 8064 bytes =
  2688 slots, 126 words). The daemon floors `spp` to that and caps it at
  8192 bytes (sc16 2048, sc8 4096, sc12 2688, fc32 1024 slots); `num_done` /
  `num_more` counts are rounded UP to the granule; `info spp=` stays in sc16
  slots (the payload bytes of the last setup) and returns to 2048 when the
  claim is released.
* The daemon refuses (`ERR otw=<fmt>: ... exceeds the 100GbE payload
  capacity 12.38 GB/s`) a format whose aggregate wire rate, N × per-channel
  rate × bytes/slot, exceeds the link, and one the loaded bitstream does not
  convert (it probes the FMT registers at bring-up: a bitstream from before
  §10 reads them back as 0 and offers only sc16). Every build converts all
  four formats; which it offers at its rate is this link check and the RX
  fc32 rule below (§9 table). A rate or channel change
  re-applies the stream setups with their formats.
* Timestamps, the slot interleave of §9 and flow-control credit (in 64-byte
  words) are unchanged; only the bytes per slot differ.
* fc32 details (as implemented): TX rounds half-to-even when converting
  v * 32768 to int16; a TX fc32 end-of-burst packet that ends on half a
  16-slot group is padded by the FPGA with 8 zero slots. RX fc32 is not
  supported on 512-bit-beat builds (every 4, 8 and 16-channel build): the
  streamer would need two FIFO words per clock and drops every packet. The
  daemon refuses the combination even where the link would carry it (e.g.
  4ch at 281.25 MS/s); TX fc32 works there.
* 1024-bit-beat builds (sc8max 8ch / 16ch, §9) carry **sc8 only**, both
  directions: one beat (32 slots) is one sc8 wire word per clock. With any
  other FMT the streamer drops (and counts) every packet and the player plays
  nothing; the daemon refuses those formats (`info otw_formats=sc8`).
* Test pattern (§5) is generated in sc16 before the conversion, so a
  pattern stream checks the converter too: the host compares against the
  pattern passed through the same rounding.
* Reference implementation of both directions: `server/vrt.py`
  (`sc16_to_wire`, `wire_to_sc16`, `pack_sc12`), used by the software device,
  the host emulator and `host/tools/check_pattern_file.py --otw`.
* Host side (UHD `stream_args.otw_format`, e.g. `rx_samples_to_file
  --wirefmt sc8`, `benchmark_rate --rx_otw sc12`): fc32/fc64 full scale is
  ±1.0 in every format (RX scalars 1/32767 sc16, 1/128 sc8, 1/2048 sc12, 1
  fc32), sc16 keeps the converters' int16 scale (RX sc8 → v·256, sc12 → v·16,
  fc32 → round(f·32768); TX the inverse with the RX rounding above), and CPU
  `sc8` works with otw `sc8` only (a copy). See `host/lib/zcu216_otw.hpp`.

## 11. TX and RX beamforming (N >= 2 builds)

Two independent blocks, each with its own register file, daemon commands, UHD
tree nodes and user-register map. Both use Q1.15 complex weights (int16 real
in bits 15:0, int16 imaginary in bits 31:16) and the same steering rule, so the
weights of one angle steer TX and RX the same way (by reciprocity the
propagation phase of element c is the same in both directions; neither block
conjugates).

### TX beamformer: `eth100g/tx_beamformer` (every N >= 2 build)

Between the UDP player and the DACs: the v47 `user.org:user:beamformer:1.0`
datapath (per-channel complex multiply, output = round((x*w) >> 15)) inside the
wrapper `hw_design/ip_design/uhd_ip/src/tx_beamformer.v` (packaged as
`user.org:uhd:tx_beamformer:1.0`), AXI-Lite at 0x8006_0000:

| reg | access | meaning |
|---|---|---|
| 0x00 ID | RO | 0x5A423031 ('ZB01') |
| 0x04 CTRL | RW | [0] enable: 0 = bit-exact bypass (normal N-channel TX); 1 = beamform: TX channel 0 is fanned out to all N DACs, DAC c gets ch0 x w[c] (channels 1..N-1 of the TX stream are ignored) |
| 0x08 NCH | RO | N |
| 0x0C LOAD | WO | write 1: apply W[0..N-1] to the datapath atomically (between samples) |
| 0x40 + 4c | RW | W[c], c = 0..N-1, Q1.15; reset 0x00007FFF |

### RX beamformer: `eth100g/rx_beamformer` (N >= 2 builds that carry it)

Between the RF-ADCs and the RX channel interleave in front of udp_streamer:
`hw_design/ip_design/uhd_ip/src/rx_beamformer.v` (packaged as
`user.org:uhd:rx_beamformer:1.0`), AXI-Lite at 0x8007_0000. Every N = 2, 4,
8, 16 build has it; the N = 1 builds have none (`info rbf=0`). The daemon detects it from the build's `.hwh`
(module `rx_beamformer`, `N_CH` = N), never from the address.

| reg | access | meaning |
|---|---|---|
| 0x00 ID | RO | 0x5A523031 ('ZR01') |
| 0x04 CTRL | RW | [0] enable: 0 = bit-exact bypass; 1 = RX channel 0 carries the beam, channels 1..N-1 their raw samples |
| 0x08 NCH | RO | N |
| 0x0C LOAD | WO | write 1: apply W[0..N-1] AND SHIFT to the datapath atomically (a beat is never split between weight sets) |
| 0x10 SHIFT | RW | [3:0] extra right shift, reset log2(N); takes effect on LOAD |
| 0x40 + 4c | RW | W[c], c = 0..N-1, Q1.15; reset 0x00007FFF |

The beam, per sample, with exact complex products and sum, per real and
imaginary part (round half up, saturated, no wrap-around):

    acc_re = sum_c I_c*wI_c - Q_c*wQ_c
    acc_im = sum_c I_c*wQ_c + Q_c*wI_c
    y      = sat16((acc + 2^(14+SHIFT)) >> (15+SHIFT))      (arithmetic shift)

With unity weights and the reset SHIFT = log2(N), N equal inputs x give
y ~= x (gain 32767/32768). The pass-through channels are delayed like the beam,
so the beam of sample k arrives next to the raw channels 1..N-1 of sample k.
`server/rx_beamformer.py` `beam_payload` is the bit-exact reference.

**Stream semantics with RX beamforming enabled:** RX channel 0 of the UHD
stream is the beam, channels 1..N-1 are the elements 1..N-1 unchanged (for
calibration next to the beam). Element 0's own samples are not delivered while
the beam is on. The §5 test pattern is inserted by udp_streamer AFTER the
beamformer, so a `pattern=1` capture is never beamformed on the FPGA (the
software device and the emulator do beamform it, so the host path can be
checked bit for bit). To check the beam on the FPGA bit for bit, use real ADC
data with w[0] = 0: the beam is then a function of the delivered channels
1..N-1 only (`host/tools/zcu216_bf.py --rx --capture`).

### Weights, state, write order

Weights follow `rfsoc_lib/dsp/beamformer.py` (uniform linear array):
`w[c] = exp(j*c*dphi)`, `dphi = -2*pi*d*sin(theta)/lambda`, quantised with
`round(x * 32767)`. Defaults: d = 1.07e-3 m, f = 135e9 Hz. TX and RX each keep
their own geometry, angle, weights (and RX SHIFT).

State (as implemented, `server/backend.py`), per beamformer: enable, geometry,
the last angle, the weights and (RX) SHIFT are kept across reloads (§8: an
angle is recomputed for the new N; raw weights of another N fall back to unity,
32767 + 0j; a SHIFT set for another N falls back to log2(N)) and reset to
bypass, unity weights, SHIFT log2(N) and the default geometry when the claim is
released. `set_bf_params` / `set_rbf_params` with an angle in effect re-steer
to it. Write order: W[0..N-1], (RX) SHIFT, then LOAD, then CTRL.

The weights steer only if the converter channels keep a fixed phase relation:
the daemon resets the NCO phases together after every tune (§3d), so within one
tile (N <= 4) the inter-channel phase is the same after every retune. Across
tiles (N = 8, 16) it is not deterministic without SYSREF-timed events (§3d):
calibrate per tune there. Every `*_bf*` command is `ERR` on a build without a
TX beamformer (N = 1), every `*_rbf*` command on a build without an RX
beamformer (`ERR no RX beamformer in <fpga> ...`).

Control commands (TCP, §3):

| command | reply | meaning |
|---|---|---|
| `get_bf` | `OK enable=<0/1>;angle_deg=<a or none>;carrier_freq=<hz>;element_spacing=<m>;weights=<re0>,<im0>,<re1>,...` | TX state |
| `set_bf_enable <0/1>` | `OK <0/1>` | TX bypass / beamform |
| `set_bf_params <carrier_hz> <spacing_m>` | `OK` | TX ULA geometry for angle steering |
| `set_bf_angle <deg>` | `OK <re0>,<im0>,...` | compute the weights with Beamformer.compute_weights_fixed_point and LOAD them |
| `set_bf_weights <re0> <im0> ... <reN-1> <imN-1>` | `OK` | raw Q1.15 weights, LOAD |
| `get_rbf` | as `get_bf`, plus `;shift=<s>` | RX state |
| `set_rbf_enable <0/1>` | `OK <0/1>` | RX bypass / beam on channel 0 |
| `set_rbf_params <carrier_hz> <spacing_m>` | `OK` | RX ULA geometry |
| `set_rbf_angle <deg>` | `OK <re0>,<im0>,...` | RX weights of that angle (the TX rule), LOAD |
| `set_rbf_weights <re0> <im0> ... <reN-1> <imN-1>` | `OK` | raw Q1.15 RX weights, LOAD |
| `set_rbf_shift <0..15>` | `OK <s>` | RX SHIFT, LOAD |

`info` reports `bf=1` on builds with the TX beamformer (`bf=0` on N = 1) and
`rbf=1` on builds with the RX beamformer (`rbf=0` otherwise; a daemon from
before it sends no `rbf` key, which the host reads as 0).

UHD API (host module, `host/README.md`). Property tree, created at `make()`
for the beamformers the loaded build has (test with `tree.exists(.../enable)`):

| node | type | meaning |
|---|---|---|
| `/mboards/0/tx_beamformer/` and its alias `/mboards/0/beamformer/` | | the TX beamformer (the alias is the name from before the RX one) |
| `/mboards/0/rx_beamformer/` | | the RX beamformer |
| `.../enable` | bool | `set_*_enable` / `get_*` |
| `.../angle_deg` | double (NaN = raw weights, no angle) | `set_*_angle` |
| `.../carrier_freq`, `.../element_spacing` | double (Hz, m) | `set_*_params` |
| `.../weights` | `std::vector<std::complex<double>>`, Q1.15 / 32767 | `set_*_weights` (quantised round(x * 32767), saturated); length N |
| `.../weights_q15` | `std::vector<int>` re0, im0, ... (read-only) | |
| `.../weights_str` | string "re0,im0,re1,..." (read-only; Python's tree bindings read only bool/int/double/string) | |
| `/mboards/0/rx_beamformer/shift` | int 0..15 | `set_rbf_shift` |

The standard `multi_usrp::set_user_register(addr, value)` (usable from
Python) writes the user-register map below; UHD 4.6's multi_usrp has no
`get_user_register`: the same map reads back through
`get_user_settings_iface(chan)->peek32(addr)` (C++) or, from Python, the tree
nodes.

| TX addr | RX addr | write | peek32 |
|---|---|---|---|
| 0 | 64 | enable (bit 0) | enable |
| 1 | 65 | steering angle in millidegrees (int32, two's complement): computes and LOADs the weights | angle (0x80000000 = none) |
| 2 | 66 | carrier frequency in kHz | carrier kHz |
| 3 | 67 | element spacing in nanometres | spacing nm |
| -- | 68 | SHIFT 0..15 | SHIFT |
| 15 | 79 | anything: LOAD the staged raw weights | N |
| 16 + c | 80 + c | raw weight c (int16 real \| int16 imag << 16), staged until LOAD (c < N, N <= 16) | W[c] |

Any other address is refused (`uhd::value_error`); an address of a
beamformer the loaded build does not have raises `uhd::not_implemented_error`
naming it (`... has no RX beamformer ... info rbf=0`).
