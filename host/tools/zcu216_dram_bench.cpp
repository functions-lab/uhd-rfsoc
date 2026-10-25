//
// zcu216_dram_bench -- can the host keep up with the 100GbE link out of DRAM?
//
// zcu216_kernel_bench measures the conversion kernels on a cache-resident
// 512 KB payload; at 10-12 GB/s per direction the limit is DRAM bandwidth
// instead, shared with the NIC's own DMA. This bench runs the module's real
// kernels (zcu216_kernels) and worker pool (zcu216_pool) the way recv() and
// send() do, against a packet ring much larger than L3, while a "NIC" thread
// streams the DMA traffic (writes the ring for RX, reads it for TX) at a set
// rate. Host and NIC are coupled through the ring as on the real link: RX,
// the host converts only what the NIC has written, and a NIC more than a ring
// ahead of the host is an overflow; TX, the host fills at most a ring ahead of
// the NIC, and a NIC that finds nothing to send is an underrun. Sustained =
// host and NIC at the target rate with no overflow / underrun.
//
//   zcu216_dram_bench --dir rx|tx|duplex [--n 16] [--otw sc16] [--cpu sc16|fc32]
//       [--workers 1,3,5] [--main 2] [--nic 0[,6]] [--nic-gbps 12] [--spb 32]
//       [--app-mb 0] [--ring-mb 512] [--tx-ring-mb (duplex TX; default --ring-mb)] [--secs 3]
//   duplex: the TX side uses --tx-workers / --tx-main / --tx-nic (CPUs).
//   CPUs: by default nothing is pinned (3 RX workers, 2 TX workers, one NIC
//   thread per side). Pin every thread to its own physical core for numbers
//   that mean something, e.g. on a 6-core / 12-thread host --workers 1,3,5
//   --main 2 --nic 0 (duplex: --tx-workers 7,9 --tx-main 4 --tx-nic 6).
//   --app-mb 0: the application buffers are reused (cache-resident, like
//   benchmark_rate); > 0: they walk through a region of that size (an
//   application that keeps the samples).
//
#include "zcu216_kernels.hpp"
#include "zcu216_pool.hpp"
#include <immintrin.h>
#include <pthread.h>
#include <sched.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace zcu216;
using clk = std::chrono::steady_clock;

namespace {

double secs_since(clk::time_point t0)
{
    return std::chrono::duration<double>(clk::now() - t0).count();
}

void pin(int cpu)
{
    if (cpu < 0)
        return;
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu, &s);
    pthread_setaffinity_np(pthread_self(), sizeof(s), &s);
}

std::vector<int> cpu_list(const std::string& s)
{
    std::vector<int> v;
    size_t i = 0;
    while (i < s.size()) {
        size_t j = s.find(',', i);
        if (j == std::string::npos)
            j = s.size();
        if (j > i)
            v.push_back(std::atoi(s.substr(i, j - i).c_str()));
        i = j + 1;
    }
    return v;
}

uint8_t* big_alloc(size_t bytes)
{
    void* p = nullptr;
    if (posix_memalign(&p, 2 << 20, bytes))
        std::abort();
    std::memset(p, 0x11, bytes); // fault every page in
    return static_cast<uint8_t*>(p);
}

struct opts
{
    std::string dir = "rx", otw = "sc16", cpu = "sc16";
    size_t n = 16, spb = 32, ring_mb = 512, tx_ring_mb = 0, app_mb = 0;
    double nic_gbps = 12.0, secs = 3.0;
    // -1 = not pinned (see the usage above)
    std::vector<int> workers{-1, -1, -1}, tx_workers{-1, -1};
    int main_cpu = -1, tx_main = -1;
    std::vector<int> nic_cpus{-1}, tx_nic_cpus{-1};
};

