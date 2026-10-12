//
// uhd_zcu216 -- sample kernels (see zcu216_kernels.hpp).
//
#include "zcu216_kernels.hpp"
#include <uhd/exception.hpp>
#include <immintrin.h>
#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstring>

#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#    error "uhd_zcu216 kernels assume a little-endian host (the wire is little-endian)"
#endif

#define Z_AVX2 __attribute__((target("avx2")))

namespace zcu216 {

cpu_t cpu_lookup(const std::string& name)
{
    if (name == "fc32")
        return cpu_t::fc32;
    if (name == "fc64")
        return cpu_t::fc64;
    if (name == "sc16")
        return cpu_t::sc16;
    if (name == "sc8")
        return cpu_t::sc8;
    throw uhd::value_error("ZCU216: cpu_format '" + name + "' is not supported (use fc32, fc64, sc16, or sc8 with otw sc8)");
}

size_t cpu_bytes(cpu_t c)
{
    switch (c) {
        case cpu_t::fc32:
            return 8;
        case cpu_t::fc64:
            return 16;
        case cpu_t::sc16:
            return 4;
        case cpu_t::sc8:
            return 2;
    }
    return 0;
}

const char* cpu_name(cpu_t c)
{
    switch (c) {
        case cpu_t::fc32:
            return "fc32";
        case cpu_t::fc64:
            return "fc64";
        case cpu_t::sc16:
            return "sc16";
        case cpu_t::sc8:
            return "sc8";
    }
    return "?";
}

bool cpu_has_avx2()
{
    static const bool have = [] {
        const char* e = std::getenv("ZCU216_NO_SIMD"); // force the scalar loops
        if (e and *e and *e != '0')
            return false;
        __builtin_cpu_init();
        return __builtin_cpu_supports("avx2") != 0;
    }();
    return have;
}

namespace {

const char* otw_nm(otw_t o)
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
void check_pair(const char* dir, otw_t otw, cpu_t cpu)
{
    if (cpu == cpu_t::sc8 and otw != otw_t::sc8)
        throw uhd::value_error(std::string("ZCU216: ") + dir + " cpu_format sc8 needs otw_format sc8 (otw "
                               + otw_nm(otw) + " supports cpu_format fc32, fc64, sc16)");
}

std::string chan_list(const uint8_t* ch, size_t m)
{
    std::string s;
    for (size_t j = 0; j < m; j++)
        s += (j ? "," : "") + std::to_string(ch[j]);
    return s;
}

// ---------------------------------------------------------------------------
// scalar slot access
// ---------------------------------------------------------------------------
inline uint32_t ld32(const uint8_t* p)
{
    uint32_t v;
    std::memcpy(&v, p, 4);
    return v;
}
struct ipair
{
    int32_t i, q;
};
struct fpair
{
    float i, q;
};
inline int32_t sx12(uint32_t v)
{
    return int32_t(v << 20) >> 20;
}
template <otw_t O>
inline ipair dec_int(const uint8_t* pay, size_t slot)
{
    if constexpr (O == otw_t::sc16) {
        int16_t v[2];
        std::memcpy(v, pay + 4 * slot, 4);
        return {v[0], v[1]};
    } else if constexpr (O == otw_t::sc8) {
        return {int8_t(pay[2 * slot]), int8_t(pay[2 * slot + 1])};
    } else { // sc12: UHD sc12_item32_le, 4 slots in 3 LE words, MSB-first fields
        const uint8_t* g  = pay + 12 * (slot >> 2);
        const uint32_t w0 = ld32(g), w1 = ld32(g + 4), w2 = ld32(g + 8);
        switch (slot & 3) {
            case 0:
                return {sx12(w0 >> 20), sx12((w0 >> 8) & 0xfff)};
            case 1:
                return {sx12(((w0 & 0xff) << 4) | (w1 >> 28)), sx12((w1 >> 16) & 0xfff)};
            case 2:
                return {sx12((w1 >> 4) & 0xfff), sx12(((w1 & 0xf) << 8) | (w2 >> 24))};
            default:
                return {sx12((w2 >> 12) & 0xfff), sx12(w2 & 0xfff)};
        }
    }
}
inline fpair dec_fc32(const uint8_t* pay, size_t slot)
{
    float v[2];
    std::memcpy(v, pay + 8 * slot, 8);
    return {v[0], v[1]};
}

inline int16_t sat16(int32_t v)
{
    return int16_t(std::max(-32768, std::min(32767, v)));
}
inline int8_t sat8(int32_t v)
{
    return int8_t(std::max(-128, std::min(127, v)));
}
//! _mm_cvtps_epi32: round to nearest even (MXCSR default), out of range or
//! NaN -> INT_MIN ("integer indefinite")
inline int32_t cvt_ps(float p)
{
    return _mm_cvtss_si32(_mm_set_ss(p)); // the same instruction semantics, one sample
}
//! _mm_cvttpd_epi32: truncate, out of range or NaN -> INT_MIN
inline int32_t cvtt_pd(double p)
{
    return _mm_cvttsd_si32(_mm_set_sd(p));
}
//! RX fc32 -> sc16 (§10, this module's rule): round(f * 32768), saturated, NaN -> 0
inline int16_t f_to_s16(float f)
{
    const float v = f * 32768.0f;
    if (v != v)
        return 0;
    return sat16(int32_t(std::lrintf(std::max(-40000.0f, std::min(40000.0f, v)))));
}

// ---------------------------------------------------------------------------
// RX, scalar
// ---------------------------------------------------------------------------
template <cpu_t C>
inline void enc_int(const rx_kernel& k, uint8_t* o, ipair v)
{
    if constexpr (C == cpu_t::fc32) {
        const float f[2] = {float(v.i) * k.kf, float(v.q) * k.kf};
        std::memcpy(o, f, 8);
    } else if constexpr (C == cpu_t::fc64) {
        const double d[2] = {double(v.i) * k.kd, double(v.q) * k.kd};
        std::memcpy(o, d, 16);
    } else if constexpr (C == cpu_t::sc16) {
        const int16_t s[2] = {int16_t(v.i * k.mul), int16_t(v.q * k.mul)};
        std::memcpy(o, s, 4);
    } else {
        o[0] = uint8_t(int8_t(v.i));
        o[1] = uint8_t(int8_t(v.q));
    }
}
template <cpu_t C>
inline void enc_flt(uint8_t* o, fpair v)
{
    if constexpr (C == cpu_t::fc32) {
        std::memcpy(o, &v, 8);
    } else if constexpr (C == cpu_t::fc64) {
        const double d[2] = {double(v.i), double(v.q)};
        std::memcpy(o, d, 16);
    } else {
        const int16_t s[2] = {f_to_s16(v.i), f_to_s16(v.q)};
        std::memcpy(o, s, 4);
    }
}

template <otw_t O, cpu_t C>
void rx_scalar(const rx_kernel& k, const uint8_t* pay, size_t s0, size_t n, void* const* outs, size_t o0)
{
    const size_t N = k.N, cpb = k.cpb;
    for (size_t j = 0; j < k.M; j++) {
        uint8_t* o  = static_cast<uint8_t*>(outs[j]) + o0 * cpb;
        size_t slot = s0 * N + k.ch[j];
        for (size_t s = 0; s < n; s++, slot += N, o += cpb) {
            if constexpr (O == otw_t::fc32)
                enc_flt<C>(o, dec_fc32(pay, slot));
            else
                enc_int<C>(k, o, dec_int<O>(pay, slot));
        }
    }
}

//! sc12 -> int16 values (NOT x16): slots [slot0, slot0 + n) -> out[2 * k], out[2 * k + 1]
void sc12_unpack(const uint8_t* pay, size_t slot0, size_t n, int16_t* out)
{
    auto sx = [](uint64_t v) { return int16_t(int16_t(uint16_t(v << 4)) >> 4); };
    size_t s = slot0;
    const size_t end = slot0 + n;
    while (s < end and (s & 3)) { // head inside a group
        const ipair v = dec_int<otw_t::sc12>(pay, s++);
        *out++        = int16_t(v.i);
        *out++        = int16_t(v.q);
    }
    for (; s + 4 <= end; s += 4) {
        // the group is one 96-bit big-endian number of eight 12-bit fields
        const uint8_t* g  = pay + 3 * s;
        const uint64_t w0 = ld32(g), w1 = ld32(g + 4), w2 = ld32(g + 8);
        const uint64_t hi = (w0 << 16) | (w1 >> 16);           // i0 q0 i1 q1
        const uint64_t lo = ((w1 & 0xFFFF) << 32) | w2;       // i2 q2 i3 q3
        out[0] = sx(hi >> 36), out[1] = sx(hi >> 24), out[2] = sx(hi >> 12), out[3] = sx(hi);
        out[4] = sx(lo >> 36), out[5] = sx(lo >> 24), out[6] = sx(lo >> 12), out[7] = sx(lo);
        out += 8;
    }
    while (s < end) {
        const ipair v = dec_int<otw_t::sc12>(pay, s++);
        *out++        = int16_t(v.i);
        *out++        = int16_t(v.q);
    }
}

//! sc12 group shuffles (per 128-bit lane: one group = 4 slots = 12 bytes).
//! A group is the 96-bit big-endian number I0 Q0 I1 Q1 I2 Q2 I3 Q3; with
//! u_k = I_k << 12 | Q_k (24 bits, one 32-bit lane per slot) its bytes in
//! memory (three LE words) are u1[23:16] u0[7:0] u0[15:8] u0[23:16]
//! u2[15:8] u2[23:16] u1[7:0] u1[15:8] u3[7:0] u3[15:8] u3[23:16] u2[7:0].
Z_AVX2 inline __m256i sc12_unshuf()
{
    return _mm256_setr_epi8(1, 2, 3, -1, 6, 7, 0, -1, 11, 4, 5, -1, 8, 9, 10, -1, //
        1, 2, 3, -1, 6, 7, 0, -1, 11, 4, 5, -1, 8, 9, 10, -1);
}
Z_AVX2 inline __m256i sc12_shuf()
{
    return _mm256_setr_epi8(6, 0, 1, 2, 9, 10, 4, 5, 12, 13, 14, 8, -1, -1, -1, -1, //
        6, 0, 1, 2, 9, 10, 4, 5, 12, 13, 14, 8, -1, -1, -1, -1);
}

//! sc12_unpack with AVX2: two groups (8 slots) per step
Z_AVX2 void sc12_unpack_avx2(const uint8_t* pay, size_t slot0, size_t n, int16_t* out)
{
    size_t s         = slot0;
    const size_t end = slot0 + n;
    const size_t a   = std::min(end, (slot0 + 3) & ~size_t(3));
    if (a > s) { // head inside a group
        sc12_unpack(pay, s, a - s, out);
        out += 2 * (a - s);
        s = a;
    }
    const __m256i sh = sc12_unshuf(), m12 = _mm256_set1_epi32(0xFFF);
    // each step reads 28 bytes for 24: keep one more group behind it
    for (; s + 12 <= end; s += 8) {
        const uint8_t* g = pay + 3 * s;
        const __m256i v  = _mm256_set_m128i(_mm_loadu_si128(reinterpret_cast<const __m128i*>(g + 12)),
            _mm_loadu_si128(reinterpret_cast<const __m128i*>(g)));
        const __m256i u = _mm256_shuffle_epi8(v, sh);
        const __m256i x = _mm256_or_si256(_mm256_and_si256(_mm256_srli_epi32(u, 12), m12),
            _mm256_slli_epi32(_mm256_and_si256(u, m12), 16));
        _mm256_storeu_si256(reinterpret_cast<__m256i*>(out), _mm256_srai_epi16(_mm256_slli_epi16(x, 4), 4));
        out += 16;
    }
    if (s < end)
        sc12_unpack(pay, s, end - s, out);
}

//! pack_sc12 with AVX2: two groups per step
Z_AVX2 void pack_sc12_avx2(const uint32_t* in, uint8_t* out, size_t n)
{
    const __m256i sh = sc12_shuf(), m12 = _mm256_set1_epi16(0xFFF), eight = _mm256_set1_epi16(8);
    const __m256i mul = _mm256_set1_epi32((1 << 16) | 4096); // per slot: I * 4096 + Q * 1
    size_t k = 0;
    // each step writes 28 bytes for 24: keep one more group behind it
    for (; k + 12 <= n; k += 8) {
        const __m256i v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(in + k));
        // round half up, saturated: (32767 + 8) saturates to 32767 -> 2047
        const __m256i q = _mm256_and_si256(_mm256_srai_epi16(_mm256_adds_epi16(v, eight), 4), m12);
        const __m256i b = _mm256_shuffle_epi8(_mm256_madd_epi16(q, mul), sh);
        _mm_storeu_si128(reinterpret_cast<__m128i*>(out), _mm256_castsi256_si128(b));
        _mm_storeu_si128(reinterpret_cast<__m128i*>(out + 12), _mm256_extracti128_si256(b, 1));
        out += 24;
    }
    pack_sc12(in + k, out, n - k);
}

//! N = 1, cpu item == wire item: a copy
void rx_copy(const rx_kernel& k, const uint8_t* pay, size_t s0, size_t n, void* const* outs, size_t o0)
{
    std::memcpy(static_cast<uint8_t*>(outs[0]) + o0 * k.cpb, pay + s0 * k.cpb, n * k.cpb);
}

// ---------------------------------------------------------------------------
// AVX2: 8 x 32-bit transposes. RX: r[] = N registers of 8 consecutive slots
// (8 samples x N channels, sample-major) -> r[c] = 8 samples of channel c.
// TX: the inverse.
// ---------------------------------------------------------------------------
Z_AVX2 inline void tr8(__m256i* r)
{
    const __m256i t0 = _mm256_unpacklo_epi32(r[0], r[1]), t1 = _mm256_unpackhi_epi32(r[0], r[1]);
    const __m256i t2 = _mm256_unpacklo_epi32(r[2], r[3]), t3 = _mm256_unpackhi_epi32(r[2], r[3]);
    const __m256i t4 = _mm256_unpacklo_epi32(r[4], r[5]), t5 = _mm256_unpackhi_epi32(r[4], r[5]);
    const __m256i t6 = _mm256_unpacklo_epi32(r[6], r[7]), t7 = _mm256_unpackhi_epi32(r[6], r[7]);
    const __m256i u0 = _mm256_unpacklo_epi64(t0, t2), u1 = _mm256_unpackhi_epi64(t0, t2);
    const __m256i u2 = _mm256_unpacklo_epi64(t1, t3), u3 = _mm256_unpackhi_epi64(t1, t3);
    const __m256i u4 = _mm256_unpacklo_epi64(t4, t6), u5 = _mm256_unpackhi_epi64(t4, t6);
    const __m256i u6 = _mm256_unpacklo_epi64(t5, t7), u7 = _mm256_unpackhi_epi64(t5, t7);
    r[0] = _mm256_permute2x128_si256(u0, u4, 0x20);
    r[1] = _mm256_permute2x128_si256(u1, u5, 0x20);
    r[2] = _mm256_permute2x128_si256(u2, u6, 0x20);
    r[3] = _mm256_permute2x128_si256(u3, u7, 0x20);
    r[4] = _mm256_permute2x128_si256(u0, u4, 0x31);
    r[5] = _mm256_permute2x128_si256(u1, u5, 0x31);
    r[6] = _mm256_permute2x128_si256(u2, u6, 0x31);
    r[7] = _mm256_permute2x128_si256(u3, u7, 0x31);
}

template <int N>
Z_AVX2 inline void deint(__m256i* r)
{
    if constexpr (N == 2) {
        // r0 = samples 0-3, r1 = samples 4-7, (ch0, ch1) pairs
        const __m256i p = _mm256_setr_epi32(0, 2, 4, 6, 1, 3, 5, 7);
        const __m256i a = _mm256_permutevar8x32_epi32(r[0], p); // [c0 s0-3 | c1 s0-3]
        const __m256i b = _mm256_permutevar8x32_epi32(r[1], p); // [c0 s4-7 | c1 s4-7]
        r[0] = _mm256_permute2x128_si256(a, b, 0x20);
        r[1] = _mm256_permute2x128_si256(a, b, 0x31);
    } else if constexpr (N == 4) {
        // r[k] = samples 2k, 2k+1 (4 channels each) -> 64-bit (ch c, s2k..2k+1)
        const __m256i p  = _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7);
        const __m256i a0 = _mm256_permutevar8x32_epi32(r[0], p);
        const __m256i a1 = _mm256_permutevar8x32_epi32(r[1], p);
        const __m256i a2 = _mm256_permutevar8x32_epi32(r[2], p);
        const __m256i a3 = _mm256_permutevar8x32_epi32(r[3], p);
        const __m256i t0 = _mm256_unpacklo_epi64(a0, a1), t1 = _mm256_unpackhi_epi64(a0, a1);
        const __m256i t2 = _mm256_unpacklo_epi64(a2, a3), t3 = _mm256_unpackhi_epi64(a2, a3);
        r[0] = _mm256_permute2x128_si256(t0, t2, 0x20);
        r[1] = _mm256_permute2x128_si256(t1, t3, 0x20);
        r[2] = _mm256_permute2x128_si256(t0, t2, 0x31);
        r[3] = _mm256_permute2x128_si256(t1, t3, 0x31);
    } else if constexpr (N == 8) {
        tr8(r);
    } else if constexpr (N == 16) {
        // sample s = r[2s] (ch 0-7), r[2s+1] (ch 8-15)
        __m256i a[8], b[8];
        for (int s = 0; s < 8; s++) {
            a[s] = r[2 * s];
            b[s] = r[2 * s + 1];
        }
        tr8(a);
        tr8(b);
        for (int c = 0; c < 8; c++) {
            r[c]     = a[c];
            r[c + 8] = b[c];
        }
    }
}

