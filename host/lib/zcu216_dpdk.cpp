//
// uhd_zcu216 -- the DPDK data plane (see zcu216_dpdk.hpp).
//
#include "zcu216_dpdk.hpp"
#include <arpa/inet.h>
#include <unistd.h>
#include <algorithm>
#include <climits>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <thread>

namespace zcu216 {
namespace dpdk {

using clk = std::chrono::steady_clock;

static bool parse_mac(const std::string& s, uint8_t out[6])
{
    unsigned b[6];
    char extra = 0;
    if (std::sscanf(s.c_str(), "%x:%x:%x:%x:%x:%x%c", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &extra)
        != 6)
        return false;
    for (int i = 0; i < 6; i++) {
        if (b[i] > 255)
            return false;
        out[i] = uint8_t(b[i]);
    }
    return true;
}

static std::string norm_mac(const std::string& s)
{
    uint8_t b[6];
    if (not parse_mac(s, b))
        return "";
    char buf[18];
    std::snprintf(buf, sizeof(buf), "%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]);
    return buf;
}

//! /proc/net/arp: "IP address  HW type  Flags  HW address  Mask  Device"
static std::string neigh_mac(const std::string& ip, const std::string& ifname)
{
    std::ifstream f("/proc/net/arp");
    std::string line;
    std::getline(f, line); // header
    while (std::getline(f, line)) {
        std::istringstream ss(line);
        std::string a, hwtype, flags, mac, mask, dev;
        if (not(ss >> a >> hwtype >> flags >> mac >> mask >> dev))
            continue;
        if (a != ip or (not ifname.empty() and dev != ifname))
            continue;
        const unsigned long fl = std::strtoul(flags.c_str(), nullptr, 16);
        if (not(fl & 0x2)) // ATF_COM: resolved
            continue;
        const std::string m = norm_mac(mac);
        if (not m.empty() and m != "00:00:00:00:00:00")
            return m;
    }
    return "";
}

std::string fpga_mac(const std::string& override_mac,
    const std::string& ifname,
    const std::string& data_ip,
    const std::string& info_mac)
{
    if (not override_mac.empty()) {
        const std::string m = norm_mac(override_mac);
        if (m.empty())
            throw uhd::value_error("ZCU216: bad data_mac '" + override_mac + "'");
        ZLOG_INFO("DPDK TX: FPGA data MAC " << m << " (data_mac=)");
        return m;
    }
    // the tx_arp_prime probe went out just before; give the reply a moment
    std::string n;
    for (int i = 0; i < 10 and n.empty(); i++) {
        n = neigh_mac(data_ip, ifname);
        if (n.empty())
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    const std::string im = norm_mac(info_mac);
    if (not n.empty()) {
        if (not im.empty() and im != n)
            ZLOG_WARN("DPDK TX: kernel neighbour table has " << data_ip << " at " << n
                                                              << " but the daemon reports data_mac="
                                                              << im << "; using " << n);
        ZLOG_INFO("DPDK TX: FPGA data MAC " << n << " (kernel neighbour table, " << ifname << ")");
        return n;
    }
    if (not im.empty()) {
        ZLOG_INFO("DPDK TX: FPGA data MAC " << im << " (daemon info; " << data_ip
                                            << " not in the neighbour table)");
        return im;
    }
    throw uhd::lookup_error("ZCU216: FPGA data MAC unknown: no ARP reply from " + data_ip + " on "
                            + ifname + " and the daemon reports no data_mac. Is the 100G link "
                            "up (sensor cmac_aligned)? Pass data_mac= to override.");
}

} // namespace dpdk
} // namespace zcu216

// ---------------------------------------------------------------------------
// DPDK
// ---------------------------------------------------------------------------
#include <rte_cycles.h>
#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ethdev.h>
#include <rte_ether.h>
#include <rte_flow.h>
#include <rte_ip.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>
#include <rte_memcpy.h>
#include <rte_mempool.h>
#include <rte_pause.h>
#include <rte_ring.h>
#include <rte_udp.h>
#include <rte_version.h>
#include <dlfcn.h>
#include <glob.h>
#include <pthread.h>
#include <sched.h>
#include <atomic>
#include <cstdlib>
#include <map>
#include <mutex>
#include <set>

namespace zcu216 {
namespace dpdk {

namespace {

constexpr uint16_t kRxBurst    = 32;
constexpr uint16_t kTxBurst    = 32;
constexpr uint32_t kMbufRoom   = 10240; // incl. headroom: a 9000-MTU frame in one segment
constexpr unsigned kPoolCache  = 256;
constexpr size_t kEthIpUdp     = 14 + 20 + 8;
constexpr unsigned kTxRingSize = 1024; // TX lcore ring (power of two)
constexpr uint32_t kHoldMark   = 0x5A484F4Cu; // mbuf hash.usr: an untimed burst starts here
constexpr size_t kMaxPrefill   = 256;         // packets the TX lcore holds at most
constexpr uint16_t kStatusRxd  = 256;  // descriptors of the TX status queue
constexpr uint16_t kStatusBurst = 16;

std::string rte_err(int e)
{
    return std::string(rte_strerror(e < 0 ? -e : e));
}

std::string flow_err(const rte_flow_error& e)
{
    std::string s = e.message ? e.message : "(no message)";
    return s + " [type " + std::to_string(int(e.type)) + ", " + rte_err(rte_errno) + "]";
}

std::string busy_hint(const std::string& name)
{
    return " -- is another DPDK application (dpdk-testpmd, a second UHD process) using " + name
           + "? Is it an mlx5 port with rdma-core/ibverbs-providers installed?";
}

//! PCI address of a netdev (/sys/class/net/<if>/device -> ../../<domain:bus:dev.fn>)
std::string pci_of_iface(const std::string& ifname)
{
    if (ifname.empty())
        return "";
    char buf[512];
    const std::string link = "/sys/class/net/" + ifname + "/device";
    const ssize_t n        = ::readlink(link.c_str(), buf, sizeof(buf) - 1);
    if (n <= 0)
        return "";
    buf[n]                = 0;
    const std::string p   = buf;
    const auto slash      = p.rfind('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

//! effective capabilities: NET_ADMIN (12), NET_RAW (13), IPC_LOCK (14)
bool have_privileges(std::string& why)
{
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line)) {
        if (line.compare(0, 7, "CapEff:") != 0)
            continue;
        const unsigned long long cap = std::strtoull(line.c_str() + 7, nullptr, 16);
        const unsigned long long need = (1ull << 12) | (1ull << 13) | (1ull << 14);
        if ((cap & need) == need)
            return true;
        why = "the process lacks CAP_NET_ADMIN/CAP_NET_RAW/CAP_IPC_LOCK (euid "
              + std::to_string(geteuid()) + ")";
        return false;
    }
    return geteuid() == 0;
}

size_t free_hugepages()
{
    size_t total = 0;
    glob_t g{};
    if (::glob("/sys/kernel/mm/hugepages/hugepages-*/free_hugepages", 0, nullptr, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            std::ifstream f(g.gl_pathv[i]);
            size_t n = 0;
            if (f >> n)
                total += n;
        }
    }
    ::globfree(&g);
    return total;
}

std::string mac_str(const rte_ether_addr& a)
{
    char buf[RTE_ETHER_ADDR_FMT_SIZE];
    rte_ether_format_addr(buf, sizeof(buf), &a);
    for (char* c = buf; *c; c++)
        *c = char(std::tolower((unsigned char)*c));
    return buf;
}

struct port_state
{
    bool started      = false;
    uint16_t nq_rx    = 0; // data queues 0..nq_rx-1; queue nq_rx is the TX status queue
    rte_mempool* rx_pool = nullptr;
    size_t rx_pool_n  = 0;
    rte_mempool* tx_pool = nullptr;
    bool rx_active = false, tx_active = false;
    int objects    = 0; // live port objects (devices)
};

struct global_state
{
    std::mutex m;
    int eal = 0; // 0 not tried, 1 up, -1 failed
    std::string eal_err, eal_args;
    std::vector<std::string> argv_store; // EAL may keep pointers into argv
    std::vector<char*> argv;
    std::map<uint16_t, port_state> ports;
    unsigned seq = 0;
};

//! never destroyed: used by the atexit handler
global_state& G()
{
    static global_state* g = new global_state;
    return *g;
}

void stop_port(uint16_t id, port_state& ps)
{
    rte_flow_error err{};
    rte_flow_flush(id, &err);
    const int rc = rte_eth_dev_stop(id);
    if (rc != 0)
        ZLOG_WARN("DPDK: rte_eth_dev_stop(" << id << "): " << rte_err(rc));
    ps.started = false;
    ZLOG_DEBUG("DPDK: port " << id << " stopped");
}

//! process exit: close the ports and clean up the EAL, unless an lcore is
//! still working (a streamer the application never destroyed)
void at_exit()
{
    global_state& g = G();
    std::unique_lock<std::mutex> lk(g.m, std::try_to_lock);
    if (not lk.owns_lock() or g.eal != 1)
        return;
    for (auto& kv : g.ports)
        if (kv.second.rx_active or kv.second.tx_active)
            return;
    for (auto& kv : g.ports) {
        if (kv.second.started)
            stop_port(kv.first, kv.second);
        rte_eth_dev_close(kv.first);
    }
    g.ports.clear();
    rte_eal_cleanup();
    g.eal = 0;
}

//! Keep fork() usable in the application once the EAL has loaded the mlx
//! PMDs. Called before rte_eal_init.
//!
//! The EAL loads every PMD in its plugin directory (Ubuntu:
//! /usr/lib/x86_64-linux-gnu/dpdk/pmds-24.0), and librte_net_mlx4's
//! constructor calls ibv_fork_init() unconditionally (mlx5's only when
//! rdma-core says it is needed). That switches on rdma-core's fork
//! protection: from then on every buffer rdma-core or the mlx5 PMD registers
//! is madvise(MADV_DONTFORK)ed with page granularity -- ordinary malloc heap
//! pages that also hold unrelated application data. A child created by
//! fork() then lacks those pages, and the first touch before exec() kills it
//! with SIGSEGV. That is how stock rx_samples_to_file died with "Error:
//! stod": its disk pre-test forks `dd` through boost::process, the child
//! segfaults before exec, dd prints nothing, and std::stod("") throws.
//!
//! rdma-core itself reports the protection as unneeded (IBV_FORK_UNNEEDED)
//! when the kernel says it copies DMA-pinned pages at fork (the RDMA netlink
//! copy-on-fork attribute, Linux 5.13+): the parent's registered memory then
//! stays where the NIC expects it without any MADV_DONTFORK.
//! In that case, poison rdma-core's fork init the documented way: once
//! ibv_dofork_range() has been called before ibv_fork_init(), the latter
//! returns EINVAL and the protection stays off (the PMDs ignore the result).
//! On an older kernel the protection is left alone -- it is what keeps the
//! DMA memory correct there -- and a warning says fork() is unsafe.
void keep_fork_usable()
{
    // the same libibverbs.so.1 the PMDs link; never unloaded
    void* h = ::dlopen("libibverbs.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (not h) {
        ZLOG_DEBUG("DPDK: no libibverbs.so.1 (" << ::dlerror() << "): no rdma-core fork handling");
        return;
    }
    using status_fn = int (*)(void);
    using range_fn  = int (*)(void*, size_t);
    const auto status = reinterpret_cast<status_fn>(::dlsym(h, "ibv_is_fork_initialized"));
    const auto dofork = reinterpret_cast<range_fn>(::dlsym(h, "ibv_dofork_range"));
    if (not status or not dofork) {
        ZLOG_WARN("DPDK: libibverbs lacks ibv_is_fork_initialized/ibv_dofork_range; "
                  "fork() in this process may kill the child (MADV_DONTFORK)");
        return;
    }
    enum { FORK_DISABLED = 0, FORK_ENABLED = 1, FORK_UNNEEDED = 2 }; // enum ibv_fork_status
    switch (status()) {
        case FORK_UNNEEDED: {
            static char probe;
            dofork(&probe, 0); // no madvise: only marks ibv_fork_init() "too late"
            ZLOG_DEBUG("DPDK: kernel copies pinned pages at fork; rdma-core fork "
                       "protection (MADV_DONTFORK) kept off");
            break;
        }
        case FORK_ENABLED:
            ZLOG_WARN("DPDK: rdma-core fork protection was already enabled in this process "
                      "(RDMAV_FORK_SAFE?); a fork()ed child may segfault before exec()");
            break;
        default:
            ZLOG_WARN("DPDK: this kernel does not copy DMA-pinned pages at fork; rdma-core "
                      "will MADV_DONTFORK registered memory, and a fork()ed child (e.g. "
                      "rx_samples_to_file's dd pre-test) may segfault before exec()");
            break;
    }
}

bool has_lcore_opt(const std::vector<std::string>& t)
{
    for (const auto& s : t)
        if (s == "-l" or s == "-c" or s == "--lcores" or s.compare(0, 2, "-l") == 0
            or s.compare(0, 2, "-c") == 0 or s.compare(0, 9, "--lcores=") == 0)
            return true;
    return false;
}

//! caller holds G().m
void eal_init_once(const uhd::device_addr_t& args,
    const std::string& pci,
    unsigned main_core,
    const std::vector<unsigned>& rx_cores,
    unsigned tx_core)
{
    global_state& g = G();
    if (g.eal == 1)
        return;
    if (g.eal == -1)
        throw uhd::runtime_error(g.eal_err);

    std::string raw;
    if (const char* e = std::getenv("ZCU216_DPDK_EAL")) {
        raw = e;
    } else if (args.has_key("dpdk_eal")) {
        // UHD device args cannot hold ',' or '=': write ';' and '~' instead
        raw = args["dpdk_eal"];
        std::replace(raw.begin(), raw.end(), ';', ',');
        std::replace(raw.begin(), raw.end(), '~', '=');
    } else {
        raw = "-a " + pci + " --file-prefix uhd_zcu216 --in-memory --no-telemetry";
    }
    std::vector<std::string> toks;
    {
        std::istringstream ss(raw);
        std::string t;
        while (ss >> t)
            toks.push_back(t);
    }
    if (not has_lcore_opt(toks)) {
        std::vector<unsigned> l{main_core};
        for (unsigned c : rx_cores)
            l.push_back(c);
        l.push_back(tx_core);
        std::string s;
        std::set<unsigned> seen;
        for (unsigned c : l)
            if (seen.insert(c).second)
                s += (s.empty() ? "" : ",") + std::to_string(c);
        toks.push_back("-l");
        toks.push_back(s); // the first one is the main lcore
    }
    bool no_huge = false;
    for (const auto& t : toks)
        no_huge = no_huge or t == "--no-huge";

    std::string why;
    if (not have_privileges(why))
        throw uhd::runtime_error(
            "ZCU216: the DPDK data plane needs root (or CAP_NET_ADMIN, CAP_NET_RAW, "
            "CAP_IPC_LOCK): " + why
            + ". Run the application with sudo (e.g. sudo uhd_usrp_probe --args type=zcu216)");
    if (not no_huge and free_hugepages() == 0)
        throw uhd::runtime_error("ZCU216: no free hugepages for DPDK "
                                 "(/sys/kernel/mm/hugepages/*/free_hugepages); run "
                                 "rfsoc_lib/uhd/host/setup_dpdk.sh");

    g.argv_store.clear();
    g.argv_store.push_back("uhd_zcu216");
    for (auto& t : toks)
        g.argv_store.push_back(t);
    g.argv.clear();
    for (auto& s : g.argv_store)
        g.argv.push_back(&s[0]);
    g.argv.push_back(nullptr);
    g.eal_args.clear();
    for (size_t i = 1; i < g.argv_store.size(); i++)
        g.eal_args += (i > 1 ? " " : "") + g.argv_store[i];
    ZLOG_INFO("DPDK: rte_eal_init " << g.eal_args << " (" << rte_version() << ")");
    keep_fork_usable(); // before the EAL loads the mlx PMDs

    // rte_eal_init pins the calling thread (an application thread) to the
    // main lcore: give it its CPUs back afterwards.
    cpu_set_t saved;
    CPU_ZERO(&saved);
    const bool have_aff = pthread_getaffinity_np(pthread_self(), sizeof(saved), &saved) == 0;
    const int rc        = rte_eal_init(int(g.argv.size() - 1), g.argv.data());
    const int err       = rte_errno;
    if (have_aff)
        pthread_setaffinity_np(pthread_self(), sizeof(saved), &saved);
    if (rc < 0) {
        g.eal     = -1; // rte_eal_init cannot be retried in this process
        g.eal_err = "ZCU216: rte_eal_init(" + g.eal_args + ") failed: " + rte_err(err)
                    + ". Check: root, hugepages (setup_dpdk.sh), the -a PCI address, "
                      "and that no other process uses the same --file-prefix without --in-memory";
        throw uhd::runtime_error(g.eal_err);
    }
    g.eal = 1;
    std::atexit(at_exit);
}

} // namespace

// ---------------------------------------------------------------------------
// port
// ---------------------------------------------------------------------------
class port
{
public:
    uint16_t id = 0;
    std::string name;   // EAL device name (PCI address)
    std::string ifname; // kernel netdev of the host data endpoint (may be empty)
    rte_ether_addr mac{};
    int sock_id = 0;
    std::vector<unsigned> rx_cores;
    unsigned tx_core = 1;
    uint16_t rxd = 4096, txd = 4096, min_rxq = 1;
    //! RX mbufs per queue that zero-copy rings may hold (0: copy mode)
    size_t zc_frames = 0;
    uint16_t mtu = 9000;
    //! mempool drivers of the RX / TX mbuf pools ("" = DPDK's default ring).
    //! "stack" hands back the most recently freed mbuf first: its lines are
    //! still in L3, so a TX packet is written without a DRAM read for
    //! ownership and an RX buffer is refilled into cached lines -- the
    //! difference on a memory-bandwidth-bound host (one DIMM channel).
    std::string rx_pool_ops, tx_pool_ops;

