//
// uhd_zcu216 -- sample kernels: de-interleave/interleave of the N channels of
// the one wire stream (PROTOCOL §9) fused with the OTW <-> CPU format
// conversion (PROTOCOL §10, zcu216_otw.hpp), scalar and AVX2.
//
// Every kernel addresses whole slots (sc12 too: its 4-slot groups are
// unpacked per slot), so a call may start and end on any sample. The AVX2
// variants (runtime-dispatched, __builtin_cpu_supports) cover the hot paths:
//
//   RX  wire sc16 | sc8  ->  cpu sc16 | fc32,  N = 1, 2, 4, 8, 16, any channel subset
//   TX  cpu sc16 | fc32  ->  wire sc16 (and sc12 via sc16), N = 1, 2, 4, 8, 16
//
// (8 samples of all N channels are loaded, transposed in registers and the
// requested channels stored), everything else runs the scalar loops. Both
// produce exactly what UHD 4.6's converters produce (each was checked
// against uhd::convert with random data when it was written):
//
//   RX sc16 -> fc32  float(v) * float(1/32767)         (UHD sc16_chdr, SSE2 and general)
//   RX sc16 -> fc64  double(v) * (1/32767)
//   RX sc8  -> fc32/fc64  v / 128 (exact)              (UHD sc8_item32_be)
//   RX sc12 -> fc32/fc64  v / 2048 (exact), sc16 v*16  (UHD sc12_item32_le)
//   RX fc32 -> fc64  exact widening
//   TX fc32 -> sc16  cvtps(x * 32767f): round half to even, saturated; NaN and
//                    |x*32767| >= 2^31 -> -32768       (UHD's SSE2 sc16_chdr bulk path)
//   TX fc64 -> sc16  cvttpd(x * 32767): truncated, saturated (UHD's SSE2 fc64 path)
//   TX fc32/fc64 -> sc8  the same with 128, saturated to int8 (UHD sc8_item32_be)
//
// UHD's converters run a scalar loop on the unaligned head and the n % 4 tail
// of each call, which TRUNCATES instead of rounding (clamp<int16_t>(x * s)),
// so UHD's own TX output for a non-integer sample depends on where it falls in
// the call. These kernels apply the bulk rule to every sample.
//
// The formats this module defines itself (zcu216_otw.hpp): RX sc8 -> sc16
// v * 256, fc32 -> sc16 round(f * 32768) saturated (NaN -> 0); TX sc16 -> sc8
// round-half-up(x / 256) saturated, sc16 -> sc12 round-half-up(x / 16)
// saturated, sc16 -> fc32 x / 32768, fc64 -> fc32 float(x).
//
#pragma once

#include "zcu216_otw.hpp"
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace zcu216 {

enum class cpu_t : int { fc32, fc64, sc16, sc8 };
//! "fc32", "fc64", "sc16", "sc8"; uhd::value_error otherwise
cpu_t cpu_lookup(const std::string& name);
size_t cpu_bytes(cpu_t c);
const char* cpu_name(cpu_t c);
//! the CPU runs AVX2 (and the build has the AVX2 kernels)
bool cpu_has_avx2();

//! RX: wire slots (N channels interleaved) -> one CPU buffer per requested channel
class rx_kernel
{
public:
    //! chans: the wire channels to extract, in output-buffer order (each < N).
    //! simd = false forces the scalar loops (tests). Throws uhd::value_error
    //! for a cpu/otw pair the module does not support (zcu216_otw.hpp).
    rx_kernel(otw_t otw, cpu_t cpu, size_t nchan, const std::vector<size_t>& chans, bool simd = true);

    //! n samples per channel, from sample s0 of the payload `pay` (slot 0 at
    //! byte 0), to outs[j] + (o0 + k) * cpu_bytes for k < n
    void operator()(const uint8_t* pay, size_t s0, size_t n, void* const* outs, size_t o0) const
    {
        _fn(*this, pay, s0, n, outs, o0);
    }
    const std::string& desc() const
    {
        return _desc;
    }
    bool simd() const
    {
        return _simd;
    }

    // configuration, read by the kernels
    otw_t otw;
    cpu_t cpu;
    size_t N, M; // wire channels, requested channels
    size_t cpb;  // CPU bytes per sample
    uint8_t ch[16];
    float kf  = 1.0f; // fc32 scale
    double kd = 1.0;  // fc64 scale
    int mul   = 1;    // sc16 multiplier (sc8: 256, sc12: 16)

    using fn_t = void (*)(const rx_kernel&, const uint8_t*, size_t, size_t, void* const*, size_t);

private:
    fn_t _fn;
    bool _simd = false;
    std::string _desc;
};

//! TX: one CPU buffer per requested channel -> wire slots (N channels
//! interleaved; the channels not requested carry zeros)
class tx_kernel
{
public:
    tx_kernel(cpu_t cpu, otw_t otw, size_t nchan, const std::vector<size_t>& chans, bool simd = true);

    //! n samples per channel from ins[j] + (i0 + k) * cpu_bytes -> the wire
    //! slots of samples [s0, s0 + n) of the payload `pay`. sc12: s0 * N and
    //! n * N must be multiples of 4 (whole 3-word groups).
    void operator()(const void* const* ins, size_t i0, size_t n, uint8_t* pay, size_t s0) const
    {
        _fn(*this, ins, i0, n, pay, s0);
    }
    const std::string& desc() const
    {
        return _desc;
    }
    bool simd() const
    {
        return _simd;
    }

    cpu_t cpu;
    otw_t otw;
    size_t N, M;
    size_t cpb;
    uint8_t ch[16];   // index into ins -> wire channel
    int8_t jmap[16];  // wire channel -> index into ins, or -1 (zeros)

    using fn_t = void (*)(const tx_kernel&, const void* const*, size_t, size_t, uint8_t*, size_t);
    fn_t sc16_fn = nullptr; // sc12: the cpu -> sc16 stage before packing

private:
    fn_t _fn;
    bool _simd = false;
    std::string _desc;
};

//! n sc16 slots (n a multiple of 4) -> UHD sc12_item32_le words, each 12-bit
//! value = round-half-up(x / 16) saturated to [-2048, 2047]
void pack_sc12(const uint32_t* sc16_slots, uint8_t* out, size_t n);

} // namespace zcu216