template <int N>
Z_AVX2 inline void inter(__m256i* c)
{
    if constexpr (N == 2) {
        const __m256i q = _mm256_setr_epi32(0, 4, 1, 5, 2, 6, 3, 7);
        const __m256i a = _mm256_permute2x128_si256(c[0], c[1], 0x20); // [c0 s0-3 | c1 s0-3]
        const __m256i b = _mm256_permute2x128_si256(c[0], c[1], 0x31); // [c0 s4-7 | c1 s4-7]
        c[0] = _mm256_permutevar8x32_epi32(a, q);
        c[1] = _mm256_permutevar8x32_epi32(b, q);
    } else if constexpr (N == 4) {
        const __m256i q  = _mm256_setr_epi32(0, 2, 4, 6, 1, 3, 5, 7);
        const __m256i a0 = _mm256_permute2x128_si256(c[0], c[2], 0x20);
        const __m256i a1 = _mm256_permute2x128_si256(c[0], c[2], 0x31);
        const __m256i b0 = _mm256_permute2x128_si256(c[1], c[3], 0x20);
        const __m256i b1 = _mm256_permute2x128_si256(c[1], c[3], 0x31);
        c[0] = _mm256_permutevar8x32_epi32(_mm256_unpacklo_epi64(a0, b0), q);
        c[1] = _mm256_permutevar8x32_epi32(_mm256_unpackhi_epi64(a0, b0), q);
        c[2] = _mm256_permutevar8x32_epi32(_mm256_unpacklo_epi64(a1, b1), q);
        c[3] = _mm256_permutevar8x32_epi32(_mm256_unpackhi_epi64(a1, b1), q);
    } else if constexpr (N == 8) {
        tr8(c);
    } else if constexpr (N == 16) {
        __m256i a[8], b[8];
        for (int k = 0; k < 8; k++) {
            a[k] = c[k];
            b[k] = c[k + 8];
        }
        tr8(a);
        tr8(b);
        for (int s = 0; s < 8; s++) {
            c[2 * s]     = a[s];
            c[2 * s + 1] = b[s];
        }
    }
}