    ~port()
    {
        std::lock_guard<std::mutex> l(G().m);
        auto it = G().ports.find(id);
        if (it == G().ports.end())
            return;
        port_state& ps = it->second;
        if (--ps.objects == 0 and ps.started and not ps.rx_active and not ps.tx_active) {
            stop_port(id, ps);
            ZLOG_INFO("DPDK: port " << name << " stopped");
        }
    }

    //! configure (isolated) and start with at least nq RX queues; G().m held
    void ensure_started(uint16_t nq)
    {
        port_state& ps = G().ports[id];
        nq             = std::max(nq, min_rxq);
        if (ps.started and ps.nq_rx >= nq)
            return;
        if (ps.started) {
            if (ps.rx_active or ps.tx_active)
                throw uhd::runtime_error("ZCU216: DPDK port " + name + " runs "
                                         + std::to_string(ps.nq_rx) + " RX queues and " + std::to_string(nq)
                                         + " are needed while a stream is active; pass nports="
                                         + std::to_string(nq) + " as a device arg");
            stop_port(id, ps);
        }
        const auto t0 = clk::now();
        rte_flow_error ferr{};
        if (rte_flow_isolate(id, 1, &ferr) != 0)
            throw uhd::runtime_error("ZCU216: rte_flow_isolate(" + name + "): " + flow_err(ferr)
                                     + ". Isolated mode is required so that ARP, ICMP and the "
                                       "async status port stay with the kernel.");
        rte_eth_dev_info info{};
        int rc = rte_eth_dev_info_get(id, &info);
        if (rc != 0)
            throw uhd::runtime_error("ZCU216: rte_eth_dev_info_get(" + name + "): " + rte_err(rc));
        // nq data queues + the TX status queue (PROTOCOL §7, polled by the TX lcore)
        const uint16_t nrxq = uint16_t(nq + 1);
        if (std::string(info.driver_name ? info.driver_name : "") == "net_tap" and nrxq > 4)
            // DPDK 23.11's tap PMD puts one fd per RX and TX queue into an
            // 8-fd IPC message at start (tap_mp_req_on_rxtx) and overflows
            // the stack beyond that; it also wants as many TX as RX queues
            throw uhd::runtime_error("ZCU216: net_tap supports at most 3 sample queues (nports <= 3: "
                                     + std::to_string(nq) + " + the TX status queue, as many TX "
                                       "queues, must stay within 8 queue fds)");
        if (nrxq > info.max_rx_queues)
            throw uhd::runtime_error("ZCU216: DPDK port " + name + " has only "
                                     + std::to_string(info.max_rx_queues) + " RX queues ("
                                     + std::to_string(nq) + " for samples + 1 for TX status needed)");
        // The kernel netdev owns the MTU (bifurcated mlx5 reports 1500 until
        // told otherwise); only a netdev below the stream's frames is a problem.
        uint16_t cur_mtu = 0;
        std::ifstream mf("/sys/class/net/" + ifname + "/mtu");
        if (ifname.empty() or not(mf >> cur_mtu))
            rte_eth_dev_get_mtu(id, &cur_mtu);
        if (cur_mtu < mtu)
            ZLOG_WARN("DPDK: " << (ifname.empty() ? name : ifname) << " MTU is " << cur_mtu
                               << ", the stream needs " << mtu
                               << " (setup_cx5.sh sets 9000 on the netdev)");
        rte_eth_conf conf{};
        conf.rxmode.mtu = std::max(cur_mtu, mtu);
        if (info.max_mtu and conf.rxmode.mtu > info.max_mtu)
            conf.rxmode.mtu = info.max_mtu;
        // One TX queue is used. Some PMDs (net_tap, used for testing) insist
        // on as many TX queues as RX queues: then configure nq, use queue 0.
        uint16_t ntxq = 1;
        rc            = rte_eth_dev_configure(id, nrxq, ntxq, &conf);
        if (rc != 0) {
            ntxq = nrxq;
            rc   = rte_eth_dev_configure(id, nrxq, ntxq, &conf);
        }
        if (rc != 0)
            throw uhd::runtime_error("ZCU216: rte_eth_dev_configure(" + name + ", " + std::to_string(nq)
                                     + " RX queues): " + rte_err(rc) + busy_hint(name));
        // rxd 0 (the default): ~1024 RX descriptors in all, split over the
        // queues. The buffers the NIC fills must still be in L3 when it
        // fills them again, so recv() reads them from cache and their dead
        // dirty lines are overwritten instead of written back to DRAM: with
        // the LIFO pool, 2 x 512 (8 MB) passes 16ch sc16 RX at 12 GB/s
        // strict on wei-duke-wsp5 (15 MB L3, one DIMM), 2 x 1024 does not.
        const uint16_t nrx_def = uint16_t(std::max(128, 1024 / std::max(1, int(nq))));
        uint16_t nrx = rxd ? rxd : nrx_def, ntx = txd;
        rte_eth_dev_adjust_nb_rx_tx_desc(id, &nrx, &ntx);

        const unsigned nlc = unsigned(rx_cores.size()) + 2;
        const size_t need  = size_t(nq) * (nrx + kRxBurst + zc_frames) + kStatusRxd + kStatusBurst
                            + nlc * kPoolCache * 3 / 2 + 1024;
        rte_mempool* old   = nullptr;
        if (not ps.rx_pool or ps.rx_pool_n < need) {
            const std::string pn = "zcu_rx" + std::to_string(id) + "_" + std::to_string(G().seq++);
            rte_mempool* mp = rx_pool_ops.empty()
                ? rte_pktmbuf_pool_create(pn.c_str(), unsigned(need), kPoolCache, 0, uint16_t(kMbufRoom), sock_id)
                : rte_pktmbuf_pool_create_by_ops(pn.c_str(), unsigned(need), kPoolCache, 0,
                      uint16_t(kMbufRoom), sock_id, rx_pool_ops.c_str());
            if (not mp)
                throw uhd::runtime_error("ZCU216: cannot allocate " + std::to_string(need)
                                         + " RX mbufs of " + std::to_string(kMbufRoom) + " B ("
                                         + rte_err(rte_errno) + "): not enough hugepages? "
                                         "(setup_dpdk.sh; lower dpdk_rxd=)");
            old          = ps.rx_pool;
            ps.rx_pool   = mp;
            ps.rx_pool_n = need;
        }
        for (uint16_t q = 0; q < nrxq; q++) {
            uint16_t nd = nrx;
            if (q == nq) { // the status queue: a few 24-byte packets per ms
                nd = kStatusRxd;
                uint16_t dummy = 0;
                rte_eth_dev_adjust_nb_rx_tx_desc(id, &nd, &dummy);
            }
            rc = rte_eth_rx_queue_setup(id, q, nd, unsigned(sock_id), nullptr, ps.rx_pool);
            if (rc != 0)
                throw uhd::runtime_error("ZCU216: rte_eth_rx_queue_setup(" + name + ", "
                                         + std::to_string(q) + "): " + rte_err(rc));
        }
        if (old)
            rte_mempool_free(old); // every queue that used it was set up again
        if (not ps.tx_pool) {
            const std::string pn = "zcu_tx" + std::to_string(id) + "_" + std::to_string(G().seq++);
            const unsigned n     = 2u * ntx + kTxRingSize + 2048u + 4u * kPoolCache - 1u;
            ps.tx_pool = tx_pool_ops.empty()
                ? rte_pktmbuf_pool_create(pn.c_str(), n, kPoolCache, 0, uint16_t(kMbufRoom), sock_id)
                : rte_pktmbuf_pool_create_by_ops(pn.c_str(), n, kPoolCache, 0, uint16_t(kMbufRoom), sock_id,
                      tx_pool_ops.c_str());
            if (not ps.tx_pool)
                throw uhd::runtime_error("ZCU216: cannot allocate " + std::to_string(n)
                                         + " TX mbufs (" + rte_err(rte_errno)
                                         + "): not enough hugepages?");
        }
        for (uint16_t q = 0; q < ntxq; q++) {
            rc = rte_eth_tx_queue_setup(id, q, ntx, unsigned(sock_id), nullptr);
            if (rc != 0)
                throw uhd::runtime_error("ZCU216: rte_eth_tx_queue_setup(" + name + "): " + rte_err(rc));
        }
        rc = rte_eth_dev_start(id);
        if (rc != 0)
            throw uhd::runtime_error("ZCU216: rte_eth_dev_start(" + name + "): " + rte_err(rc)
                                     + busy_hint(name));
        ps.started = true;
        ps.nq_rx   = nq;
        // Wait for the link: frames sent before it is up are lost (on the
        // net_tap harness the bridge drops everything until the tap's carrier
        // comes up, ~0.2-0.5 s after the start). The CX-5 netdev's link is
        // normally up already; a down link is worth a warning either way.
        rte_eth_link link{};
        const auto link_dl = clk::now() + std::chrono::seconds(3);
        while (true) {
            rte_eth_link_get_nowait(id, &link);
            if (link.link_status == RTE_ETH_LINK_UP or clk::now() > link_dl)
                break;
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if (link.link_status != RTE_ETH_LINK_UP)
            ZLOG_WARN("DPDK: port " << name << " link is DOWN after 3 s (is the 100G link to "
                                       "the FPGA up? ethtool " << (ifname.empty() ? name : ifname)
                                    << ")");
        ZLOG_INFO("DPDK: port " << name << " started, isolated: " << nq << " RX queue(s) x " << nrx
                                << " desc + TX status queue " << nq << ", " << ntxq << " TX queue(s) x " << ntx << " desc, MTU "
                                << conf.rxmode.mtu << ", link "
                                << (link.link_status == RTE_ETH_LINK_UP ? "up" : "DOWN") << ", in "
                                << std::chrono::duration_cast<std::chrono::milliseconds>(clk::now() - t0).count()
                                << " ms");
    }
};

std::string cpu_list(const std::vector<unsigned>& v)
{
    std::string s;
    for (unsigned c : v)
        s += (s.empty() ? "" : ":") + std::to_string(c);
    return s;
}

const cpu_layout& default_layout()
{
    static const cpu_layout L = [] {
        cpu_layout l;
        std::string online;
        std::ifstream f("/sys/devices/system/cpu/online");
        std::getline(f, online);
        if (online.empty())
            return l;
        // physical cores: groups of hyperthread siblings
        std::vector<std::vector<unsigned>> cores;
        std::set<unsigned> seen;
        for (unsigned c : parse_cpus(online, "online CPUs")) {
            if (seen.count(c))
                continue;
            std::vector<unsigned> g{c};
            std::ifstream t("/sys/devices/system/cpu/cpu" + std::to_string(c)
                            + "/topology/thread_siblings_list");
            std::string sib;
            if (std::getline(t, sib) and not sib.empty())
                g = parse_cpus(sib, "thread siblings");
            std::sort(g.begin(), g.end());
            for (unsigned x : g)
                seen.insert(x);
            cores.push_back(g);
        }
        std::sort(cores.begin(), cores.end());
        // heterogeneous CPUs (arm big.LITTLE, e.g. the DGX Spark's Cortex-X925
        // + A725: /sys/.../cpu_capacity 1024 vs ~720): the fastest cores
        // first, so the application, the lcores and the workers get them;
        // workers only on cores within 90 % of the fastest (the little ones
        // stay with the system). Uniform capacity (x86): unchanged.
        auto capacity = [](unsigned c) {
            std::ifstream t("/sys/devices/system/cpu/cpu" + std::to_string(c) + "/cpu_capacity");
            long v = 0;
            return (t >> v) ? v : 0L;
        };
        long cap_max = 0, cap_min = LONG_MAX;
        for (const auto& g : cores) {
            const long v = capacity(g.front());
            cap_max = std::max(cap_max, v), cap_min = std::min(cap_min, v);
        }
        const bool hetero = cap_max > 0 and cap_min < cap_max;
        if (hetero)
            std::stable_sort(cores.begin(), cores.end(), [&](const auto& a, const auto& b) {
                return capacity(a.front()) > capacity(b.front());
            });
        size_t k = 0;
        auto next = [&]() -> const std::vector<unsigned>* { return k < cores.size() ? &cores[k++] : nullptr; };
        const auto* c0 = next();
        const auto* c1 = next();
        if (not c0 or not c1) // one core: everything on it
            return l;
        l.main = c0->front();
        l.rx   = {c1->front()};
        if (c1->size() > 1) {
            l.tx = (*c1)[1];
        } else if (const auto* c2 = next()) {
            l.tx = c2->front();
        } else {
            l.tx = c0->back();
        }
        // the application on C0 with the EAL main lcore (that IS the
        // application thread, idle as an lcore after rte_eal_init), and a
        // conversion worker on every remaining core: recv()/send() at 100GbE
        // rates are bound by the workers' memory traffic, and the measured
        // best on wei-duke-wsp5 (6 cores, one DIMM) gives them 4 cores
        // (main/app 0+6, lcores 1+7, workers 2,3,4,5; the old layout, app on
        // the last core and 3 workers, lost ~1 GB/s of RX at sc12)
        if (k < cores.size()) {
            l.app = *c0;
            for (size_t i = k; i < cores.size(); i++)
                if (not hetero or capacity(cores[i].front()) * 10 >= cap_max * 9)
                    l.workers.push_back(cores[i].front());
        }
        return l;
    }();
    return L;
}

port_sptr open_port(const uhd::device_addr_t& args, const local_iface& ifc, size_t mtu)
{
    auto p          = std::make_shared<port>();
    const cpu_layout& L = default_layout();
    p->rx_cores     = parse_cpus(args.get("dpdk_rx_cores", cpu_list(L.rx)), "dpdk_rx_cores");
    p->tx_core      = parse_cpus(args.get("dpdk_tx_core", std::to_string(L.tx)), "dpdk_tx_core").at(0);
    const unsigned main_core =
        parse_cpus(args.get("dpdk_main_core", std::to_string(L.main)), "dpdk_main_core").at(0);
    auto clamp_arg = [&](const char* k, const char* def, long long lo, long long hi) {
        return std::max(lo, std::min(hi, parse_ll(args.get(k, def), k)));
    };
    p->rxd     = args.has_key("dpdk_rxd") ? uint16_t(clamp_arg("dpdk_rxd", "4096", 64, 32768)) : 0; // 0: auto
    p->txd     = uint16_t(clamp_arg("dpdk_txd", "4096", 64, 32768));
    p->min_rxq = uint16_t(clamp_arg("nports", "2", 1, 16));
    // zero-copy RX: the rings hold mbufs, so the pool has num_recv_frames
    // more per queue (the streamer reads the same two args)
    if (args.get("rx_zero_copy", "1") != "0")
        p->zc_frames = size_t(clamp_arg("num_recv_frames", "4096", 64, 1 << 20));
    p->mtu          = uint16_t(std::min<size_t>(mtu, 9600));
    auto ops_arg = [&](const char* k) {
        const std::string v = args.get(k, "");
        return v == "ring" ? std::string() : v; // "ring" = DPDK's default
    };
    // RX: LIFO by default too, with the short descriptor rings above (both
    // are needed: either alone leaves 16ch sc16 RX at ~65 %)
    p->rx_pool_ops = args.has_key("dpdk_rx_pool_ops") ? ops_arg("dpdk_rx_pool_ops") : "stack";
    // TX: LIFO by default. send() allocates from a non-lcore thread (no
    // per-lcore cache), so the default FIFO ring hands it the coldest of
    // ~12k mbufs and every packet write first reads its lines from DRAM; on
    // one DIMM channel that halved sc16 TX at 12 GB/s (54 % -> 100 %
    // measured, 16ch 187.5 MS/s).
    p->tx_pool_ops = args.has_key("dpdk_tx_pool_ops") ? ops_arg("dpdk_tx_pool_ops") : "stack";
    for (unsigned c : p->rx_cores)
        if (c == p->tx_core or c == main_core)
            throw uhd::value_error("ZCU216: dpdk_rx_cores must not contain dpdk_tx_core ("
                                   + std::to_string(p->tx_core) + ") or dpdk_main_core ("
                                   + std::to_string(main_core) + ")");
    if (p->tx_core == main_core)
        throw uhd::value_error("ZCU216: dpdk_tx_core must differ from dpdk_main_core");

    std::string pci = args.get("dpdk_port", "");
    if (pci.empty())
        pci = pci_of_iface(ifc.name);
    if (pci.empty())
        throw uhd::lookup_error("ZCU216: cannot tell the PCI device of the data interface '"
                                + ifc.name + "' (" + ifc.ip
                                + "); pass dpdk_port=<PCI address or vdev name>");

    std::lock_guard<std::mutex> l(G().m);
    const bool first = G().eal == 0;
    eal_init_once(args, pci, main_core, p->rx_cores, p->tx_core);
    if (not first and (args.has_key("dpdk_eal") or std::getenv("ZCU216_DPDK_EAL")))
        ZLOG_DEBUG("DPDK: EAL already initialised in this process (" << G().eal_args
                                                                      << "); dpdk_eal ignored");
    uint16_t id = 0;
    if (rte_eth_dev_get_port_by_name(pci.c_str(), &id) != 0) {
        std::string have;
        uint16_t pid;
        RTE_ETH_FOREACH_DEV(pid)
        {
            char nm[RTE_ETH_NAME_MAX_LEN];
            if (rte_eth_dev_get_name_by_port(pid, nm) == 0)
                have += std::string(have.empty() ? "" : ", ") + nm;
        }
        throw uhd::runtime_error("ZCU216: DPDK port '" + pci + "' not found (EAL ports: "
                                 + (have.empty() ? "none" : have)
                                 + "). Is it in the EAL allow list (-a) and is the mlx5 PMD "
                                   "installed (ibverbs-providers)?"
                                 + (G().eal_args.find(pci) == std::string::npos
                                        ? " The EAL was initialised with: " + G().eal_args
                                        : std::string()));
    }
    p->id     = id;
    p->name   = pci;
    p->ifname = ifc.name;
    const int sock = rte_eth_dev_socket_id(id);
    p->sock_id     = sock < 0 ? int(rte_socket_id()) : sock;
    rte_eth_macaddr_get(id, &p->mac);
    const std::string pm = mac_str(p->mac);
    if (not ifc.mac.empty() and norm_mac(ifc.mac) != pm)
        ZLOG_WARN("DPDK: port " << pci << " MAC " << pm << " differs from the host data MAC "
                                << ifc.mac << " (" << ifc.name
                                << ") that the FPGA is told to send to");
    for (unsigned c : p->rx_cores)
        if (not rte_lcore_is_enabled(c) or c == rte_get_main_lcore())
            throw uhd::value_error("ZCU216: dpdk_rx_cores: CPU " + std::to_string(c)
                                   + " is not an EAL worker lcore (EAL: " + G().eal_args + ")");
    if (not rte_lcore_is_enabled(p->tx_core) or p->tx_core == rte_get_main_lcore())
        throw uhd::value_error("ZCU216: dpdk_tx_core " + std::to_string(p->tx_core)
                               + " is not an EAL worker lcore (EAL: " + G().eal_args + ")");
    G().ports[id].objects++;
    ZLOG_INFO("DPDK: port " << pci << " (" << pm << ", " << ifc.name << "), RX lcores "
                            << cpu_list(p->rx_cores) << ", TX lcore " << p->tx_core);
    // Configure and start the port now (isolated, no flows yet: nothing
    // reaches it). Starting takes up to seconds (mempools, queues); done at
    // the first streamer it would eat into the lead time of a timed command
    // the application scheduled after set_time_now() -- tx_timed_samples'
    // 1.5 s burst would start late.
    p->ensure_started(p->min_rxq);
    return p;
}

// ---------------------------------------------------------------------------
// RX
// ---------------------------------------------------------------------------
namespace {

class rx_session_impl : public rx_session
{
public:
    struct worker
    {
        rx_session_impl* s = nullptr;
        unsigned lcore     = 0;
        std::vector<std::pair<uint16_t, rx_sink*>> qs;
        uint64_t pkts = 0, bad = 0, missteered = 0, trunc = 0, full = 0;
        uint64_t overflows = 0, discarded = 0;
        bool launched = false;
    };
    port_sptr p;
    uint32_t ip_be     = 0;
    uint16_t port_base = 0, nq = 0;
    bool active        = false;
    std::vector<rte_flow*> flows;
    std::vector<std::unique_ptr<worker>> workers;
    std::atomic<bool> stop{false};
    rte_eth_stats st0{};

