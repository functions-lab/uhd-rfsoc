//
// uhd_zcu216 -- TX streamer implementation (Protocol §6, §7).
//
#include "zcu216_tx_streamer.hpp"
#include "zcu216_pool.hpp"
#include <arpa/inet.h>
#include <endian.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <cmath>
#include <cerrno>
#include <cstring>
#include <numeric>
#include <thread>

namespace zcu216 {

using clk = std::chrono::steady_clock;

static clk::time_point deadline_in(double s)
{
    return clk::now()
           + std::chrono::duration_cast<clk::duration>(std::chrono::duration<double>(std::max(0.0, s)));
}

static inline void cpu_relax()
{
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}

//! the TX lcore's view of this streamer: every UDP payload sent to the async port
struct tx_streamer_impl::status_sink : public dpdk::tx_status_sink
{
    tx_streamer_impl* self = nullptr;
    void on_status(const uint8_t* pay, uint32_t len) override
    {
        self->_on_status(pay, len);
    }
};

tx_streamer_impl::tx_streamer_impl(
    std::shared_ptr<dev_state> st, const uhd::stream_args_t& args_in)
    : _st(std::move(st))
{
    uhd::stream_args_t args = args_in;
    if (args.channels.empty())
        args.channels = {0};
    auto arg = [&](const std::string& k, const std::string& def) {
        if (args.args.has_key(k))
            return args.args[k];
        return _st->args.get(k, def);
    };

    // Protocol §10: cpu -> wire format here, wire -> int16 in the FPGA
    // an empty otw_format: the device arg otw= if given, else sc16
    _otw = &otw_lookup(args.otw_format.empty() ? _st->args.get("otw", "") : args.otw_format);
    const auto offered = _st->otw_offered(false);
    if (std::find(offered.begin(), offered.end(), _otw->name) == offered.end()) {
        std::string have;
        for (const auto& f : offered)
            have += (have.empty() ? "" : ",") + f;
        throw uhd::value_error(std::string("ZCU216: TX otw_format ") + _otw->name
                               + " is not offered by the daemon for this build (it offers "
                               + have + "; an older daemon/bitstream offers only sc16). "
                                 "Protocol §9/§10: the sc8-only builds are selected with "
                                 "the device arg otw=sc8 before set_rx_rate");
    }
    // the daemon's current format (§3) is now this stream's; later rate
    // requests declare it
    _st->set_cur_otw(_otw->name);
    const cpu_t cpu     = cpu_lookup(args.cpu_format);
    _bytes_per_cpu_item = cpu_bytes(cpu);

    // tx_spp counts SLOTS: whole 64-byte words of the format and a multiple
    // of N (§9, §10), payload at most 8192 bytes
    _nchan               = _st->nchan;
    const size_t B       = _otw->slot_bytes;
    const size_t quantum = std::lcm(_otw->granule, _nchan);
    _quantum             = quantum / _nchan;
    const size_t max_spp =
        std::min((_st->mtu - 28 - kHdrBytes) / B, kMaxPayloadBytes / B) / quantum * quantum;
    size_t spp = size_t(parse_ll(arg("tx_spp", std::to_string(max_spp)), "tx_spp"));
    _spp       = std::max(quantum, std::min(spp, max_spp)) / quantum * quantum;
    _buf_pkts  = size_t(std::max(1LL, std::min(64LL,
        parse_ll(arg("spb_pkts", "32"), "spb_pkts"))));
    _drain_timeout = parse_double(arg("tx_drain_timeout", "2.0"), "tx_drain_timeout");
    _max_pkts      = size_t(std::max(1LL, parse_ll(arg("tx_max_pkts", "2040"), "tx_max_pkts")));
    _spin_s        = std::max(0.0, parse_double(arg("tx_spin_us", "20"), "tx_spin_us")) * 1e-6;
    _yield_s       = std::max(_spin_s, parse_double(arg("tx_yield_us", "2000"), "tx_yield_us") * 1e-6);
    _keep_warm     = arg("tx_keep_warm", "1") != "0";
    _stats.on            = std::getenv("ZCU216_TX_STATS") != nullptr;
    _stats.ignore_credit = arg("tx_ignore_credit", "0") == "1";
    if (_stats.ignore_credit)
        ZLOG_WARN("tx_ignore_credit=1: TX flow control DISABLED (measurement only; "
                  "the FPGA will drop what does not fit)");
    _stats.status_gap_us.reserve(_stats.on ? 1u << 22 : 0);
    _stats.events.reserve(_stats.on ? 64 : 0);
    _stats.slows.reserve(_stats.on ? 65536 : 0);
    const auto tx_port   = uint16_t(parse_ll(arg("tx_port", std::to_string(kTxPort)), "tx_port"));
    const auto recv_port = uint16_t(parse_ll(arg("recv_port", std::to_string(kRecvPortBase)), "recv_port"));
    const auto async_base = uint16_t(parse_ll(
        arg("async_port", std::to_string(recv_port + kAsyncOffset)), "async_port"));

    for (const size_t ch : args.channels) {
        if (ch >= _st->num_tx)
            throw uhd::index_error("ZCU216: TX channel " + std::to_string(ch)
                                   + " out of range (device has " + std::to_string(_st->num_tx)
                                   + ")");
        if (std::find(_dev_chans.begin(), _dev_chans.end(), ch) != _dev_chans.end())
            throw uhd::value_error("ZCU216: TX channel listed twice");
        _dev_chans.push_back(ch);
    }
    // throws for a cpu/otw pair the module does not support
    _kern = std::make_unique<tx_kernel>(cpu, _otw->fmt, _nchan, _dev_chans);
    _ev.resize(kEvRing);

    const local_iface ifc = _st->host_data_iface();
    _generation           = _st->fpga_generation.load();
    try {
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port   = htons(tx_port);
        if (inet_pton(AF_INET, _st->data_ip.c_str(), &dst.sin_addr) != 1)
            throw uhd::value_error("ZCU216: bad FPGA data IP '" + _st->data_ip + "'");
        // The DPDK frames need a UDP source port. Bind a kernel socket to the
        // host data IP to reserve one, so no kernel socket gets it too.
        _src_fd = ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (_src_fd < 0)
            throw uhd::os_error(std::string("ZCU216: socket(): ") + strerror(errno));
        sockaddr_in me{};
        me.sin_family = AF_INET;
        if (inet_pton(AF_INET, ifc.ip.c_str(), &me.sin_addr) != 1
            or ::bind(_src_fd, reinterpret_cast<sockaddr*>(&me), sizeof(me)) != 0)
            throw uhd::io_error("ZCU216: cannot bind a UDP socket to the host data IP " + ifc.ip
                                + ": " + strerror(errno));
        socklen_t ml = sizeof(me);
        ::getsockname(_src_fd, reinterpret_cast<sockaddr*>(&me), &ml);

        // Resolve the FPGA's MAC through the kernel (the isolated DPDK port
        // leaves ARP to it) before the first burst: one byte to the discard
        // port 9, which the FPGA ignores (§6); the reply lands in the
        // neighbour table that dpdk::fpga_mac() reads.
        if (arg("tx_arp_prime", "1") != "0") {
            const int pfd = ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
            sockaddr_in d9 = dst;
            d9.sin_port    = htons(9);
            const char z   = 0;
            ::sendto(pfd, &z, 1, 0, reinterpret_cast<sockaddr*>(&d9), sizeof(d9));
            ::close(pfd);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }

        // One stream for every channel (§9): <ch> is 0 in every command.
        wire& c      = _w;
        c.sid        = kTxSidBase;
        c.async_port = async_base;
        _host_ip     = ifc.ip;
        _host_mac    = ifc.mac;

        // Frames are built by hand in mbufs; the async status port is steered
        // to a DPDK queue that the TX lcore polls (installed before
        // stream_setup_tx, so the first status packet is already ours).
        dpdk::tx_endpoint ep;
        ep.dst_mac     = dpdk::fpga_mac(arg("data_mac", ""), ifc.name, _st->data_ip, _st->data_mac);
        ep.src_ip      = ifc.ip;
        ep.dst_ip      = _st->data_ip;
        ep.src_port    = ntohs(me.sin_port);
        ep.dst_port    = tx_port;
        ep.status_port = c.async_port;
        // untimed bursts start with a lead (dpdk::tx_endpoint), sized by
        // _size_prefill() once stream_setup_tx has given the credit
        _prefill_arg     = arg("tx_prefill", "auto");
        _prefill_lead_us = std::max(0.0, parse_double(arg("tx_prefill_lead_us", "200"), "tx_prefill_lead_us"));
        _prefill_us      = std::max(0.0, parse_double(arg("tx_prefill_us", "1000"), "tx_prefill_us"));
        ep.prefill_pkts  = 32;
        ep.prefill_us    = _prefill_us;
        ep.warmup_pkts  = size_t(std::max(0LL, parse_ll(arg("tx_warmup", "512"), "tx_warmup")));
        _status_sink       = std::make_unique<status_sink>();
        _status_sink->self = this;
        _dpdk_tx = dpdk::start_tx(_st->dpdk, ep, kBatch, kHdrBytes + _spp * B, _status_sink.get());

        _setup_tx();
        std::string chs;
        for (const size_t ch : _dev_chans)
            chs += (chs.empty() ? "" : ",") + std::to_string(ch);
        ZLOG_INFO("TX ch " << chs << " of " << _nchan << ": -> " << _st->data_ip << ":"
                           << tx_port << ", spp " << _spp << " slots (" << _spp / _nchan
                           << " samples/channel), buffer " << c.buf_words << " words ("
                           << c.buf_words * kTxWordBytes / B << " slots), fc every "
                           << c.fc_interval << ", max " << _max_pkts
                           << " pkts in flight, untimed bursts start with " << _prefill_pkts
                           << " pkts held, async status " << ifc.ip << ":" << c.async_port
                           << " via DPDK, " << _kern->desc()
                           << (_st->txp() ? ", packed in parallel above "
                                               + std::to_string(_st->par_min_slots) + " slots/batch"
                                         : ""));
    } catch (...) {
        shutdown();
        throw;
    }
    _residual.resize(_dev_chans.size());
    _plan.resize(kBatch);
    _asm.resize(kBatch);
    _batch_len.resize(kBatch);
    _warm_up(size_t(std::max(0LL, parse_ll(arg("tx_warmup_rounds", "4"), "tx_warmup_rounds"))));
}

// Warm-up. Measured (4ch F4 sc8, full-rate duplex, ZCU216_TX_STATS): an
// underflow 2 ms after a timed start, after one send() spent 4 ms packing --
// the first conversions after the ~250 ms wait for the start met sleeping
// pool workers and cold caches, while the FPGA buffer holds < 1 ms at that
// rate. So the packing path runs once over scratch buffers here (code, worker
// threads, the per-slot assembly buffers at full size), and _wait_credit keeps
// the workers in their spin window while it waits.
void tx_streamer_impl::_warm_up(size_t rounds)
{
    const size_t n   = std::max<size_t>(1, _spp / _nchan); // samples per channel per packet
    const size_t cpb = _bytes_per_cpu_item;
    for (auto& a : _asm)
        a.reserve(_dev_chans.size() * n * cpb);
    if (rounds == 0)
        return;
    const size_t pay = n * _nchan * _otw->slot_bytes;
    std::vector<std::vector<uint8_t>> in(_dev_chans.size(), std::vector<uint8_t>(n * cpb, 0));
    std::vector<uint8_t> out(kBatch * pay, 0);
    for (size_t bi = 0; bi < kBatch; bi++) {
        pkt_plan& pp = _plan[bi];
        pp.pay       = out.data() + bi * pay;
        pp.n         = n;
        pp.in_off    = 0;
        for (size_t i = 0; i < _dev_chans.size(); i++)
            pp.ins[i] = in[i].data();
    }
    worker_pool* pool = _st->txp();
    _job_chunk        = n;
    _job_per_pkt      = 1;
    for (size_t r = 0; r < rounds; r++) {
        if (pool)
            pool->run(kBatch, &tx_streamer_impl::_task, this);
        else
            for (size_t bi = 0; bi < kBatch; bi++)
                _task(this, bi);
    }
    for (auto& pp : _plan)
        pp = pkt_plan{};
}

tx_streamer_impl::~tx_streamer_impl()
{
    shutdown();
}

void tx_streamer_impl::shutdown()
{
    std::lock_guard<std::mutex> lock(_shutdown_mutex);
    if (_shut)
        return;
    _shut   = true;
    wire& c = _w;
    if (c.buf_words) { // stream_setup_tx went through
        if (_st->fpga_generation.load() != _generation) {
            // reloaded FPGA: nothing of ours is queued any more
        } else if (_in_burst) {
            ZLOG_WARN("TX streamer destroyed inside a burst (no end_of_burst sent); "
                      "stopping the DAC player");
        } else {
            // let what is queued play out, like a USRP would (the TX lcore
            // keeps reading status until the session goes below)
            const auto dl = deadline_in(_drain_timeout);
            while (not(_ack_since_eob.load() or c.consumed.load() >= c.sent_words)
                   and clk::now() < dl)
                std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
        try {
            _st->ctrl->call("stream_stop_tx 0");
        } catch (const std::exception& e) {
            ZLOG_WARN("stream_stop_tx failed: " << e.what());
        }
    }
    _running = false;
    {
        std::lock_guard<std::mutex> l(_ev_mutex);
        _ev_cv.notify_all();
    }
    _dpdk_tx.reset(); // send what is still queued (bounded), stop the TX lcore, drop the flow
    _print_stats();
    if (_st->txp() and (_flush_par or _flush_inline))
        ZLOG_INFO("TX packing: " << _flush_par << " batches split across the pool ("
                                 << _st->txp()->desc() << " + the application thread), "
                                 << _flush_inline << " in the application thread alone");
    if (c.buf_words)
        ZLOG_DEBUG("TX closed: sent " << c.sent_words << " words, consumed "
                                      << c.consumed.load() << ", " << c.status_pkts
                                      << " status packets, " << c.underflows << " underflows, "
                                      << c.seq_errors << " seq errors, " << c.late << " late, "
                                      << c.acks << " acks");
    if (_src_fd >= 0)
        ::close(_src_fd);
    _src_fd = -1;
}

void tx_streamer_impl::_print_stats()
{
    if (not _stats.on or _stats.calls == 0)
        return;
    const double wall = std::chrono::duration<double>(_stats.last_exit - _stats.first).count();
    const double ns2s = 1e-9;
    std::vector<uint32_t> g = _stats.status_gap_us;
    std::sort(g.begin(), g.end());
    auto pct = [&](double q) { return g.empty() ? 0u : g[size_t(q * (g.size() - 1))]; };
    double mean = 0;
    for (auto v : g)
        mean += v;
    mean = g.empty() ? 0 : mean / g.size();
    const double slots_per_word = double(kTxWordBytes) / double(_otw->slot_bytes);
    const double samps = double(_w.sent_words) * slots_per_word / std::max<size_t>(1, _nchan);
    ZLOG_INFO("TX stats: " << _stats.calls << " send() calls, " << _stats.pkts << " pkts, "
        << samps / wall / 1e6 << " MS/s/ch sent over " << wall << " s");
    ZLOG_INFO("TX stats: time in send() " << 100.0 * _stats.in_send_ns * ns2s / wall
        << " % (packing " << 100.0 * _stats.build_ns * ns2s / wall << " %, " << _stats.par_batches
        << " batches packed in parallel; credit wait " << 100.0 * _stats.wait_ns * ns2s / wall
        << " % over " << _stats.waits << " waits), app between calls "
        << 100.0 * _stats.between_ns * ns2s / wall << " %");
    ZLOG_INFO("TX stats: packing " << (_stats.pkts ? _stats.build_ns / _stats.pkts : 0)
        << " ns/pkt = " << (_stats.build_ns ? double(_w.sent_words) * kTxWordBytes / (_stats.build_ns * ns2s) / 1e9 : 0)
        << " GB/s; status packets (DPDK, TX lcore) " << _w.status_pkts << ", gap us min "
        << pct(0) << " p50 " << pct(0.5) << " mean " << mean << " p99 " << pct(0.99) << " max "
        << pct(1.0) << "; fc_interval " << _w.fc_interval << " words = "
        << _w.fc_interval * slots_per_word / std::max(1.0, samps / wall) * 1e6 << " us at this rate");
    if (_stats.events.size() > 8)
        ZLOG_INFO("TX stats: " << _stats.events.size() << " events recorded (capacity "
                  << _stats.events.capacity() << "), the first 8:");
    for (size_t ei = 0; ei < std::min<size_t>(8, _stats.events.size()); ei++) {
        const auto& e = _stats.events[ei];
        const std::string since_eob =
            _stats.have_eob ? ", " + std::to_string(std::chrono::duration<double, std::micro>(
                                         e.t - _stats.last_eob).count()) + " us after the last EOB"
                            : std::string(", no EOB sent");
        const double since_first = std::chrono::duration<double, std::micro>(e.t - _stats.first).count();
        ZLOG_INFO("TX stats: event " << e.code << " (0x2 underflow, 0x4 seq, 0x8 late, 0x10 underflow in packet) at "
            << since_first << " us after the first send()"
            << since_eob << ", TSF " << e.tsf << ", consumed " << e.consumed << " of " << e.sent
            << " words sent");
        // the sending thread's slow episodes in the 5 ms before the event
        std::string sl;
        size_t nsl = 0;
        for (const auto& w : _stats.slows) {
            const double ago = std::chrono::duration<double, std::micro>(e.t - w.t).count();
            if (ago < 0 or ago > 5000)
                continue;
            if (++nsl > 12)
                continue;
            sl += std::string(sl.empty() ? "" : "; ") + (w.kind == 'g' ? "app gap " : "send() ")
                  + std::to_string(w.dur_us) + " us"
                  + (w.kind == 's' ? " (packing " + std::to_string(w.build_us) + ", credit wait "
                                         + std::to_string(w.wait_us) + ", rest "
                                         + std::to_string(w.dur_us - std::min(w.dur_us, w.build_us + w.wait_us)) + ")"
                                   : std::string())
                  + " starting " + std::to_string(int64_t(ago)) + " us before";
        }
        ZLOG_INFO("TX stats:   slow episodes (> " << tx_stats::kSlowUs << " us) in the 5 ms before: "
                  << (nsl ? std::to_string(nsl) + ": " + sl + (nsl > 12 ? "; ..." : "") : std::string("none")));
    }
    ZLOG_INFO("TX stats: " << _stats.slows.size() << " slow episodes (> " << tx_stats::kSlowUs
              << " us) in the whole stream" << (_stats.slows.size() == _stats.slows.capacity() ? " (record full)" : ""));
}

// ---------------------------------------------------------------------------
// async status (Protocol §7), on the TX lcore
// ---------------------------------------------------------------------------
void tx_streamer_impl::_fc_lock()
{
    while (_w.fc_lock.exchange(true, std::memory_order_acquire))
        cpu_relax();
}
void tx_streamer_impl::_fc_unlock()
{
    _w.fc_lock.store(false, std::memory_order_release);
}

void tx_streamer_impl::_on_status(const uint8_t* pay, uint32_t len)
{
    wire* c = &_w;
    if (len < 24) {
        c->foreign++;
        return;
    }
    uint32_t w[6];
    std::memcpy(w, pay, sizeof(w));
    for (int i = 0; i < 6; i++)
        w[i] = le32toh(w[i]);
    if (w[0] != kAsyncMagic or w[1] != c->sid) {
        c->foreign++;
        return;
    }
    c->status_pkts++;
    if (_stats.on) {
        const auto now = clk::now();
        if (_stats.have_status and _stats.status_gap_us.size() < _stats.status_gap_us.capacity())
            _stats.status_gap_us.push_back(uint32_t(
                std::chrono::duration_cast<std::chrono::microseconds>(now - _stats.last_status).count()));
        _stats.last_status = now;
        _stats.have_status = true;
    }
    const uint64_t tsf  = (uint64_t(w[2]) << 32) | w[3];
    const uint32_t code = w[4];
    _fc_lock();
    if (not c->baseline_valid) { // before stream_setup_tx answered: not ours yet
        _fc_unlock();
        return;
    }
    const uint32_t delta = w[5] - c->last_consumed32;
    if (delta < 0x80000000u) { // a stale (reordered, pre-baseline) report goes backwards
        c->last_consumed32 = w[5];
        c->consumed.fetch_add(delta, std::memory_order_release);
    }
    _fc_unlock();
    if (code == uhd::async_metadata_t::EVENT_CODE_BURST_ACK)
        _ack_since_eob.store(true, std::memory_order_release);
    if (code == 0)
        return; // flow-control update only
    if (_stats.on and code != uhd::async_metadata_t::EVENT_CODE_BURST_ACK
        and _stats.events.size() < _stats.events.capacity())
        _stats.events.push_back({clk::now(), code, tsf, c->consumed.load(), c->sent_words});
    switch (code) {
        case uhd::async_metadata_t::EVENT_CODE_UNDERFLOW:
        case uhd::async_metadata_t::EVENT_CODE_UNDERFLOW_IN_PACKET:
            c->underflows++;
            UHD_LOG_FASTPATH("U");
            break;
        case uhd::async_metadata_t::EVENT_CODE_SEQ_ERROR:
        case uhd::async_metadata_t::EVENT_CODE_SEQ_ERROR_IN_BURST:
            c->seq_errors++;
            UHD_LOG_FASTPATH("S");
            break;
        case uhd::async_metadata_t::EVENT_CODE_TIME_ERROR:
            c->late++;
            UHD_LOG_FASTPATH("L");
            break;
        case uhd::async_metadata_t::EVENT_CODE_BURST_ACK:
            c->acks++;
            break;
        default:
            break;
    }
    // SPSC ring to recv_async_msg(); when full the newest event is dropped.
    // One stream carries every channel, so the FPGA reports one event; UHD
    // reports one per channel of the streamer (md.channel = the channel's
    // index in it), so apps that count ACKs per channel see them all.
    uint64_t wr        = _ev_wr.load(std::memory_order_relaxed);
    const size_t nchan = std::max<size_t>(1, _dev_chans.size());
    if (wr + nchan - _ev_rd.load(std::memory_order_acquire) > kEvRing) {
        c->ev_dropped++;
        return;
    }
    for (size_t k = 0; k < nchan; k++, wr++) {
        uhd::async_metadata_t& md = _ev[wr % kEvRing];
        md.channel       = k;
        md.has_time_spec = true;
        md.time_spec     = uhd::time_spec_t::from_ticks((long long)tsf, _st->tick_rate);
        md.event_code    = uhd::async_metadata_t::event_code_t(code);
        std::memset(md.user_payload, 0, sizeof(md.user_payload));
        md.user_payload[0] = w[5];
    }
    _ev_wr.store(wr, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    if (_ev_waiters.load(std::memory_order_relaxed) > 0) {
        // never block the lcore: a waiter that holds the mutex right now
        // re-checks the ring within 10 ms anyway
        std::unique_lock<std::mutex> l(_ev_mutex, std::try_to_lock);
        if (l.owns_lock())
            _ev_cv.notify_all();
    }
}

void tx_streamer_impl::_setup_tx()
{
    wire& c        = _w;
    std::string req = "stream_setup_tx 0 " + _host_ip + " " + _host_mac + " "
                      + std::to_string(c.async_port);
    if (_otw->fmt != otw_t::sc16) // a daemon without §10 knows only sc16
        req += std::string(" otw=") + _otw->name;
    const auto rep = _st->ctrl->call_tokens(req);
    if (rep.size() < 2)
        throw uhd::runtime_error("ZCU216: short reply to stream_setup_tx");
    const size_t buf_words = size_t(parse_ll(rep[0], "tx_buf_words"));
    if (buf_words < 2 * _words(_spp / _nchan))
        throw uhd::runtime_error("ZCU216: TX buffer of " + rep[0]
                                 + " words is smaller than two packets");
    // consumed count is monotonic on the FPGA; count from the baseline
    // (older daemons reply with two tokens: baseline 0)
    const uint32_t baseline =
        rep.size() >= 3 ? uint32_t(parse_ll(rep[2], "consumed_baseline")) : 0u;
    c.buf_words   = buf_words;
    c.fc_interval = size_t(parse_ll(rep[1], "fc_interval"));
    _fc_lock();
    c.last_consumed32 = baseline;
    c.baseline_valid  = true;
    c.consumed.store(0);
    _fc_unlock();
    c.sent_words = 0;
    c.pkt_ends.clear();
    _size_prefill();
}

void tx_streamer_impl::_size_prefill()
{
    // An untimed burst plays from its first packet (Protocol §6), so the TX
    // lcore holds its first packets and releases them back to back
    // (dpdk::tx_endpoint::prefill_pkts); the lead they give has to cover the
    // host's start-up. A fixed 32 packets were 27 us of 1.2 GS/s fc32, and
    // every full-rate 1-channel fc32 run underflowed once, right after them.
    // tx_prefill=auto: tx_prefill_lead_us of play-out at the current rate and
    // format, at least 32 packets, at most 3/4 of the FPGA credit, the
    // lcore's 256 and tx_max_pkts - 1; tx_prefill=<n> fixes it (0 = off).
    if (not _dpdk_tx or not _w.buf_words)
        return;
    const size_t pkt_words = std::max<size_t>(1, _words(_spp / _nchan));
    size_t n;
    if (_prefill_arg != "auto") {
        n = size_t(std::max(0LL, parse_ll(_prefill_arg, "tx_prefill")));
    } else {
        const double wire_bps = _st->get_tx_rate(0) * double(_nchan) * double(_otw->slot_bytes);
        const double need =
            std::ceil(_prefill_lead_us * 1e-6 * wire_bps / double(pkt_words * kTxWordBytes));
        n = std::max<size_t>(32, size_t(need));
        n = std::min({n, _w.buf_words / pkt_words * 3 / 4, size_t(256),
            std::max<size_t>(1, _max_pkts - 1)});
    }
    _prefill_pkts = n;
    _dpdk_tx->set_prefill(n, _prefill_us);
}

void tx_streamer_impl::_resync_if_reloaded()
{
    const uint64_t g = _st->fpga_generation.load();
    if (g == _generation)
        return;
    ZLOG_WARN("TX: the FPGA was reloaded (rate change) after this streamer was set up; "
              "redoing stream_setup_tx with the new consumed baseline"
              << (_in_burst ? ". The burst in progress was lost; a new one starts" : "")
              << ". Create streamers after set_tx_rate() to avoid this.");
    _setup_tx();
    for (auto& r : _residual)
        r.clear();
    _in_burst      = false;
    _pending_sob   = false;
    _pending_timed = false;
    _ack_since_eob = true;
    _generation    = g;
}

bool tx_streamer_impl::recv_async_msg(uhd::async_metadata_t& md, double timeout)
{
    const auto dl = deadline_in(timeout);
    std::unique_lock<std::mutex> lk(_ev_mutex);
    while (true) {
        const uint64_t rd = _ev_rd.load(std::memory_order_relaxed);
        if (rd != _ev_wr.load(std::memory_order_acquire)) {
            md = _ev[rd % kEvRing];
            _ev_rd.store(rd + 1, std::memory_order_release);
            return true;
        }
        if (not _running.load() or clk::now() >= dl)
            return false;
        _ev_waiters.fetch_add(1);
        std::atomic_thread_fence(std::memory_order_seq_cst);
        if (_ev_rd.load(std::memory_order_relaxed) == _ev_wr.load(std::memory_order_acquire))
            _ev_cv.wait_until(lk, std::min(dl, clk::now() + std::chrono::milliseconds(10)));
        _ev_waiters.fetch_sub(1);
    }
}

// ---------------------------------------------------------------------------
// send
// ---------------------------------------------------------------------------
bool tx_streamer_impl::_have_credit(size_t words)
{
    wire& c             = _w;
    const uint64_t cons = c.consumed.load(std::memory_order_acquire);
    // a packet stays in flight until its last word is retired
    while (not c.pkt_ends.empty() and c.pkt_ends.front() <= cons)
        c.pkt_ends.pop_front();
    if (_stats.ignore_credit)
        return true;
    const uint64_t inflight = c.sent_words > cons ? c.sent_words - cons : 0;
    return inflight + words <= c.buf_words and c.pkt_ends.size() + 1 <= _max_pkts;
}

bool tx_streamer_impl::_wait_credit(size_t words, clk::time_point deadline)
{
    if (_have_credit(words))
        return true;
    // The TX lcore updates `consumed` within ~100 ns of a status packet's
    // arrival; spin on it, yield the CPU after tx_spin_us, and nap 20 us at a
    // time only once the wait is long (a timed start far ahead), where 20 us
    // is noise against the FPGA's buffer.
    const auto t0 = clk::now();
    const auto spin  = std::chrono::duration_cast<clk::duration>(std::chrono::duration<double>(_spin_s));
    const auto yield = std::chrono::duration_cast<clk::duration>(std::chrono::duration<double>(_yield_s));
    bool ok = false;
    worker_pool* pool    = _keep_warm ? _st->txp() : nullptr;
    auto last_ping       = t0;
    const auto ping_from = std::chrono::microseconds(200), ping_every = std::chrono::microseconds(100);
    for (unsigned i = 1;; i++) {
        if (_have_credit(words)) {
            ok = true;
            break;
        }
        if (i % 16) {
            cpu_relax();
            continue;
        }
        if (not _running.load(std::memory_order_relaxed))
            break;
        const auto now = clk::now();
        if (now >= deadline)
            break;
        const auto el = now - t0;
        // a long wait (the FPGA full ahead of a timed start): keep the pool's
        // workers inside their spin window, so the first packing after the
        // credit returns does not wait for them to wake
        if (pool and el >= ping_from and now - last_ping >= ping_every) {
            pool->run(pool->workers(), &tx_streamer_impl::_noop, nullptr);
            last_ping = now;
        }
        if (el < spin)
            cpu_relax();
        else if (el < yield)
            sched_yield();
        else
            std::this_thread::sleep_for(std::chrono::microseconds(20));
    }
    if (_stats.on) {
        _stats.waits++;
        _stats.wait_ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
            clk::now() - t0).count());
    }
    return ok;
}

void tx_streamer_impl::_build(size_t bi,
    size_t n,
    bool sob,
    bool eob,
    bool timed,
    const buffs_type* buffs,
    size_t in_off,
    size_t take)
{
    wire& c             = _w;
    const auto tb0      = _stats.on ? clk::now() : clk::time_point{};
    const size_t slots  = n * _nchan;
    const size_t bytes  = slots * _otw->slot_bytes; // whole 64-byte words (§10 granule)
    uint8_t* pkt        = _dpdk_tx->slot(bi); // UDP payload of mbuf bi
    uint32_t* h         = reinterpret_cast<uint32_t*>(pkt);
    const uint64_t tsf  = timed ? _pending_tsf : 0;
    h[0] = htole32((0x1u << 28) | (sob ? 1u << 25 : 0) | (eob ? 1u << 24 : 0)
                   | (timed ? 1u << 20 : 0) | ((c.seq & 0xFu) << 16)
                   | uint32_t(4 + bytes / 4));
    h[1] = htole32(c.sid);
    h[2] = htole32(uint32_t(tsf >> 32));
    h[3] = htole32(uint32_t(tsf));
    // the payload is planned: n CPU samples per channel, straight from the
    // application's buffers, or the residual + new samples + zero pad
    // assembled here
    pkt_plan& pp      = _plan[bi];
    pp.pay            = pkt + kHdrBytes;
    pp.n              = n;
    const size_t cpb  = _bytes_per_cpu_item;
    const size_t res  = _residual.empty() ? 0 : _residual[0].size() / cpb;
    if (res == 0 and take == n) {
        for (size_t i = 0; i < _dev_chans.size(); i++)
            pp.ins[i] = (*buffs)[i];
        pp.in_off = in_off;
    } else {
        std::vector<uint8_t>& a = _asm[bi];
        a.resize(_dev_chans.size() * n * cpb);
        for (size_t i = 0; i < _dev_chans.size(); i++) {
            uint8_t* d             = a.data() + i * n * cpb;
            std::vector<uint8_t>& r = _residual[i];
            const size_t rr        = std::min(res, n);
            std::memcpy(d, r.data(), rr * cpb);
            const size_t t = std::min(take, n - rr);
            if (t)
                std::memcpy(d + rr * cpb, static_cast<const uint8_t*>((*buffs)[i]) + in_off * cpb, t * cpb);
            if (rr + t < n)
                std::memset(d + (rr + t) * cpb, 0, (n - rr - t) * cpb);
            pp.ins[i] = d;
        }
        pp.in_off = 0;
    }
    for (auto& r : _residual)
        r.clear();
    c.seq++;
    c.sent_words += bytes / kTxWordBytes;
    c.pkt_ends.push_back(c.sent_words);
    _batch_len[bi] = uint32_t(kHdrBytes + bytes);
    if (_stats.on) {
        _stats.pkts++;
        _stats.build_ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
            clk::now() - tb0).count());
    }
}