// RX loads: 8 slots -> 8 sc16 slots in one register
struct ld_sc16
{
    Z_AVX2 static inline __m256i ld(const uint8_t* pay, size_t slot)
    {
        return _mm256_loadu_si256(reinterpret_cast<const __m256i*>(pay + 4 * slot));
    }
};
struct ld_sc8
{
    Z_AVX2 static inline __m256i ld(const uint8_t* pay, size_t slot)
    {
        return _mm256_cvtepi8_epi16(_mm_loadu_si128(reinterpret_cast<const __m128i*>(pay + 2 * slot)));
    }
};
// RX stores: 8 sc16 slots -> 8 CPU samples
struct st_sc16
{
    Z_AVX2 static inline void st(uint8_t* o, __m256i v, __m256)
    {
        _mm256_storeu_si256(reinterpret_cast<__m256i*>(o), v);
    }
};
struct st_sc16_x256 // sc8 wire -> sc16: v * 256
{
    Z_AVX2 static inline void st(uint8_t* o, __m256i v, __m256)
    {
        _mm256_storeu_si256(reinterpret_cast<__m256i*>(o), _mm256_slli_epi16(v, 8));
    }
};
struct st_sc8 // sc8 wire -> sc8 CPU: the int8 values ld_sc8 widened, narrowed back (exact)
{
    Z_AVX2 static inline void st(uint8_t* o, __m256i v, __m256)
    {
        const __m256i b = _mm256_permute4x64_epi64(_mm256_packs_epi16(v, v), 0xD8);
        _mm_storeu_si128(reinterpret_cast<__m128i*>(o), _mm256_castsi256_si128(b));
    }
};
struct st_sc16_x16 // sc12 values -> sc16: v * 16
{
    Z_AVX2 static inline void st(uint8_t* o, __m256i v, __m256)
    {
        _mm256_storeu_si256(reinterpret_cast<__m256i*>(o), _mm256_slli_epi16(v, 4));
    }
};
struct st_fc32
{
    Z_AVX2 static inline void st(uint8_t* o, __m256i v, __m256 k)
    {
        const __m256i lo = _mm256_cvtepi16_epi32(_mm256_castsi256_si128(v));
        const __m256i hi = _mm256_cvtepi16_epi32(_mm256_extracti128_si256(v, 1));
        _mm256_storeu_ps(reinterpret_cast<float*>(o), _mm256_mul_ps(_mm256_cvtepi32_ps(lo), k));
        _mm256_storeu_ps(reinterpret_cast<float*>(o + 32), _mm256_mul_ps(_mm256_cvtepi32_ps(hi), k));
    }
};

