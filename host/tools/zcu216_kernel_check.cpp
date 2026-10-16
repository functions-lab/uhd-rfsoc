//
// zcu216_kernel_check -- the SIMD sample kernels (SSE on x86, NEON through
// sse2neon on aarch64) against the scalar ones, bit for bit: every RX and TX
// format pair, N = 1, 2, 4, 8, 16, several channel subsets, unaligned starts
// and lengths, random data with the edge cases (-32768, rounding ties, NaN,
// +-inf, +-huge). Prints one line per direction and a digest of every output
// buffer: the same digest on two machines means the same bits (x86 vs arm).
// No device, no root. Exit status: the number of mismatching cases.
//
//   zcu216_kernel_check [--verbose]
//
#include "zcu216_kernels.hpp"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <random>
#include <string>
#include <vector>

using namespace zcu216;

namespace {

uint64_t fnv(uint64_t h, const uint8_t* p, size_t n)
{
    for (size_t i = 0; i < n; i++)
        h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

size_t wire_bytes(otw_t o, size_t slots) // a payload of `slots` slots, rounded up to sc12 groups
{
    switch (o) {
        case otw_t::sc16:
            return 4 * slots;
        case otw_t::sc8:
            return 2 * slots;
        case otw_t::sc12:
            return 12 * ((slots + 3) / 4);
        case otw_t::fc32:
            return 8 * slots;
    }
    return 0;
}

const char* otw_s(otw_t o)
{
    return o == otw_t::sc16 ? "sc16" : o == otw_t::sc8 ? "sc8" : o == otw_t::sc12 ? "sc12" : "fc32";
}

// random bytes for an integer wire / CPU buffer; floats with edge cases
void fill_int(std::vector<uint8_t>& b, std::mt19937& g)
{
    for (size_t i = 0; i + 1 < b.size(); i += 2) {
        const uint32_t r = g();
        int16_t v        = int16_t(r);
        switch (r >> 28) {
            case 0: v = -32768; break;
            case 1: v = 32767; break;
            case 2: v = int16_t(((r >> 8) & 0xFF) * 256 + 128); break; // sc8 rounding ties
            case 3: v = int16_t(((r >> 8) & 0xFFF) * 16 + 8); break;    // sc12 rounding ties
            default: break;
        }
        std::memcpy(&b[i], &v, 2);
    }
}
template <class F>
void fill_flt(std::vector<uint8_t>& b, std::mt19937& g)
{
    std::uniform_real_distribution<F> u(F(-1.1), F(1.1));
    for (size_t i = 0; i + sizeof(F) <= b.size(); i += sizeof(F)) {
        const uint32_t r = g();
        F v              = u(g);
        switch (r % 16) {
            case 0: v = std::numeric_limits<F>::quiet_NaN(); break;
            case 1: v = std::numeric_limits<F>::infinity(); break;
            case 2: v = -std::numeric_limits<F>::infinity(); break;
            case 3: v = F(1e12); break;
            case 4: v = F(-1e12); break;
            case 5: v = F((int(r >> 8) % 65536 - 32768) + 0.5) / F(32767); break; // ties after x 32767
            case 6: v = F((int(r >> 8) % 256 - 128) + 0.5) / F(128); break;        // ties after x 128
            case 7: v = F(1.0); break;
            case 8: v = F(-1.0); break;
            default: break;
        }
        std::memcpy(&b[i], &v, sizeof(F));
    }
}
void fill_cpu(cpu_t c, std::vector<uint8_t>& b, std::mt19937& g)
{
    if (c == cpu_t::fc32)
        fill_flt<float>(b, g);
    else if (c == cpu_t::fc64)
        fill_flt<double>(b, g);
    else if (c == cpu_t::sc16)
        fill_int(b, g);
    else
        for (auto& x : b)
            x = uint8_t(g());
}
void fill_wire(otw_t o, std::vector<uint8_t>& b, std::mt19937& g)
{
    if (o == otw_t::fc32)
        fill_flt<float>(b, g);
    else if (o == otw_t::sc16)
        fill_int(b, g);
    else
        for (auto& x : b)
            x = uint8_t(g());
}

std::vector<std::vector<size_t>> subsets(size_t N)
{
    std::vector<std::vector<size_t>> v;
    std::vector<size_t> all, rev;
    for (size_t c = 0; c < N; c++)
        all.push_back(c), rev.push_back(N - 1 - c);
    v.push_back(all);
    if (N > 1) {
        v.push_back(rev);
        v.push_back({N - 1});
        v.push_back({0, N / 2});
    }
    return v;
}

} // namespace

int main(int argc, char** argv)
{
    const bool verbose = argc > 1 and std::string(argv[1]) == "--verbose";
    const otw_t otws[] = {otw_t::sc16, otw_t::sc8, otw_t::sc12, otw_t::fc32};
    const cpu_t cpus[] = {cpu_t::fc32, cpu_t::fc64, cpu_t::sc16, cpu_t::sc8};
    const size_t Ns[]  = {1, 2, 4, 8, 16};
    // (start sample, samples per channel); sc12 needs s0 * N and n * N in whole groups (TX)
    const std::pair<size_t, size_t> spans[] = {{0, 4096}, {3, 1021}, {1, 7}, {5, 1}, {12, 300}};
    std::printf("zcu216_kernel_check: SIMD %s, %s\n", simd_name(), cpu_has_simd() ? "used" : "NOT available (scalar only)");
    int fails = 0;
    for (int dir = 0; dir < 2; dir++) {
        uint64_t digest = 1469598103934665603ull;
        size_t cases = 0, simd_cases = 0;
        int dfail = 0;
        for (otw_t o : otws)
            for (cpu_t c : cpus)
                for (size_t N : Ns)
                    for (const auto& ch : subsets(N))
                        for (auto [s0, n] : spans) {
                            if (dir == 1 and o == otw_t::sc12 and ((s0 * N) % 4 or (n * N) % 4))
                                continue;
                            std::mt19937 g(uint32_t(cases * 2654435761u + dir));
                            try {
                                if (dir == 0) {
                                    rx_kernel ks(o, c, N, ch, true), kc(o, c, N, ch, false);
                                    std::vector<uint8_t> pay(wire_bytes(o, (s0 + n) * N) + 64);
                                    fill_wire(o, pay, g);
                                    const size_t ob = cpu_bytes(c) * n;
                                    std::vector<std::vector<uint8_t>> a(ch.size(), std::vector<uint8_t>(ob)), b = a;
                                    std::vector<void*> pa, pb;
                                    for (size_t j = 0; j < ch.size(); j++)
                                        pa.push_back(a[j].data()), pb.push_back(b[j].data());
                                    ks(pay.data(), s0, n, pa.data(), 0);
                                    kc(pay.data(), s0, n, pb.data(), 0);
                                    bool ok = true;
                                    for (size_t j = 0; j < ch.size(); j++) {
                                        ok = ok and a[j] == b[j];
                                        digest = fnv(digest, a[j].data(), ob);
                                    }
                                    simd_cases += ks.simd();
                                    if (not ok or verbose)
                                        std::printf("  %s RX %s -> %s N=%zu ch %zu s0=%zu n=%zu  %s  [%s]\n", ok ? "ok  " : "FAIL",
                                            otw_s(o), cpu_name(c), N, ch.size(), s0, n, ks.simd() ? "simd" : "scalar", ks.desc().c_str());
                                    dfail += not ok;
                                } else {
                                    tx_kernel ks(c, o, N, ch, true), kc(c, o, N, ch, false);
                                    std::vector<std::vector<uint8_t>> in(ch.size(), std::vector<uint8_t>(cpu_bytes(c) * (n + 8)));
                                    std::vector<const void*> pi;
                                    for (auto& v : in) {
                                        fill_cpu(c, v, g);
                                        pi.push_back(v.data());
                                    }
                                    const size_t wb = wire_bytes(o, (s0 + n) * N) + 64;
                                    std::vector<uint8_t> a(wb, 0xA5), b(wb, 0xA5);
                                    ks(pi.data(), 0, n, a.data(), s0);
                                    kc(pi.data(), 0, n, b.data(), s0);
                                    const bool ok = a == b;
                                    digest = fnv(digest, a.data(), a.size());
                                    simd_cases += ks.simd();
                                    if (not ok or verbose)
                                        std::printf("  %s TX %s -> %s N=%zu ch %zu s0=%zu n=%zu  %s  [%s]\n", ok ? "ok  " : "FAIL",
                                            cpu_name(c), otw_s(o), N, ch.size(), s0, n, ks.simd() ? "simd" : "scalar", ks.desc().c_str());
                                    dfail += not ok;
                                }
                                cases++;
                            } catch (const std::exception&) { // a pair the module does not support
                            }
                        }
        std::printf("%s: %zu cases (%zu SIMD), %d mismatch(es), digest %016llx\n", dir == 0 ? "RX" : "TX", cases,
            simd_cases, dfail, (unsigned long long)digest);
        fails += dfail;
    }
    return fails;
}
