//
// uhd_zcu216 -- RX streamer implementation (Protocol §4, §5).
//
#include "zcu216_rx_streamer.hpp"
#include "zcu216_pool.hpp"
#include <uhd/transport/vrt_if_packet.hpp>
#include <algorithm>
#include <cstring>
#include <numeric>
#include <thread>

namespace zcu216 {

using clk = std::chrono::steady_clock;

static inline void cpu_relax()
{
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}

//! the producer side of one port ring, driven by a DPDK RX lcore (the only
//! producer of that ring)
struct rx_streamer_impl::dpdk_sink : public dpdk::rx_sink
{
    rx_streamer_impl* self = nullptr;
    port_rx* p             = nullptr;
    size_t reserve(uint8_t** bufs, size_t max) override
    {
        const uint64_t w = p->wr.load(std::memory_order_relaxed);
        const uint64_t r = p->rd.load(std::memory_order_acquire);
        const size_t n   = std::min(p->cap - size_t(w - r), max);
        if (bufs)
            for (size_t i = 0; i < n; i++)
                bufs[i] = p->slots[(w + i) % p->cap].buf;
        return n;
    }
    bool zero_copy() const override
    {
        return p->zc;
    }
    bool overflowed() override
    {
        if (not self->_overflow_hyst)
            return false;
        // a new overflow only if the stream was not already discarding
        return not self->_discard.exchange(true, std::memory_order_acq_rel);
    }
    bool discarding() override
    {
        if (not self->_discard.load(std::memory_order_relaxed))
            return false;
        // resume only once every ring is down to rx_overflow_resume of its
        // capacity (default 1/16: 256 of 4096 packets, ~2 MB). Resuming at
        // half full left recv() ~16 MB behind, past L3: it then read cold
        // buffers, stayed too slow and overflowed again for the rest of the
        // stream (one 16ch sc16 run in 20 sat at 71 %)
        for (auto& pp : self->_w.ports) {
            const uint64_t w = pp->wr.load(std::memory_order_relaxed);
            const uint64_t r = pp->rd.load(std::memory_order_acquire);
            if (size_t(w - r) > self->_resume_slots)
                return true;
        }
        self->_discard.store(false, std::memory_order_release);
        return false;
    }
    void commit_zc(void* const* mbufs, uint8_t* const* pays, const uint32_t* lens, size_t n) override
    {
        const uint64_t w = p->wr.load(std::memory_order_relaxed);
        for (size_t i = 0; i < n; i++) {
            slot& s = p->slots[(w + i) % p->cap];
            s.buf   = pays[i];
            s.len   = lens[i];
            s.mbuf  = mbufs[i];
            self->_parse_slot(s);
        }
        self->_publish(p, w, n);
    }
    void commit(const uint32_t* lens, size_t n) override
    {
        const uint64_t w = p->wr.load(std::memory_order_relaxed);
        for (size_t i = 0; i < n; i++) {
            slot& s = p->slots[(w + i) % p->cap];
            s.len   = lens[i];
            self->_parse_slot(s);
        }
        self->_publish(p, w, n);
    }
    size_t slot_bytes() const override
    {
        return p->slot_size;
    }
    void note_full() override
    {
        p->full_waits.fetch_add(1, std::memory_order_relaxed);
    }
};

rx_streamer_impl::rx_streamer_impl(
    std::shared_ptr<dev_state> st, const uhd::stream_args_t& args_in)
    : _st(std::move(st))
{
    uhd::stream_args_t args = args_in;
    if (args.channels.empty())
        args.channels = {0};
    // args: stream args override device args
    auto arg = [&](const std::string& k, const std::string& def) {
        if (args.args.has_key(k))
            return args.args[k];
        return _st->args.get(k, def);
    };

    // Protocol §10: the wire format (the FPGA converts), then wire -> cpu here
    // an empty otw_format: the device arg otw= if given, else sc16
    _otw = &otw_lookup(args.otw_format.empty() ? _st->args.get("otw", "") : args.otw_format);
    const auto offered = _st->otw_offered(true);
    if (std::find(offered.begin(), offered.end(), _otw->name) == offered.end()) {
        std::string have;
        for (const auto& f : offered)
            have += (have.empty() ? "" : ",") + f;
        throw uhd::value_error(std::string("ZCU216: RX otw_format ") + _otw->name
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

    _nchan = _st->nchan;
    // spp counts SLOTS: whole 64-byte FIFO words of the format (§10: 16 sc16,
    // 32 sc8, 64 sc12, 8 fc32 slots) and a multiple of N (§9), so a packet
    // carries spp / N whole samples of every channel; at most 8192 bytes
    const size_t B       = _otw->slot_bytes;
    const size_t quantum = std::lcm(_otw->granule, _nchan);
    const size_t max_spp =
        std::min((_st->mtu - 28 - kHdrBytes) / B, kMaxPayloadBytes / B) / quantum * quantum;
    // default: the daemon's spp (sc16 slots), i.e. the same payload bytes
    size_t spp = size_t(parse_ll(arg("spp", std::to_string(_st->default_spp * 4 / B)), "spp"));
    spp        = std::max(quantum, std::min(spp, max_spp));
    spp        = spp / quantum * quantum;
    _nports     = size_t(std::max(1LL, std::min(16LL, parse_ll(arg("nports", "2"), "nports"))));
    const auto port_base = uint16_t(parse_ll(arg("recv_port", std::to_string(kRecvPortBase)), "recv_port"));
    const size_t frames  = size_t(std::max(64LL, parse_ll(arg("num_recv_frames", "4096"), "num_recv_frames")));
    const bool pattern   = arg("pattern", "0") == "1" or arg("pattern", "0") == "true";
    _reorder_s           = parse_double(arg("reorder_ms", "2"), "reorder_ms") / 1000.0;
    if (const char* t = std::getenv("ZCU216_RX_TRACE"))
        _trace_left = std::max(0, std::atoi(t));

    const local_iface ifc = _st->host_data_iface();
    _generation           = _st->fpga_generation.load();

    for (const size_t ch : args.channels) {
        if (ch >= _st->num_rx)
            throw uhd::index_error("ZCU216: RX channel " + std::to_string(ch)
                                   + " out of range (device has " + std::to_string(_st->num_rx)
                                   + ")");
        if (std::find(_dev_chans.begin(), _dev_chans.end(), ch) != _dev_chans.end())
            throw uhd::value_error("ZCU216: RX channel listed twice");
        _dev_chans.push_back(ch);
    }

    // throws for a cpu/otw pair the module does not support
    _kern = std::make_unique<rx_kernel>(_otw->fmt, cpu, _nchan, _dev_chans);

    try {
        // One stream for every channel (§9): stream commands ignore <ch>, 0 it is.
        wire& c = _w;
        c.sid   = kRxSidBase;
        for (size_t k = 0; k < _nports; k++) {
            auto p  = std::make_unique<port_rx>();
            p->port = uint16_t(port_base + k);
            c.ports.push_back(std::move(p));
        }
        std::string req = "stream_setup 0 " + ifc.ip + " " + ifc.mac + " "
                          + std::to_string(port_base) + " " + std::to_string(_nports) + " "
                          + std::to_string(spp);
        if (pattern)
            req += " pattern=1";
        if (_otw->fmt != otw_t::sc16) // a daemon without §10 knows only sc16
            req += std::string(" otw=") + _otw->name;
        _setup_cmd     = req;
        const auto rep = _st->ctrl->call_tokens(req);
        if (rep.size() < 2)
            throw uhd::runtime_error("ZCU216: short reply to stream_setup");
        const size_t spp_r = size_t(parse_ll(rep[0], "stream_setup spp"));
        const size_t np_r  = size_t(parse_ll(rep[1], "stream_setup nports"));
        if (spp_r == 0 or spp_r % quantum or np_r == 0 or np_r > _nports)
            throw uhd::runtime_error("ZCU216: bad stream_setup reply: spp=" + rep[0]
                                     + " nports=" + rep[1] + " (spp must be a multiple of "
                                     + std::to_string(quantum) + ")");
        while (c.ports.size() > np_r)
            c.ports.pop_back();
        _spp = spp_r;
        // auto: ~250 us of samples per buffer, 32 packets at the high rates:
        // one packet is 1.7 us at 1.2 GS/s, a call per packet the Python
        // bindings cannot make (benchmark_rate.py received 7.7 %), and one
        // packet is below par_min_slots for the worker pool (otw fc32 at N = 1:
        // 51.9 % -> 100.0 % measured). At low rates fewer packets: a split-8
        // gNB's RX block (= this size) must stay well below its 1 ms RX->TX lead.
        _buf_pkts = buf_pkts_from_arg(arg("spb_pkts", "auto"), _st->get_rx_rate(0), _nchan, _spp);
        // ring memory
        const size_t slot_size = std::max<size_t>(
            ((kHdrBytes + _spp * B + 63) / 64) * 64 + 64, (_st->mtu + 63) / 64 * 64);
        // zero-copy (the default): slots point into the lcores' mbufs; the
        // port's pool was sized for num_recv_frames of them per queue
        const bool zc = _st->args.get("rx_zero_copy", "1") != "0";
        _overflow_hyst = arg("rx_overflow_hyst", "1") != "0";
        _rx_stats      = std::getenv("ZCU216_RX_STATS") != nullptr or std::getenv("ZCU216_TX_STATS") != nullptr;
        {
            const double f = parse_double(arg("rx_overflow_resume", "0.0625"), "rx_overflow_resume");
            if (not(f >= 0.0 and f <= 1.0))
                throw uhd::value_error("ZCU216: rx_overflow_resume must be in 0..1");
            _resume_slots = size_t(f * double(frames));
        }
        for (auto& p : c.ports) {
            p->cap       = frames;
            p->slot_size = slot_size;
            p->zc        = zc;
            p->slots.resize(frames);
            if (not zc) {
                p->mem.resize(frames * slot_size);
                for (size_t i = 0; i < frames; i++)
                    p->slots[i].buf = p->mem.data() + i * slot_size;
            }
        }
        std::string chs;
        for (const size_t ch : _dev_chans)
            chs += (chs.empty() ? "" : ",") + std::to_string(ch);
        ZLOG_INFO("RX ch " << chs << " of " << _nchan << ": " << c.ports.size()
                           << " DPDK queue(s) for "
                           << ifc.ip << ":" << port_base << (c.ports.size() > 1 ? "+" : "")
                           << ", spp " << _spp << " slots (" << _spp / _nchan
                           << " samples/channel)" << (pattern ? ", TEST PATTERN" : "")
                           << (c.ports.front()->zc ? ", zero-copy" : ", copied") << ", otw "
                           << _otw->name << " -> " << args.cpu_format << " (" << _kern->desc()
                           << ")"
                           << (_st->pool ? ", converted in parallel above "
                                               + std::to_string(_st->par_min_slots) + " slots/call"
                                         : ""));
        std::vector<dpdk::rx_sink*> sinks;
        for (auto& p : c.ports) {
            auto k  = std::make_unique<dpdk_sink>();
            k->self = this;
            k->p    = p.get();
            sinks.push_back(k.get());
            _dpdk_sinks.push_back(std::move(k));
        }
        _dpdk_rx = dpdk::start_rx(_st->dpdk, ifc.ip, port_base, sinks);
    } catch (...) {
        shutdown();
        throw;
    }
}

rx_streamer_impl::~rx_streamer_impl()
{
    shutdown();
}

void rx_streamer_impl::shutdown()
{
    std::lock_guard<std::mutex> lock(_shutdown_mutex);
    if (_shut)
        return;
    _shut = true;
    if (_streaming) {
        try {
            _st->ctrl->call("stream_cmd 0 stop_cont 0 1 0");
        } catch (const std::exception& e) {
            ZLOG_WARN("stop_cont on shutdown failed: " << e.what());
        }
        _streaming = false;
    }
    _running = false;
    {
        std::lock_guard<std::mutex> l(_wait_mutex);
        _wait_cv.notify_all();
    }
    _dpdk_rx.reset(); // stop the lcores (before the rings go) and remove the flows
    for (auto& p : _w.ports)
        if (p->zc)
            p->drop_all(); // mbufs still in the rings go back to the pool
    uint64_t pkts = 0, full = 0;
    for (auto& p : _w.ports) {
        pkts += p->pkts;
        full += p->full_waits;
    }
    ZLOG_DEBUG("RX closed: " << pkts << " pkts, " << _w.gaps << " gaps, " << _w.late
                             << " late, " << _w.bad << " bad, " << full << " ring-full polls; "
                             << _conv_par << " parallel / " << _conv_inline
                             << " single-thread conversions");
    if (_st->pool and (_conv_par or _conv_inline))
        ZLOG_INFO("RX conversion: " << _conv_par << " calls split across the pool ("
                                    << _st->pool->desc() << " + the application thread), "
                                    << _conv_inline << " in the application thread alone");
    if (_rx_stats and _recv_calls) {
        std::sort(_gaps.begin(), _gaps.end(), [](const rx_gap& a, const rx_gap& b) { return a.at_ms < b.at_ms; });
        std::string g;
        for (const auto& x : _gaps)
            g += std::string(g.empty() ? "" : ", ") + (x.kind == 'g' ? "gap " : "call ")
                 + std::to_string(int(x.dur_ms)) + " ms at " + std::to_string(x.at_ms / 1e3) + " s";
        ZLOG_INFO("RX stats: the application did not call recv() for > 10 ms " << _gap10 << " times (> 50 ms "
                  << _gap50 << ", > 100 ms " << _gap100 << "); recv() calls > 10 ms: " << _call10
                  << (g.empty() ? std::string() : "; largest: " + g));
    }
    if (_recv_calls) {
        const double tot = double(_ns_recv) / 1e9;
        auto pct = [&](uint64_t ns) { return tot > 0 ? 100.0 * double(ns) / double(_ns_recv) : 0.0; };
        const uint64_t plan = _ns_recv - std::min(_ns_recv, _ns_conv + _ns_rel + _ns_wait);
        ZLOG_INFO("RX recv() time: " << tot << " s in " << _recv_calls << " calls: converting "
                                     << pct(_ns_conv) << " %, releasing slots " << pct(_ns_rel)
                                     << " %, waiting for data " << pct(_ns_wait) << " %, planning (serial) "
                                     << pct(plan) << " %");
    }
}

void rx_streamer_impl::_note_gap(char kind, double at_ms, double dur_ms)
{
    if (kind == 'g') {
        _gap10++;
        if (dur_ms > 50.0)
            _gap50++;
        if (dur_ms > 100.0)
            _gap100++;
    } else {
        _call10++;
    }
    if (_gaps.size() < kGapKeep) {
        _gaps.push_back({at_ms, dur_ms, kind});
        return;
    }
    auto mn = std::min_element(_gaps.begin(), _gaps.end(),
        [](const rx_gap& a, const rx_gap& b) { return a.dur_ms < b.dur_ms; });
    if (dur_ms > mn->dur_ms)
        *mn = {at_ms, dur_ms, kind};
}

// ---------------------------------------------------------------------------
// producer side (DPDK RX lcores, through dpdk_sink)
// ---------------------------------------------------------------------------
void rx_streamer_impl::_parse_slot(slot& s) const
{
    s.valid = false;
    if (s.len < kHdrBytes or (s.len & 3))
        return;
    uhd::transport::vrt::if_packet_info_t info;
    info.num_packet_words32 = s.len / 4;
    try {
        uhd::transport::vrt::if_hdr_unpack_le(reinterpret_cast<const uint32_t*>(s.buf), info);
    } catch (const std::exception&) {
        return;
    }
    if (info.packet_type != uhd::transport::vrt::if_packet_info_t::PACKET_TYPE_DATA
        or not info.has_sid or not info.has_tsf or info.has_tlr)
        return;
    // §10: whole slots of the format, whole converter groups, whole samples
    // of every channel (§9); anything else is malformed
    const size_t bytes = info.num_payload_words32 * 4;
    if (bytes % _otw->slot_bytes)
        return;
    const size_t slots = bytes / _otw->slot_bytes;
    if (slots % _otw->group or slots % _nchan)
        return;
    s.nsamps    = uint32_t(slots / _nchan);
    s.hdr_bytes = uint32_t(info.num_header_words32 * 4);
    s.sid       = info.sid;
    s.tsf       = info.tsf;
    s.sob       = info.sob;
    s.eob       = info.eob;
    s.valid     = true;
}

void rx_streamer_impl::_publish(port_rx* p, uint64_t w, size_t n)
{
    p->pkts += uint64_t(n);
    p->wr.store(w + uint64_t(n), std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    if (_waiting.load(std::memory_order_relaxed)) {
        std::lock_guard<std::mutex> l(_wait_mutex);
        _wait_cv.notify_all();
    }
}

// ---------------------------------------------------------------------------
// consumer
// ---------------------------------------------------------------------------
template <typename Pred>
void rx_streamer_impl::_wait(clk::time_point until, Pred pred)
{
    const auto t0 = clk::now();
    struct acc_t
    {
        uint64_t& ns;
        clk::time_point t0;
        ~acc_t()
        {
            ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(clk::now() - t0).count());
        }
    } acc{_ns_wait, t0};
    for (int i = 0; i < 256; i++) {
        if (pred())
            return;
        cpu_relax();
    }
    std::unique_lock<std::mutex> lk(_wait_mutex);
    _waiting.store(true);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    if (not pred() and _running.load())
        _wait_cv.wait_until(lk, std::min(until, clk::now() + std::chrono::milliseconds(5)));
    _waiting.store(false);
}

rx_streamer_impl::port_rx* rx_streamer_impl::_pick(wire& c, clk::time_point deadline, bool block)
{
    while (_running.load(std::memory_order_relaxed)) {
        port_rx* best     = nullptr;
        uint64_t best_tsf = 0;
        size_t nonempty   = 0;
        for (auto& pp : c.ports) {
            port_rx* p = pp.get();
            if (p->empty())
                continue;
            nonempty++;
            const slot& s = p->head();
            if (not s.valid or (c.expected_valid and s.tsf == c.expected_tsf)) {
                c.reorder_armed = false;
                return p;
            }
            if (not best or s.tsf < best_tsf) {
                best     = p;
                best_tsf = s.tsf;
            }
        }
        if (best and nonempty == c.ports.size()) {
            c.reorder_armed = false;
            return best;
        }
        const auto now = clk::now();
        if (best) {
            // a lower TSF may still be on its way through another port
            if (not c.reorder_armed) {
                c.reorder_armed    = true;
                c.reorder_deadline = now + std::chrono::duration_cast<clk::duration>(
                                               std::chrono::duration<double>(_reorder_s));
            }
            if (now >= c.reorder_deadline) {
                c.reorder_armed = false;
                return best;
            }
        }
        if (not block)
            return nullptr;
        if (now >= deadline) {
            if (best)
                c.reorder_armed = false;
            return best;
        }
        const auto until = c.reorder_armed ? std::min(deadline, c.reorder_deadline) : deadline;
        _wait(until, [&] {
            size_t ne = 0;
            for (auto& pp : c.ports)
                ne += pp->empty() ? 0 : 1;
            return ne > nonempty;
        });
    }
    return nullptr;
}

bool rx_streamer_impl::_fetch(wire& c, clk::time_point deadline, bool block)
{
    // ticks per per-channel sample (= slots x ticks per slot), once per recv()
    const uint64_t tps = _tps;
    while (true) {
        if (c.late_pending or c.broken_pending)
            return false; // recv() reports the error first
        if (c.split_slot) {
            // the rest of a packet whose first part ended a chain link
            port_rx* p        = c.split_port;
            slot& s           = *c.split_slot;
            const size_t from = c.split_off;
            c.split_port      = nullptr;
            c.split_slot      = nullptr;
            if (_take(c, p, s, from, false, tps))
                return true;
            continue;
        }
        port_rx* p = _pick(c, deadline, block);
        if (not p)
            return false;
        slot& s = p->head();
        if (not s.valid or s.sid != c.sid) {
            c.bad++;
            if (not _warned_bad) {
                _warned_bad = true;
                ZLOG_WARN("RX: dropping malformed packet (len " << s.len
                                  << ", sid 0x" << std::hex << s.sid << std::dec
                                  << "); further ones are only counted");
            }
            p->pop();
            continue;
        }
        if (_trace_left > 0) { // ZCU216_RX_TRACE=<n>: the first n packets the merge takes
            _trace_left--;
            ZLOG_INFO("RX trace: port " << p->port << " tsf " << s.tsf << " nsamps " << s.nsamps
                      << " sob " << s.sob << " eob " << s.eob << " | expected "
                      << (c.expected_valid ? std::to_string(c.expected_tsf) : std::string("-"))
                      << " | queued on every port: " << [&] {
                             std::string q;
                             for (auto& pp : c.ports)
                                 q += std::to_string(pp->port) + (pp->empty() ? ":- " : ":" + std::to_string(pp->head().tsf) + " ");
                             return q;
                         }());
        }
        if (c.expected_valid and not s.sob and s.tsf != c.expected_tsf) {
            if (s.tsf < c.expected_tsf) {
                // older than what we already delivered: late reorder or dup
                c.late++;
                if (not _warned_late) {
                    _warned_late = true;
                    ZLOG_WARN("RX: dropping late packet (TSF " << s.tsf
                                      << " < expected " << c.expected_tsf
                                      << "); raise reorder_ms if this repeats");
                }
                p->pop();
                continue;
            }
            if (not c.gap_pending) {
                c.gap_pending = true;
                c.gap_tsf     = c.expected_tsf;
            }
            c.gaps++;
            // what the gap looked like (the first few per stream): a missing
            // packet, a burst boundary, or a reorder
            if (_gap_logs < 4) {
                _gap_logs++;
                ZLOG_WARN("RX: gap: expected TSF " << c.expected_tsf << ", got " << s.tsf << " (+"
                          << (s.tsf - c.expected_tsf) / std::max<uint64_t>(1, tps)
                          << " samples/ch) on UDP port " << p->port << "; packet sob " << s.sob
                          << " eob " << s.eob << " nsamps " << s.nsamps);
            }
        }
        c.expected_tsf   = s.tsf + uint64_t(s.nsamps) * tps;
        c.expected_valid = not s.eob;

        const bool pkt_sob = s.sob, pkt_eob = s.eob;
        if (pkt_sob) {
            // a new FPGA burst: the next command that is not a chain link
            c.discard_to_eob = false;
            c.limit_active   = false;
            c.skip_left      = 0;
            c.sob_carry      = false;
            c.cur_kind       = burst::K_CONT;
            burst b;
            bool have = false;
            {
                std::lock_guard<std::mutex> l(_burst_mutex);
                // links still queued belong to a burst that is over
                while (not c.pending.empty() and c.pending.front().link)
                    c.pending.pop_front();
                if (not c.pending.empty()) {
                    b = c.pending.front();
                    c.pending.pop_front();
                    have = true;
                }
            }
            if (have) {
                const uint64_t beat =
                    _st->beat_slots() * _st->ticks_per_slot(_st->get_rx_rate(0));
                if (b.timed and s.tsf > b.start - b.start % beat) {
                    // Protocol §4a: the FPGA starts a late timed command at
                    // once (and the daemon sends a short marker burst for
                    // one already late when issued). Like a USRP: no samples,
                    // ERROR_CODE_LATE_COMMAND; its chain links die with it.
                    c.late_cmds++;
                    c.late_pending = true;
                    c.err_tsf      = s.tsf;
                    {
                        std::lock_guard<std::mutex> l(_burst_mutex);
                        while (not c.pending.empty() and c.pending.front().link)
                            c.pending.pop_front();
                        if (b.kind == burst::K_MORE and c.pending.empty() and c.chain == CH_OPEN)
                            c.chain = CH_NONE;
                    }
                    c.discard_to_eob = not pkt_eob;
                    p->pop();
                    return false;
                }
                c.cur_kind = b.kind;
                if (b.timed and b.start > s.tsf)
                    c.skip_left = (b.start - s.tsf + tps - 1) / tps;
                if (b.count) {
                    c.limit_active = true;
                    c.limit_left   = b.count;
                }
            }
        } else if (c.discard_to_eob) {
            p->pop();
            if (pkt_eob)
                c.discard_to_eob = false;
            continue;
        }
        if (_take(c, p, s, 0, pkt_sob, tps))
            return true;
    }
}

bool rx_streamer_impl::_take(wire& c, port_rx* p, slot& s, size_t from, bool pkt_sob, uint64_t tps)
{
    const size_t skip = from + size_t(std::min<uint64_t>(c.skip_left, s.nsamps - from));
    c.skip_left -= skip - from;
    size_t take = s.nsamps - skip;
    bool eob    = s.eob;
    if (c.limit_active) {
        if (take >= c.limit_left) {
            take           = size_t(c.limit_left);
            c.limit_active = false;
            c.limit_left   = 0;
            if (c.cur_kind == burst::K_MORE) {
                // the end of a num_more link: the next one continues the
                // stream seamlessly if the daemon joined it (§4a); otherwise
                // the chain is broken -- unless a deliberately separate
                // command follows (a timed one), like a USRP's queue
                eob = false;
                burst nb;
                bool next = false, broken = false;
                {
                    std::lock_guard<std::mutex> l(_burst_mutex);
                    if (not c.pending.empty() and c.pending.front().link) {
                        nb = c.pending.front();
                        c.pending.pop_front();
                        next = true;
                    } else if (c.pending.empty()) {
                        broken  = true;
                        c.chain = CH_BROKEN; // a later command is a new burst
                    } else {
                        broken = c.pending.front().wanted_link;
                    }
                }
                if (next) {
                    c.cur_kind     = nb.kind;
                    c.limit_active = nb.count != 0;
                    c.limit_left   = nb.count;
                    if (skip + take < s.nsamps) {
                        c.split_port = p;
                        c.split_slot = &s;
                        c.split_off  = skip + take;
                    }
                } else {
                    if (broken) {
                        c.broken_pending = true;
                        c.broken++;
                        c.err_tsf = s.tsf + uint64_t(skip + take) * tps;
                    }
                    c.discard_to_eob = not s.eob;
                }
            } else {
                // num_done: exactly the samples asked for, then EOB
                c.discard_to_eob = not s.eob;
                eob              = true;
            }
        } else {
            c.limit_left -= take;
        }
    }
    const bool deliver_sob = pkt_sob or c.sob_carry;
    if (take == 0 and not eob) {
        c.sob_carry = deliver_sob;
        if (c.split_slot != &s)
            p->pop();
        return false;
    }
    c.sob_carry = false;
    c.cur_port  = p;
    c.cur       = &s;
    c.off       = skip;
    c.remaining = take;
    c.cur_tsf   = s.tsf + uint64_t(skip) * tps;
    c.cur_sob   = deliver_sob;
    c.cur_eob   = eob;
    if (from == 0)
        c.frag_base = skip;
    return true;
}

void rx_streamer_impl::_advance(wire& c, size_t n)
{
    const uint64_t tps = _tps;
    c.off += n;
    c.remaining -= n;
    c.cur_tsf += uint64_t(n) * tps;
    if (n)
        c.cur_sob = false;
}

void rx_streamer_impl::_release(wire& c)
{
    // the payload stays valid until _convert releases it; a packet split at a
    // chain link stays at its port's head until its second part is taken
    if (c.cur_port and c.split_slot != c.cur)
        c.cur_port->pop();
    c.cur_port  = nullptr;
    c.cur       = nullptr;
    c.remaining = 0;
}

// ---------------------------------------------------------------------------
// conversion: the planned segments -> the application's buffers
// ---------------------------------------------------------------------------
void rx_streamer_impl::_task(void* ctx, size_t t)
{
    auto* self      = static_cast<rx_streamer_impl*>(ctx);
    const auto& seg = self->_segs;
    // output samples [a, b): the batch starts at its first segment's offset
    const size_t base = seg.front().out;
    const size_t a    = base + t * self->_job_chunk;
    const size_t b    = std::min(base + self->_job_total, a + self->_job_chunk);
    // segments are contiguous in output space, in order
    size_t i = 0;
    while (i < seg.size() and seg[i].out + seg[i].n <= a)
        i++;
    for (; i < seg.size() and seg[i].out < b; i++) {
        const size_t lo = std::max(a, seg[i].out), hi = std::min(b, seg[i].out + seg[i].n);
        (*self->_kern)(seg[i].pay, seg[i].off + (lo - seg[i].out), hi - lo, self->_job_outs, lo);
    }
}

void rx_streamer_impl::_convert(const buffs_type& buffs)
{
    const auto t0 = clk::now();
    if (not _segs.empty()) {
        for (size_t j = 0; j < _dev_chans.size(); j++)
            _job_outs[j] = buffs[j];
        const size_t total = _seg_samps;
        worker_pool* pool  = _st->pool.get();
        if (pool and total * _nchan >= _st->par_min_slots) {
            // disjoint output ranges, at least par_min_slots / 4 slots each,
            // in multiples of 64 samples
            const size_t parts = pool->workers() + 1;
            size_t chunk       = std::max((total + parts - 1) / parts,
                std::max<size_t>(1, _st->par_min_slots / 4 / _nchan));
            chunk              = (chunk + 63) / 64 * 64;
            _job_chunk         = chunk;
            _job_total         = total;
            pool->run((total + chunk - 1) / chunk, &rx_streamer_impl::_task, this);
            _conv_par++;
        } else {
            for (const auto& g : _segs)
                (*_kern)(g.pay, g.off, g.n, _job_outs, g.out);
            _conv_inline++;
        }
        _segs.clear();
        _seg_samps = 0;
    }
    const auto t1 = clk::now();
    for (auto& p : _w.ports)
        p->release();
    _ns_conv += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
    _ns_rel += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(clk::now() - t1).count());
}

size_t rx_streamer_impl::recv(const buffs_type& buffs,
    const size_t nsamps,
    uhd::rx_metadata_t& md,
    const double timeout,
    const bool one_packet)
{
    dpdk::register_thread(); // a per-thread mbuf cache for releasing slots
    if (_has_held.load()) { // a chain opened "now" is sent when it is read
        std::lock_guard<std::mutex> l(_burst_mutex);
        _flush_held_locked();
    }
    // the rate only changes with an FPGA reload: once per call, not per packet
    _tps = _st->ticks_per_sample(_st->get_rx_rate(0));
    md.reset();
    if (buffs.size() < _dev_chans.size())
        throw uhd::value_error("ZCU216: recv() needs one buffer per channel");
    if (nsamps == 0)
        return 0;
    const auto t_call = clk::now();
    if (_rx_stats) {
        if (_recv_calls == 0)
            _first_call = t_call;
        if (_have_exit) {
            const double g = std::chrono::duration<double, std::milli>(t_call - _last_exit).count();
            if (g > 10.0)
                _note_gap('g', std::chrono::duration<double, std::milli>(_last_exit - _first_call).count(), g);
        }
    }
    struct call_acc_t
    {
        rx_streamer_impl* self;
        clk::time_point t0;
        ~call_acc_t()
        {
            const auto t1 = clk::now();
            self->_ns_recv += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
            self->_recv_calls++;
            if (self->_rx_stats) {
                self->_last_exit = t1;
                self->_have_exit = true;
                const double d   = std::chrono::duration<double, std::milli>(t1 - t0).count();
                if (d > 10.0)
                    self->_note_gap('c', std::chrono::duration<double, std::milli>(t0 - self->_first_call).count(), d);
            }
        }
    } call_acc{this, t_call};
    const double tick = _st->tick_rate;
    const auto deadline =
        clk::now()
        + std::chrono::duration_cast<clk::duration>(std::chrono::duration<double>(std::max(0.0, timeout)));
    // plan at most this many packets before converting (bounds how long ring
    // slots stay held)
    constexpr size_t kMaxSegs = 256;
    wire& c      = _w;
    size_t accum = 0;
    while (true) {
        // inline messages (Protocol §4a): reported with no samples, after
        // the samples before them
        if (c.late_pending or c.broken_pending) {
            if (accum > 0)
                break;
            if (c.late_pending) {
                c.late_pending = false;
                md.error_code  = uhd::rx_metadata_t::ERROR_CODE_LATE_COMMAND;
                UHD_LOG_FASTPATH("L");
            } else {
                c.broken_pending = false;
                md.error_code    = uhd::rx_metadata_t::ERROR_CODE_BROKEN_CHAIN;
            }
            md.has_time_spec = true;
            md.time_spec     = uhd::time_spec_t::from_ticks((long long)c.err_tsf, tick);
            break;
        }
        if (c.cur == nullptr and not _fetch(c, deadline, false)) {
            if (c.late_pending or c.broken_pending)
                continue;
            // nothing next yet: convert what is planned while waiting
            _convert(buffs);
            if (not _fetch(c, deadline, true)) {
                if (c.late_pending or c.broken_pending)
                    continue;
                if (accum == 0)
                    md.error_code = uhd::rx_metadata_t::ERROR_CODE_TIMEOUT;
                break;
            }
        }
        // loss: report once, at the time of the first missing sample
        if (c.gap_pending) {
            if (accum > 0)
                break;
            c.gap_pending = false;
            _overflows++;
            md.error_code      = uhd::rx_metadata_t::ERROR_CODE_OVERFLOW;
            md.out_of_sequence = false;
            md.has_time_spec   = true;
            md.time_spec       = uhd::time_spec_t::from_ticks((long long)c.gap_tsf, tick);
            UHD_LOG_FASTPATH("O");
            break;
        }
        if (accum > 0 and c.cur_sob)
            break; // a new burst starts: report its SOB/time next call
        if (accum == 0) {
            md.has_time_spec  = true;
            md.time_spec      = uhd::time_spec_t::from_ticks((long long)c.cur_tsf, tick);
            md.start_of_burst = c.cur_sob;
            // samples of this packet that earlier recv() calls returned
            md.fragment_offset = c.off - c.frag_base;
        }
        const size_t n = std::min(nsamps - accum, c.remaining);
        if (n) {
            _segs.push_back({c.cur->buf + c.cur->hdr_bytes, c.off, n, accum});
            _seg_samps += n;
        }
        _advance(c, n);
        accum += n;
        const bool eob = c.remaining == 0 and c.cur_eob;
        if (c.remaining == 0)
            _release(c);
        if (eob) {
            md.end_of_burst = true;
            break;
        }
        if (one_packet or accum >= nsamps)
            break;
        if (_segs.size() >= kMaxSegs)
            _convert(buffs);
    }
    // the call ended inside a packet: the rest comes with the next call
    md.more_fragments = (c.cur != nullptr and c.remaining > 0) or c.split_slot != nullptr;
    _convert(buffs);
    return accum;
}

void rx_streamer_impl::_resync_if_reloaded()
{
    const uint64_t g = _st->fpga_generation.load();
    if (g == _generation)
        return;
    ZLOG_WARN("RX: the FPGA was reloaded (rate change) after this streamer was set up; "
              "redoing stream_setup. Create streamers after set_rx_rate() to avoid this.");
    const auto rep = _st->ctrl->call_tokens(_setup_cmd);
    if (rep.size() < 2 or size_t(parse_ll(rep[0], "spp")) != _spp
        or size_t(parse_ll(rep[1], "nports")) != _w.ports.size())
        throw uhd::runtime_error("ZCU216: stream_setup after FPGA reload changed spp/nports; "
                                 "recreate the RX streamer");
    wire& c          = _w;
    c.expected_valid = false;
    c.gap_pending    = false;
    c.limit_active   = false;
    c.discard_to_eob = false;
    c.skip_left      = 0;
    c.late_pending = c.broken_pending = false;
    c.split_port   = nullptr;
    c.split_slot   = nullptr;
    {
        std::lock_guard<std::mutex> l(_burst_mutex);
        c.pending.clear();
        c.chain           = CH_NONE;
        c.chain_end_valid = false;
    }
    _streaming  = false;
    _generation = g;
}

void rx_streamer_impl::issue_stream_cmd(const uhd::stream_cmd_t& cmd)
{
    _resync_if_reloaded();
    const bool now       = cmd.stream_now;
    long long t          = now ? 0 : cmd.time_spec.to_ticks(_st->tick_rate);
    const uint64_t ticks = uint64_t(std::max(0LL, t));
    const uint64_t num   = uint64_t(cmd.num_samps); // per channel
    using sc             = uhd::stream_cmd_t;

    // The daemon queues commands in order (Protocol §4a); the reply says
    // whether one joined the open num_more chain. Decided under the mutex
    // that recv() takes at the end of a chain link, so both sides agree.
    std::lock_guard<std::mutex> l(_burst_mutex);
    if (cmd.stream_mode == sc::STREAM_MODE_STOP_CONTINUOUS) {
        _held     = held_cmd{};
        _has_held = false;
        _st->ctrl->call("stream_cmd 0 stop_cont 0 1 0");
        _w.pending.clear();
        _w.chain           = CH_NONE;
        _w.chain_end_valid = false;
        _streaming         = false;
        return;
    }
    const bool more = cmd.stream_mode == sc::STREAM_MODE_NUM_SAMPS_AND_MORE;
    const bool done = cmd.stream_mode == sc::STREAM_MODE_NUM_SAMPS_AND_DONE;
    if (_held.valid) {
        if (now and (more or done)) { // a continuation of the held chain
            _held.count += num;
            if (done) { // closed: nothing more can merge, send it now
                _held.done = true;
                _flush_held_locked();
            }
            return;
        }
        _flush_held_locked();
    }
    if (more and now and _w.chain != CH_OPEN) { // a chain opens now: hold it
        _held     = held_cmd{true, false, num};
        _has_held = true;
        return;
    }
    _issue_locked(cmd.stream_mode, num, now, ticks);
}

void rx_streamer_impl::_flush_held_locked()
{
    if (not _held.valid)
        return;
    const held_cmd h = _held;
    _held            = held_cmd{};
    _has_held        = false;
    _issue_locked(h.done ? uhd::stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_DONE
                         : uhd::stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_MORE,
        h.count, true, 0);
}

void rx_streamer_impl::_issue_locked(
    uhd::stream_cmd_t::stream_mode_t smode, uint64_t num, bool now, uint64_t ticks)
{
    wire& c = _w;
    const uint64_t tps = _st->ticks_per_sample(_st->get_rx_rate(0));
    // A timed start begins on the fabric beat containing the time (§4, §9);
    // ask for the lead-in too so the trimmed burst is still complete.
    const uint64_t beat = _st->beat_slots() * _st->ticks_per_slot(_st->get_rx_rate(0));
    burst b;
    std::string mode;
    switch (smode) {
        case uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS:
            mode   = "start_cont";
            b.kind = burst::K_CONT;
            break;
        case uhd::stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_DONE:
            mode    = "num_done";
            b.kind  = burst::K_DONE;
            b.count = num;
            break;
        case uhd::stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_MORE:
            mode    = "num_more";
            b.kind  = burst::K_MORE;
            b.count = num;
            break;
        default:
            throw uhd::value_error("ZCU216: unsupported stream mode");
    }
    // a continuation of the open chain: stream_now, or timed at exactly its end
    const bool cont = c.chain == CH_OPEN
                      and (now or (c.chain_end_valid and ticks == c.chain_end));
    const uint64_t lead = (now or cont) ? 0 : ((ticks % beat) + tps - 1) / tps;
    const uint64_t req  = b.kind == burst::K_CONT ? 0 : (num + lead) * _nchan; // SLOTS (§9)
    std::string line    = "stream_cmd 0 " + mode + " " + std::to_string(req) + " "
                       + (now ? "1" : "0") + " " + std::to_string(ticks);
    if (cont)
        line += " cont=1";
    const auto rep    = _st->ctrl->call_tokens(line);
    const bool joined = cont and not rep.empty() and rep[0] == "cont";
    b.timed           = not now;
    b.start           = ticks;
    b.link            = joined;
    b.wanted_link     = cont and not joined;
    c.pending.push_back(b);
    if (b.kind == burst::K_MORE) {
        if (joined) {
            if (c.chain_end_valid)
                c.chain_end += num * tps;
        } else {
            c.chain           = CH_OPEN;
            c.chain_end_valid = not now;
            c.chain_end       = ticks + num * tps;
        }
    } else {
        c.chain           = CH_NONE;
        c.chain_end_valid = false;
    }
    _streaming = true;
}

} // namespace zcu216
