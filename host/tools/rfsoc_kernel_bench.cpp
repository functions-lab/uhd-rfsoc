//
// rfsoc_kernel_bench -- throughput of the uhd_rfsoc sample kernels, the
// per-sample work of recv() / send(): the fused channel (de-)interleave and
// format conversion, SIMD (AVX-512 / NEON) against scalar against UHD 4.6's own converter, one
// thread on a cache-resident 512 KB payload (64 packets of 2048 sc16 slots,
// packet by packet like recv()), and the worker pool on a 64-packet call.
// GS/s of wire slots. No device, no root.
//
//   rfsoc_kernel_bench [--cpu C]     # --cpu: the single-thread rows pinned to
//                                     # CPU C (one the module's lcores do not
//                                     # use); the pool rows keep the original
//                                     # affinity (unpinned workers)
//   rfsoc_kernel_bench --pool-cpus 2,3,4,5   # pool workers pinned like the module's
//   rfsoc_kernel_bench --sweep [--secs S]    # RX sc16 -> fc32 and TX fc32 -> sc16 only,
//                                             # N = 1, 2, 4, 8, 16, each row timed for S s
//                                             # (default 0.3)
//
// What the host can convert at all; rfsoc_dram_bench then measures the same
// kernels against DRAM with the NIC's DMA traffic, where a 100GbE stream
// usually hits its limit first.
//
#include "rfsoc_kernels.hpp"
#include "rfsoc_pool.hpp"
#include <uhd/convert.hpp>
#include <uhd/exception.hpp>
#include <pthread.h>
#include <sched.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <random>
#include <string>
#include <thread>
#include <vector>

using namespace rfsoc;

