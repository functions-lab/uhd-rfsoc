//
// uhd_zcu216 -- TX streamer (PROTOCOL §6, §7).
//
// send() cuts the application's samples into packets of up to spp slots
// (whole 64-byte words of the OTW format and a multiple of N; a tail too short
// for that is carried to the next call, the last packet of a burst is
// zero-padded) and builds each one directly in a DPDK mbuf that the TX lcore
// sends (zcu216_dpdk.cpp). The header is written while planning; the payload
// -- the N channels interleaved slot by slot (PROTOCOL §9; channels the
// application did not ask for carry zeros) and converted to the OTW format
// (PROTOCOL §10) by one fused kernel (zcu216_kernels.hpp) -- is filled for a
// batch of up to 32 packets at once, by the worker pool (zcu216_pool.hpp) and
// the application thread when the batch is large, just before the batch goes
// to the TX lcore.
//
// Credit-based flow control: at most tx_buf_words 64-byte words and at most
// tx_max_pkts packets (2040 on the FPGA) may be sent but not yet consumed.
// The FPGA's async status packets (§7) reach a dedicated DPDK RX queue (an
// rte_flow rule for the async port) that the TX lcore polls between bursts:
// the lcore extends the 32-bit consumed count into the atomic the sender
// reads, and queues events (lock-free) for recv_async_msg(). send() waits for
// credit by spinning on that atomic (pause, then sched_yield, then 20 us naps
// once a wait exceeds ~2 ms), so fresh credit is seen within ~100 ns of its
// arrival -- no kernel socket, no interrupt, no condition variable.
//
#pragma once

#include "zcu216_common.hpp"
#include "zcu216_dpdk.hpp"
#include "zcu216_kernels.hpp"
#include "zcu216_otw.hpp"
#include <uhd/stream.hpp>
#include <uhd/version.hpp>
#include <uhd/exception.hpp>
#include <uhd/types/metadata.hpp>
#include <condition_variable>
#include <deque>
#include <vector>

namespace zcu216 {

class tx_streamer_impl : public uhd::tx_streamer
{
public:
    using sptr = std::shared_ptr<tx_streamer_impl>;
    tx_streamer_impl(std::shared_ptr<dev_state> st, const uhd::stream_args_t& args);
    ~tx_streamer_impl() override;

    size_t get_num_channels(void) const override
    {
        return _dev_chans.size();
    }
#if UHD_VERSION >= 4080000
    // UHD >= 4.8 streamers carry RFNoC action hooks; this is not an RFNoC
    // device, so there is nothing to post an action to.
    void post_output_action(const std::shared_ptr<uhd::rfnoc::action_info>&, const size_t) override
    {
        throw uhd::not_implemented_error("zcu216: post_output_action (RFNoC) is not supported");
    }
#endif
    //! samples PER CHANNEL in one packet (spp slots / N)
    //! samples per channel in one application buffer: _buf_pkts packets
    //! (device/stream arg spb_pkts=, default 32), so a
    //! buffer is never only a fraction of a packet per channel.
    //! UHD apps size their buffers and calls by this; one packet per call at
    //! N = 8 or 16 meant a recv()/send() every 0.85 us.
    size_t get_max_num_samps(void) const override
    {
        return _buf_pkts * (_spp / _nchan);
    }
    size_t send(const buffs_type& buffs,
        const size_t nsamps_per_buff,
        const uhd::tx_metadata_t& metadata,
        const double timeout) override;
    bool recv_async_msg(uhd::async_metadata_t& async_metadata, double timeout) override;