    ~rx_session_impl() override
    {
        stop.store(true);
        uint64_t pkts = 0, bad = 0, mis = 0, trunc = 0, full = 0, ovf = 0, disc = 0;
        for (auto& w : workers) {
            if (w->launched)
                rte_eal_wait_lcore(w->lcore);
            ovf += w->overflows;
            disc += w->discarded;
            pkts += w->pkts;
            bad += w->bad;
            mis += w->missteered;
            trunc += w->trunc;
            full += w->full;
        }
        std::lock_guard<std::mutex> l(G().m);
        for (auto* f : flows) {
            rte_flow_error err{};
            if (f and rte_flow_destroy(p->id, f, &err) != 0)
                ZLOG_WARN("DPDK: rte_flow_destroy: " << flow_err(err));
        }
        if (active) {
            G().ports[p->id].rx_active = false;
            rte_eth_stats st{};
            rte_eth_stats_get(p->id, &st);
            ZLOG_INFO("DPDK RX closed: " << pkts << " pkts, " << bad << " foreign/malformed, "
                                         << mis << " on the wrong queue, " << trunc
                                         << " oversized, " << full << " ring-full polls, "
                                         << ovf << " overflow(s) = " << disc
                                         << " pkts discarded until every ring was half free; port: "
                                         << st.ipackets - st0.ipackets << " ipackets, "
                                         << st.imissed - st0.imissed << " imissed, "
                                         << st.rx_nombuf - st0.rx_nombuf << " rx_nombuf, "
                                         << st.ierrors - st0.ierrors << " ierrors");
        }
    }
};

enum frame_kind { FRAME_OK, FRAME_FOREIGN, FRAME_MISSTEERED };

//! UDP ports a sample stream may use: the FPGA streamer sends packet i to
//! port_base + (k mod nports), and its counter k is NOT reset between
//! stream setups. A session after one with more ports (benchmark_rate's 4
//! after a 2-port tool, or the other way) therefore gets its first packet
//! on port_base + (old k): measured, the kernel received one 8 KiB sample
//! packet on port 49813 during a 2-port session after a 4-port one, and the
//! session's first finite capture came up one packet short. The daemon now
//! zeroes the counter at every stream setup (eth100g._zero_port_counter), so
//! this does not happen; for an older daemon every port of the span is
//! steered to queue (port - base) mod nq, so such a packet still lands in one
//! of ours -- measured, it can then arrive BEHIND the next packet of that
//! queue and the merge reports a gap, so this is a fallback, not the fix.
constexpr uint16_t kStreamPortSpan = 16;

//! Eth / IPv4 (no fragments) / UDP to our IP and a port of this queue
//! (base + q + j*nq within `span` ports of base); returns the UDP payload.
//! FOREIGN: not ours at all (the flow rules should never let one through on
//! mlx5); MISSTEERED: one of our ports, on the wrong queue (dropped: ring k
//! has exactly one producer).
inline frame_kind parse_frame(const rte_mbuf* m,
    uint32_t ip_be,
    uint16_t base,
    uint16_t nq,
    uint16_t q,
    const uint8_t*& pay,
    uint32_t& plen,
    uint16_t span = 1)
{
    if (m->nb_segs != 1)
        return FRAME_FOREIGN;
    const uint32_t len = rte_pktmbuf_data_len(m);
    const uint8_t* d   = rte_pktmbuf_mtod(m, const uint8_t*);
    if (len < kEthIpUdp)
        return FRAME_FOREIGN;
    const auto* eth = reinterpret_cast<const rte_ether_hdr*>(d);
    if (eth->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4))
        return FRAME_FOREIGN;
    const auto* ip   = reinterpret_cast<const rte_ipv4_hdr*>(d + 14);
    const uint32_t hl = uint32_t(ip->version_ihl & 0x0f) * 4;
    if ((ip->version_ihl >> 4) != 4 or hl < 20 or ip->next_proto_id != IPPROTO_UDP
        or (ip->fragment_offset & rte_cpu_to_be_16(0x3fff)) != 0 or ip->dst_addr != ip_be)
        return FRAME_FOREIGN;
    const uint32_t tot = rte_be_to_cpu_16(ip->total_length);
    if (tot < hl + 8 or 14 + tot > len)
        return FRAME_FOREIGN;
    const auto* udp     = reinterpret_cast<const rte_udp_hdr*>(d + 14 + hl);
    const uint16_t port = rte_be_to_cpu_16(udp->dst_port);
    const uint16_t top = uint16_t(base + std::max<uint16_t>(span, nq));
    if (port < base or port >= top)
        return FRAME_FOREIGN;
    if ((port - base) % nq != q)
        return FRAME_MISSTEERED;
    const uint32_t ul = rte_be_to_cpu_16(udp->dgram_len);
    if (ul < 8 or hl + ul > tot)
        return FRAME_FOREIGN;
    pay  = d + 14 + hl + 8;
    plen = ul - 8;
    return FRAME_OK;
}

} // namespace

void free_mbufs(void* const* mbufs, size_t n)
{
    if (n)
        rte_pktmbuf_free_bulk(reinterpret_cast<rte_mbuf**>(const_cast<void**>(mbufs)), unsigned(n));
}

void free_rx_mbufs_raw(void* const* mbufs, size_t n)
{
    if (n == 0)
        return;
    auto* const* m = reinterpret_cast<rte_mbuf* const*>(mbufs);
    // the state rte_pktmbuf_free would leave them in, which they are in
    // already: refcnt 1, next NULL, nb_segs 1 (single-segment NIC RX)
    rte_mempool_put_bulk(m[0]->pool, const_cast<void* const*>(mbufs), unsigned(n));
}

void register_thread()
{
    // A non-EAL thread has no mempool cache: every mbuf free (recv() releasing
    // slots) and alloc (send()) went to the pool itself under its lock --
    // 13 % of recv() at 12 GB/s. Registered, it gets an lcore id and a cache.
    struct reg_t
    {
        bool mine = false;
        reg_t()
        {
            if (rte_lcore_id() == LCORE_ID_ANY) {
                mine = rte_thread_register() == 0;
                ZLOG_INFO("DPDK: application thread registered as lcore " << rte_lcore_id()
                          << (mine ? "" : " (failed: " + std::string(rte_strerror(rte_errno)) + ")"));
            }
        }
        ~reg_t()
        {
            if (mine)
                rte_thread_unregister();
        }
    };
    thread_local reg_t reg;
    (void)reg;
}

namespace {

int rx_main(void* arg)
{
    auto* w            = static_cast<rx_session_impl::worker*>(arg);
    rx_session_impl* s = w->s;
    const uint16_t pid = s->p->id;
    rte_mbuf* mb[kRxBurst];
    uint8_t* bufs[kRxBurst];
    uint32_t lens[kRxBurst];
    unsigned idle = 0;
    while (not s->stop.load(std::memory_order_relaxed)) {
        bool any = false;
        for (auto& qs : w->qs) {
            const uint16_t q = qs.first;
            rx_sink* sink    = qs.second;
            const bool zc     = sink->zero_copy();
            if (sink->discarding()) {
                // the stream overflowed: drop whole bursts (rx_sink)
                const uint16_t n = rte_eth_rx_burst(pid, q, mb, kRxBurst);
                if (n) {
                    rte_pktmbuf_free_bulk(mb, n);
                    w->discarded += n;
                    any = true;
                }
                continue;
            }
            const size_t room = sink->reserve(zc ? nullptr : bufs, kRxBurst);
            if (room == 0) {
                // consumer behind: the stream discards until it caught up, or
                // (a sink without hysteresis) the packets stay in the NIC
                // ring and drops show up as a TSF gap and in imissed
                w->full++;
                sink->note_full();
                if (sink->overflowed())
                    w->overflows++;
                continue;
            }
            const uint16_t n = rte_eth_rx_burst(pid, q, mb, uint16_t(room));
            if (n == 0)
                continue;
            any = true;
            const size_t maxb = sink->slot_bytes();
            size_t k          = 0;
            if (zc) {
                void* zm[kRxBurst];
                uint8_t* zp[kRxBurst];
                for (uint16_t i = 0; i < n; i++) {
                    const uint8_t* pay = nullptr;
                    uint32_t plen      = 0;
                    const frame_kind fk =
                        parse_frame(mb[i], s->ip_be, s->port_base, s->nq, q, pay, plen, kStreamPortSpan);
                    if (fk != FRAME_OK) {
                        (fk == FRAME_MISSTEERED ? w->missteered : w->bad)++;
                        rte_pktmbuf_free(mb[i]);
                        continue;
                    }
                    zm[k]     = mb[i];
                    zp[k]     = const_cast<uint8_t*>(pay);
                    lens[k++] = plen;
                }
                if (k)
                    sink->commit_zc(zm, zp, lens, k);
                w->pkts += n;
                continue;
            }
            for (uint16_t i = 0; i < n; i++) {
                const uint8_t* pay = nullptr;
                uint32_t plen      = 0;
                const frame_kind fk =
                    parse_frame(mb[i], s->ip_be, s->port_base, s->nq, q, pay, plen, kStreamPortSpan);
                if (fk != FRAME_OK) {
                    (fk == FRAME_MISSTEERED ? w->missteered : w->bad)++;
                    continue;
                }
                if (plen > maxb) {
                    w->trunc++;
                    continue;
                }
                rte_memcpy(bufs[k], pay, plen);
                lens[k++] = plen;
            }
            rte_pktmbuf_free_bulk(mb, n);
            if (k)
                sink->commit(lens, k);
            w->pkts += n;
        }
        if (any)
            idle = 0;
        else if (++idle > 20000)
            std::this_thread::sleep_for(std::chrono::microseconds(20)); // idle: stop burning the core
        else
            rte_pause();
    }
    return 0;
}

rte_flow* make_rx_flow(uint16_t pid, uint32_t ip_be, uint16_t udp_port, uint16_t queue, std::string& why)
{
    rte_flow_attr attr{};
    attr.ingress = 1;
    rte_flow_item_ipv4 ip_spec{}, ip_mask{};
    ip_spec.hdr.dst_addr = ip_be;
    ip_mask.hdr.dst_addr = 0xffffffffu;
    rte_flow_item_udp udp_spec{}, udp_mask{};
    udp_spec.hdr.dst_port = rte_cpu_to_be_16(udp_port);
    udp_mask.hdr.dst_port = 0xffff;
    rte_flow_item pat[4]{};
    pat[0].type = RTE_FLOW_ITEM_TYPE_ETH;
    pat[1].type = RTE_FLOW_ITEM_TYPE_IPV4;
    pat[1].spec = &ip_spec;
    pat[1].mask = &ip_mask;
    pat[2].type = RTE_FLOW_ITEM_TYPE_UDP;
    pat[2].spec = &udp_spec;
    pat[2].mask = &udp_mask;
    pat[3].type = RTE_FLOW_ITEM_TYPE_END;
    rte_flow_action_queue qa{};
    qa.index = queue;
    rte_flow_action act[2]{};
    act[0].type = RTE_FLOW_ACTION_TYPE_QUEUE;
    act[0].conf = &qa;
    act[1].type = RTE_FLOW_ACTION_TYPE_END;
    rte_flow_error err{};
    if (rte_flow_validate(pid, &attr, pat, act, &err) != 0) {
        why = "rte_flow_validate: " + flow_err(err);
        return nullptr;
    }
    rte_flow* f = rte_flow_create(pid, &attr, pat, act, &err);
    if (not f)
        why = "rte_flow_create: " + flow_err(err);
    return f;
}

} // namespace

std::unique_ptr<rx_session> start_rx(const port_sptr& p,
    const std::string& host_ip,
    uint16_t port_base,
    const std::vector<rx_sink*>& sinks)
{
    if (not p)
        throw uhd::runtime_error("ZCU216: DPDK port not open");
    auto s       = std::make_unique<rx_session_impl>();
    s->p         = p;
    s->port_base = port_base;
    s->nq        = uint16_t(sinks.size());
    in_addr a{};
    if (inet_pton(AF_INET, host_ip.c_str(), &a) != 1)
        throw uhd::value_error("ZCU216: bad host data IP '" + host_ip + "'");
    s->ip_be = a.s_addr;
    {
        std::lock_guard<std::mutex> l(G().m);
        port_state& ps = G().ports[p->id];
        if (ps.rx_active)
            throw uhd::runtime_error("ZCU216: a DPDK RX session is already active on " + p->name);
        p->ensure_started(s->nq);
        ps.rx_active = true;
        s->active    = true;
        for (uint16_t q = 0; q < s->nq; q++) {
            std::string why;
            rte_flow* f = make_rx_flow(p->id, s->ip_be, uint16_t(port_base + q), q, why);
            if (not f)
                throw uhd::runtime_error("ZCU216: DPDK flow " + host_ip + ":"
                                         + std::to_string(port_base + q) + " -> queue "
                                         + std::to_string(q) + ": " + why);
            s->flows.push_back(f);
        }
        // the rest of the span the streamer may still use (kStreamPortSpan):
        // a safety net, so a rule that cannot be added only costs a warning
        for (uint16_t k = s->nq; k < kStreamPortSpan; k++) {
            std::string why;
            rte_flow* f = make_rx_flow(p->id, s->ip_be, uint16_t(port_base + k), uint16_t(k % s->nq), why);
            if (f)
                s->flows.push_back(f);
            else
                ZLOG_WARN("DPDK flow " << host_ip << ":" << (port_base + k) << " -> queue "
                                       << (k % s->nq) << " (stale-port safety net): " << why);
        }
        rte_eth_stats_get(p->id, &s->st0);
    }
    const size_t ncores = std::min<size_t>(p->rx_cores.size(), s->nq);
    for (size_t j = 0; j < ncores; j++) {
        auto w   = std::make_unique<rx_session_impl::worker>();
        w->s     = s.get();
        w->lcore = p->rx_cores[j];
        for (uint16_t q = 0; q < s->nq; q++)
            if (q % ncores == j)
                w->qs.emplace_back(q, sinks[q]);
        s->workers.push_back(std::move(w));
    }
    std::string map;
    for (auto& w : s->workers) {
        if (rte_eal_get_lcore_state(w->lcore) != WAIT)
            throw uhd::runtime_error("ZCU216: DPDK lcore " + std::to_string(w->lcore) + " is busy");
        const int rc = rte_eal_remote_launch(rx_main, w.get(), w->lcore);
        if (rc != 0)
            throw uhd::runtime_error("ZCU216: rte_eal_remote_launch(lcore "
                                     + std::to_string(w->lcore) + "): " + rte_err(rc));
        w->launched = true;
        map += " lcore " + std::to_string(w->lcore) + ":q";
        for (size_t i = 0; i < w->qs.size(); i++)
            map += (i ? "," : "") + std::to_string(w->qs[i].first);
    }
    ZLOG_INFO("DPDK RX: " << host_ip << ":" << port_base << (s->nq > 1 ? "+" : "") << " -> "
                          << s->nq << " queue(s), UDP port k -> queue k (ports up to +"
                          << (kStreamPortSpan - 1) << " -> queue k mod " << s->nq << ");" << map);
    return s;
}

// ---------------------------------------------------------------------------
// TX
// ---------------------------------------------------------------------------
namespace {

class tx_session_impl : public tx_session
{
public:
    port_sptr p;
    rte_mempool* pool = nullptr;
    rte_ring* ring    = nullptr;
    std::vector<rte_mbuf*> slots;
    uint8_t hdr[kEthIpUdp];
    size_t max_payload = 0;
    uint16_t ip_id     = 0;
    bool active = false, launched = false;
    std::atomic<bool> stop{false}, abort{false};
    std::atomic<uint64_t> pkts{0}, stalls{0};
    rte_eth_stats st0{};
    // TX status (PROTOCOL §7): flow -> status queue, polled by the TX lcore
    tx_status_sink* sink = nullptr;
    rte_flow* sflow      = nullptr;
    uint16_t squeue = 0, sport = 0;
    uint32_t sip_be = 0;
    uint64_t status_pkts = 0, status_bad = 0; // TX lcore only
    // untimed-burst prefill (tx_endpoint::prefill_pkts), TX lcore only
    std::atomic<size_t> prefill_pkts{0};
    std::atomic<uint64_t> prefill_tsc{0};
    uint64_t prefills = 0, prefill_timeouts = 0;