template <int N, otw_t O, cpu_t C, class L, class S>
Z_AVX2 void rx_avx2(const rx_kernel& k, const uint8_t* pay, size_t s0, size_t n, void* const* outs, size_t o0)
{
    const size_t cpb = k.cpb, M = k.M;
    const __m256 kf  = _mm256_set1_ps(k.kf);
    uint8_t* o[16];
    for (size_t j = 0; j < M; j++)
        o[j] = static_cast<uint8_t*>(outs[j]) + o0 * cpb;
    size_t s = 0;
    for (; s + 8 <= n; s += 8) {
        const size_t base = (s0 + s) * N;
        __m256i r[N];
        for (int i = 0; i < N; i++)
            r[i] = L::ld(pay, base + 8 * size_t(i));
        deint<N>(r);
        for (size_t j = 0; j < M; j++)
            S::st(o[j] + s * cpb, r[k.ch[j]], kf);
    }
    if (s < n)
        rx_scalar<O, C>(k, pay, s0 + s, n - s, outs, o0 + s);
}

template <otw_t O, cpu_t C, class L, class S>
rx_kernel::fn_t rx_avx2_for(size_t N)
{
    switch (N) {
        case 1:
            return &rx_avx2<1, O, C, L, S>;
        case 2:
            return &rx_avx2<2, O, C, L, S>;
        case 4:
            return &rx_avx2<4, O, C, L, S>;
        case 8:
            return &rx_avx2<8, O, C, L, S>;
        case 16:
            return &rx_avx2<16, O, C, L, S>;
    }
    return nullptr;
}