void tx_streamer_impl::_task(void* ctx, size_t t)
{
    auto* self         = static_cast<tx_streamer_impl*>(ctx);
    const size_t p     = t / self->_job_per_pkt;
    const pkt_plan& pp = self->_plan[p];
    const size_t lo    = (t % self->_job_per_pkt) * self->_job_chunk;
    if (lo >= pp.n)
        return;
    const size_t m = std::min(self->_job_chunk, pp.n - lo);
    (*self->_kern)(pp.ins, pp.in_off + lo, m, pp.pay, lo);
}

void tx_streamer_impl::_flush()
{
    const size_t total = _batch_count;
    if (total == 0)
        return;
    _batch_count  = 0;
    const auto t0 = _stats.on ? clk::now() : clk::time_point{};
    size_t samps  = 0, maxn = 0;
    for (size_t i = 0; i < total; i++) {
        samps += _plan[i].n;
        maxn = std::max(maxn, _plan[i].n);
    }
    worker_pool* pool = _st->txp();
    if (pool and samps * _nchan >= _st->par_min_slots) {
        // whole packets, or packets cut in pieces of >= 64 samples when the
        // batch has fewer packets than threads
        const size_t parts = pool->workers() + 1;
        size_t per         = total >= parts ? 1 : (parts + total - 1) / total;
        size_t chunk       = (maxn + per - 1) / per;
        chunk              = std::max<size_t>(64, (chunk + 63) / 64 * 64);
        per                = (maxn + chunk - 1) / chunk;
        _job_chunk         = chunk;
        _job_per_pkt       = per;
        pool->run(total * per, &tx_streamer_impl::_task, this);
        _flush_par++;
        if (_stats.on)
            _stats.par_batches++;
    } else {
        for (size_t i = 0; i < total; i++)
            (*_kern)(_plan[i].ins, _plan[i].in_off, _plan[i].n, _plan[i].pay, 0);
        _flush_inline++;
    }
    if (_stats.on)
        _stats.build_ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
            clk::now() - t0).count());
    _dpdk_tx->send(_batch_len.data(), total, _hold_at); // in order, to the TX lcore
    _hold_at = dpdk::tx_session::kNoHold;
}