    void set_prefill(size_t pkts, double us) override
    {
        prefill_pkts.store(std::min(pkts, kMaxPrefill), std::memory_order_relaxed);
        prefill_tsc.store(uint64_t(std::max(0.0, us) * 1e-6 * double(rte_get_tsc_hz())),
            std::memory_order_relaxed);
    }

    uint8_t* slot(size_t i) override
    {
        if (not slots.at(i)) {
            // the rest of the batch at once: one pool access instead of one
            // per packet (send() runs in an application thread, which has no
            // mempool cache, so every single alloc takes the pool's lock)
            size_t j = i;
            while (j < slots.size() and not slots[j])
                j++;
            if (rte_pktmbuf_alloc_bulk(pool, slots.data() + i, unsigned(j - i)) != 0)
                std::fill(slots.begin() + long(i), slots.begin() + long(j), nullptr); // all or none
        }
        if (not slots[i]) {
            const auto dl = clk::now() + std::chrono::seconds(2);
            while (not(slots[i] = rte_pktmbuf_alloc(pool))) {
                if (clk::now() > dl)
                    throw uhd::io_error("ZCU216: DPDK TX mbuf pool exhausted for 2 s "
                                        "(is the link down?)");
                rte_pause();
            }
        }
        return rte_pktmbuf_mtod(slots[i], uint8_t*) + kEthIpUdp;
    }