// the NIC: streams DMA traffic over the ring at `gbps` (0 = as fast as it can),
// coupled to the host's progress `host` (bytes) through the ring. One CPU
// thread reads only ~9 GB/s out of DRAM (a DMA engine has no such limit), so
// the NIC is T threads striping the ring in 64 KB chunks (thread i takes
// chunks i, i+T, ...); its progress is the slowest stripe's.
struct nic_thread
{
    std::atomic<bool> stop{false}, go{false};
    std::atomic<uint64_t> events{0}; // overflows (RX) / underruns (TX)
    std::vector<std::atomic<uint64_t>> next; // per stripe: next chunk index
    std::vector<std::thread> th;
    static constexpr size_t CH = 64 << 10;

    uint64_t bytes() const // contiguous bytes done
    {
        uint64_t m = UINT64_MAX;
        for (const auto& n : next)
            m = std::min<uint64_t>(m, n.load(std::memory_order_acquire));
        // stripe i has done chunks i, i+T, ... below next[i]: all chunks
        // below min(next) are done
        return m * CH;
    }

    void start(uint8_t* ring, size_t ring_bytes, bool write, double gbps, const std::vector<int>& cpus,
        const std::atomic<uint64_t>* host)
    {
        const size_t T = std::max<size_t>(1, cpus.size());
        next = std::vector<std::atomic<uint64_t>>(T);
        for (size_t i = 0; i < T; i++)
            next[i] = i;
        const size_t nch = ring_bytes / CH; // whole chunks only
        for (size_t i = 0; i < T; i++) {
            th.emplace_back([=] {
                pin(cpus.empty() ? -1 : cpus[i]);
                __m256i acc     = _mm256_setzero_si256();
                const __m256i v = _mm256_set1_epi32(0x01020304);
                while (not go.load())
                    ;
                while (not write and host->load() < ring_bytes / 2 and not stop.load())
                    ;
                const auto t0 = clk::now();
                bool starved  = false;
                uint64_t k    = i, mine = 0;
                while (not stop.load(std::memory_order_relaxed)) {
                    if (gbps > 0 and mine * CH > secs_since(t0) * gbps / T * 1e9) {
                        _mm_pause();
                        continue;
                    }
                    const uint64_t end = (k + 1) * CH;
                    const uint64_t h   = host->load(std::memory_order_acquire);
                    if (write) {
                        if (end > h + nch * CH) // the host is a ring behind: overwrite
                            events.fetch_add(1, std::memory_order_relaxed);
                    } else if (end > h) { // nothing to send
                        if (not starved)
                            events.fetch_add(1, std::memory_order_relaxed);
                        starved = true;
                        _mm_pause();
                        continue;
                    }
                    starved = false;
                    auto* p = reinterpret_cast<__m256i*>(ring + (k % nch) * CH);
                    if (write) { // DMA write: non-temporal, no read-for-ownership
                        for (size_t q = 0; q < CH / 32; q++)
                            _mm256_stream_si256(p + q, v);
                        _mm_sfence();
                    } else {
                        for (size_t q = 0; q < CH / 32; q++)
                            acc = _mm256_xor_si256(acc, _mm256_stream_load_si256(p + q));
                    }
                    k += T;
                    mine++;
                    next[i].store(k, std::memory_order_release);
                }
                volatile int sink = _mm256_extract_epi32(acc, 0);
                (void)sink;
            });
        }
    }
    void finish()
    {
        stop = true;
        for (auto& t : th)
            t.join();
    }
};

// recv()/send() on the ring: each call converts spb packets, split over the
// pool + the calling thread, packet ranges per task (as the module does)
struct side
{
    bool rx;
    size_t N, spb, spp, slot, pay_bytes, S; // S = samples per channel per packet
    uint8_t* ring;
    size_t ring_pkts;
    std::vector<uint8_t*> app; // per channel, app region
    size_t app_samps;           // samples per channel in the app region
    size_t cpb;
    rx_kernel* rk = nullptr;
    tx_kernel* tk = nullptr;
    // per call
    size_t pkt0, app0;
    size_t ntasks;
    std::vector<void*> outs;
    std::vector<const void*> ins;
};