size_t tx_streamer_impl::send(const buffs_type& buffs,
    const size_t nsamps,
    const uhd::tx_metadata_t& md,
    const double timeout)
{
    dpdk::register_thread(); // a per-thread mbuf cache for the packet allocations
    std::lock_guard<std::mutex> lock(_send_mutex);
    const auto ts0 = _stats.on ? clk::now() : clk::time_point{};
    if (_stats.on) {
        if (_stats.calls++ == 0)
            _stats.first = ts0;
        if (_stats.have_exit) {
            const auto gap = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                ts0 - _stats.last_exit).count());
            _stats.between_ns += gap;
            if (gap > tx_stats::kSlowUs * 1000ull and _stats.slows.size() < _stats.slows.capacity())
                _stats.slows.push_back({_stats.last_exit, 'g', uint32_t(gap / 1000), 0, 0});
        }
    }
    struct exit_mark
    {
        tx_stats& s;
        clk::time_point t0;
        uint64_t build0, wait0;
        ~exit_mark()
        {
            if (not s.on)
                return;
            s.last_exit = clk::now();
            s.have_exit = true;
            const auto d = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                s.last_exit - t0).count());
            s.in_send_ns += d;
            if (d > tx_stats::kSlowUs * 1000ull and s.slows.size() < s.slows.capacity())
                s.slows.push_back({t0, 's', uint32_t(d / 1000), uint32_t((s.build_ns - build0) / 1000),
                    uint32_t((s.wait_ns - wait0) / 1000)});
        }
    } mark{_stats, ts0, _stats.build_ns, _stats.wait_ns};
    _resync_if_reloaded();
    if (buffs.size() < _dev_chans.size() and nsamps > 0)
        throw uhd::value_error("ZCU216: send() needs one buffer per channel");
    const auto deadline = deadline_in(timeout);
    const long long ticks =
        md.has_time_spec ? std::max(0LL, md.time_spec.to_ticks(_st->tick_rate)) : 0;
    const size_t spp_samps = _spp / _nchan; // samples per channel in a full packet

    if (md.start_of_burst and _in_burst) {
        if (not _warned_sob) {
            _warned_sob = true;
            ZLOG_WARN("start_of_burst inside a burst: closing the previous burst with EOB");
        }
        // what is still carried (a short tail, a timed lead-in) closes it
        const size_t res = _residual.empty() ? 0 : _residual[0].size() / _bytes_per_cpu_item;
        const size_t nq  = std::min(_spp / _nchan,
             std::max<size_t>(1, (res + _quantum - 1) / _quantum) * _quantum);
        if (_wait_credit(_words(nq), deadline)) {
            _build(0, nq, _pending_sob, true, _pending_sob and _pending_timed, &buffs, 0, 0);
            _batch_count = 1;
            _flush();
        }
        _in_burst = false;
    }
    if (not _in_burst) {
        _in_burst      = true;
        _pending_sob   = true;
        _pending_timed = false;
        _ack_since_eob = false;
    }
    if (_pending_sob and md.has_time_spec and not _pending_timed) {
        // The FPGA starts a timed burst on the fabric beat containing its TSF
        // (Protocol §6, §9). Start at that beat and prepend the lead as
        // zeros, so the first user sample plays exactly at the requested time.
        const double rate   = _st->get_tx_rate(0);
        const uint64_t tps  = _st->ticks_per_sample(rate);
        const uint64_t beat = _st->beat_slots() * _st->ticks_per_slot(rate);
        const uint64_t lead = (uint64_t(ticks) % beat) / tps;
        _pending_timed      = true;
        _pending_tsf        = uint64_t(ticks) - lead * tps;
        for (auto& r : _residual)
            r.insert(r.begin(), size_t(lead) * _bytes_per_cpu_item, uint8_t(0));
    }

    const bool eob = md.end_of_burst;
    size_t in_off  = 0;
    while (true) {
        // every requested channel's residual has the same length; with no
        // channel requested there is nothing to carry
        const size_t res   = _residual.empty() ? 0 : _residual[0].size() / _bytes_per_cpu_item;
        const size_t avail = res + (nsamps - in_off);
        size_t n;
        if (avail >= _quantum)
            n = std::min(spp_samps, avail / _quantum * _quantum);
        else if (eob)
            n = _quantum; // zero-padded final packet (one granule of slots)
        else {
            // keep the tail (< one granule of slots) for the next call, unconverted
            const size_t left = nsamps - in_off;
            for (size_t i = 0; i < _dev_chans.size() and left; i++) {
                const auto* in = static_cast<const uint8_t*>(buffs[i]) + in_off * _bytes_per_cpu_item;
                _residual[i].insert(_residual[i].end(), in, in + left * _bytes_per_cpu_item);
            }
            in_off = nsamps;
            break;
        }
        const bool last    = eob and avail <= n;
        const size_t words = _words(n);
        const size_t take  = std::min(n - std::min(res, n), nsamps - in_off);
        // credit covers everything already in the batch (sent_words counts it)
        if (not _have_credit(words)) {
            _flush(); // the FPGA only returns credit for what it has
            if (not _wait_credit(words, deadline))
                break; // timeout: report what was accepted
        }
        if (_pending_sob and not _pending_timed and not last)
            _hold_at = _batch_count; // an untimed burst of more than one packet
        _build(_batch_count, n, _pending_sob, last, _pending_sob and _pending_timed, &buffs,
            in_off, take);
        _batch_count++;
        in_off += take;
        _pending_sob = false;
        if (_batch_count == kBatch)
            _flush();
        if (last) {
            _in_burst = false;
            if (_stats.on) {
                _stats.last_eob = clk::now();
                _stats.have_eob = true;
            }
            break;
        }
    }
    _flush();
    return in_off;
}

} // namespace zcu216