    void send(const uint32_t* lens, size_t n, size_t hold_at) override
    {
        for (size_t i = 0; i < n; i++) {
            rte_mbuf* m = slots.at(i);
            if (not m)
                throw uhd::runtime_error("ZCU216: DPDK TX: send() of an unbuilt slot");
            m->hash.usr = i == hold_at ? kHoldMark : 0; // read by the TX lcore only
            uint8_t* d = rte_pktmbuf_mtod(m, uint8_t*);
            std::memcpy(d, hdr, kEthIpUdp);
            auto* ip         = reinterpret_cast<rte_ipv4_hdr*>(d + 14);
            auto* udp        = reinterpret_cast<rte_udp_hdr*>(d + 34);
            ip->total_length = rte_cpu_to_be_16(uint16_t(28 + lens[i]));
            ip->packet_id    = rte_cpu_to_be_16(ip_id++);
            ip->hdr_checksum = 0;
            ip->hdr_checksum = rte_ipv4_cksum(ip);
            udp->dgram_len   = rte_cpu_to_be_16(uint16_t(8 + lens[i]));
            if (in_warmup)
                udp->dst_port = rte_cpu_to_be_16(9); // discard: the FPGA ignores it
            m->data_len      = uint16_t(kEthIpUdp + lens[i]);
            m->pkt_len       = kEthIpUdp + lens[i];
        }
        size_t done   = 0;
        const auto dl = clk::now() + std::chrono::seconds(5);
        while (done < n) {
            done += rte_ring_sp_enqueue_burst(
                ring, reinterpret_cast<void* const*>(slots.data() + done), unsigned(n - done), nullptr);
            if (done < n) {
                if (clk::now() > dl or rte_eal_get_lcore_state(p->tx_core) != RUNNING) {
                    for (size_t i = 0; i < done; i++)
                        slots[i] = nullptr;
                    throw uhd::io_error("ZCU216: DPDK TX lcore " + std::to_string(p->tx_core)
                                        + " is not draining its ring (link down?)");
                }
                rte_pause();
            }
        }
        for (size_t i = 0; i < n; i++)
            slots[i] = nullptr;
    }

