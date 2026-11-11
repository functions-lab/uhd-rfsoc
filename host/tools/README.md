# host/tools — what a user runs

The tools for day-to-day use. Tests of the whole system on the board are in
`../benchmark/`.

## The wrapper

`uhd-rfsoc <app> [args]` runs a UHD application with the module:

- as root (`sudo -E`);
- with the installed module loaded (`UHD_RFSOC_MODULE=<file>` for a build
  tree instead);
- with UHD example names such as `benchmark_rate` looked up in
  `/usr/libexec/uhd/examples`.

`cmake --install` puts a copy on `/usr/local/bin`. The one here works from
the source tree, with the module in `../build/`.

## Checks that need no board

| tool | what |
|---|---|
| `check_pattern_file.py <capture...>` | bit-exact check of an `rx_samples_to_file` capture (or a TX dump) against the FPGA's test pattern, in any wire format (`--otw`) and channel set (`--chans`, `--interleaved`) |
| `rfsoc_kernel_check` (built) | the SIMD conversion kernels against the scalar ones, bit for bit. Exit status = mismatches. The printed digest must be the same on x86 and aarch64 |
| `rfsoc_kernel_bench` (built) | what the per-sample work costs on this CPU: SIMD, scalar, UHD's own converter, and the worker pool (pin the pool with `--pool-cpus`) |
| `rfsoc_dram_bench` (built, x86 only) | whether this host's memory system can carry a configuration at all, before a board is involved. Pin every thread (see its header) |

## With a board

| tool | what |
|---|---|
| `rfsoc_bf.py --args ... [--rx] --angle\|--weights ... --enable` | steer the TX or RX beamformer and read it back (`--check`). `--rx --capture N` checks the RX beam bit for bit on real ADC data (needs `w[0] = 0`) |
| `uhd_smoke.py --args ...,pattern=1` | a Python `MultiUSRP` smoke test: receive, a timed capture and `send_waveform`, all bit-exact against the pattern |
| `uhd_semantics.py --args ...,pattern=1` | USRP behaviour through the Python API: late commands, `num_more` chains, command order, tuning, antennas, sensors, timed commands and more |

Run them through the wrapper, from `host/`:

```sh
uhd-rfsoc python3 tools/uhd_smoke.py --args type=rfsoc,addr=<board-ip>,pattern=1
```

## For full-rate runs

`isolate_cpus.sh apply <housekeeping CPUs> | restore | status` moves every
other task, kernel workqueue and movable interrupt to the given CPUs. The
change lasts until `restore` or a reboot.
