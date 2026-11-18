# The low-rate chains: FIR Compiler lanes and arithmetic

The contract between `src/rx_rate.v` / `src/tx_rate.v`, their FIR Compiler
stages (`rate_sr_cfg`, verbatim in every block design and in
`sim/rate_fir_ip.tcl`) and the bit-exact model `sim/check_rate.py`. Measured
with FIR Compiler 7.2 (rev 16, Vivado 2021.1) in behavioural simulation.

## The filter

One half-band for every stage and both directions: `rate_hb.coe`, 63 taps
(J = 16), 18-bit integers = coefficient x 2^17, centre 65536 (made and checked
by `design_hb.py`): passband 0.4 x the output rate, ripple 0.0006 dB;
stopband from 0.6 x the output rate, 87.9 dB after quantisation.

Every stage is polyphase. The FIR Compiler core runs only the odd branch
g = h[0::2] (2J = 32 taps, symmetric), single rate; the hub adds the centre
tap (65536 = 2^16, the only non-zero tap of the other branch) as a delay:

    RX ÷2   y[m]    = sat16((fir(xe)[m] + 65536 xo[m - J] + 2^16) >>> 17)
            xe[i] = x[2i], xo[i] = x[2i + 1]
    TX ×2   y[2m]   = sat16((fir(x)[m] + 2^15) >>> 16)      (gain 2: the same integers, 16 fractional bits)
            y[2m+1] = x[m - (J - 1)]

`>>>` arithmetic (round half up), saturation to [-32768, 32767]. State is
zero after the chain reset.

## FIR Compiler configuration (rate_sr_cfg)

Stage i (1 = next to the RFDC) of a build with SPC samples per channel per
beat runs its FIR at p = SPC / 2^i samples per clock per path, in both
directions (RX: the even half of a stage input of SPC / 2^(i-1); TX: the
whole stage input). `Clock_Frequency` is a nominal 100 and
`Sample_Frequency` 100 x p: the core's architecture depends on the ratio
only. Single_Rate, Symmetric, Integer_Coefficients 18 bit, Data_Width 16,
Full_Precision out (34 bits, in 40-bit lanes, sign-extended), ARESETn,
M_DATA_Has_TREADY, S_DATA_Has_FIFO.

## tdata lanes (measured: an impulse per input lane)

Sample-major, in and out: lane = s * paths + a, sample s of the clock's
vector, path a. 16-bit input lanes, 40-bit output lanes. Paths are the I
and Q of each channel: path 2c = I, 2c + 1 = Q of channel c (of the
instance's share of the channels).

- At most 16 paths per instance: builds with 2 N_CH > 16 (16 channels) use
  G = 2 identical instances per stage, lanes 0..15 and 16..31, fed and
  enabled together (cycle-aligned; the chain sims check it bit-exact).
- One output per input (the core's zero state at reset): the hub's centre
  FIFO pairs output m with input m by count.
- **FIR Compiler pads the half-length of a symmetric filter to a multiple of
  its oversampling rate with leading zeros** (`C_COEF_FILE_LINES` of the
  generated core: 13 -> 14 at 2 cycles per sample, -> 16 at 4), which delays
  its output by that many samples: measured 1 and 3 samples with a 26-tap
  branch, independent of the input's phase. The 32-tap branch (half-length
  16) divides every time-shared rate the chains use (2, 4, 8, 16) and takes
  one multiplier at 32 and 64, so no padding: this is why the filter has 63
  taps and not the 51 the spec alone needs.
- After `aresetn` the core holds `s_axis_data_tready` low for some cycles:
  the hubs start their stages (`crst`) only once every FIR in use is ready.

## Timed start at depth k (udp_player)

`udp_player` decides a timed start two pipeline stages before a beat
reaches the DAC. Behind `tx_rate` the DAC side takes a beat one cycle in 2^k
and `adc_time` advances one beat in 2^k cycles, so the old allowance
(adc_time of the previous cycle + 2 beats) started bursts and stamped
BURST_ACK / UNDERFLOW / TIME_ERROR one beat off. It now uses the adc_time of
the current cycle + 1 beat (a 16-bit "advanced" compare selecting
precomputed +1 / +2 / +3 beat sums), which is the same value whenever time
advances every cycle (every depth-0 build): `make sim-gap` (GAP = 1..6) and
the depth-0 regressions pass.
