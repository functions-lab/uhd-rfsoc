//
// uhd_rfsoc -- the DPDK sample data plane (the only one).
//
// The 100G port is driven by DPDK's mlx5 PMD in *bifurcated, isolated* mode:
// rte_flow rules steer only IPv4/UDP to <host ip>:[recv_port, recv_port+nports)
// into DPDK RX queues (queue k = port k), and UDP to <host ip>:<async port>
// (the FPGA's TX status, Protocol §7) into one more queue (queue nports, the
// "status queue"); everything else -- ARP, ICMP, discovery/control on the
// LAN, anything unrelated -- still reaches the kernel netdev, which stays up.
// TX frames are built in mbufs and sent by a TX lcore, which also polls the
// status queue and hands each status payload to the TX streamer.
//
// The RX lcores copy each UDP payload into the per-port SPSC rings of the RX
// streamer, and the TX streamer builds its packets straight into mbuf
// payloads; TSF merge, gap detection, de-interleave, conversion, trimming
// and flow control live in the streamers.
//
// This header does not include DPDK (only rfsoc_dpdk.cpp sees its flags).
//
#pragma once
#include <atomic>

#include "rfsoc_common.hpp"
#include <memory>
#include <string>
#include <vector>

namespace rfsoc {
namespace dpdk {

//! Producer side of one RX ring. The lcore that polls queue k is the only
//! producer of ring k.
class rx_sink
{
public:
    virtual ~rx_sink() = default;
    //! up to max free slot buffers (slot_bytes() each), in ring order;
    //! bufs = nullptr only counts the free slots (zero-copy)
    virtual size_t reserve(uint8_t** bufs, size_t max) = 0;
    //! Zero-copy (device arg rx_zero_copy, default on): the lcore hands over
    //! its mbufs instead of copying their payloads into slot buffers, and the
    //! consumer returns them with free_rx_mbufs_raw() once converted. The
    //! payload stays where the NIC wrote it (DDIO: in the LLC) and one copy
    //! of every byte is saved.
    virtual bool zero_copy() const
    {
        return false;
    }
    //! publish n mbufs (opaque), their UDP payloads and payload lengths
    virtual void commit_zc(void* const* mbufs, uint8_t* const* pays, const uint32_t* lens, size_t n)
    {
        (void)mbufs, (void)pays, (void)lens, (void)n;
    }
    //! publish the first n reserved slots; lens[i] = UDP payload bytes
    virtual void commit(const uint32_t* lens, size_t n) = 0;
    virtual size_t slot_bytes() const = 0;
    //! Overflow hysteresis, for the whole stream (every queue of it): after
    //! overflowed() the lcores discard whole bursts while discarding() says
    //! so, i.e. until every ring of the stream has drained to the fraction
    //! rx_overflow_resume (default 1/16) of its capacity. The loss is then
    //! one long gap, not a gap after nearly every packet (which costs the
    //! consumer an extra recv() per packet and keeps it behind). Both return
    //! false / do nothing when the sink does not take part.
    virtual bool overflowed()
    {
        return false;
    }
    virtual bool discarding()
    {
        return false;
    }
    //! the ring was full when the lcore came to poll the queue
    virtual void note_full() = 0;
};

//! Return the mbufs a zero-copy sink was given (any thread). They came
//! straight from the NIC -- one segment, not shared, all from the pool of
//! mbufs[0] -- so they go back with one rte_mempool_put_bulk, without reading
//! each header as rte_pktmbuf_free does (the header was last touched by the
//! RX lcore on another core: a cross-core miss per packet, ~13 % of recv()
//! at 12 GB/s).
void free_rx_mbufs_raw(void* const* mbufs, size_t n);
//! Give the calling (application) thread a DPDK lcore id once, so its mbuf
//! allocations and frees go through a per-thread mempool cache instead of
//! taking the pool's lock every time (recv()/send() call it; unregistered when
//! the thread exits).
void register_thread();

//! One DPDK ethdev, opened by every device. The EAL is initialised
//! once per process on the first open; the port is configured and started
//! (isolated, nports RX queues, no flows yet) by open_port(), reconfigured if
//! a session needs more queues, and stopped when the last reference goes
//! (device destruction). It is closed, and the EAL cleaned up, at process exit.
class port;
using port_sptr = std::shared_ptr<port>;

//! Initialise the EAL (first call only) and find the port. `ifc` is the host
//! data interface (its PCI device is the default port); `mtu` the largest
//! frame the stream uses. Throws uhd::runtime_error with a hint on failure
//! (not root, no hugepages, port not found or busy, ...).
port_sptr open_port(const uhd::device_addr_t& args, const local_iface& ifc, size_t mtu);

//! Default CPU placement, from the CPU topology (physical cores = groups of
//! hyperthread siblings, ordered by their lowest CPU number C0, C1, ...):
//!   main  C0 (the EAL main core; the application's own threads get their
//!         affinity back after rte_eal_init)
//!   rx    the first thread of C1, tx its sibling (C2 without SMT): the
//!         polling lcores share ONE physical core -- with zero-copy RX they
//!         are light, and a spinning lcore must never share a core with
//!         conversion work
//!   workers  the first thread of every other core (on big.LITTLE one fast
//!         core after C0 is left out, for the application)
//! The application gets what is left -- C0 beside the main lcore, and the
//! spare fast core on big.LITTLE (rfsoc_device::_place_app derives it from
//! the lcores and workers in use). Measured on a 6-core/12-thread x86 host,
//! ConnectX-5 at PCIe Gen3 x16, 8 x 312.5 MS/s sc16, benchmark_rate with
//! 32-packet buffers: lcores sharing one core gave TX 98.8-99.6 % against
//! 71.6 % with each lcore on its own core (the conversion workers then had
//! too few cores); RX ~100 % either way. Each piece is overridden by
//! dpdk_main_core / dpdk_rx_cores / dpdk_tx_core / worker_cpus / rx_workers.
//! The initial values below stand only where the topology cannot be read.
struct cpu_layout
{
    unsigned main = 0, tx = 1;
    std::vector<unsigned> rx{2}, workers;
};
const cpu_layout& default_layout();
//! "2:8" style list
std::string cpu_list(const std::vector<unsigned>& v);

//! RX: queue k <- UDP dst port port_base + k, sinks[k] fed by an RX lcore.
//! Destroying it stops the lcores and removes the flow rules.
class rx_session
{
public:
    virtual ~rx_session() = default;
};
std::unique_ptr<rx_session> start_rx(const port_sptr& p,
    const std::string& host_ip,
    uint16_t port_base,
    const std::vector<rx_sink*>& sinks);

struct tx_endpoint
{
    std::string dst_mac; // FPGA data MAC
    std::string src_ip, dst_ip;
    uint16_t src_port = 0, dst_port = 0;
    //! host UDP port the FPGA sends TX status to (Protocol §7); 0 = none
    uint16_t status_port = 0;
    //! Untimed-burst prefill: the FPGA plays an untimed burst from its first
    //! packet, so the host starts with no lead and one late packet underflows.
    //! From a packet send() marks as hold_at, the TX lcore holds packets until
    //! it has prefill_pkts (or prefill_us passed) and then sends them back to
    //! back at line rate, which is several times the sample rate. 0 = off.
    size_t prefill_pkts = 0;
    double prefill_us   = 0;
    //! Packets sent to the FPGA's discard port (9, ignored by the player,
    //! Protocol §6) when the session starts. The first packets a freshly
    //! started mlx5 TX queue sends can leave gaps of more than one packet's
    //! play time between them (measured: the first untimed burst of a
    //! process underflowed once after its first packet even with 255 packets
    //! released back to back; a warm process never did). 0 = off.
    size_t warmup_pkts = 0;
};
//! Receives the TX status packets. Called on the TX lcore, so it must not
//! block (no mutex a sleeping thread may hold).
class tx_status_sink
{
public:
    virtual ~tx_status_sink() = default;
    //! one UDP payload sent to <src_ip>:<status_port>
    virtual void on_status(const uint8_t* payload, uint32_t len) = 0;
};
//! TX: the caller writes UDP payloads into slot(i) and hands slots 0..n-1 to
//! send(), which adds Ethernet/IPv4/UDP headers and queues them, in order, to
//! the TX lcore. With a status sink, an rte_flow rule steers UDP to
//! ep.status_port into the status queue and the TX lcore feeds every packet
//! there to the sink. Destroying it sends what is queued (bounded), stops
//! the lcore and removes the rule.
class tx_session
{
public:
    virtual ~tx_session() = default;
    //! payload buffer of batch slot i (< nslots), room for max_payload bytes
    virtual uint8_t* slot(size_t i) = 0;
    //! queue slots 0..n-1 (UDP payload lengths lens[]); blocks while the
    //! TX ring is full. Slot hold_at (if < n) starts an untimed burst: the
    //! lcore prefills from it (tx_endpoint::prefill_pkts).
    static constexpr size_t kNoHold = size_t(-1);
    virtual void send(const uint32_t* lens, size_t n, size_t hold_at = kNoHold) = 0;
    //! replace tx_endpoint::prefill_pkts / prefill_us (the streamer sizes the
    //! prefill once it knows the rate and the FPGA credit); takes effect at
    //! the next untimed burst
    virtual void set_prefill(size_t pkts, double us) = 0;
    //! Credit gate on the TX lcore (Protocol §6 flow control): from now on
    //! the lcore releases a queued packet to the NIC only while the FPGA has
    //! room for it -- in-flight words (released - *consumed) <= buf_words and
    //! in-flight packets <= max_pkts -- and holds the rest, in order. So
    //! send() may queue up to the host queue beyond the FPGA's credit without
    //! the application thread waiting for the FPGA. A packet's words are
    //! (UDP payload - hdr_bytes) / word_bytes. *consumed counts words retired
    //! since the baseline (stream_setup_tx); this call is that baseline:
    //! the lcore's released count restarts at 0. consumed == nullptr: off.
    virtual void set_credit(const std::atomic<uint64_t>* consumed, uint64_t buf_words,
        size_t max_pkts, size_t hdr_bytes, size_t word_bytes) = 0;
    //! packets the lcore may hold beyond the FPGA credit (its FIFO, < the
    //! spare mbufs of the TX pool)
    static constexpr size_t kMaxHostQueuePkts = 2048;
};
std::unique_ptr<tx_session> start_tx(const port_sptr& p,
    const tx_endpoint& ep,
    size_t nslots,
    size_t max_payload,
    tx_status_sink* status = nullptr);

//! The FPGA data MAC for DPDK TX, first match of: `override` (device arg
//! data_mac=), the kernel neighbour table (/proc/net/arp, filled by the
//! tx_arp_prime probe), the daemon's `info data_mac=`; none of them ->
//! uhd::lookup_error.
std::string fpga_mac(const std::string& override_mac,
    const std::string& ifname,
    const std::string& data_ip,
    const std::string& info_mac);

} // namespace dpdk
} // namespace rfsoc
