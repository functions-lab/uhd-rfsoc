//
// uhd_zcu216 -- OTW sample formats (Protocol §10). The conversions are the
// kernels of zcu216_kernels.cpp.
//
#include "zcu216_otw.hpp"
#include <uhd/exception.hpp>

namespace zcu216 {

namespace {
const otw_info kFormats[] = {
    {otw_t::sc16, "sc16", 4, 1, 16},
    {otw_t::sc8, "sc8", 2, 2, 32},
    {otw_t::sc12, "sc12", 3, 4, 64},
    {otw_t::fc32, "fc32", 8, 1, 8},
};
} // namespace

const otw_info& otw_lookup(const std::string& name)
{
    if (name.empty())
        return kFormats[0];
    for (const auto& f : kFormats)
        if (name == f.name)
            return f;
    throw uhd::value_error("ZCU216: otw_format '" + name
                           + "' is not one of sc16, sc8, sc12, fc32 (Protocol §10)");
}

} // namespace zcu216
