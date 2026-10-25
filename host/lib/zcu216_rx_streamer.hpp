//
// uhd_zcu216 -- RX streamer (Protocol §4, §5).
//
// The DPDK RX lcores (zcu216_dpdk.cpp) fill one single-producer/single-
// consumer ring of packet slots per UDP port (= NIC queue). recv() works in
// two steps:
//
//  1. plan (application thread): merge the rings by TSF, detect gaps, trim
//     timed/num_done bursts to exactly what was asked for, and list the
//     packet stretches that cover the request -- "segments" (payload, first
//     sample, count, output offset). The ring slots stay owned by the
//     consumer (a private read cursor runs ahead of the published one) until
//     step 2 is done with them.
//  2. convert: one fused kernel per stretch (zcu216_kernels.hpp) de-interleaves
//     the N channels of the wire stream (Protocol §9: slot i = channel i % N,
//     sample i / N) into the requested channels' buffers and converts the OTW
//     format (Protocol §10) to the CPU format. A large request is cut into
//     disjoint output ranges that the worker pool (zcu216_pool.hpp) and the
//     application thread convert in parallel. Then the slots are released.
//
// Planning stops early to convert what it has whenever the next packet has
// not arrived yet, so conversion overlaps the wait.
//
#pragma once

#include "zcu216_common.hpp"
#include "zcu216_dpdk.hpp"
#include "zcu216_kernels.hpp"
#include "zcu216_otw.hpp"
#include <uhd/stream.hpp>
#include <uhd/version.hpp>
#include <uhd/exception.hpp>
#include <condition_variable>
#include <deque>

namespace zcu216 {

class rx_streamer_impl : public uhd::rx_streamer
{
public:
    using sptr = std::shared_ptr<rx_streamer_impl>;
    rx_streamer_impl(std::shared_ptr<dev_state> st, const uhd::stream_args_t& args);
    ~rx_streamer_impl() override;

    size_t get_num_channels(void) const override
    {
        return _dev_chans.size();
    }
#if UHD_VERSION >= 4080000
    // UHD >= 4.8 streamers carry RFNoC action hooks; this is not an RFNoC
    // device, so there is nothing to post an action to.
    void post_input_action(const std::shared_ptr<uhd::rfnoc::action_info>&, const size_t) override
    {
        throw uhd::not_implemented_error("zcu216: post_input_action (RFNoC) is not supported");
    }
#endif
    //! samples per channel in one application buffer: _buf_pkts packets
    //! (device/stream arg spb_pkts=, default auto: ~250 us, 1..32), so a
    //! buffer is never only a fraction of a packet per channel.
    //! UHD apps size their buffers and calls by this; one packet per call at
    //! N = 8 or 16 meant a recv()/send() every 0.85 us.
    size_t get_max_num_samps(void) const override
    {
        return _buf_pkts * (_spp / _nchan);
    }
    size_t recv(const buffs_type& buffs,
        const size_t nsamps_per_buff,
        uhd::rx_metadata_t& metadata,
        const double timeout,
        const bool one_packet) override;
    void issue_stream_cmd(const uhd::stream_cmd_t& stream_cmd) override;

