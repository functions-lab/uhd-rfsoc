//
// uhd_rfsoc -- over-the-wire (OTW) sample formats, Protocol §10.
//
// The FPGA converts between the converters' int16 samples and the wire
// format; the host converts between the wire format and the application's
// CPU format. Every conversion is scaled so that fc32/fc64 full scale is
// +-1.0 and sc16 keeps the converters' int16 scale, whatever the OTW format:
//
//   RX (wire -> cpu)        fc32 / fc64                     sc16                   sc8
//     otw sc16              UHD sc16_chdr, 1/32767          copy                   --
//     otw sc8               UHD sc8_item32_be, 1/128        v * 256                copy
//     otw sc12              UHD sc12_item32_le, 1/2048      UHD (v * 16)           --
//                           (fc64: via sc16, 1/32768)
//     otw fc32              copy / UHD fc32_item32_le       round(f*32768), sat    --
//
//   TX (cpu -> wire)
//     otw sc16              UHD sc16_chdr, 32767            copy                   --
//     otw sc8               UHD sc8_item32_be, 128          rhu(x/256), sat        copy
//     otw sc12              UHD -> sc16 (32767), then       rhu(x/16), sat,        --
//                           rhu(x/16) sat, sc12 packing     sc12 packing
//     otw fc32              copy / UHD fc32_item32_le       x / 32768              --
//
// rhu = round half up = floor(x/d + 1/2), the FPGA's RX rule (§10), so a host
// quantisation and an FPGA one of the same int16 agree bit for bit. UHD's own
// fc32 -> sc12 packer is not used: it truncates and WRAPS at full scale (+1.0
// -> -2048, measured on UHD 4.6), so TX goes through sc16 (rounded and
// saturated like UHD's) and the module packs. The layout is UHD's
// sc12_item32_le (identical words for in-range values, checked against UHD 4.6).
//
// The conversions themselves, fused with the channel (de-)interleave, are the
// kernels of rfsoc_kernels.hpp, bit for bit equal to UHD's converters (the
// "UHD ..." entries above).
//
#pragma once

#include "rfsoc_common.hpp"
#include <memory>
#include <string>

namespace rfsoc {

//! Protocol §10 formats; the value is the FPGA FMT register code
enum class otw_t : int { sc16 = 0, sc8 = 1, sc12 = 2, fc32 = 3 };

struct otw_info
{
    otw_t fmt;
    const char* name; // "sc16", "sc8", "sc12", "fc32"
    size_t slot_bytes; // bytes per slot (one complex sample of one channel)
    size_t group;      // slots a converter call must start/end on (sc8 2, sc12 4)
    size_t granule;    // slots per whole 64-byte FIFO words (16, 32, 64, 8)
};

//! §10: a packet's payload is at most 8192 bytes
constexpr size_t kMaxPayloadBytes = 8192;
//! the FPGA's flow-control credit unit (§6): one 64-byte buffer word
constexpr size_t kTxWordBytes = 64;

//! "" -> sc16; throws uhd::value_error for an unknown format
const otw_info& otw_lookup(const std::string& name);

} // namespace rfsoc