    //! Let queued samples play out (bounded), stop the player and the lcore.
    void shutdown();
    const std::vector<size_t>& device_channels() const
    {
        return _dev_chans;
    }

private:
    //! The one wire stream (all N channels): credit and async state.
    struct wire
    {
        uint32_t sid        = 0;
        uint16_t async_port = 0;
        size_t buf_words = 0, fc_interval = 0;
        uint64_t sent_words = 0;              // sender thread only
        //! words retired since stream_setup_tx; written by the TX lcore only
        alignas(64) std::atomic<uint64_t> consumed{0};
        // lcore-side state, guarded by fc_lock (the sender takes it only to
        // re-baseline at stream_setup_tx)
        alignas(64) std::atomic<bool> fc_lock{false};
        uint32_t last_consumed32 = 0; // raw FPGA count; starts at the baseline
        bool baseline_valid      = false;
        std::deque<uint64_t> pkt_ends; // sent_words at the end of each packet
                                       // not yet fully retired (sender only)
        uint32_t seq = 0;
        // event counters (TX lcore; read after it stopped)
        uint64_t status_pkts = 0, underflows = 0, seq_errors = 0, late = 0, acks = 0;
        uint64_t foreign = 0, ev_dropped = 0;
    };

    //! Measurement hooks (ZCU216_TX_STATS=1 / tx_ignore_credit=1), printed at
    //! shutdown: where the sender's time goes and how often credit arrives.
    struct tx_stats
    {
        bool on = false, ignore_credit = false;
        uint64_t calls = 0, pkts = 0, waits = 0, par_batches = 0;
        uint64_t build_ns = 0, wait_ns = 0, in_send_ns = 0, between_ns = 0;
        std::chrono::steady_clock::time_point first, last_exit;
        bool have_exit = false;
        std::vector<uint32_t> status_gap_us; // TX lcore only
        std::chrono::steady_clock::time_point last_status;
        bool have_status = false;
        //! underflow/late/seq events as they arrive (TX lcore): when, the TSF
        //! the FPGA reported, and the credit state at that moment
        struct event
        {
            std::chrono::steady_clock::time_point t;
            uint32_t code;
            uint64_t tsf, consumed, sent;
        };
        std::vector<event> events; // capacity reserved, never grown on the lcore
        //! slow episodes of the sending thread (> kSlowUs): a gap between two
        //! send() calls ('g', the application's time) or one long send() call
        //! ('s': packing, credit wait, the rest = handing packets to the TX
        //! lcore, which blocks while its ring is full). Printed next to each
        //! event, to tell which part stopped feeding the FPGA.
        static constexpr uint32_t kSlowUs = 100;
        struct slow
        {
            std::chrono::steady_clock::time_point t; // start
            char kind;
            uint32_t dur_us, build_us, wait_us;
        };
        std::vector<slow> slows; // capacity reserved, never grown
        std::chrono::steady_clock::time_point last_eob;
        bool have_eob = false;
    } _stats;
    void _print_stats();

    //! the TX lcore hands every packet of the async port here (zcu216_dpdk)
    struct status_sink;
    std::unique_ptr<status_sink> _status_sink;
    //! TX lcore: one async status packet (PROTOCOL §7)
    void _on_status(const uint8_t* pay, uint32_t len);
    void _fc_lock();
    void _fc_unlock();

    //! stream_setup_tx; returns after taking the new baseline
    void _setup_tx();
    //! FPGA reloaded since setup (rate change): its consumed count restarted
    //! at 0 and anything queued is gone. Redo stream_setup_tx and re-baseline.
    void _resync_if_reloaded();
    bool _wait_credit(size_t words, std::chrono::steady_clock::time_point deadline);
    bool _have_credit(size_t words);
    //! packet bi of the batch: header now, payload (n samples per channel, n *
    //! N slots) planned for _flush()
    void _build(size_t batch_idx, size_t n, bool sob, bool eob, bool timed,
        const buffs_type* buffs, size_t in_off, size_t take);
    //! fill the planned payloads (in parallel when large), hand the batch to
    //! the TX lcore
    void _flush();
    static void _task(void* ctx, size_t t);
    static void _noop(void*, size_t) {}
    //! run the packing path once over scratch buffers (tx_warmup_rounds)
    void _warm_up(size_t rounds);
    bool _keep_warm = true; //!< tx_keep_warm: ping the pool during long credit waits

