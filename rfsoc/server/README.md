# server — the board daemon

`uhd_rfsoc_daemon.py` is what UHD talks to: discovery on UDP 49700,
control on TCP 49710 (the Protocol in the top `AGENTS.md`). It loads a
`<board>_v49_<N>ch_qsfp*.bit` build, programs the clock chips, brings the
RFDC up, locks multi-tile sync, aligns the 100G link, and then serves one
UHD client at a time: channel count, sample rate (retune in place or reload
another build), NCOs, gains, RX / TX streams and the beamformers. Runs as
root in the PYNQ venv on a ZCU216 or an RFSoC 4x2 (UHD sees both as
`type=rfsoc`).

Setting a board up from scratch: `../README.md`. Day to day:

    ../../run_daemon.sh                  # start (also stop, restart, status, log, fg)
    ../../run_daemon.sh --bitstream zcu216_v49_4ch_qsfp_f2_fs2500.bit   # start with this build

Needs, in this directory: `uhd_rfsoc.conf` (from `uhd_rfsoc.conf.example`
via `../setup_board.sh`; `data_ip` = the FPGA's 100G address) and the
`.bit` + `.hwh` pairs to serve. Any subset of the builds works, both clock
families together too; every installed build's rates are offered.

Debugging on the board (root, PYNQ venv: `sudo bash -c 'source
/etc/profile.d/pynq_venv.sh && ...'`):

    python3 bringup.py --status                   # read-only: CMAC status, clock meters, streamer / player registers
    python3 bringup.py --link-only --rsfec 0      # redo the 100G link bring-up on the loaded build
    python3 ../rfsoc_lib/gt_refclk.py --status    # the ZCU216's 8A34001 GT refclk

Tests: `python3 -m unittest discover -s tests` (no board: the protocol
against a stubbed backend, the xrfdc patch), and from the host against a
running daemon `python3 tests/client_check.py --addr <board-ip> [--tx]
[--rate 6e8] [--channels N] [--otw sc8] [--bf]` (discovery, every command,
an RX pattern stream checked bit for bit, a TX burst, the beamformers).

Internals and the choices made where the Protocol is silent: `AGENTS.md`.