    //! n full-size frames to UDP port 9 of the FPGA (it ignores them), through
    //! the ring and the TX lcore like samples; returns once they are on the wire
    bool in_warmup = false;
    void warmup(size_t n)
    {
        in_warmup = true;
        const uint64_t p0 = pkts.load();
        const uint32_t len = uint32_t(max_payload);
        size_t done = 0;
        while (done < n) {
            const size_t k = std::min(n - done, slots.size());
            std::vector<uint32_t> lens(k, len);
            for (size_t i = 0; i < k; i++)
                std::memset(slot(i), 0, len);
            send(lens.data(), k, kNoHold);
            done += k;
        }
        const auto dl = clk::now() + std::chrono::seconds(1);
        while (pkts.load() - p0 < n and clk::now() < dl)
            rte_pause();
        warmed    = pkts.load() - p0;
        in_warmup = false;
    }
    uint64_t warmed = 0;

    ~tx_session_impl() override
    {
        stop.store(true);
        if (launched) {
            // it exits once the ring is empty; give queued packets a moment
            const auto dl = clk::now() + std::chrono::seconds(2);
            while (rte_eal_get_lcore_state(p->tx_core) == RUNNING and clk::now() < dl)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            abort.store(true);
            rte_eal_wait_lcore(p->tx_core);
        }
        size_t left = 0;
        if (ring) {
            void* obj;
            while (rte_ring_sc_dequeue(ring, &obj) == 0) {
                rte_pktmbuf_free(static_cast<rte_mbuf*>(obj));
                left++;
            }
            rte_ring_free(ring);
        }
        for (auto* m : slots)
            if (m)
                rte_pktmbuf_free(m);
        if (active) {
            std::lock_guard<std::mutex> l(G().m);
            if (sflow) {
                rte_flow_error err{};
                if (rte_flow_destroy(p->id, sflow, &err) != 0)
                    ZLOG_WARN("DPDK: rte_flow_destroy (TX status): " << flow_err(err));
                // drop what is still in the status queue
                rte_mbuf* mb[kStatusBurst];
                uint16_t k;
                while ((k = rte_eth_rx_burst(p->id, squeue, mb, kStatusBurst)) > 0)
                    rte_pktmbuf_free_bulk(mb, k);
            }
            G().ports[p->id].tx_active = false;
        }
        rte_eth_stats st{};
        rte_eth_stats_get(p->id, &st);
        ZLOG_INFO("DPDK TX closed: " << pkts.load() << " pkts sent, " << stalls.load()
                                     << " NIC-full retries" << (left ? ", " : "")
                                     << (left ? std::to_string(left) + " dropped at close" : "")
                                     << "; " << status_pkts << " status pkts on queue " << squeue
                                     << (status_bad ? " (" + std::to_string(status_bad) + " foreign)" : "")
                                     << (warmed ? "; " + std::to_string(warmed) + " warm-up pkts to port 9" : "")
                                     << (prefills ? "; " + std::to_string(prefills) + " untimed-burst prefill(s), "
                                                        + std::to_string(prefill_timeouts) + " released by timeout"
                                                  : "")
                                     << "; port: " << st.opackets - st0.opackets << " opackets, "
                                     << st.oerrors - st0.oerrors << " oerrors");
    }
};

//! the TX lcore: the TX ring -> the NIC, and the status queue -> the sink.
//! It never sleeps while packets or status flow; after 50 ms of neither it
//! naps 20 us per round.
int tx_main(void* arg)
{
    auto* s            = static_cast<tx_session_impl*>(arg);
    const uint16_t pid = s->p->id;
    rte_mbuf* mb[kTxBurst];
    rte_mbuf* rb[kStatusBurst];
    const uint64_t hz     = rte_get_tsc_hz();
    const uint64_t idle_t = hz / 20;
    uint64_t last_active  = rte_get_tsc_cycles();
    // in order to the NIC; retries while it is full
    auto xmit = [&](rte_mbuf** v, unsigned n) {
        unsigned sent = 0;
        while (sent < n) {
            sent += rte_eth_tx_burst(pid, 0, v + sent, uint16_t(n - sent));
            if (sent < n) {
                if (s->abort.load(std::memory_order_relaxed)) {
                    rte_pktmbuf_free_bulk(v + sent, n - sent);
                    break;
                }
                s->stalls.fetch_add(1, std::memory_order_relaxed);
                rte_pause();
            }
        }
        s->pkts.fetch_add(sent, std::memory_order_relaxed);
    };
    // untimed-burst prefill: packets held from a marked one on
    rte_mbuf* held[kMaxPrefill];
    unsigned nheld        = 0;
    bool holding          = false;
    uint64_t hold_end     = 0;
    size_t prefill        = 0; // packets the current hold waits for (set when it starts)
    while (true) {
        bool any = false;
        if (s->sink) {
            const uint16_t k = rte_eth_rx_burst(pid, s->squeue, rb, kStatusBurst);
            for (uint16_t i = 0; i < k; i++) {
                const uint8_t* pay = nullptr;
                uint32_t plen      = 0;
                if (parse_frame(rb[i], s->sip_be, s->sport, 1, 0, pay, plen) == FRAME_OK) {
                    s->sink->on_status(pay, plen);
                    s->status_pkts++;
                } else {
                    s->status_bad++;
                }
            }
            if (k) {
                rte_pktmbuf_free_bulk(rb, k);
                any = true;
            }
        }
        const unsigned n =
            rte_ring_sc_dequeue_burst(s->ring, reinterpret_cast<void**>(mb), kTxBurst, nullptr);
        if (n) {
            any        = true;
            unsigned i = 0;
            if (not holding)
                prefill = s->prefill_pkts.load(std::memory_order_relaxed);
            if (not holding and prefill) {
                while (i < n and mb[i]->hash.usr != kHoldMark)
                    i++;
                if (i)
                    xmit(mb, i);
                if (i < n) {
                    holding  = true;
                    hold_end = rte_get_tsc_cycles() + s->prefill_tsc.load(std::memory_order_relaxed);
                    s->prefills++;
                }
            }
            if (holding) {
                for (; i < n; i++) {
                    if (nheld == kMaxPrefill) {
                        xmit(held, nheld);
                        nheld = 0;
                    }
                    held[nheld++] = mb[i];
                }
            } else if (i < n) {
                xmit(mb + i, n - i);
            }
        }
        if (holding) {
            const bool timeout = rte_get_tsc_cycles() >= hold_end;
            if (nheld >= prefill or timeout or s->stop.load(std::memory_order_relaxed)
                or s->abort.load(std::memory_order_relaxed)) {
                if (timeout and nheld < prefill)
                    s->prefill_timeouts++;
                xmit(held, nheld);
                nheld   = 0;
                holding = false;
            }
            any = true;
        }
        if (any) {
            last_active = rte_get_tsc_cycles();
            continue;
        }
        if (s->stop.load(std::memory_order_relaxed))
            break;
        if (rte_get_tsc_cycles() - last_active > idle_t)
            std::this_thread::sleep_for(std::chrono::microseconds(20));
        else
            rte_pause();
    }
    return 0;
}

} // namespace

std::unique_ptr<tx_session> start_tx(const port_sptr& p,
    const tx_endpoint& ep,
    size_t nslots,
    size_t max_payload,
    tx_status_sink* status)
{
    if (not p)
        throw uhd::runtime_error("ZCU216: DPDK port not open");
    if (kEthIpUdp + max_payload + RTE_PKTMBUF_HEADROOM > kMbufRoom)
        throw uhd::value_error("ZCU216: DPDK TX payload too large");
    auto s         = std::make_unique<tx_session_impl>();
    s->p           = p;
    s->max_payload = max_payload;
    s->slots.assign(nslots, nullptr);
    s->set_prefill(ep.prefill_pkts, ep.prefill_us);
    // header template
    uint8_t dmac[6];
    if (not parse_mac(ep.dst_mac, dmac))
        throw uhd::value_error("ZCU216: bad FPGA MAC '" + ep.dst_mac + "'");
    in_addr sa{}, da{};
    if (inet_pton(AF_INET, ep.src_ip.c_str(), &sa) != 1 or inet_pton(AF_INET, ep.dst_ip.c_str(), &da) != 1)
        throw uhd::value_error("ZCU216: bad TX IP " + ep.src_ip + " -> " + ep.dst_ip);
    std::memset(s->hdr, 0, sizeof(s->hdr));
    auto* eth = reinterpret_cast<rte_ether_hdr*>(s->hdr);
    std::memcpy(&eth->dst_addr, dmac, 6);
    eth->src_addr   = p->mac;
    eth->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);
    auto* ip            = reinterpret_cast<rte_ipv4_hdr*>(s->hdr + 14);
    ip->version_ihl     = 0x45;
    ip->fragment_offset = rte_cpu_to_be_16(0x4000); // DF
    ip->time_to_live    = 64;
    ip->next_proto_id   = IPPROTO_UDP;
    ip->src_addr        = sa.s_addr;
    ip->dst_addr        = da.s_addr;
    auto* udp           = reinterpret_cast<rte_udp_hdr*>(s->hdr + 34);
    udp->src_port       = rte_cpu_to_be_16(ep.src_port);
    udp->dst_port       = rte_cpu_to_be_16(ep.dst_port);
    udp->dgram_cksum    = 0; // PROTOCOL §4/§6: UDP checksum 0