    //! Stop streaming (best effort), stop the DPDK RX lcores. Idempotent.
    void shutdown();
    //! FPGA reloaded (rate change) since setup? Then redo stream_setup and
    //! forget continuity/burst state. Called before each stream command.
    void _resync_if_reloaded();
    const std::vector<size_t>& device_channels() const
    {
        return _dev_chans;
    }

private:
    struct slot
    {
        uint8_t* buf      = nullptr;
        uint32_t len      = 0;
        uint32_t nsamps   = 0; // samples PER CHANNEL (slots / N)
        uint32_t hdr_bytes = 0;
        uint32_t sid      = 0;
        uint64_t tsf      = 0;
        bool sob = false, eob = false, valid = false;
        void* mbuf        = nullptr; // zero-copy: the DPDK mbuf buf points into
    };
    //! one host UDP port = one NIC RX queue; filled by exactly one lcore
    struct port_rx
    {
        uint16_t port = 0;
        std::vector<slot> slots;
        std::vector<uint8_t> mem;
        size_t cap = 0, slot_size = 0;
        alignas(64) std::atomic<uint64_t> wr{0}; // producer: published up to
        alignas(64) std::atomic<uint64_t> rd{0}; // consumer: released up to
        uint64_t cons = 0;                       // consumer: next slot to plan (>= rd)
        std::atomic<uint64_t> pkts{0}, full_waits{0};
        bool empty() const
        {
            return cons == wr.load(std::memory_order_acquire);
        }
        slot& head()
        {
            return slots[cons % cap];
        }
        //! done planning the head slot; it stays valid until release()
        void pop()
        {
            cons++;
        }
        bool zc = false; // slots point into DPDK mbufs (rx_zero_copy)
        //! hand every popped slot back to the producer (zero-copy: and their
        //! mbufs back to the pool)
        void release()
        {
            if (zc) {
                void* m[64];
                size_t k = 0;
                for (uint64_t i = rd.load(std::memory_order_relaxed); i != cons; i++) {
                    slot& s = slots[i % cap];
                    if (s.mbuf)
                        m[k++] = s.mbuf;
                    s.mbuf = nullptr;
                    if (k == 64) {
                        dpdk::free_rx_mbufs_raw(m, k);
                        k = 0;
                    }
                }
                dpdk::free_rx_mbufs_raw(m, k);
            }
            rd.store(cons, std::memory_order_release);
        }
        //! zero-copy: free the mbufs of every published slot (after the
        //! producer stopped)
        void drop_all()
        {
            cons = wr.load(std::memory_order_acquire);
            release();
        }
    };
    //! One stream command the daemon accepted (Protocol §4a), in its
    //! order. A command is its own FPGA burst (one SOB) unless the daemon
    //! joined it to the open num_more chain before it ("link": no SOB, its
    //! samples follow the previous command's seamlessly).
    struct burst
    {
        enum kind_t { K_CONT, K_DONE, K_MORE };
        kind_t kind       = K_CONT;
        bool timed        = false;
        uint64_t start    = 0; // requested start, ticks
        uint64_t count    = 0; // samples per channel; 0 = unlimited
        bool link         = false; // daemon reply "cont": continues the chain
        bool wanted_link  = false; // sent as a continuation, became a new burst
    };
    //! the host's view of the latest num_more chain, for issue_stream_cmd()
    enum chain_t { CH_NONE, CH_OPEN, CH_BROKEN };
    //! The one wire stream (all N channels). Offsets and counts below are in
    //! samples per channel; one sample = N consecutive slots.
    struct wire
    {
        uint32_t sid  = 0;
        std::vector<std::unique_ptr<port_rx>> ports;
        // cursor into the current packet
        port_rx* cur_port = nullptr;
        slot* cur         = nullptr;
        size_t off = 0, remaining = 0;
        uint64_t cur_tsf = 0;
        bool cur_sob = false, cur_eob = false;
        // a packet from another port is waited for until reorder_deadline
        bool reorder_armed = false;
        std::chrono::steady_clock::time_point reorder_deadline;
        // continuity
        bool expected_valid   = false;
        uint64_t expected_tsf = 0;
        bool gap_pending      = false;
        uint64_t gap_tsf      = 0;
        // burst trimming (Protocol §4 granularity) and the command queue (§4a)
        std::deque<burst> pending; // guarded by _burst_mutex
        chain_t chain        = CH_NONE; // guarded by _burst_mutex
        bool chain_end_valid = false;   // guarded by _burst_mutex
        uint64_t chain_end   = 0;       // ticks: where a timed chain ends
        burst::kind_t cur_kind = burst::K_CONT; // the command being delivered
        uint64_t skip_left  = 0;
        bool sob_carry      = false;
        bool limit_active   = false;
        uint64_t limit_left = 0;
        bool discard_to_eob = false;
        // a chain link ended inside a packet: the rest of it belongs to the
        // next link (the slot stays at its port's head until consumed)
        port_rx* split_port = nullptr;
        slot* split_slot    = nullptr;
        size_t split_off    = 0;
        // inline errors for the next recv() (UHD reports them with 0 samples)
        bool late_pending   = false; // ERROR_CODE_LATE_COMMAND
        bool broken_pending = false; // ERROR_CODE_BROKEN_CHAIN
        uint64_t err_tsf    = 0;
        size_t frag_base    = 0;     // first deliverable sample of the cursor packet
        // stats
        uint64_t gaps = 0, late = 0, bad = 0, late_cmds = 0, broken = 0;
    };

    //! producer side, run on the DPDK RX lcores: VRT header -> slot fields
    //! (sets valid), then publish n filled slots starting at ring index w and
    //! wake the consumer
    void _parse_slot(slot& s) const;
    void _publish(port_rx* p, uint64_t w, size_t n);
    //! adapter that lets a DPDK RX lcore fill one port ring
    struct dpdk_sink;
    //! the port whose head packet comes next; block = false returns nullptr
    //! instead of waiting (for a packet, or for the reorder window)
    port_rx* _pick(wire& c, std::chrono::steady_clock::time_point deadline, bool block);
    bool _fetch(wire& c, std::chrono::steady_clock::time_point deadline, bool block);
    //! the deliverable part of packet s from sample `from` on under the
    //! current command (limits, chain links); false = nothing in it
    bool _take(wire& c, port_rx* p, slot& s, size_t from, bool sob, uint64_t tps);
    void _advance(wire& c, size_t n);
    void _release(wire& c);

