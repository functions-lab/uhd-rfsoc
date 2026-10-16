//
// uhd_zcu216 -- UHD out-of-tree device module for the ZCU216 RFSoC board.
// Shared declarations: constants, control client, network helpers and the
// device state that streamers share with the device.
//
// The wire contract is the Protocol section of ../../AGENTS.md. Keep the constants below in sync.
//
#pragma once

#include <uhd/exception.hpp>
#include <uhd/types/device_addr.hpp>
#include <uhd/types/sensors.hpp>
#include <uhd/utils/log.hpp>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#define ZLOG_TRACE(msg) UHD_LOG_TRACE("ZCU216", msg)
#define ZLOG_DEBUG(msg) UHD_LOG_DEBUG("ZCU216", msg)
#define ZLOG_INFO(msg) UHD_LOG_INFO("ZCU216", msg)
#define ZLOG_WARN(msg) UHD_LOG_WARNING("ZCU216", msg)
#define ZLOG_ERROR(msg) UHD_LOG_ERROR("ZCU216", msg)

namespace zcu216 {

// ---- Protocol constants -------------------------------------------------------------
constexpr uint16_t kDiscPort       = 49700; // §2
constexpr uint16_t kCtrlPort       = 49710; // §3
constexpr uint16_t kRecvPortBase   = 49810; // §1, host data UDP port base
constexpr uint16_t kTxPort         = 49900; // §6, FPGA TX sample port
constexpr uint16_t kAsyncOffset    = 16;    // §7, async_port = port_base + 16
constexpr uint32_t kRxSidBase      = 0x5A160000u; // §4
constexpr uint32_t kTxSidBase      = 0x5A170000u; // §6
constexpr uint32_t kAsyncMagic     = 0x5A17A5C0u; // §7
constexpr size_t kDefaultSpp       = 2048;
constexpr size_t kSampQuantum      = 16; // §4/§6/§9: FPGA works in 16-slot units
constexpr size_t kBeatSamps        = 4;  // one 128-bit ADC beat (slots)
constexpr size_t kTxMaxSpp         = 2048; // §6 (slots)
constexpr size_t kSampsPerTxWord   = 16; // slots in one 64-byte TX buffer word
constexpr size_t kMaxChans         = 16; // §9: N = 1, 2, 4, 8, 16
constexpr size_t kHdrBytes         = 16; // 4-word header, §4/§6
constexpr const char* kDiscRequest     = "ZCU216-DISC?";
constexpr const char* kDiscReplyPrefix = "ZCU216-DISC ";

// ---- string helpers -------------------------------------------------------
std::vector<std::string> split(const std::string& s, char sep, bool keep_empty = true);
std::string trim(const std::string& s);
double parse_double(const std::string& s, const std::string& what);
long long parse_ll(const std::string& s, const std::string& what);
std::string fmt_double(double v); // "%.17g"
//! "k=v;k=v" -> device_addr_t (Protocol §2/§3)
uhd::device_addr_t parse_kv(const std::string& s);
//! CPU list "2-5", "2:3:4:5", "2;3", "2 3" (or "2,3" where UHD's arg parser
//! does not split on commas); uhd::value_error naming `what` otherwise
std::vector<unsigned> parse_cpus(const std::string& s, const std::string& what);

// ---- control client (Protocol §3) -----------------------------------------
class ctrl_client
{
public:
    using sptr = std::shared_ptr<ctrl_client>;
    ctrl_client(const std::string& host, uint16_t port, double timeout_s);
    ~ctrl_client();