namespace {

std::mt19937_64 rng(0x5A16D00D);
cpu_set_t g_all_cpus; // the affinity before --cpu: the pool rows run with it
std::vector<int> g_pool_cpus; // --pool-cpus: pin pool workers like the module does
double g_secs = 0.3;          // --secs: how long each row repeats its conversion
bool g_sweep  = false;        // --sweep: sc16 <-> fc32 only, every N

const char* otw_name(otw_t o)
{
    switch (o) {
        case otw_t::sc16:
            return "sc16";
        case otw_t::sc8:
            return "sc8";
        case otw_t::sc12:
            return "sc12";
        case otw_t::fc32:
            return "fc32";
    }
    return "?";
}
size_t slot_bytes(otw_t o)
{
    return o == otw_t::sc16 ? 4 : o == otw_t::sc8 ? 2 : o == otw_t::sc12 ? 3 : 8;
}

//! 64-byte aligned byte buffer
struct abuf
{
    std::vector<uint8_t> v;
    uint8_t* p = nullptr;
    explicit abuf(size_t n = 0, uint8_t fill = 0) : v(n + 128, fill)
    {
        p = v.data() + ((64 - (uintptr_t(v.data()) & 63)) & 63);
    }
};

//! run a UHD converter (best priority) over n items; false if UHD has none
bool uhd_conv(const std::string& in, const std::string& out, double scalar, const void* src,
    void* dst, size_t n)
{
    uhd::convert::id_type id;
    id.input_format  = in;
    id.num_inputs    = 1;
    id.output_format = out;
    id.num_outputs   = 1;
    uhd::convert::converter::sptr c;
    try {
        c = uhd::convert::get_converter(id)();
    } catch (const uhd::exception&) {
        return false;
    }
    c->set_scalar(scalar);
    const uhd::convert::converter::input_type iv(src);
    const uhd::convert::converter::output_type ov(dst);
    c->conv(iv, ov, n);
    return true;
}

// ---- random payloads with extremes --------------------------------------------
void fill_int16(int16_t* v, size_t n)
{
    static const int16_t ex[] = {-32768, 32767, 0, -1, 1, -32767, 16384, -16384, 127, -128, 2047, -2048};
    for (size_t i = 0; i < n; i++)
        v[i] = (rng() % 8 == 0) ? ex[rng() % (sizeof(ex) / sizeof(ex[0]))] : int16_t(rng());
}
void fill_floats(float* f, size_t n, bool specials)
{
    std::uniform_real_distribution<float> u(-1.25f, 1.25f);
    for (size_t i = 0; i < n; i++) {
        const unsigned k = unsigned(rng() % 16);
        if (k == 0) // a rounding tie of x * 32767 or x * 128
            f[i] = (float(int(rng() % 65536) - 32768) + 0.5f) / ((rng() & 1) ? 32767.0f : 128.0f);
        else if (k == 1)
            f[i] = (rng() & 1) ? 1.0f : -1.0f;
        else if (k == 2 and specials) {
            const float sp[] = {std::numeric_limits<float>::quiet_NaN(), INFINITY, -INFINITY, 1e10f,
                -1e10f, 70000.0f, -70000.0f, 65536.5f, 0.0f, -0.0f};
            f[i] = sp[rng() % (sizeof(sp) / sizeof(sp[0]))];
        } else
            f[i] = u(rng);
    }
}

void rx_random_payload(otw_t otw, uint8_t* pay, size_t P)
{
    const size_t bytes = otw == otw_t::sc12 ? P / 4 * 12 : P * slot_bytes(otw);
    if (otw == otw_t::sc16) {
        fill_int16(reinterpret_cast<int16_t*>(pay), 2 * P);
    } else if (otw == otw_t::fc32) {
        // what the FPGA sends (int16 / 32768), plus anything else a float can be
        std::vector<int16_t> v(2 * P);
        fill_int16(v.data(), v.size());
        std::vector<float> f(2 * P);
        fill_floats(f.data(), f.size(), true);
        for (size_t i = 0; i < 2 * P; i++) {
            const float x = (rng() % 2) ? float(v[i]) / 32768.0f : f[i];
            std::memcpy(pay + 4 * i, &x, 4);
        }
    } else {
        for (size_t i = 0; i < bytes; i++)
            pay[i] = uint8_t(rng());
        if (otw == otw_t::sc8)
            for (size_t i = 0; i < bytes; i += 7)
                pay[i] = (rng() & 1) ? 0x80 : 0x7f; // -128 / 127
    }
}

void tx_random_input(cpu_t cpu, uint8_t* in, size_t n)
{
    switch (cpu) {
        case cpu_t::sc16:
            fill_int16(reinterpret_cast<int16_t*>(in), 2 * n);
            break;
        case cpu_t::sc8:
            for (size_t i = 0; i < 2 * n; i++)
                in[i] = uint8_t(rng());
            break;
        case cpu_t::fc32:
            fill_floats(reinterpret_cast<float*>(in), 2 * n, true);
            break;
        case cpu_t::fc64: {
            std::vector<float> f(2 * n);
            fill_floats(f.data(), f.size(), true);
            for (size_t i = 0; i < 2 * n; i++) {
                const double d = (rng() % 3) ? double(f[i]) : double(f[i]) + 1e-9 * double(int(rng() % 1000) - 500);
                std::memcpy(in + 8 * i, &d, 8);
            }
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// throughput
// ---------------------------------------------------------------------------
double secs_since(std::chrono::steady_clock::time_point t0)
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

void bench()
{
    std::printf("\nthroughput, GS/s of wire slots (one thread unless noted; SIMD %s %s)\n", simd_name(),
        cpu_has_simd() ? "available" : "NOT available");
    const size_t PKT = 2048; // sc16 slots per packet
    const size_t NP  = 64;   // packets per call: 512 KB of sc16 payload
    struct rxcase
    {
        otw_t otw;
        cpu_t cpu;
        size_t N;
        const char* uhd_in;
    };
    std::vector<rxcase> rcs = {{otw_t::sc16, cpu_t::fc32, 1, "sc16_chdr"}, {otw_t::sc16, cpu_t::sc16, 4, nullptr},
        {otw_t::sc16, cpu_t::fc32, 4, nullptr}, {otw_t::sc16, cpu_t::fc32, 8, nullptr},
        {otw_t::sc16, cpu_t::fc32, 16, nullptr}, {otw_t::sc8, cpu_t::fc32, 8, nullptr},
        {otw_t::sc8, cpu_t::sc16, 8, nullptr}, {otw_t::sc8, cpu_t::sc8, 8, nullptr},
        {otw_t::sc12, cpu_t::fc32, 4, nullptr}};
    if (g_sweep) {
        rcs.clear();
        for (const size_t n : {1, 2, 4, 8, 16})
            rcs.push_back({otw_t::sc16, cpu_t::fc32, n, nullptr});
    }
    for (const auto& c : rcs) {
        const size_t slots = PKT * NP, S = slots / c.N;
        abuf pay(slots * 8);
        rx_random_payload(c.otw, pay.p, slots);
        std::vector<size_t> chans(c.N);
        for (size_t i = 0; i < c.N; i++)
            chans[i] = i;
        std::vector<abuf> outs;
        std::vector<void*> op;
        for (size_t j = 0; j < c.N; j++) {
            outs.emplace_back(S * cpu_bytes(c.cpu));
            op.push_back(outs.back().p);
        }
        std::printf("  RX %-4s -> %-4s N=%-2zu:", otw_name(c.otw), cpu_name(c.cpu), c.N);
        for (const bool simd : {true, false}) {
            rx_kernel k(c.otw, c.cpu, c.N, chans, simd);
            if (simd and not k.simd())
                continue;
            const auto t0 = std::chrono::steady_clock::now();
            int reps      = 0;
            while (secs_since(t0) < g_secs) {
                for (size_t p = 0; p < NP; p++) // packet by packet, like recv()
                    k(pay.p + p * (slots / NP) * (c.otw == otw_t::sc12 ? 3 : slot_bytes(c.otw)), 0, S / NP,
                        op.data(), p * (S / NP));
                reps++;
            }
            std::printf("  %s %6.2f", simd ? "SIMD" : "scalar", reps * double(slots) / secs_since(t0) / 1e9);
        }
        if (c.uhd_in and c.N == 1 and not g_sweep) {
            const auto t0 = std::chrono::steady_clock::now();
            int reps      = 0;
            while (secs_since(t0) < g_secs) {
                uhd_conv(c.uhd_in, cpu_name(c.cpu), 1.0 / 32767.0, pay.p, outs[0].p, slots);
                reps++;
            }
            std::printf("  UHD %6.2f", reps * double(slots) / secs_since(t0) / 1e9);
        }
        std::printf("\n");
    }
    struct txcase
    {
        cpu_t cpu;
        otw_t otw;
        size_t N;
    };
    std::vector<txcase> tcs = {{cpu_t::fc32, otw_t::sc16, 1}, {cpu_t::sc16, otw_t::sc16, 4},
        {cpu_t::fc32, otw_t::sc16, 4}, {cpu_t::fc32, otw_t::sc16, 16}, {cpu_t::fc32, otw_t::sc12, 4},
        {cpu_t::fc32, otw_t::sc8, 4}, {cpu_t::sc8, otw_t::sc8, 8}};
    if (g_sweep) {
        tcs.clear();
        for (const size_t n : {1, 2, 4, 8, 16})
            tcs.push_back({cpu_t::fc32, otw_t::sc16, n});
    }
    for (const auto& c : tcs) {
        const size_t slots = PKT * NP, S = slots / c.N;
        std::vector<size_t> chans(c.N);
        for (size_t i = 0; i < c.N; i++)
            chans[i] = i;
        std::vector<abuf> ins;
        std::vector<const void*> ip;
        for (size_t j = 0; j < c.N; j++) {
            ins.emplace_back(S * cpu_bytes(c.cpu));
            tx_random_input(c.cpu, ins.back().p, S);
            ip.push_back(ins.back().p);
        }
        abuf pay(slots * 8);
        std::printf("  TX %-4s -> %-4s N=%-2zu:", cpu_name(c.cpu), otw_name(c.otw), c.N);
        for (const bool simd : {true, false}) {
            tx_kernel k(c.cpu, c.otw, c.N, chans, simd);
            if (simd and not k.simd())
                continue;
            const auto t0 = std::chrono::steady_clock::now();
            int reps      = 0;
            while (secs_since(t0) < g_secs) {
                k(ip.data(), 0, S, pay.p, 0);
                reps++;
            }
            std::printf("  %s %6.2f", simd ? "SIMD" : "scalar", reps * double(slots) / secs_since(t0) / 1e9);
        }
        if (c.N == 1 and c.cpu == cpu_t::fc32 and c.otw == otw_t::sc16 and not g_sweep) {
            const auto t0 = std::chrono::steady_clock::now();
            int reps      = 0;
            while (secs_since(t0) < g_secs) {
                uhd_conv("fc32", "sc16_chdr", 32767.0, ins[0].p, pay.p, S);
                reps++;
            }
            std::printf("  UHD %6.2f", reps * double(slots) / secs_since(t0) / 1e9);
        }
        std::printf("\n");
    }
    // the pool on a large RX request (64 packets, N = 8, sc16 -> fc32), with
    // the original affinity: workers inherit the caller's, and under --cpu
    // they would all share that one CPU
    if (g_sweep)
        return;
    pthread_setaffinity_np(pthread_self(), sizeof(g_all_cpus), &g_all_cpus);
    for (const size_t W : {0, 1, 2, 4}) {
        std::vector<int> cpus(W, -1);
        for (size_t i = 0; i < W and i < g_pool_cpus.size(); i++)
            cpus[i] = g_pool_cpus[i];
        worker_pool pool(cpus, 200.0);
        const size_t N = 8, slots = PKT * NP, S = slots / N;
        abuf pay(slots * 4);
        rx_random_payload(otw_t::sc16, pay.p, slots);
        std::vector<size_t> chans(N);
        for (size_t i = 0; i < N; i++)
            chans[i] = i;
        rx_kernel k(otw_t::sc16, cpu_t::fc32, N, chans, true);
        std::vector<abuf> outs;
        std::vector<void*> op;
        for (size_t j = 0; j < N; j++) {
            outs.emplace_back(S * 8);
            op.push_back(outs.back().p);
        }
        struct ctx_t
        {
            rx_kernel* k;
            const uint8_t* pay;
            void** op;
            size_t chunk, S;
        } ctx{&k, pay.p, op.data(), (S + W) / (W + 1), S};
        auto task = [](void* c, size_t t) {
            auto* x        = static_cast<ctx_t*>(c);
            const size_t a = t * x->chunk, n = std::min(x->S - a, x->chunk);
            (*x->k)(x->pay, a, n, x->op, a);
        };
        const auto t0 = std::chrono::steady_clock::now();
        int reps      = 0;
        while (secs_since(t0) < g_secs) {
            pool.run(W + 1, task, &ctx);
            reps++;
        }
        std::printf("  RX sc16 -> fc32 N=8, 64-packet call, pool of %zu + caller: %6.2f GS/s  (%s; %llu calls on "
                    "the workers, %llu by the caller alone)\n", W, reps * double(slots) / secs_since(t0) / 1e9,
            pool.desc().c_str(), (unsigned long long)pool.parallel_calls(), (unsigned long long)pool.inline_calls());
    }
}

} // namespace

int main(int argc, char** argv)
{
    pthread_getaffinity_np(pthread_self(), sizeof(g_all_cpus), &g_all_cpus);
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "--cpu" and i + 1 < argc) {
            const int c = std::atoi(argv[++i]);
            cpu_set_t s;
            CPU_ZERO(&s);
            CPU_SET(c, &s);
            if (pthread_setaffinity_np(pthread_self(), sizeof(s), &s) != 0) {
                std::fprintf(stderr, "cannot pin to CPU %d\n", c);
                return 2;
            }
            std::printf("pinned to CPU %d\n", c);
        } else if (a == "--pool-cpus" and i + 1 < argc) {
            const std::string l = argv[++i];
            for (size_t p0 = 0; p0 < l.size();) {
                const size_t p1 = l.find(',', p0);
                g_pool_cpus.push_back(std::atoi(l.substr(p0, p1 - p0).c_str()));
                p0 = p1 == std::string::npos ? l.size() : p1 + 1;
            }
        } else if (a == "--sweep") {
            g_sweep = true;
        } else if (a == "--secs" and i + 1 < argc) {
            g_secs = std::atof(argv[++i]);
            if (not(g_secs > 0)) {
                std::fprintf(stderr, "--secs must be > 0\n");
                return 2;
            }
        } else {
            std::fprintf(stderr, "usage: rfsoc_kernel_bench [--cpu C] [--pool-cpus a,b,c,d] [--sweep] [--secs S]\n");
            return 2;
        }
    }
    bench();
    return 0;
}
