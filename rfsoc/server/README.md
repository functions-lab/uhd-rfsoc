# server — the board daemon

`uhd_rfsoc_daemon.py` is what UHD talks to: discovery on UDP 49700, control
on TCP 49710 (the Protocol in the top `AGENTS.md`).

At start it loads a bitstream, programs the clock chips, brings up the RF
converters, locks multi-tile sync and aligns the 100G link. Then it serves
one UHD client at a time: channel count, sample rate, carriers (NCOs),
gains, RX / TX streams and the beamformers.

It runs as root in the PYNQ environment, on a ZCU216 or an RFSoC 4x2.

## Run

Setting a board up from scratch: `../README.md`. Day to day, from the top of
the checkout:

```sh
./run_daemon.sh                  # start; also: stop, restart, status, log, fg
./run_daemon.sh --bitstream zcu216_v49_4ch_qsfp_f2_fs2500.bit   # start with this build
```

The daemon needs, in this directory:

- `uhd_rfsoc.conf`, created from `uhd_rfsoc.conf.example` by
  `../setup_board.sh`. Its `data_ip` is the FPGA's 100G address.
- The `.bit` + `.hwh` pairs to serve. Any subset of the builds works, of
  any mix of converter rates; every installed build's rates are offered.

## Debugging

On the board, in this directory, as root in the PYNQ environment
(`sudo bash -c 'source /etc/profile.d/pynq_venv.sh && ...'`):

```sh
python3 bringup.py --status                   # read-only: 100G link status, clock meters, streamer / player registers
python3 bringup.py --link-only --rsfec 0      # redo the 100G link bring-up on the loaded build
python3 ../rfsoc_lib/gt_refclk.py --status    # ZCU216: the 100G reference clock chip (8A34001)
```

## Tests

Both from this directory. Without a board (the protocol against a stubbed
backend, the xrfdc patch):

```sh
python3 -m unittest discover -s tests
```

From the host, against a running daemon (discovery, every command, a
bit-exact RX pattern stream, a TX burst, the beamformers):

```sh
python3 tests/client_check.py --addr <board-ip> [--tx] [--rate 6e8] [--channels N] [--otw sc8] [--bf]
```

Internals, and the choices made where the Protocol is silent: `AGENTS.md`.