    //! a packet stretch planned for conversion (samples per channel)
    struct segment
    {
        const uint8_t* pay; // payload, slot 0
        size_t off, n;      // first sample in the packet, count
        size_t out;         // first output sample (recv() buffer offset)
    };
    //! convert the planned segments into buffs (in parallel when large), then
    //! release their ring slots
    void _convert(const buffs_type& buffs);
    static void _task(void* ctx, size_t t);
    template <typename Pred>
    void _wait(std::chrono::steady_clock::time_point until, Pred pred);

    std::shared_ptr<dev_state> _st;
    std::vector<size_t> _dev_chans; // requested channels, in buffer order
    size_t _nchan = 1;              // N: channels on the wire
    std::string _setup_cmd;         // for re-setup after a reload
    uint64_t _generation = 0;
    wire _w;
    size_t _spp = kDefaultSpp; // slots per packet
    size_t _buf_pkts = 1;      // packets per get_max_num_samps()
    bool _overflow_hyst = true; // rx_overflow_hyst: on overflow, discard until every ring drained to _resume_slots
    uint64_t _tps = 1;           // ticks per sample, refreshed at each recv()
    size_t _resume_slots = 0; // overflow: discard until every ring holds at most this many
    std::atomic<bool> _discard{false}; // the stream is discarding (DPDK lcores)
    size_t _nports = 1;
    const otw_info* _otw = nullptr; // Protocol §10 wire format
    std::unique_ptr<rx_kernel> _kern; // wire -> cpu, de-interleave
    std::vector<segment> _segs;       // planned, not yet converted
    size_t _seg_samps = 0;
    // conversion job handed to the pool (valid during _convert)
    void* _job_outs[kMaxChans] = {};
    size_t _job_chunk = 0, _job_total = 0;
    uint64_t _conv_par = 0, _conv_inline = 0;
    // time accounting of recv() (ns): all of it, converting, releasing slots, waiting for data
    uint64_t _ns_recv = 0, _ns_conv = 0, _ns_rel = 0, _ns_wait = 0, _recv_calls = 0;
    //! gaps between the application's recv() calls (it did not read) and
    //! long recv() calls, printed with ZCU216_TX_STATS / ZCU216_RX_STATS: the
    //! largest few with their time, and counts above 10 / 50 / 100 ms
    bool _rx_stats = false;
    std::chrono::steady_clock::time_point _first_call, _last_exit;
    bool _have_exit = false;
    struct rx_gap
    {
        double at_ms, dur_ms;
        char kind; // 'g' gap between calls, 'c' long call
    };
    std::vector<rx_gap> _gaps; // the largest kGapKeep
    static constexpr size_t kGapKeep = 12;
    uint64_t _gap10 = 0, _gap50 = 0, _gap100 = 0, _call10 = 0;
    void _note_gap(char kind, double at_ms, double dur_ms);
    // the lcores fill the port rings through these
    std::vector<std::unique_ptr<dpdk_sink>> _dpdk_sinks;
    std::unique_ptr<dpdk::rx_session> _dpdk_rx;
    std::atomic<bool> _running{true};
    bool _shut      = false;
    bool _streaming = false;
    double _reorder_s = 0.002;
    std::mutex _shutdown_mutex;
    std::mutex _burst_mutex;
    //! A num_more issued "now" that opens a chain is held here until recv()
    //! or the next command, and continuations issued "now" meanwhile merge
    //! into it: one command reaches the daemon for the whole chain. Sent one
    //! by one, a continuation joins only if it reaches the FPGA before the
    //! previous link ends, and at 1.25 GS/s a 5000-sample link lasts 4 us,
    //! far less than one control round trip (BROKEN_CHAIN instead).
    struct held_cmd
    {
        bool valid    = false;
        bool done     = false;     // a num_done merged in: the chain is closed
        uint64_t count = 0;        // samples per channel, the links' sum
    };
    held_cmd _held;                // guarded by _burst_mutex
    std::atomic<bool> _has_held{false};
    //! send one stream command to the daemon and record it (_burst_mutex held)
    void _issue_locked(uhd::stream_cmd_t::stream_mode_t mode, uint64_t num, bool now, uint64_t ticks);
    //! send the held chain, if any (_burst_mutex held)
    void _flush_held_locked();

    // consumer wake-up
    std::mutex _wait_mutex;
    std::condition_variable _wait_cv;
    std::atomic<bool> _waiting{false};

    uint64_t _overflows = 0; //!< ERROR_CODE_OVERFLOW reports (one per gap delivered)
    bool _warned_bad = false, _warned_late = false;
    int _gap_logs = 0; //!< gap warnings logged (the first few per stream)
    int _trace_left = 0; //!< ZCU216_RX_TRACE: packets still to trace
};

} // namespace zcu216