//! sc12: unpack a chunk of whole samples to int16 slots, then the AVX2 sc16
//! kernel (k.kf = 1/2048, sc16 output x16) on that
template <int N, cpu_t C, class S>
Z_AVX2 void rx_sc12_avx2(const rx_kernel& k, const uint8_t* pay, size_t s0, size_t n, void* const* outs, size_t o0)
{
    constexpr size_t kChunk = 64; // samples
    alignas(64) int16_t tmp[2 * kChunk * N];
    const uint8_t* t = reinterpret_cast<const uint8_t*>(tmp);
    for (size_t s = 0; s < n; s += kChunk) {
        const size_t m = std::min(kChunk, n - s);
        sc12_unpack_avx2(pay, (s0 + s) * N, m * N, tmp);
        rx_avx2<N, otw_t::sc16, C, ld_sc16, S>(k, t, 0, m, outs, o0 + s);
    }
}

template <cpu_t C, class S>
rx_kernel::fn_t rx_sc12_for(size_t N)
{
    switch (N) {
        case 1:
            return &rx_sc12_avx2<1, C, S>;
        case 2:
            return &rx_sc12_avx2<2, C, S>;
        case 4:
            return &rx_sc12_avx2<4, C, S>;
        case 8:
            return &rx_sc12_avx2<8, C, S>;
        case 16:
            return &rx_sc12_avx2<16, C, S>;
    }
    return nullptr;
}

