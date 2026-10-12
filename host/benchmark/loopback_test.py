#!/usr/bin/env python3
"""Board-only end-to-end test of the v49 100G data plane, no PC needed.

Run after `bringup.py --loopback` (overlay loaded, CMAC aligned with the GT in
near-end PMA loopback). The RX streamer is pointed at the FPGA's OWN TX port,
so its frames go out through the CMAC, come straight back in through the GT
loopback, and are played by udp_player on the DAC:

    ADC timekeeper -> udp_streamer (VRT/UDP frames, counter pattern)
      -> axis_pkt_arb -> CMAC TX -> GT loopback -> CMAC RX
      -> udp_player (checks MAC/IP/port, VRT header, packet count, length)
      -> URAM buffer -> DAC

Both paths run on the converter clock, so at the native rate the player
consumes exactly as fast as the streamer produces: every counter below must
come out exact. The streamer's first packet is "timed" at its own ADC
timestamp, already in the past when it reaches the player, so exactly one
TIME_ERROR (late) is expected per burst.
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "rfsoc", "server"))
import eth100g as E  # noqa: E402



def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--nsamps", type=int, default=16_000_000)
    ap.add_argument("--spp", type=int, default=2048)
    ap.add_argument("--cont-seconds", type=float, default=3.0)
    ap.add_argument("--config", default=None,
                    help="settings file with data_ip/data_mac [see board_config.py]")
    ap.add_argument("--data-ip", default=None, help="FPGA data IP [config data_ip]")
    ap.add_argument("--data-mac", default=None, help="FPGA data MAC [config / derived]")
    args = ap.parse_args()
    # the FPGA talks to itself: its own configured address on both ends
    import board_config
    try:
        FPGA_IP, FPGA_MAC, _name, _how = board_config.resolve(
            args.data_ip, args.data_mac, None, config=args.config)
    except board_config.ConfigError as e:
        print(f"error: {e}")
        return 2

    eth = E.Eth100G()            # fixed addresses; overlay must already be loaded
    st = E.decode_cmac_status(eth.cmac_status())
    print("cmac", json.dumps(st))
    if not st.get("rx_aligned"):
        print("CMAC not aligned -- run bringup.py --loopback first")
        return 2

    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"  {'OK ' if good else 'BAD'} {name}: {got} (want {want})")

    def clear_all():
        eth.s.write(E.STR_CTRL, eth._ctrl | E.STR_CTRL_CLEAR_STATS)
        eth.s.write(E.STR_CTRL, eth._ctrl)
        pc = E.PLY_CTRL_ENABLE | E.PLY_CTRL_DAC_SRC
        eth.p.write(E.PLY_CTRL, pc | E.PLY_CTRL_CLEAR_STATS)
        eth.p.write(E.PLY_CTRL, pc)

    # Player: our own MAC/IP; status packets addressed to ourselves are ignored.
    base = eth.player_setup(FPGA_MAC, FPGA_IP, FPGA_MAC, FPGA_IP,
                            async_port=49826, fc_interval=512, sid=0x5A170000)
    spp = eth.configure(FPGA_MAC, FPGA_IP, FPGA_MAC, FPGA_IP,
                        src_port=49800, dst_port_base=49900, nports=1,
                        spp=args.spp, sid=0x5A160000, pattern=True)

    # 1) finite burst at the full converter rate
    n = (args.nsamps + 15) // 16 * 16
    npk = -(-n // spp)
    print(f"[1] num_done {n} samples ({npk} packets of <= {spp}) through the loopback")
    eth.stream_cmd("num_done", n, now=True, time_ticks=0)
    time.sleep(0.2 + n / 1.2e9 * 2)
    s, p = eth.streamer_stats(), eth.player_stats()
    print("   streamer", json.dumps(s))
    print("   player  ", json.dumps(p))
    check("streamer packets", s["pkts"], npk)
    check("streamer overflows", s["overflows"], 0)
    check("player udp_accepted", p["udp_accepted"], npk)
    check("player rx_bad_fcs", p["rx_bad_fcs"], 0)
    check("player udp_malformed", p["udp_malformed"], 0)
    check("player seq_errors", p["seq_errors"], 0)
    check("player dropped (overflow)", p["udp_dropped_overflow"], 0)
    check("player late (first packet is in the past)", p["late"], 1)
    check("player bursts_acked", p["bursts_acked"], 1)
    check("player consumed words", (p["consumed_words"] - base) & 0xFFFFFFFF, n // 16)
    print(f"   underflows during playout: {p['underflows']} (0 = rate-matched end to end)")

    # 2) continuous streaming: sustained 38.4 Gb/s through CMAC TX and RX
    print(f"[2] continuous for {args.cont_seconds} s")
    clear_all()
    t0 = time.time()
    eth.stream_cmd("start_cont", 0, now=True, time_ticks=0)
    time.sleep(args.cont_seconds)
    eth.stream_cmd("stop_cont", 0, now=True, time_ticks=0)
    dt = time.time() - t0
    time.sleep(0.2)
    s, p = eth.streamer_stats(), eth.player_stats()
    print("   streamer", json.dumps(s))
    print("   player  ", json.dumps(p))
    gbps = s["pkts"] * spp * 4 * 8 / dt / 1e9
    print(f"   {s['pkts']} packets in {dt:.2f} s = {gbps:.1f} Gb/s of samples "
          f"({s['pkts'] * spp / dt / 1e6:.0f} MS/s)")
    check("streamer overflows", s["overflows"], 0)
    check("player accepted == streamer sent", p["udp_accepted"], s["pkts"])
    check("player rx_bad_fcs", p["rx_bad_fcs"], 0)
    check("player seq_errors", p["seq_errors"], 0)
    check("player dropped (overflow)", p["udp_dropped_overflow"], 0)

    eth.player_stop()
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