void task(void* c, size_t t)
{
    auto* x          = static_cast<side*>(c);
    const size_t per = (x->spb + x->ntasks - 1) / x->ntasks;
    const size_t a = t * per, b = std::min(x->spb, a + per);
    for (size_t p = a; p < b; p++) {
        uint8_t* pkt = x->ring + ((x->pkt0 + p) % x->ring_pkts) * x->pay_bytes;
        if (x->rx)
            (*x->rk)(pkt, 0, x->S, x->outs.data(), x->app0 + p * x->S);
        else
            (*x->tk)(x->ins.data(), x->app0 + p * x->S, x->S, pkt, 0);
    }
}

struct result
{
    double wire_gbps, nic_gbps;
    uint64_t events;
};

result run_side(const opts& o, bool rx, worker_pool& pool, int main_cpu, nic_thread& nic,
    std::atomic<bool>* go, std::atomic<bool>* stop_flag)
{
    pin(main_cpu);
    const otw_t ow = o.otw == "sc8" ? otw_t::sc8 : o.otw == "sc12" ? otw_t::sc12 : otw_t::sc16;
    const cpu_t cp = o.cpu == "fc32" ? cpu_t::fc32 : cpu_t::sc16;
    side s;
    s.rx   = rx;
    s.N    = o.n;
    s.spb  = o.spb;
    s.slot = ow == otw_t::sc16 ? 4 : ow == otw_t::sc8 ? 2 : 3;
    s.pay_bytes = 8192; // the daemon caps a payload at 8192 bytes
    if (ow == otw_t::sc12)
        s.pay_bytes = 8064;
    s.spp       = s.pay_bytes / s.slot;
    s.S         = s.spp / s.N;
    s.ring_pkts = ((not rx and o.tx_ring_mb ? o.tx_ring_mb : o.ring_mb) << 20) / s.pay_bytes;
    s.ring      = big_alloc(s.ring_pkts * s.pay_bytes);
    s.cpb       = cpu_bytes(cp);
    const size_t call_samps = s.spb * s.S;
    s.app_samps = o.app_mb ? std::max(call_samps, ((o.app_mb << 20) / s.N / s.cpb) / call_samps * call_samps)
                           : call_samps;
    std::vector<size_t> chans(s.N);
    for (size_t i = 0; i < s.N; i++)
        chans[i] = i;
    rx_kernel rk(ow, cp, s.N, chans, true);
    tx_kernel tk(cp, ow, s.N, chans, true);
    s.rk = &rk;
    s.tk = &tk;
    for (size_t j = 0; j < s.N; j++)
        s.app.push_back(big_alloc(s.app_samps * s.cpb));
    s.outs.resize(s.N);
    s.ins.resize(s.N);
    s.ntasks = pool.workers() + 1;
    const size_t ring_bytes = s.ring_pkts * s.pay_bytes, call_bytes = s.spb * s.pay_bytes;
    std::atomic<uint64_t> host{0};
    nic.start(s.ring, ring_bytes, rx, o.nic_gbps, rx ? o.nic_cpus : o.tx_nic_cpus, &host);
    while (go and not go->load())
        ;
    nic.go = true;
    size_t calls = 0, pkt = 0, app = 0;
    uint64_t hb = 0;
    const auto t0 = clk::now();
    auto running = [&] {
        return stop_flag ? not stop_flag->load(std::memory_order_relaxed) : secs_since(t0) < o.secs;
    };
    while (running()) {
        // RX: wait until the NIC has written this call's packets; TX: until
        // the ring has room for them
        if (rx ? nic.bytes() < hb + call_bytes : hb + call_bytes > nic.bytes() + ring_bytes - 2 * nic.CH) {
            _mm_pause();
            continue;
        }
        s.pkt0 = pkt;
        s.app0 = 0;
        for (size_t j = 0; j < s.N; j++) {
            s.outs[j] = s.app[j] + app * s.cpb;
            s.ins[j]  = s.app[j] + app * s.cpb;
        }
        pool.run(s.ntasks, task, &s);
        pkt = (pkt + s.spb) % s.ring_pkts;
        app = (app + call_samps) % s.app_samps;
        calls++;
        hb += call_bytes;
        host.store(hb, std::memory_order_release);
    }
    const double t   = secs_since(t0);
    const uint64_t nb = nic.bytes();
    nic.finish();
    result r{hb / t / 1e9, nb / t / 1e9, nic.events.load()};
    free(s.ring);
    for (auto* p : s.app)
        free(p);
    return r;
}

} // namespace