    {
        std::lock_guard<std::mutex> l(G().m);
        port_state& ps = G().ports[p->id];
        if (ps.tx_active)
            throw uhd::runtime_error("ZCU216: a DPDK TX session is already active on " + p->name);
        p->ensure_started(1);
        ps.tx_active = true;
        s->active    = true;
        s->pool      = ps.tx_pool;
        rte_eth_stats_get(p->id, &s->st0);
        const std::string rn = "zcu_txr" + std::to_string(p->id) + "_" + std::to_string(G().seq++);
        s->ring = rte_ring_create(rn.c_str(), kTxRingSize, p->sock_id, RING_F_SP_ENQ | RING_F_SC_DEQ);
        if (not s->ring)
            throw uhd::runtime_error("ZCU216: rte_ring_create: " + rte_err(rte_errno));
        if (status and ep.status_port) {
            s->squeue = ps.nq_rx; // the queue after the sample queues
            s->sport  = ep.status_port;
            s->sip_be = sa.s_addr;
            std::string why;
            s->sflow = make_rx_flow(p->id, s->sip_be, s->sport, s->squeue, why);
            if (not s->sflow)
                throw uhd::runtime_error("ZCU216: DPDK flow (TX status) " + ep.src_ip + ":"
                                         + std::to_string(s->sport) + " -> queue "
                                         + std::to_string(s->squeue) + ": " + why);
            s->sink = status;
        }
    }
    if (rte_eal_get_lcore_state(p->tx_core) != WAIT)
        throw uhd::runtime_error("ZCU216: DPDK TX lcore " + std::to_string(p->tx_core) + " is busy");
    const int rc = rte_eal_remote_launch(tx_main, s.get(), p->tx_core);
    if (rc != 0)
        throw uhd::runtime_error("ZCU216: rte_eal_remote_launch(TX lcore "
                                 + std::to_string(p->tx_core) + "): " + rte_err(rc));
    s->launched = true;
    if (ep.warmup_pkts)
        s->warmup(ep.warmup_pkts);
    ZLOG_INFO("DPDK TX: " << ep.src_ip << ":" << ep.src_port << " (" << mac_str(p->mac) << ") -> "
                          << ep.dst_ip << ":" << ep.dst_port << " (" << ep.dst_mac << "), lcore "
                          << p->tx_core
                          << (s->sink ? ", TX status " + ep.src_ip + ":" + std::to_string(s->sport)
                                            + " -> queue " + std::to_string(s->squeue)
                                            + " (polled by the TX lcore)"
                                      : std::string()));
    return s;
}

} // namespace dpdk
} // namespace zcu216