template <otw_t O>
rx_kernel::fn_t rx_scalar_for(cpu_t c)
{
    switch (c) {
        case cpu_t::fc32:
            return &rx_scalar<O, cpu_t::fc32>;
        case cpu_t::fc64:
            return &rx_scalar<O, cpu_t::fc64>;
        case cpu_t::sc16:
            return &rx_scalar<O, cpu_t::sc16>;
        case cpu_t::sc8:
            return &rx_scalar<O, cpu_t::sc8>;
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// TX, scalar
// ---------------------------------------------------------------------------
template <cpu_t C, otw_t O>
inline void tx_enc(uint8_t* w, const uint8_t* in)
{
    if constexpr (O == otw_t::sc16) {
        int16_t s[2];
        if constexpr (C == cpu_t::sc16) {
            std::memcpy(s, in, 4);
        } else if constexpr (C == cpu_t::fc32) {
            float f[2];
            std::memcpy(f, in, 8);
            s[0] = sat16(cvt_ps(f[0] * 32767.0f));
            s[1] = sat16(cvt_ps(f[1] * 32767.0f));
        } else { // fc64
            double d[2];
            std::memcpy(d, in, 16);
            s[0] = sat16(cvtt_pd(d[0] * 32767.0));
            s[1] = sat16(cvtt_pd(d[1] * 32767.0));
        }
        std::memcpy(w, s, 4);
    } else if constexpr (O == otw_t::sc8) {
        if constexpr (C == cpu_t::sc8) {
            std::memcpy(w, in, 2);
        } else if constexpr (C == cpu_t::sc16) {
            int16_t s[2];
            std::memcpy(s, in, 4);
            w[0] = uint8_t(int8_t(std::min(127, (int32_t(s[0]) + 128) >> 8)));
            w[1] = uint8_t(int8_t(std::min(127, (int32_t(s[1]) + 128) >> 8)));
        } else if constexpr (C == cpu_t::fc32) {
            float f[2];
            std::memcpy(f, in, 8);
            w[0] = uint8_t(sat8(cvt_ps(f[0] * 128.0f)));
            w[1] = uint8_t(sat8(cvt_ps(f[1] * 128.0f)));
        } else {
            double d[2];
            std::memcpy(d, in, 16);
            w[0] = uint8_t(sat8(cvtt_pd(d[0] * 128.0)));
            w[1] = uint8_t(sat8(cvtt_pd(d[1] * 128.0)));
        }
    } else { // fc32
        if constexpr (C == cpu_t::fc32) {
            std::memcpy(w, in, 8);
        } else if constexpr (C == cpu_t::fc64) {
            double d[2];
            std::memcpy(d, in, 16);
            const float f[2] = {float(d[0]), float(d[1])};
            std::memcpy(w, f, 8);
        } else {
            int16_t s[2];
            std::memcpy(s, in, 4);
            const float f[2] = {float(s[0]) * (1.0f / 32768.0f), float(s[1]) * (1.0f / 32768.0f)};
            std::memcpy(w, f, 8);
        }
    }
}

template <cpu_t C, otw_t O>
void tx_scalar(const tx_kernel& k, const void* const* ins, size_t i0, size_t n, uint8_t* pay, size_t s0)
{
    constexpr size_t B = O == otw_t::sc16 ? 4 : O == otw_t::sc8 ? 2 : 8;
    const size_t N = k.N, cpb = k.cpb;
    if (k.M < N) {
        for (size_t c = 0; c < N; c++) {
            if (k.jmap[c] >= 0)
                continue;
            uint8_t* w = pay + (s0 * N + c) * B;
            for (size_t s = 0; s < n; s++, w += N * B)
                std::memset(w, 0, B);
        }
    }
    for (size_t j = 0; j < k.M; j++) {
        const uint8_t* in = static_cast<const uint8_t*>(ins[j]) + i0 * cpb;
        uint8_t* w        = pay + (s0 * N + k.ch[j]) * B;
        for (size_t s = 0; s < n; s++, w += N * B, in += cpb)
            tx_enc<C, O>(w, in);
    }
}

void tx_copy(const tx_kernel& k, const void* const* ins, size_t i0, size_t n, uint8_t* pay, size_t s0)
{
    std::memcpy(pay + s0 * k.cpb, static_cast<const uint8_t*>(ins[0]) + i0 * k.cpb, n * k.cpb);
}

//! sc12: cpu -> sc16 slots (k.sc16_fn) in chunks, then packed
void tx_sc12(const tx_kernel& k, const void* const* ins, size_t i0, size_t n, uint8_t* pay, size_t s0)
{
    // chunks of 2048 slots (8 KB of sc16, stays in L1) whatever N is: a
    // fixed sample count made N = 1 call the kernel every 64 slots
    constexpr size_t kSlots = 2048;
    alignas(64) uint32_t tmp[kSlots];
    const size_t chunk = kSlots / k.N; // whole samples; N <= 16 divides 2048
    for (size_t s = 0; s < n; s += chunk) {
        const size_t m = std::min(chunk, n - s);
        k.sc16_fn(k, ins, i0 + s, m, reinterpret_cast<uint8_t*>(tmp), 0);
        if (k.simd()) // 3 bytes per slot
            pack_sc12_avx2(tmp, pay + (s0 + s) * k.N * 3, m * k.N);
        else
            pack_sc12(tmp, pay + (s0 + s) * k.N * 3, m * k.N);
    }
}

// TX loads: 8 CPU samples -> 8 sc16 slots
struct tl_sc16
{
    Z_AVX2 static inline __m256i ld(const uint8_t* in)
    {
        return _mm256_loadu_si256(reinterpret_cast<const __m256i*>(in));
    }
};
struct tl_fc32
{
    Z_AVX2 static inline __m256i ld(const uint8_t* in)
    {
        const __m256 k  = _mm256_set1_ps(32767.0f);
        const __m256 a  = _mm256_loadu_ps(reinterpret_cast<const float*>(in));
        const __m256 b  = _mm256_loadu_ps(reinterpret_cast<const float*>(in + 32));
        const __m256i p = _mm256_packs_epi32(
            _mm256_cvtps_epi32(_mm256_mul_ps(a, k)), _mm256_cvtps_epi32(_mm256_mul_ps(b, k)));
        return _mm256_permute4x64_epi64(p, 0xD8); // [s0s1 s4s5 s2s3 s6s7] -> in order
    }
};

template <int N, cpu_t C, class L>
Z_AVX2 void tx_avx2(const tx_kernel& k, const void* const* ins, size_t i0, size_t n, uint8_t* pay, size_t s0)
{
    const size_t cpb = k.cpb;
    const uint8_t* in[16];
    for (size_t j = 0; j < k.M; j++)
        in[j] = static_cast<const uint8_t*>(ins[j]) + i0 * cpb;
    size_t s = 0;
    for (; s + 8 <= n; s += 8) {
        __m256i c[N];
        for (int ch = 0; ch < N; ch++) {
            const int j = k.jmap[ch];
            c[ch]       = j >= 0 ? L::ld(in[j] + s * cpb) : _mm256_setzero_si256();
        }
        inter<N>(c);
        uint8_t* w = pay + 4 * (s0 + s) * N;
        for (int i = 0; i < N; i++)
            _mm256_storeu_si256(reinterpret_cast<__m256i*>(w + 32 * size_t(i)), c[i]);
    }
    if (s < n)
        tx_scalar<C, otw_t::sc16>(k, ins, i0 + s, n - s, pay, s0 + s);
}

// TX loads for sc8: 8 CPU samples -> 8 slots of int16 pairs holding the int8
// value (saturated to int8 by the final pack)
struct tl_fc32_sc8
{
    Z_AVX2 static inline __m256i ld(const uint8_t* in)
    {
        const __m256 k  = _mm256_set1_ps(128.0f);
        const __m256 a  = _mm256_loadu_ps(reinterpret_cast<const float*>(in));
        const __m256 b  = _mm256_loadu_ps(reinterpret_cast<const float*>(in + 32));
        const __m256i p = _mm256_packs_epi32(
            _mm256_cvtps_epi32(_mm256_mul_ps(a, k)), _mm256_cvtps_epi32(_mm256_mul_ps(b, k)));
        return _mm256_permute4x64_epi64(p, 0xD8);
    }
};
struct tl_sc8_sc8 // sc8 CPU -> sc8 wire: widened here, the final pack restores them exactly
{
    Z_AVX2 static inline __m256i ld(const uint8_t* in)
    {
        return _mm256_cvtepi8_epi16(_mm_loadu_si128(reinterpret_cast<const __m128i*>(in)));
    }
};
struct tl_sc16_sc8 // round half up: (x + 128) >> 8; 32767 + 128 saturates to 127
{
    Z_AVX2 static inline __m256i ld(const uint8_t* in)
    {
        const __m256i v = _mm256_loadu_si256(reinterpret_cast<const __m256i*>(in));
        return _mm256_srai_epi16(_mm256_adds_epi16(v, _mm256_set1_epi16(128)), 8);
    }
};

template <int N, cpu_t C, class L>
Z_AVX2 void tx_avx2_sc8(const tx_kernel& k, const void* const* ins, size_t i0, size_t n, uint8_t* pay, size_t s0)
{
    const size_t cpb = k.cpb;
    const uint8_t* in[16];
    for (size_t j = 0; j < k.M; j++)
        in[j] = static_cast<const uint8_t*>(ins[j]) + i0 * cpb;
    size_t s = 0;
    for (; s + 8 <= n; s += 8) {
        __m256i c[N];
        for (int ch = 0; ch < N; ch++) {
            const int j = k.jmap[ch];
            c[ch]       = j >= 0 ? L::ld(in[j] + s * cpb) : _mm256_setzero_si256();
        }
        inter<N>(c);
        uint8_t* w = pay + 2 * (s0 + s) * N;
        if constexpr (N == 1) {
            const __m256i b = _mm256_permute4x64_epi64(_mm256_packs_epi16(c[0], c[0]), 0xD8);
            _mm_storeu_si128(reinterpret_cast<__m128i*>(w), _mm256_castsi256_si128(b));
        } else {
            for (int i = 0; i < N; i += 2) { // rows i, i+1 = 16 consecutive slots
                const __m256i b = _mm256_permute4x64_epi64(_mm256_packs_epi16(c[i], c[i + 1]), 0xD8);
                _mm256_storeu_si256(reinterpret_cast<__m256i*>(w + 16 * size_t(i)), b);
            }
        }
    }
    if (s < n)
        tx_scalar<C, otw_t::sc8>(k, ins, i0 + s, n - s, pay, s0 + s);
}

template <cpu_t C, class L>
tx_kernel::fn_t tx_avx2_sc8_for(size_t N)
{
    switch (N) {
        case 1:
            return &tx_avx2_sc8<1, C, L>;
        case 2:
            return &tx_avx2_sc8<2, C, L>;
        case 4:
            return &tx_avx2_sc8<4, C, L>;
        case 8:
            return &tx_avx2_sc8<8, C, L>;
        case 16:
            return &tx_avx2_sc8<16, C, L>;
    }
    return nullptr;
}

template <cpu_t C, class L>
tx_kernel::fn_t tx_avx2_for(size_t N)
{
    switch (N) {
        case 1:
            return &tx_avx2<1, C, L>;
        case 2:
            return &tx_avx2<2, C, L>;
        case 4:
            return &tx_avx2<4, C, L>;
        case 8:
            return &tx_avx2<8, C, L>;
        case 16:
            return &tx_avx2<16, C, L>;
    }
    return nullptr;
}

template <otw_t O>
tx_kernel::fn_t tx_scalar_for(cpu_t c)
{
    switch (c) {
        case cpu_t::fc32:
            return &tx_scalar<cpu_t::fc32, O>;
        case cpu_t::fc64:
            return &tx_scalar<cpu_t::fc64, O>;
        case cpu_t::sc16:
            return &tx_scalar<cpu_t::sc16, O>;
        case cpu_t::sc8:
            if constexpr (O == otw_t::sc8)
                return &tx_scalar<cpu_t::sc8, O>;
            return nullptr;
    }
    return nullptr;
}

bool simd_n(size_t N)
{
    return N == 1 or N == 2 or N == 4 or N == 8 or N == 16;
}

void check_chans(size_t N, const std::vector<size_t>& chans)
{
    if (N == 0 or N > 16)
        throw uhd::value_error("ZCU216: kernel for N = " + std::to_string(N) + " channels");
    if (chans.size() > N)
        throw uhd::value_error("ZCU216: more channels requested than the stream carries");
    for (size_t c : chans)
        if (c >= N)
            throw uhd::index_error("ZCU216: channel " + std::to_string(c) + " not in the stream");
}

} // namespace

// ---------------------------------------------------------------------------
rx_kernel::rx_kernel(otw_t otw_, cpu_t cpu_, size_t nchan, const std::vector<size_t>& chans, bool simd)
    : otw(otw_), cpu(cpu_), N(nchan), M(chans.size()), cpb(cpu_bytes(cpu_))
{
    check_pair("RX", otw, cpu);
    check_chans(N, chans);
    for (size_t j = 0; j < M and j < 16; j++) // M <= N <= 16 (check_chans)
        ch[j] = uint8_t(chans[j]);
    std::string rule;
    switch (otw) {
        case otw_t::sc16:
            kf = float(1.0 / 32767.0), kd = 1.0 / 32767.0, mul = 1;
            rule = "x 1/32767";
            break;
        case otw_t::sc8:
            kf = 1.0f / 128.0f, kd = 1.0 / 128.0, mul = 256;
            rule = cpu == cpu_t::sc16 ? "x 256" : "x 1/128";
            break;
        case otw_t::sc12:
            kf = 1.0f / 2048.0f, kd = 1.0 / 2048.0, mul = 16;
            rule = cpu == cpu_t::sc16 ? "x 16" : "x 1/2048";
            break;
        case otw_t::fc32:
            rule = cpu == cpu_t::sc16 ? "round(x 32768), saturated" : "exact";
            break;
    }
    if (cpu == cpu_t::sc16 and otw == otw_t::sc16)
        rule = "copy";
    if (cpu == cpu_t::sc8 or (cpu == cpu_t::fc32 and otw == otw_t::fc32))
        rule = "copy";
    const bool identity = (otw == otw_t::sc16 and cpu == cpu_t::sc16) or (otw == otw_t::sc8 and cpu == cpu_t::sc8)
                          or (otw == otw_t::fc32 and cpu == cpu_t::fc32);
    // cpu sc8 (otw sc8 only): the scalar per-sample de-interleave held N > 1
    // sc8 builds to ~70 % of 4.8 GS/s in full-rate duplex
    _simd = simd and cpu_has_avx2() and simd_n(N)
            and (((otw == otw_t::sc16 or otw == otw_t::sc8 or otw == otw_t::sc12)
                     and (cpu == cpu_t::sc16 or cpu == cpu_t::fc32))
                 or (otw == otw_t::sc8 and cpu == cpu_t::sc8));
    if (identity and N == 1 and M == 1) {
        _fn   = &rx_copy;
        _simd = false;
    } else if (_simd) {
        if (otw == otw_t::sc16)
            _fn = cpu == cpu_t::fc32 ? rx_avx2_for<otw_t::sc16, cpu_t::fc32, ld_sc16, st_fc32>(N)
                                     : rx_avx2_for<otw_t::sc16, cpu_t::sc16, ld_sc16, st_sc16>(N);
        else if (otw == otw_t::sc12)
            _fn = cpu == cpu_t::fc32 ? rx_sc12_for<cpu_t::fc32, st_fc32>(N)
                                     : rx_sc12_for<cpu_t::sc16, st_sc16_x16>(N);
        else if (cpu == cpu_t::sc8)
            _fn = rx_avx2_for<otw_t::sc8, cpu_t::sc8, ld_sc8, st_sc8>(N);
        else
            _fn = cpu == cpu_t::fc32 ? rx_avx2_for<otw_t::sc8, cpu_t::fc32, ld_sc8, st_fc32>(N)
                                     : rx_avx2_for<otw_t::sc8, cpu_t::sc16, ld_sc8, st_sc16_x256>(N);
    } else {
        switch (otw) {
            case otw_t::sc16:
                _fn = rx_scalar_for<otw_t::sc16>(cpu);
                break;
            case otw_t::sc8:
                _fn = rx_scalar_for<otw_t::sc8>(cpu);
                break;
            case otw_t::sc12:
                _fn = rx_scalar_for<otw_t::sc12>(cpu);
                break;
            case otw_t::fc32:
                _fn = rx_scalar_for<otw_t::fc32>(cpu);
                break;
        }
    }
    if (not _fn)
        throw uhd::value_error("ZCU216: no RX kernel for this format pair");
    _desc = std::string(otw_nm(otw)) + " -> " + cpu_name(cpu) + " (" + rule + ")"
            + (N > 1 ? ", de-interleave ch " + chan_list(ch, M) + " of " + std::to_string(N) : "")
            + (_simd ? ", AVX2" : (_fn == &rx_copy ? "" : ", scalar"));
}

tx_kernel::tx_kernel(cpu_t cpu_, otw_t otw_, size_t nchan, const std::vector<size_t>& chans, bool simd)
    : cpu(cpu_), otw(otw_), N(nchan), M(chans.size()), cpb(cpu_bytes(cpu_))
{
    check_pair("TX", otw, cpu);
    check_chans(N, chans);
    std::fill(std::begin(jmap), std::end(jmap), int8_t(-1));
    for (size_t j = 0; j < M and j < 16; j++) {
        ch[j] = uint8_t(chans[j]);
        jmap[chans[j] & 15] = int8_t(j); // < N <= 16 (check_chans)
    }
    const otw_t slot_dom = otw == otw_t::sc12 ? otw_t::sc16 : otw; // sc12 is packed from sc16
    _simd = simd and cpu_has_avx2() and simd_n(N)
            and (((slot_dom == otw_t::sc16 or slot_dom == otw_t::sc8) and (cpu == cpu_t::sc16 or cpu == cpu_t::fc32))
                 or (otw == otw_t::sc8 and cpu == cpu_t::sc8));
    const bool identity = (otw == otw_t::sc16 and cpu == cpu_t::sc16) or (otw == otw_t::sc8 and cpu == cpu_t::sc8)
                          or (otw == otw_t::fc32 and cpu == cpu_t::fc32);
    fn_t f = nullptr;
    if (identity and N == 1 and M == 1) {
        f     = &tx_copy;
        _simd = false;
    } else if (_simd and slot_dom == otw_t::sc8) {
        f = cpu == cpu_t::fc32  ? tx_avx2_sc8_for<cpu_t::fc32, tl_fc32_sc8>(N)
            : cpu == cpu_t::sc8 ? tx_avx2_sc8_for<cpu_t::sc8, tl_sc8_sc8>(N)
                                : tx_avx2_sc8_for<cpu_t::sc16, tl_sc16_sc8>(N);
    } else if (_simd) {
        f = cpu == cpu_t::fc32 ? tx_avx2_for<cpu_t::fc32, tl_fc32>(N) : tx_avx2_for<cpu_t::sc16, tl_sc16>(N);
    } else {
        switch (slot_dom) {
            case otw_t::sc16:
                f = tx_scalar_for<otw_t::sc16>(cpu);
                break;
            case otw_t::sc8:
                f = tx_scalar_for<otw_t::sc8>(cpu);
                break;
            case otw_t::fc32:
                f = tx_scalar_for<otw_t::fc32>(cpu);
                break;
            default:
                break;
        }
    }
    if (not f)
        throw uhd::value_error("ZCU216: no TX kernel for this format pair");
    if (otw == otw_t::sc12) {
        sc16_fn = f;
        _fn     = &tx_sc12;
    } else {
        _fn = f;
    }
    std::string rule;
    switch (otw) {
        case otw_t::sc16:
            rule = cpu == cpu_t::sc16 ? "copy" : cpu == cpu_t::fc32 ? "x 32767, round to even, saturated" : "x 32767, truncated, saturated";
            break;
        case otw_t::sc8:
            rule = cpu == cpu_t::sc8 ? "copy" : cpu == cpu_t::sc16 ? "round-half-up(x / 256), saturated" : "x 128, saturated";
            break;
        case otw_t::sc12:
            rule = std::string(cpu == cpu_t::sc16 ? "" : "to sc16 (x 32767), then ") + "round-half-up(x / 16), saturated, packed";
            break;
        case otw_t::fc32:
            rule = cpu == cpu_t::fc32 ? "copy" : cpu == cpu_t::sc16 ? "x / 32768" : "to float";
            break;
    }
    _desc = std::string(cpu_name(cpu)) + " -> " + otw_nm(otw) + " (" + rule + ")"
            + (N > 1 ? ", interleave ch " + chan_list(ch, M) + " of " + std::to_string(N) : "")
            + (_simd ? ", AVX2" : (f == &tx_copy ? "" : ", scalar"));
}

void pack_sc12(const uint32_t* in, uint8_t* out, size_t n)
{
    // 12-bit value of one int16: round half up, saturated (only +2048 can
    // overflow: (32767 + 8) >> 4 = 2048 -> 2047)
    auto q = [](uint32_t half) -> uint64_t {
        const int v = std::min(2047, (int(int16_t(half & 0xFFFF)) + 8) >> 4);
        return uint64_t(uint32_t(v) & 0xFFFu);
    };
    for (size_t k = 0; k + 4 <= n; k += 4) {
        const uint32_t s0 = in[k], s1 = in[k + 1], s2 = in[k + 2], s3 = in[k + 3];
        // UHD sc12_item32_le: the group is one 96-bit big-endian number
        // I0 Q0 I1 Q1 I2 Q2 I3 Q3 (12 bits each) split into three LE words:
        // w0 = {I0, Q0, I1[11:4]}, w1 = {I1[3:0], Q1, I2, Q2[11:8]}, w2 = {Q2[7:0], I3, Q3}
        const uint64_t hi = (q(s0) << 36) | (q(s0 >> 16) << 24) | (q(s1) << 12) | q(s1 >> 16);
        const uint64_t lo = (q(s2) << 36) | (q(s2 >> 16) << 24) | (q(s3) << 12) | q(s3 >> 16);
        const uint32_t w[3] = {uint32_t(hi >> 16), uint32_t(((hi & 0xFFFF) << 16) | (lo >> 32)), uint32_t(lo)};
        std::memcpy(out, w, 12);
        out += 12;
    }
}

} // namespace zcu216