    //! Send one request line; returns the text after "OK" (leading space
    //! stripped). Throws uhd::runtime_error on "ERR ..." and uhd::io_error on
    //! a broken connection or timeout. Thread-safe.
    //! timeout_s < 0: the client's default (ctrl_timeout).
    std::string call(const std::string& line, double timeout_s = -1.0);
    std::vector<std::string> call_tokens(const std::string& line, double timeout_s = -1.0);
    double call_double(const std::string& line, double timeout_s = -1.0);
    const std::string& host() const
    {
        return _host;
    }

private:
    std::string _read_line(const std::string& cmd, double timeout_s);
    std::mutex _mutex;
    int _fd = -1;
    std::string _rx;
    double _timeout;
    std::string _host;
    bool _broken = false;
};

// ---- network helpers ------------------------------------------------------
//! Protocol §2 discovery. Broadcast on all IPv4 interfaces, or unicast to
//! hint["addr"]. Waits at most timeout_s.
uhd::device_addrs_t discover(const uhd::device_addr_t& hint, double timeout_s);

struct local_iface
{
    std::string name, ip, mac;
};
//! The local interface/IP the kernel would use to reach dest_ip.
local_iface iface_for_route(const std::string& dest_ip);
//! The interface that owns local IPv4 address ip (MAC via SIOCGIFHWADDR).
local_iface iface_for_ip(const std::string& ip);
//! Resolve a host name / dotted quad to a dotted quad (IPv4 only).
std::string resolve_ipv4(const std::string& host);

namespace dpdk {
class port; // zcu216_dpdk.hpp: the DPDK data plane
}
class worker_pool; // zcu216_pool.hpp

// ---- state shared by device and streamers ---------------------------------
//! Streamers keep a shared_ptr to this, so they stay valid even if the user
//! drops the device before the streamer.
struct dev_state
{
    ctrl_client::sptr ctrl;
    uhd::device_addr_t args; // merged device args
    std::string data_ip;     // FPGA data IP (discovery data_ip=)
    std::string data_mac;    // FPGA data MAC (info data_mac=, may be empty)
    //! the DPDK port that carries every sample packet (opened at make())
    std::shared_ptr<dpdk::port> dpdk;
    //! worker threads for recv()/send() conversion (device arg rx_workers;
    //! null = everything in the application thread)
    std::shared_ptr<worker_pool> pool;
    //! send()'s own pool (tx_workers=, tx_worker_cpus=): a busy pool runs a
    //! second caller inline, so RX and TX at once need one each
    std::shared_ptr<worker_pool> tx_pool;
    worker_pool* txp() const
    {
        return tx_pool ? tx_pool.get() : pool.get();
    }
    //! a recv()/send() call with at least this many wire slots of work is
    //! split across the pool (device arg par_min_slots)
    size_t par_min_slots = 16384;
    std::string serial;
    //! ticks per second of the LOADED build (Protocol §4/§8: info tick_rate=,
    //! also the 2nd token of the set_channels / set_rx_rate replies); a rate
    //! change within one N can change it
    std::atomic<double> tick_rate{0.0};
    //! Protocol §9: N, the channels interleaved in the ONE stream per
    //! direction (slot i of a packet = channel i % N, sample i / N). One tick
    //! is one slot time for N > 1; num_rx == num_tx == nchan.
    size_t nchan  = 1;
    size_t num_rx = 1, num_tx = 1;
    size_t default_spp = kDefaultSpp; // info spp=: slots of sc16 (8192-byte payload)
    size_t mtu = 9000;
    //! Protocol §9: slots per fabric beat of the loaded build (info
    //! beat_slots=; a daemon without the key: max(4, N)); a timed start
    //! begins on the beat containing the requested tick
    std::atomic<size_t> beat_slots_info{0};
    //! §11: the loaded build has the TX beamformer (info bf=1)
    std::atomic<bool> bf{false};
    //! §11: the loaded build has the RX beamformer (info rbf=1; a daemon or
    //! bitstream from before it: no key / rbf=0)
    std::atomic<bool> rbf{false};
    //! the stream format declared with set_rx_rate (§3 otw=): device arg
    //! otw=, then the format of the latest streamer; empty = say nothing
    void set_cur_otw(const std::string& f);
    std::string cur_otw();
    //! Protocol §10: OTW formats the daemon offers for the loaded build per
    //! direction (info rx_otw_formats= / tx_otw_formats=, else otw_formats=);
    //! a daemon without the keys offers only sc16
    std::vector<std::string> otw_offered(bool rx);
    //! take tick_rate, beat_slots, spp, mtu, the otw lists, bf and rbf from `info`
    void apply_info(const uhd::device_addr_t& info);
    //! re-read `info` (after the daemon reloaded the FPGA)
    void refresh_info();
    std::vector<std::unique_ptr<std::atomic<double>>> rx_rate, tx_rate;
    //! Protocol §8: a rate change retunes the loaded template (~1-1.5 s) or
    //! reloads the FPGA (tens of seconds)
    double rate_timeout = 120.0;
    //! Incremented whenever a rate change retuned or reloaded the FPGA. Either
    //! stopped all streaming and gave the TX path a new consumed-word baseline,
    //! so streamers compare this with the value they set up under.
    std::atomic<uint64_t> fpga_generation{0};

    //! set_rx_rate/set_tx_rate (the same operation: RX and TX share one
    //! converter factor), then re-read both directions into the caches.
    double set_rate(bool rx, size_t ch, double rate);
    //! re-read the (common) RX and TX rate into every channel's cache
    void refresh_rates();

    double get_rx_rate(size_t ch) const
    {
        return rx_rate.at(ch)->load();
    }
    double get_tx_rate(size_t ch) const
    {
        return tx_rate.at(ch)->load();
    }
    //! ticks per (per-channel) sample at the current rate: tick_rate / rate
    //! (N for a multi-channel build, F/2 for the N = 1 rate variants)
    uint64_t ticks_per_sample(double rate) const;
    //! ticks per wire slot: ticks_per_sample / N (1 for every N > 1 build)
    uint64_t ticks_per_slot(double rate) const
    {
        const uint64_t t = ticks_per_sample(rate) / nchan;
        return t ? t : 1;
    }
    //! slots per fabric beat (§9): info beat_slots=, else max(4, N) (the
    //! builds from before the key)
    size_t beat_slots() const
    {
        const size_t b = beat_slots_info.load();
        return b ? b : (nchan > kBeatSamps ? nchan : kBeatSamps);
    }
    //! smallest per-channel sample count that fills whole 16-slot units
    size_t samp_quantum() const
    {
        return nchan >= kSampQuantum ? 1 : kSampQuantum / nchan;
    }

    //! host-side data-plane endpoint: resolved once, shared by rx and tx
    local_iface host_data_iface();

private:
    std::mutex _info_mutex; // the otw lists and cur_otw
    std::vector<std::string> _otw_rx{"sc16"}, _otw_tx{"sc16"};
    std::string _cur_otw;
    std::mutex _iface_mutex;
    bool _iface_valid = false;
    local_iface _iface;
};

} // namespace zcu216