    std::shared_ptr<dev_state> _st;
    std::vector<size_t> _dev_chans; // requested channels, in buffer order
    size_t _nchan   = 1;            // N: channels on the wire
    size_t _quantum = kSampQuantum; // samples per channel filling whole 64-byte words
    std::string _host_ip, _host_mac;
    uint64_t _generation = 0;
    wire _w;
    //! per requested channel: CPU-format samples not yet sent (< _quantum,
    //! plus a timed burst's lead-in as zeros); all the same length. Kept
    //! unconverted so every packet converts from its first slot, on whole
    //! groups of every format.
    std::vector<std::vector<uint8_t>> _residual;
    size_t _spp = kTxMaxSpp; // slots per packet
    size_t _buf_pkts = 1;    // packets per get_max_num_samps()
    size_t _max_pkts = 2040; // PROTOCOL §6: FPGA packet slots
    //! untimed-burst prefill (_size_prefill): device args, and the packets held
    std::string _prefill_arg = "auto";
    double _prefill_lead_us = 200, _prefill_us = 1000;
    size_t _prefill_pkts = 32;
    void _size_prefill();
    size_t _bytes_per_cpu_item = 0;
    const otw_info* _otw = nullptr; // PROTOCOL §10 wire format
    std::unique_ptr<tx_kernel> _kern; // cpu -> wire, interleave
    //! 64-byte credit words of a packet of n samples per channel
    size_t _words(size_t n) const
    {
        return n * _nchan * _otw->slot_bytes / kTxWordBytes;
    }
    //! a kernel UDP socket bound to the host data IP that only reserves the
    //! source port the DPDK frames carry (nothing is sent on it)
    int _src_fd = -1;
    //! packets are built in mbufs and sent by the DPDK TX lcore
    std::unique_ptr<dpdk::tx_session> _dpdk_tx;
    std::atomic<bool> _running{true};
    bool _shut = false;
    double _drain_timeout = 2.0;
    double _spin_s = 20e-6, _yield_s = 2e-3; // credit wait: pause, then yield, then nap
    std::mutex _shutdown_mutex;
    std::mutex _send_mutex;

    // burst state (sender)
    bool _in_burst = false, _pending_sob = false, _pending_timed = false;
    uint64_t _pending_tsf = 0;
    std::atomic<bool> _ack_since_eob{true};
    bool _warned_sob = false;

    // batch of mbufs handed to the TX lcore together
    static constexpr size_t kBatch = 32;
    struct pkt_plan
    {
        uint8_t* pay = nullptr;           // UDP payload after the 16-byte header
        const void* ins[kMaxChans] = {};  // per requested channel
        size_t in_off = 0, n = 0;         // samples
    };
    std::vector<pkt_plan> _plan;
    std::vector<std::vector<uint8_t>> _asm; // per batch slot: residual + new + pad
    std::vector<uint32_t> _batch_len;       // UDP payload bytes per packet
    size_t _batch_count = 0;
    //! batch index of the first packet of an untimed burst (the TX lcore
    //! prefills from it), else dpdk::tx_session::kNoHold
    size_t _hold_at = size_t(-1);
    // conversion job (valid during _flush)
    size_t _job_chunk = 0, _job_per_pkt = 1;
    uint64_t _flush_par = 0, _flush_inline = 0;

    // async events: SPSC ring, TX lcore -> recv_async_msg()
    static constexpr size_t kEvRing = 4096; // events (one per channel per FPGA event)
    std::vector<uhd::async_metadata_t> _ev;
    alignas(64) std::atomic<uint64_t> _ev_wr{0};
    alignas(64) std::atomic<uint64_t> _ev_rd{0};
    std::atomic<int> _ev_waiters{0};
    std::mutex _ev_mutex; // consumers; and the wake-up below
    std::condition_variable _ev_cv;
};

} // namespace zcu216