int main(int argc, char** argv)
{
    opts o;
    for (int i = 1; i + 1 < argc; i += 2) {
        const std::string k = argv[i], v = argv[i + 1];
        if (k == "--dir") o.dir = v;
        else if (k == "--n") o.n = std::stoul(v);
        else if (k == "--otw") o.otw = v;
        else if (k == "--cpu") o.cpu = v;
        else if (k == "--workers") o.workers = cpu_list(v);
        else if (k == "--tx-workers") o.tx_workers = cpu_list(v);
        else if (k == "--main") o.main_cpu = std::stoi(v);
        else if (k == "--tx-main") o.tx_main = std::stoi(v);
        else if (k == "--nic") o.nic_cpus = cpu_list(v);
        else if (k == "--tx-nic") o.tx_nic_cpus = cpu_list(v);
        else if (k == "--nic-gbps") o.nic_gbps = std::stod(v);
        else if (k == "--spb") o.spb = std::stoul(v);
        else if (k == "--app-mb") o.app_mb = std::stoul(v);
        else if (k == "--ring-mb") o.ring_mb = std::stoul(v);
        else if (k == "--tx-ring-mb") o.tx_ring_mb = std::stoul(v);
        else if (k == "--secs") o.secs = std::stod(v);
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); return 2; }
    }
    auto wdesc = [](const std::vector<int>& w) {
        std::string s;
        for (int c : w)
            s += (s.empty() ? "" : ",") + std::to_string(c);
        return s.empty() ? std::string("none") : s;
    };
    if (o.dir != "duplex") {
        const bool rx = o.dir == "rx";
        worker_pool pool(rx ? o.workers : o.workers, 200.0);
        nic_thread nic;
        const result r = run_side(o, rx, pool, o.main_cpu, nic, nullptr, nullptr);
        std::printf("%s N=%zu %s<->%s workers [%s] + main %d, nic target %.1f GB/s: host %.2f GB/s (%.1f Gb/s), nic %.2f GB/s, %s %llu\n",
            o.dir.c_str(), o.n, o.otw.c_str(), o.cpu.c_str(), wdesc(o.workers).c_str(), o.main_cpu,
            o.nic_gbps, r.wire_gbps, r.wire_gbps * 8, r.nic_gbps, rx ? "overflows" : "underruns",
            (unsigned long long)r.events);
        return 0;
    }
    worker_pool prx(o.workers, 200.0), ptx(o.tx_workers, 200.0);
    nic_thread nrx, ntx;
    std::atomic<bool> go{false}, stop{false};
    result rr{}, rt{};
    std::thread trx([&] { rr = run_side(o, true, prx, o.main_cpu, nrx, &go, &stop); });
    std::thread ttx([&] { rt = run_side(o, false, ptx, o.tx_main, ntx, &go, &stop); });
    std::this_thread::sleep_for(std::chrono::milliseconds(1500)); // allocation
    go = true;
    std::this_thread::sleep_for(std::chrono::duration<double>(o.secs));
    stop = true;
    trx.join();
    ttx.join();
    std::printf("duplex N=%zu %s<->%s, nic target %.1f GB/s each: RX workers [%s]+main %d: host %.2f GB/s (%.1f Gb/s), "
                "nic %.2f, overflows %llu | TX workers [%s]+main %d: host %.2f GB/s (%.1f Gb/s), nic %.2f, underruns %llu\n",
        o.n, o.otw.c_str(), o.cpu.c_str(), o.nic_gbps, wdesc(o.workers).c_str(), o.main_cpu, rr.wire_gbps,
        rr.wire_gbps * 8, rr.nic_gbps, (unsigned long long)rr.events, wdesc(o.tx_workers).c_str(), o.tx_main,
        rt.wire_gbps, rt.wire_gbps * 8, rt.nic_gbps, (unsigned long long)rt.events);
    return 0;
}
