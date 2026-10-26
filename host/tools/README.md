# host/tools — what a user runs

| tool | board | what |
|---|---|---|
| `uhd-rfsoc <app> [args]` | yes | run a UHD application with the module: `sudo -E`, `UHD_MODULE_PATH` = the installed module (`UHD_RFSOC_MODULE=<file>` for a build tree), bare example names looked up in `/usr/libexec/uhd/examples`. `cmake --install` puts a copy on `/usr/local/bin`; the one here works from the source tree with `../build/` |
| `check_pattern_file.py <capture...>` | no | bit-exact check of a `rx_samples_to_file` capture (or a TX dump) against the FPGA's timestamp-keyed test pattern (Protocol §5, §9), in any wire format (`--otw`), any channel set (`--chans`, `--interleaved`) |
| `rfsoc_kernel_check` (built) | no | the SIMD conversion kernels against the scalar ones, bit for bit: every format pair, N = 1..16, channel subsets, unaligned calls, edge values. Exit status = mismatches; the printed digest is the same on x86 and aarch64 when the bits are |
| `rfsoc_kernel_bench [--cpu C] [--pool-cpus ...] [--sweep]` (built) | no | what the per-sample work costs on this CPU: SIMD, scalar and UHD's own converter, and the worker pool (pin it with `--pool-cpus` for meaningful pool rows) |
| `rfsoc_dram_bench --dir rx\|tx\|duplex ...` (built, x86 only) | no | the module's kernels and pool against a packet ring far larger than L3 while a stand-in NIC thread streams DRAM at a set rate: can this host's memory system carry a configuration at all? Pin every thread (see its header) |
| `isolate_cpus.sh apply <housekeeping CPUs> \| restore \| status` | -- | move every other task, kernel workqueue and movable IRQ to the given CPUs for a full-rate run (runtime only) |
| `rfsoc_bf.py --args ... [--rx] --angle\|--weights ... --enable` | yes | steer the TX or RX beamformer through `set_user_register` and read it back from the tree (`--check`); `--rx --capture N` checks the RX beam bit for bit on real ADC data (needs `w[0] = 0`) |
| `uhd_smoke.py --args ...,pattern=1` | yes | Python `MultiUSRP` smoke test: `recv_num_samps`, a timed off-grid `num_done`, `send_waveform`, all bit-exact against the pattern |
| `uhd_semantics.py --args ...,pattern=1` | yes | USRP semantics through the Python API: late commands, `num_more` chains, FIFO order, tune split, LOs, antennas, bandwidth, sensors, fragments, timed commands, emulated PPS, subdev spec, async per channel |

The board tests run through the wrapper from `host/`:
`uhd-rfsoc python3 tools/uhd_smoke.py --args type=rfsoc,addr=<board-ip>,pattern=1`.
`benchmark/uhd_examples_hw.sh` runs the two Python harnesses as part of the
UHD compliance suite. Everything in `benchmark/` is a test of the whole
system on the board; the tools here are what a user needs day to day.
