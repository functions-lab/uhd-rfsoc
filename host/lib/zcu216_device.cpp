//
// uhd_zcu216 -- the uhd::device: discovery registration, claim, and the
// legacy (non-RFNoC) property tree that multi_usrp_impl and uhd_usrp_probe
// walk. Pattern follows pothosware/SoapyUHD UHDSoapyDevice.cpp.
//
#include "zcu216_common.hpp"
#include "zcu216_dpdk.hpp"
#include "zcu216_otw.hpp"
#include "zcu216_pool.hpp"
#include "zcu216_rx_streamer.hpp"
#include "zcu216_tx_streamer.hpp"
#include <uhd/device.hpp>
#include <uhd/property_tree.hpp>
#include <uhd/types/ranges.hpp>
#include <uhd/types/sensors.hpp>
#include <uhd/types/stream_cmd.hpp>
#include <uhd/types/time_spec.hpp>
#include <uhd/types/wb_iface.hpp>
#include <uhd/usrp/dboard_eeprom.hpp>
#include <uhd/usrp/dboard_iface.hpp>
#include <uhd/usrp/mboard_eeprom.hpp>
#include <uhd/usrp/subdev_spec.hpp>
#include <uhd/utils/static.hpp>
#include <algorithm>
#include <cctype>
#include <chrono>
#include <climits>
#include <cmath>
#include <complex>
#include <fstream>
#include <pthread.h>
#include <sched.h>
#include <set>
#include <thread>

using namespace uhd;

namespace zcu216 {

static sensor_value_t parse_sensor(const std::string& name, const std::string& reply)
{
    // "<type> <value> <unit>"; value may contain spaces for strings, unit may be empty
    const auto t = split(reply, ' ', true);
    if (t.empty() or t[0].empty())
        throw uhd::runtime_error("ZCU216: empty sensor reply for " + name);
    const std::string type = t[0];
    std::string value, unit;
    if (t.size() == 2)
        value = t[1];
    else if (t.size() >= 3) {
        unit = t.back();
        for (size_t i = 1; i + 1 < t.size(); i++)
            value += (i > 1 ? " " : "") + t[i];
    }
    if (type == "bool") {
        const bool b = value == "true" or value == "1" or value == "True" or value == "yes"
                       or value == "locked";
        return sensor_value_t(name, b, "true", "false");
    }
    if (type == "real")
        return sensor_value_t(name, parse_double(value, "sensor " + name), unit);
    if (type == "int")
        return sensor_value_t(name, int(parse_ll(value, "sensor " + name)), unit);
    return sensor_value_t(name, value, unit);
}

static meta_range_t rates_range(const std::vector<std::string>& toks)
{
    meta_range_t r;
    std::vector<double> v;
    for (const auto& t : toks)
        v.push_back(parse_double(t, "rate list"));
    std::sort(v.begin(), v.end());
    for (double x : v)
        r.push_back(range_t(x));
    if (r.empty())
        throw uhd::runtime_error("ZCU216: daemon reports no supported rates");
    return r;
}

static std::string fmt_stream_mode(stream_cmd_t::stream_mode_t m)
{
    switch (m) {
        case stream_cmd_t::STREAM_MODE_START_CONTINUOUS:
            return "start_cont";
        case stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS:
            return "stop_cont";
        case stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_DONE:
            return "num_done";
        case stream_cmd_t::STREAM_MODE_NUM_SAMPS_AND_MORE:
            return "num_more";
        default:
            throw uhd::value_error("ZCU216: bad stream mode");
    }
}

// ---------------------------------------------------------------------------
// §11 TX and RX beamformers: the daemon commands behind the tree nodes and the
// user registers. One bf_ctl per beamformer: TX = the *_bf* commands, user
// registers 0..31; RX = the *_rbf* commands (plus SHIFT), user registers
// 64..95. Same layout relative to the base: +0 enable, +1 angle (mdeg),
// +2 carrier (kHz), +3 spacing (nm), +4 shift (RX only), +15 LOAD the staged
// raw weights, +16+c raw weight c (c < 16).
// ---------------------------------------------------------------------------
class bf_ctl
{
public:
    static constexpr uint32_t kRxBase = 64, kMapSize = 32;
    static constexpr uint32_t kEnable = 0, kAngle = 1, kCarrier = 2, kSpacing = 3, kShift = 4,
                              kLoad = 15, kW0 = 16, kMaxW = 16;
    struct state
    {
        bool enable    = false;
        double angle   = std::nan(""); // degrees; NaN = raw weights / none
        double carrier = 0.0, spacing = 0.0;
        std::vector<std::complex<int>> w; // Q1.15, real/imag int16
        int shift = -1;                   // RX: SHIFT (get_rbf shift=); TX: -1
    };
    bf_ctl(std::shared_ptr<dev_state> st, bool rx)
        : _st(std::move(st)), _rx(rx), _cmd(rx ? "rbf" : "bf"), _what(rx ? "RX beamformer" : "TX beamformer")
    {
    }
    bool rx() const
    {
        return _rx;
    }
    uint32_t base() const
    {
        return _rx ? kRxBase : 0;
    }
    //! the LOADED build has it (info bf= / rbf=, re-read after every reload)
    bool present() const
    {
        return _rx ? _st->rbf.load() : _st->bf.load();
    }
    //! a clear error when the loaded build has no such beamformer
    void need() const
    {
        if (present())
            return;
        if (_rx)
            throw uhd::not_implemented_error("ZCU216: this " + std::to_string(_st->nchan)
                                             + "-channel build has no RX beamformer (Protocol §11: "
                                               "eth100g/rx_beamformer, in the N >= 2 builds that carry "
                                               "it; info rbf=0)");
        throw uhd::not_implemented_error("ZCU216: this " + std::to_string(_st->nchan)
                                         + "-channel build has no TX beamformer (Protocol "
                                           "§11: N >= 2 builds; info bf=0)");
    }

    //! `get_bf` / `get_rbf`: OK enable=..;angle_deg=..;carrier_freq=..;element_spacing=..;weights=re0,im0,..[;shift=..]
    state get()
    {
        const std::string cmd = "get_" + _cmd;
        const device_addr_t kv = parse_kv(_st->ctrl->call(cmd));
        state s;
        s.enable        = kv.get("enable", "0") == "1";
        const auto a    = kv.get("angle_deg", "none");
        s.angle         = (a == "none" or a.empty()) ? std::nan("") : parse_double(a, cmd + " angle_deg");
        s.carrier       = parse_double(kv.get("carrier_freq", "0"), cmd + " carrier_freq");
        s.spacing       = parse_double(kv.get("element_spacing", "0"), cmd + " element_spacing");
        const auto toks = split(kv.get("weights", ""), ',', false);
        for (size_t i = 0; i + 1 < toks.size(); i += 2)
            s.w.emplace_back(int(parse_ll(toks[i], cmd + " weight")), int(parse_ll(toks[i + 1], cmd + " weight")));
        if (kv.has_key("shift"))
            s.shift = int(parse_ll(kv["shift"], cmd + " shift"));
        return s;
    }
    bool set_enable(bool e)
    {
        const auto r = _st->ctrl->call_tokens("set_" + _cmd + "_enable " + (e ? "1" : "0"));
        return r.empty() ? e : r[0] == "1";
    }
    void set_angle(double deg)
    {
        _st->ctrl->call("set_" + _cmd + "_angle " + fmt_double(deg));
    }
    void set_params(double carrier, double spacing)
    {
        if (not(carrier > 0.0) or not(spacing > 0.0))
            throw uhd::value_error("ZCU216: " + _what + " carrier_freq and element_spacing must be > 0");
        _st->ctrl->call("set_" + _cmd + "_params " + fmt_double(carrier) + " " + fmt_double(spacing));
    }
    void set_weights(const std::vector<std::complex<int>>& w)
    {
        if (w.size() != _st->nchan)
            throw uhd::value_error("ZCU216: the " + _what + " takes " + std::to_string(_st->nchan)
                                   + " weights (one per channel), got " + std::to_string(w.size()));
        std::string req = "set_" + _cmd + "_weights";
        for (const auto& x : w)
            req += " " + std::to_string(x.real()) + " " + std::to_string(x.imag());
        _st->ctrl->call(req);
    }
    //! RX only: the beam is (sum_c x_c w[c]) >> (15 + shift), shift 0..15
    int set_shift(int sh)
    {
        if (not _rx)
            throw uhd::value_error("ZCU216: the TX beamformer has no shift");
        if (sh < 0 or sh > 15)
            throw uhd::value_error("ZCU216: RX beamformer shift " + std::to_string(sh) + " not in 0..15");
        const auto r = _st->ctrl->call_tokens("set_rbf_shift " + std::to_string(sh));
        return r.empty() ? sh : int(parse_ll(r[0], "set_rbf_shift"));
    }
    //! complex<double> -> Q1.15 the way the daemon quantises steering weights:
    //! round(x * 32767), saturated to int16
    static int q15(double x)
    {
        if (x != x)
            return 0;
        return int(std::max(-32768.0, std::min(32767.0, std::nearbyint(x * 32767.0))));
    }

    // ---- the user register map (§11), multi_usrp::set_user_register and
    //      get_user_settings_iface(chan)->peek32/poke32; `r` = addr - base()
    void poke(uint32_t r, uint32_t data)
    {
        need();
        std::lock_guard<std::mutex> l(_m);
        if (r == kEnable) {
            set_enable(data & 1);
        } else if (r == kAngle) {
            set_angle(double(int32_t(data)) / 1000.0);
        } else if (r == kCarrier or r == kSpacing) {
            const state s = get();
            if (r == kCarrier)
                set_params(double(data) * 1e3, s.spacing);
            else
                set_params(s.carrier, double(data) * 1e-9);
        } else if (_rx and r == kShift) {
            set_shift(int(data));
        } else if (r == kLoad) {
            _load_staged();
            set_weights(_staged);
            _staged_valid = false;
        } else if (r >= kW0 and r < kW0 + std::min<uint32_t>(kMaxW, uint32_t(_st->nchan))) {
            _load_staged();
            _staged[r - kW0] = std::complex<int>(int16_t(data & 0xFFFF), int16_t(data >> 16));
        } else {
            throw uhd::value_error("ZCU216: no " + _what + " user register " + std::to_string(base() + r) + " ("
                                   + _map_desc() + ")");
        }
    }
    uint32_t peek(uint32_t r)
    {
        need();
        std::lock_guard<std::mutex> l(_m);
        if (r == kLoad)
            return uint32_t(_st->nchan);
        const state s = get();
        switch (r) {
            case kEnable:
                return s.enable ? 1u : 0u;
            case kAngle:
                return s.angle == s.angle ? uint32_t(int32_t(std::lround(s.angle * 1000.0))) : 0x80000000u;
            case kCarrier:
                return uint32_t(std::llround(s.carrier / 1e3));
            case kSpacing:
                return uint32_t(std::llround(s.spacing * 1e9));
            default:
                break;
        }
        if (_rx and r == kShift)
            return uint32_t(s.shift);
        if (r >= kW0 and r < kW0 + std::min<size_t>(kMaxW, s.w.size())) {
            const auto x = s.w[r - kW0];
            return (uint32_t(uint16_t(int16_t(x.real())))) | (uint32_t(uint16_t(int16_t(x.imag()))) << 16);
        }
        throw uhd::value_error("ZCU216: no " + _what + " user register " + std::to_string(base() + r) + " ("
                               + _map_desc() + ")");
    }

private:
    std::string _map_desc() const
    {
        const uint32_t b = base();
        auto a           = [b](uint32_t r) { return std::to_string(b + r); };
        return a(kEnable) + " enable, " + a(kAngle) + " angle mdeg, " + a(kCarrier) + " carrier kHz, "
               + a(kSpacing) + " spacing nm, " + (_rx ? a(kShift) + " shift, " : std::string()) + a(kLoad)
               + " LOAD, " + a(kW0) + ".." + a(kW0 + std::min<uint32_t>(kMaxW, uint32_t(_st->nchan)) - 1)
               + " raw weights";
    }
    void _load_staged()
    {
        if (_staged_valid)
            return;
        _staged = get().w;
        _staged.resize(_st->nchan, std::complex<int>(32767, 0));
        _staged_valid = true;
    }
    std::shared_ptr<dev_state> _st;
    const bool _rx;
    const std::string _cmd, _what;
    std::mutex _m;
    std::vector<std::complex<int>> _staged; // raw weights written to +16+c, until LOAD (+15)
    bool _staged_valid = false;
};

//! The whole user register space: 0..31 the TX beamformer, 64..95 the RX one.
//! multi_usrp::set_user_register lands in poke; get_user_settings_iface(chan)
//! (below) reads it back through peek.
class bf_regs
{
public:
    bf_regs(std::shared_ptr<bf_ctl> tx, std::shared_ptr<bf_ctl> rx) : _tx(std::move(tx)), _rx(std::move(rx)) {}
    void poke(uint32_t addr, uint32_t data)
    {
        bf_ctl& c = _route(addr);
        c.poke(addr - c.base(), data);
    }
    uint32_t peek(uint32_t addr)
    {
        bf_ctl& c = _route(addr);
        return c.peek(addr - c.base());
    }

private:
    bf_ctl& _route(uint32_t addr)
    {
        if (addr < bf_ctl::kMapSize)
            return *_tx;
        if (addr >= bf_ctl::kRxBase and addr < bf_ctl::kRxBase + bf_ctl::kMapSize)
            return *_rx;
        throw uhd::value_error("ZCU216: no user register " + std::to_string(addr)
                               + " (Protocol §11: 0..31 TX beamformer, 64..95 RX beamformer)");
    }
    std::shared_ptr<bf_ctl> _tx, _rx;
};

//! get_user_settings_iface(chan): the same register map, readable (UHD 4.6's
//! multi_usrp has set_user_register but no get_user_register; peek32 here is
//! the read-back, C++ only -- Python reads the tree: get_tree().access_*)
class bf_user_iface : public uhd::wb_iface
{
public:
    explicit bf_user_iface(std::shared_ptr<bf_regs> c) : _c(std::move(c)) {}
    void poke32(const wb_addr_type addr, const uint32_t data) override
    {
        _c->poke(addr, data);
    }
    uint32_t peek32(const wb_addr_type addr) override
    {
        return _c->peek(addr);
    }

private:
    std::shared_ptr<bf_regs> _c;
};

class zcu216_device : public uhd::device
{
public:
    explicit zcu216_device(const device_addr_t& args);
    ~zcu216_device() override;
    rx_streamer::sptr get_rx_stream(const stream_args_t& args) override;
    tx_streamer::sptr get_tx_stream(const stream_args_t& args) override;
    bool recv_async_msg(async_metadata_t& md, double timeout) override;

private:
    //! Protocol §9: `set_channels <N>` (device arg channels=N, default 1)
    //! before `info` is trusted. A daemon without the command is a 1-channel
    //! daemon: fall back to N = 1.
    void _select_channels(const device_addr_t& args);
    //! the conversion worker pool (rx_workers=, worker_cpus=, worker_spin_us=,
    //! par_min_slots=); none with rx_workers=0
    void _make_pool(const device_addr_t& args);
    //! the application's threads off the lcores and the workers (app_cpus=)
    void _place_app(const device_addr_t& args);
    //! CPUs the conversion workers are pinned to (_make_pool)
    std::set<unsigned> _worker_cpus;
    void _build_tree(const device_addr_t& info);
    void _build_chan(bool rx, size_t ch);
    //! §11: /mboards/0/{tx_beamformer,beamformer,rx_beamformer}/* and the
    //! user registers
    void _build_bf();
    //! the beamformer nodes of `c` under `b` (TX: also under the alias)
    void _build_bf_nodes(const fs_path& b, std::shared_ptr<bf_ctl> c);

    std::shared_ptr<dev_state> _st;
    std::shared_ptr<bf_ctl> _bf, _rbf;
    std::mutex _streamers_mutex;
    std::vector<std::weak_ptr<rx_streamer_impl>> _rx_streamers;
    std::vector<std::weak_ptr<tx_streamer_impl>> _tx_streamers;
    std::weak_ptr<tx_streamer_impl> _last_tx;

    //! per converter channel (physical): the tune request's RF and DSP parts
    //! (Protocol §3b: the daemon folds them into the one NCO), gain, antenna
    struct fe_cache
    {
        double freq = 0.0, dsp = 0.0, gain = 0.0;
        std::string ant;
    };
    std::vector<fe_cache> _rx_fe, _tx_fe;
    //! subdev spec: multi_usrp channel i (= stream channel i, DSP i) is the
    //! converter channel map[i] (frontend A:map[i]); identity by default
    std::vector<size_t> _rx_map, _tx_map;
    std::mutex _map_mutex;
    size_t _phys(bool rx, size_t chan)
    {
        std::lock_guard<std::mutex> l(_map_mutex);
        const auto& m = rx ? _rx_map : _tx_map;
        return chan < m.size() ? m[chan] : chan;
    }
    //! stream args channels (multi_usrp channels) -> converter channels
    stream_args_t _map_args(bool rx, const stream_args_t& in);
    double _sc_tick_rate = 0.0; // tick rate from the set_channels reply
    //! set_command_time(): tune and gain requests carry " at=<ticks>" (§3c)
    std::mutex _cmd_mutex;
    time_spec_t _cmd_time{0.0};
    std::string _at();
    bool _warned_pps = false;
    //! device arg pps_emulation (default 1): no PPS input exists; 0 makes the
    //! PPS calls throw instead of emulating them
    bool _pps_emulation = true;
};

zcu216_device::zcu216_device(const device_addr_t& args)
{
    _type = device::USRP;
    _st   = std::make_shared<dev_state>();
    _st->args = args;
    if (not args.has_key("addr"))
        throw uhd::key_error("ZCU216: device args need addr=<board management IP>");
    const auto ctrl_port = uint16_t(args.cast<int>("ctrl_port", kCtrlPort));
    const double tmo     = args.cast<double>("ctrl_timeout", 10.0);
    _st->rate_timeout    = args.cast<double>("rate_timeout", 120.0);
    ZLOG_INFO("Connecting to ZCU216 daemon at " << args["addr"] << ":" << ctrl_port);
    _st->ctrl = std::make_shared<ctrl_client>(args["addr"], ctrl_port, tmo);
    try {
        _st->ctrl->call("claim");
    } catch (const uhd::runtime_error& e) {
        throw uhd::runtime_error(std::string(e.what())
                                 + " -- the ZCU216 is in use by another UHD session");
    }
    try {
        _select_channels(args);
        const device_addr_t info = parse_kv(_st->ctrl->call("info"));
        if (info.get("version", "1") != "1")
            ZLOG_WARN("Daemon speaks protocol version " << info["version"]
                                                        << "; this module implements 1");
        _st->serial    = info.get("serial", args.get("serial", "unknown"));
        // The FPGA data IP is the board's configuration (Protocol §1), learned
        // here; data_ip= overrides it (it must then be what the FPGA answers ARP for).
        _st->data_ip   = args.get("data_ip", info.get("data_ip", ""));
        if (_st->data_ip.empty())
            throw uhd::runtime_error("ZCU216: the daemon reports no FPGA data IP (set data_ip in "
                                     "the board's zcu216_uhd.conf or start the daemon with "
                                     "--data-ip), and no data_ip= device arg was given");
        _st->data_mac  = info.get("data_mac", "");
        _st->apply_info(info); // tick rate, beat, spp, mtu, §10 formats, §11 bf/rbf
        if (_st->tick_rate <= 0.0)
            throw uhd::runtime_error("ZCU216: daemon reports no tick_rate");
        // §3: the format the client streams in, declared with set_rx_rate
        if (args.has_key("otw"))
            _st->set_cur_otw(otw_lookup(args["otw"]).name);
        if (_sc_tick_rate > 0.0 and std::abs(_sc_tick_rate - _st->tick_rate) > 1.0)
            ZLOG_WARN("set_channels reported tick rate " << _sc_tick_rate / 1e6
                                                         << " MHz but info says "
                                                         << _st->tick_rate / 1e6
                                                         << " MHz; using info");
        // Protocol §9: the build carries N channels in each direction, all in
        // one stream. num_rx/num_tx from info must agree with N.
        const size_t n_rx = size_t(parse_ll(info.get("num_rx", "1"), "num_rx"));
        const size_t n_tx = size_t(parse_ll(info.get("num_tx", "1"), "num_tx"));
        if (n_rx != _st->nchan or n_tx != _st->nchan)
            ZLOG_WARN("Daemon reports num_rx=" << n_rx << " num_tx=" << n_tx << " for a "
                                               << _st->nchan
                                               << "-channel build; using "
                                               << _st->nchan);
        _st->num_rx      = _st->nchan;
        _st->num_tx      = _st->nchan;
        for (size_t ch = 0; ch < _st->num_rx; ch++)
            _st->rx_rate.emplace_back(std::make_unique<std::atomic<double>>(0.0));
        for (size_t ch = 0; ch < _st->num_tx; ch++)
            _st->tx_rate.emplace_back(std::make_unique<std::atomic<double>>(0.0));
        _st->refresh_rates();
        const uint64_t tpsamp = _st->ticks_per_sample(_st->get_rx_rate(0));
        if (_st->nchan > 1 and tpsamp % _st->nchan)
            ZLOG_WARN("tick rate " << _st->tick_rate.load() << " / per-channel rate "
                                   << _st->get_rx_rate(0) << " is not a multiple of N="
                                   << _st->nchan << " (Protocol §9: one tick per slot)");
        // The DPDK data plane (zcu216_dpdk.hpp) carries every sample packet.
        // Opened here so that a missing privilege/hugepage/port shows up at
        // make(), not when streaming starts.
        for (const char* k : {"use_dpdk", "recv_buff_size", "send_buff_size"})
            if (args.has_key(k))
                ZLOG_WARN("Device arg " << k << " is obsolete and ignored: DPDK is the only "
                                               "sample transport (host/README.md)");
        if (_st->data_ip.compare(0, 4, "127.") == 0)
            throw uhd::value_error("ZCU216: data IP " + _st->data_ip
                                   + " is loopback, but samples travel over DPDK, which needs a "
                                     "NIC port (the board's 100G data IP).");
        _st->dpdk = dpdk::open_port(args, _st->host_data_iface(), _st->mtu);
        _make_pool(args);
        _place_app(args);
        _rx_streamers.resize(_st->num_rx);
        _tx_streamers.resize(_st->num_tx);
        _build_tree(info);
        ZLOG_INFO("ZCU216 " << _st->serial << " (" << info.get("fpga", "?") << "): "
                            << _st->num_rx << " RX / " << _st->num_tx << " TX"
                            << (_st->nchan > 1 ? " (one interleaved stream)" : "")
                            << ", tick rate " << _st->tick_rate / 1e6 << " MHz, "
                            << _st->get_rx_rate(0) / 1e6 << " MS/s per channel, "
                            << _st->beat_slots() << "-slot beat, data IP " << _st->data_ip
                            << (_st->bf ? ", TX beamformer" : "")
                            << (_st->rbf ? ", RX beamformer" : "")
                            << (_st->pool ? ", conversion pool: " + _st->pool->desc() : ""));
    } catch (...) {
        try {
            _st->ctrl->call("unclaim");
        } catch (...) {
        }
        throw;
    }
}

void zcu216_device::_select_channels(const device_addr_t& args)
{
    const long long want = parse_ll(args.get("channels", "1"), "channels");
    if (want != 1 and want != 2 and want != 4 and want != 8 and want != 16)
        throw uhd::value_error("ZCU216: channels=" + std::to_string(want)
                               + " is not a build (1, 2, 4, 8 or 16)");
    std::vector<std::string> rep;
    // otw=: declare the format with the choice of build (§9), so a loaded
    // build that only that format fits (an sc8-max build) is kept instead of
    // replaced by the sc16 default and loaded again by the next set_*_rate
    const std::string otw = args.has_key("otw") ? otw_lookup(args["otw"]).name : "";
    const std::string cmd = "set_channels " + std::to_string(want);
    try {
        // may reload the FPGA (seconds): same budget as a rate change (§8)
        try {
            rep = _st->ctrl->call_tokens(cmd + (otw.empty() ? "" : " otw=" + otw), _st->rate_timeout);
        } catch (const uhd::runtime_error& e) {
            // a daemon from before set_channels otw=: the plain form
            if (otw.empty() or std::string(e.what()).find("usage: set_channels") == std::string::npos)
                throw;
            rep = _st->ctrl->call_tokens(cmd, _st->rate_timeout);
        }
    } catch (const uhd::runtime_error& e) {
        if (std::string(e.what()).find("unknown command") == std::string::npos)
            throw uhd::runtime_error(std::string(e.what()) + " -- cannot select the "
                                     + std::to_string(want) + "-channel build");
        if (want != 1)
            ZLOG_WARN("The daemon does not know set_channels (a 1-channel daemon); "
                      "channels=" << want << " ignored, using 1 channel");
        _st->nchan = 1;
        return;
    }
    if (rep.empty())
        throw uhd::runtime_error("ZCU216: empty reply to set_channels");
    const long long n = parse_ll(rep[0], "set_channels N");
    if (n != want)
        throw uhd::runtime_error("ZCU216: asked for " + std::to_string(want)
                                 + " channels, daemon set " + rep[0]);
    if (rep.size() >= 2)
        _sc_tick_rate = parse_double(rep[1], "set_channels tick_rate");
    _st->nchan = size_t(n);
}

zcu216_device::~zcu216_device()
{
    std::vector<std::shared_ptr<rx_streamer_impl>> rx;
    std::vector<std::shared_ptr<tx_streamer_impl>> tx;
    {
        std::lock_guard<std::mutex> l(_streamers_mutex);
        for (auto& w : _rx_streamers)
            if (auto s = w.lock())
                rx.push_back(s);
        for (auto& w : _tx_streamers)
            if (auto s = w.lock())
                tx.push_back(s);
    }
    for (auto& s : rx)
        s->shutdown();
    for (auto& s : tx)
        s->shutdown();
    // DPDK: the streamers' sessions are gone; this stops the port (flows and
    // queues released; the kernel netdev is unaffected). The EAL stays up for
    // the next make() in this process and is cleaned up at exit.
    _st->dpdk.reset();
    try {
        _st->ctrl->call("unclaim");
    } catch (const std::exception& e) {
        ZLOG_DEBUG("unclaim failed: " << e.what());
    }
}

stream_args_t zcu216_device::_map_args(bool rx, const stream_args_t& in)
{
    stream_args_t args = in;
    if (args.channels.empty())
        args.channels = {0};
    const size_t n = rx ? _st->num_rx : _st->num_tx;
    std::lock_guard<std::mutex> l(_map_mutex);
    const auto& m = rx ? _rx_map : _tx_map;
    for (auto& ch : args.channels) {
        if (ch >= m.size())
            throw uhd::index_error(std::string("ZCU216: ") + (rx ? "RX" : "TX") + " channel "
                                   + std::to_string(ch) + " out of range (the subdev spec has "
                                   + std::to_string(m.size()) + " of " + std::to_string(n) + ")");
        ch = m[ch];
    }
    return args;
}

rx_streamer::sptr zcu216_device::get_rx_stream(const stream_args_t& args_in)
{
    const stream_args_t args = _map_args(true, args_in);
    std::lock_guard<std::mutex> l(_streamers_mutex);
    // One stream per direction carries every channel (Protocol §9), and the
    // zero-copy rings deliver each packet to ONE streamer: a second streamer
    // on other channels cannot run beside the first. A new streamer that
    // shares a channel with the old one replaces it (an application
    // re-creating its streamer); one on a disjoint set while the old one is
    // still alive is refused with a clear message.
    std::vector<std::shared_ptr<rx_streamer_impl>> olds;
    for (auto& w : _rx_streamers) {
        auto old = w.lock();
        if (old and std::find(olds.begin(), olds.end(), old) == olds.end())
            olds.push_back(old);
    }
    for (auto& old : olds) {
        bool overlap = false;
        for (size_t ch : old->device_channels())
            overlap |= std::find(args.channels.begin(), args.channels.end(), ch) != args.channels.end();
        if (not overlap) {
            std::string have, want;
            for (size_t ch : old->device_channels())
                have += (have.empty() ? "" : ",") + std::to_string(ch);
            for (size_t ch : args.channels)
                want += (want.empty() ? "" : ",") + std::to_string(ch);
            throw uhd::runtime_error(
                "ZCU216: an RX streamer for converter channel(s) " + have
                + " still exists; a second RX streamer (channel(s) " + want
                + ") cannot run beside it: the ZCU216 has ONE RX stream for all channels "
                  "(Protocol §9). Create one streamer with all the channels you need "
                  "(stream_args.channels), or destroy the first one before creating another.");
        }
    }
    for (auto& w : _rx_streamers)
        w.reset();
    for (auto& old : olds) {
        ZLOG_WARN("New RX streamer: shutting down the previous one (the ZCU216 has one "
                  "RX stream for all channels; use one streamer for several channels)");
        old->shutdown();
    }
    auto s = std::make_shared<rx_streamer_impl>(_st, args);
    for (size_t ch : s->device_channels())
        _rx_streamers[ch] = s;
    return s;
}

tx_streamer::sptr zcu216_device::get_tx_stream(const stream_args_t& args_in)
{
    const stream_args_t args = _map_args(false, args_in);
    std::lock_guard<std::mutex> l(_streamers_mutex);
    // One stream per direction carries every channel (Protocol §9), so a new
    // streamer replaces any existing one, whatever its channels.
    std::vector<std::shared_ptr<tx_streamer_impl>> olds;
    for (auto& w : _tx_streamers) {
        auto old = w.lock();
        if (old and std::find(olds.begin(), olds.end(), old) == olds.end())
            olds.push_back(old);
        w.reset();
    }
    for (auto& old : olds) {
        ZLOG_WARN("New TX streamer: shutting down the previous one (the ZCU216 has one "
                  "TX stream for all channels; use one streamer for several channels)");
        old->shutdown();
    }
    auto s = std::make_shared<tx_streamer_impl>(_st, args);
    for (size_t ch : s->device_channels())
        _tx_streamers[ch] = s;
    _last_tx = s;
    return s;
}

bool zcu216_device::recv_async_msg(async_metadata_t& md, double timeout)
{
    std::shared_ptr<tx_streamer_impl> s;
    {
        std::lock_guard<std::mutex> l(_streamers_mutex);
        s = _last_tx.lock();
    }
    if (s)
        return s->recv_async_msg(md, timeout);
    std::this_thread::sleep_for(std::chrono::duration<double>(std::max(0.0, timeout)));
    return false;
}

// ---------------------------------------------------------------------------
// property tree
// ---------------------------------------------------------------------------
void zcu216_device::_build_tree(const device_addr_t& info)
{
    _tree                       = property_tree::make();
    auto st                     = _st;
    auto ctrl                   = _st->ctrl;
    const fs_path mb            = "/mboards/0";
    const std::string product   = info.get("product", "zcu216");
    const std::string name      = info.get("name", "zcu216");

    _tree->create<std::string>("/name").set("ZCU216 RFSoC (uhd_zcu216)");
    _tree->create<std::string>(mb / "name").set("ZCU216");
    _tree->create<std::string>(mb / "codename").set("zcu216");

    usrp::mboard_eeprom_t eeprom;
    eeprom["name"]    = name;
    eeprom["serial"]  = _st->serial;
    eeprom["product"] = product;
    _tree->create<usrp::mboard_eeprom_t>(mb / "eeprom")
        .set(eeprom)
        .add_coerced_subscriber([](const usrp::mboard_eeprom_t&) {});
    _tree->create<std::string>(mb / "fpga_version").set(info.get("fpga", "unknown"));
    _tree->create<std::string>(mb / "fw_version")
        .set("zcu216_uhd_daemon protocol " + info.get("version", "?"));

    _tree->create<double>(mb / "tick_rate")
        .set_coercer([st](double r) {
            if (std::abs(r - st->tick_rate) > 1.0)
                ZLOG_WARN("Master clock rate is fixed by the bitstream at "
                          << st->tick_rate / 1e6 << " MHz; ignoring " << r / 1e6 << " MHz");
            return st->tick_rate.load();
        })
        .set_publisher([st] { return st->tick_rate.load(); });
    // 100GbE, bytes/s
    _tree->create<double>(mb / "link_max_rate").set(12.5e9);

    // ---- time ----------------------------------------------------------
    auto get_ticks = [ctrl] { return parse_ll(ctrl->call("get_time"), "get_time"); };
    _tree->create<time_spec_t>(mb / "time/now")
        .set_publisher([st, get_ticks] {
            return time_spec_t::from_ticks(get_ticks(), st->tick_rate);
        })
        .add_coerced_subscriber([st, ctrl](const time_spec_t& t) {
            ctrl->call("set_time " + std::to_string(std::max(0LL, t.to_ticks(st->tick_rate))));
        });
    // There is no PPS input (mboard sensor pps_present = false). By default
    // the PPS is emulated: its edges are the whole seconds of device time.
    // "Last PPS" is the last whole second; set_time_next_pps(t) returns at
    // once and the daemon makes the time read t at the next whole second
    // (a timed set_time, §3c), like a USRP. set_time_unknown_pps() returns
    // after multi_usrp's own waits (<= 1 s for an edge, then 1 s) with the
    // time just past t. Device arg pps_emulation=0: these calls throw instead.
    _pps_emulation = parse_ll(_st->args.get("pps_emulation", "1"), "pps_emulation") != 0;
    const bool pps_emu = _pps_emulation;
    auto no_pps        = [] {
        throw uhd::runtime_error("ZCU216: no PPS input (sensor pps_present is false), and the "
                                 "device arg pps_emulation=0 disables the host emulation");
    };
    _tree->create<time_spec_t>(mb / "time/pps")
        .set_publisher([st, get_ticks, pps_emu, no_pps] {
            if (not pps_emu)
                no_pps();
            return time_spec_t(time_spec_t::from_ticks(get_ticks(), st->tick_rate).get_full_secs());
        })
        .add_coerced_subscriber([this, st, ctrl, get_ticks, pps_emu, no_pps](const time_spec_t& t) {
            if (not pps_emu)
                no_pps();
            if (not _warned_pps) {
                _warned_pps = true;
                ZLOG_INFO("No PPS on the ZCU216: set_time_next_pps() is emulated -- the PPS "
                          "edges are the whole seconds of device time (pps_emulation=0 to refuse)");
            }
            // the next emulated edge: the daemon sets the time AT it (§3c
            // timed set_time, exact to the AXI write) and we return at once,
            // like a USRP. A daemon without timed set_time: wait for the
            // edge here and set it then (accuracy ~ one control round trip).
            const long long tt   = std::max(0LL, t.to_ticks(st->tick_rate));
            const long long now  = get_ticks();
            const double rate    = st->tick_rate;
            const long long edge = (long long)((std::floor(double(now) / rate) + 1.0) * rate);
            try {
                ctrl->call("set_time " + std::to_string(tt) + " at=" + std::to_string(edge));
            } catch (const uhd::runtime_error&) {
                const double wait = double(edge - get_ticks()) / rate;
                if (wait > 0)
                    std::this_thread::sleep_for(std::chrono::duration<double>(wait));
                ctrl->call("set_time " + std::to_string(tt));
            }
        });
    // set_command_time(): the daemon runs later tune / gain requests when its
    // timekeeper reaches the time (Protocol §3c; ~1 ms accurate, all requests
    // with one command time applied together). Stream commands carry their
    // own time.
    _tree->create<time_spec_t>(mb / "time/cmd")
        .set(time_spec_t(0.0))
        .add_coerced_subscriber([this](const time_spec_t& t) {
            std::lock_guard<std::mutex> l(_cmd_mutex);
            _cmd_time = t;
        });

    // ---- clock / time source ------------------------------------------
    for (const std::string kind : {"clock", "time"}) {
        const std::vector<std::string> opts = ctrl->call_tokens("get_" + kind + "_sources");
        _tree->create<std::vector<std::string>>(mb / (kind + "_source") / "options").set(opts);
        _tree->create<std::string>(mb / (kind + "_source") / "value")
            .set_coercer([this, ctrl, kind, opts](const std::string& s) {
                // time source "external" = a PPS: there is none, but with the
                // PPS emulation on (default) it stands in for one, so apps that
                // select it before set_time_unknown_pps (rx_multi_samples
                // --sync pps) work; the source stays internal
                if (kind == "time" and s == "external" and _pps_emulation
                    and std::find(opts.begin(), opts.end(), s) == opts.end()) {
                    ZLOG_WARN("No PPS input on the ZCU216: time source 'external' is emulated "
                              "(the time source stays internal; pps_emulation=0 refuses it)");
                    return std::string("internal");
                }
                const auto r = ctrl->call_tokens("set_" + kind + "_source " + s);
                return r.empty() ? s : r[0];
            })
            .set_publisher([ctrl, kind] { return trim(ctrl->call("get_" + kind + "_source")); });
    }

    // ---- sensors -------------------------------------------------------
    _tree->create<int>(mb / "sensors"); // keep the directory even if empty
    for (const auto& s : ctrl->call_tokens("list_sensors")) {
        _tree->create<sensor_value_t>(mb / "sensors" / s).set_publisher([ctrl, s] {
            // a sensor the daemon cannot read (an older daemon: temp without
            // sysmon) reads "n/a" instead of failing usrp_list_sensors
            try {
                return parse_sensor(s, ctrl->call("get_sensor " + s));
            } catch (const uhd::runtime_error& e) {
                ZLOG_DEBUG("sensor " << s << ": " << e.what());
                return sensor_value_t(s, std::string("n/a"), "");
            }
        });
    }

    // ---- codecs, dboard ------------------------------------------------
    _tree->create<std::string>(mb / "rx_codecs/A/name").set("RFDC RF-ADC");
    _tree->create<int>(mb / "rx_codecs/A/gains");
    _tree->create<std::string>(mb / "tx_codecs/A/name").set("RFDC RF-DAC");
    _tree->create<int>(mb / "tx_codecs/A/gains");
    _tree->create<usrp::dboard_eeprom_t>(mb / "dboards/A/rx_eeprom").set(usrp::dboard_eeprom_t());
    _tree->create<usrp::dboard_eeprom_t>(mb / "dboards/A/tx_eeprom").set(usrp::dboard_eeprom_t());
    _tree->create<usrp::dboard_eeprom_t>(mb / "dboards/A/gdb_eeprom").set(usrp::dboard_eeprom_t());

    _rx_fe.resize(_st->num_rx);
    _tx_fe.resize(_st->num_tx);
    for (size_t ch = 0; ch < _st->num_rx; ch++)
        _rx_map.push_back(ch);
    for (size_t ch = 0; ch < _st->num_tx; ch++)
        _tx_map.push_back(ch);
    // GPIO: multi_usrp lists banks RXA/TXA for dboard A and reaches them
    // through dboards/A/iface. The ZCU216 has no GPIO behind the converters:
    // say so instead of "path not found".
    _tree->create<usrp::dboard_iface::sptr>(mb / "dboards/A/iface")
        .set_publisher([]() -> usrp::dboard_iface::sptr {
            throw uhd::not_implemented_error(
                "ZCU216: no GPIO -- the RFDC converters have no dboard GPIO banks "
                "(RXA/TXA are listed by multi_usrp for every dboard)");
        });
    for (size_t ch = 0; ch < _st->num_rx; ch++)
        _build_chan(true, ch);
    for (size_t ch = 0; ch < _st->num_tx; ch++)
        _build_chan(false, ch);
    if (_st->num_tx == 0) { // multi_usrp walks tx_dsps/tx_frontends unconditionally
        _tree->create<int>(mb / "tx_dsps");
        _tree->create<int>(mb / "dboards/A/tx_frontends");
    }
    if (_st->num_rx == 0) {
        _tree->create<int>(mb / "rx_dsps");
        _tree->create<int>(mb / "dboards/A/rx_frontends");
    }

    // ---- subdev specs: any order / subset of the frontends A:0 .. A:N-1.
    // multi_usrp channel i = frontend spec[i] = DSP i = stream channel i,
    // which this module maps to converter channel spec[i] (e.g. "A:1 A:0"
    // swaps channels 0 and 1 for every call and every streamer made after).
    for (const bool rx : {true, false}) {
        const size_t n = rx ? _st->num_rx : _st->num_tx;
        std::string spec;
        for (size_t ch = 0; ch < n; ch++)
            spec += (ch ? " A:" : "A:") + std::to_string(ch);
        _tree->create<usrp::subdev_spec_t>(mb / (rx ? "rx_subdev_spec" : "tx_subdev_spec"))
            .set_coercer([this, n, rx](const usrp::subdev_spec_t& s) {
                if (s.empty())
                    throw uhd::value_error("ZCU216: empty subdev spec");
                std::vector<size_t> m;
                for (size_t i = 0; i < s.size(); i++) {
                    long long fe = -1;
                    try {
                        fe = std::stoll(s[i].sd_name);
                    } catch (const std::exception&) {
                    }
                    if (s[i].db_name != "A" or fe < 0 or size_t(fe) >= n
                        or std::to_string(fe) != s[i].sd_name
                        or std::find(m.begin(), m.end(), size_t(fe)) != m.end())
                        throw uhd::value_error(
                            std::string("ZCU216: ") + (rx ? "RX" : "TX") + " subdev spec '"
                            + s.to_string() + "': each entry must be a distinct frontend A:0 .. A:"
                            + std::to_string(n - 1));
                    m.push_back(size_t(fe));
                }
                std::lock_guard<std::mutex> l(_map_mutex);
                (rx ? _rx_map : _tx_map) = m;
                return s;
            })
            .set(usrp::subdev_spec_t(spec));
    }
    _build_bf();
}

std::string zcu216_device::_at()
{
    std::lock_guard<std::mutex> l(_cmd_mutex);
    if (_cmd_time == time_spec_t(0.0))
        return "";
    return " at=" + std::to_string(std::max(0LL, _cmd_time.to_ticks(_st->tick_rate)));
}

//! USRP antenna names an application may pass: each converter channel has ONE
//! port, so these select it (the daemon accepts the same, Protocol §3)
static bool antenna_alias(bool rx, const std::string& a)
{
    std::string u = a;
    for (auto& ch : u)
        ch = char(std::toupper((unsigned char)ch));
    static const std::vector<std::string> rx_names{
        "RX", "RX1", "RX2", "TX/RX", "RX/TX", "TRX", "IN", "RF", "A"};
    static const std::vector<std::string> tx_names{
        "TX", "TX1", "TX2", "TX/RX", "RX/TX", "TRX", "OUT", "RF", "A"};
    const auto& v = rx ? rx_names : tx_names;
    return std::find(v.begin(), v.end(), u) != v.end();
}

void zcu216_device::_build_chan(bool rx, size_t ch)
{
    auto st                = _st;
    auto ctrl              = _st->ctrl;
    const std::string c    = std::to_string(ch);
    const std::string dir  = rx ? "rx" : "tx";
    const fs_path mb       = "/mboards/0";
    // DSP ch belongs to multi_usrp channel ch (-> converter _phys(rx, ch));
    // frontend ch IS converter channel ch (the subdev spec picks frontends)
    const fs_path dsp      = mb / (dir + "_dsps") / c;
    const fs_path fe       = mb / "dboards/A" / (dir + "_frontends") / c;
    fe_cache& cache        = rx ? _rx_fe[ch] : _tx_fe[ch];
    auto& rate_cache       = rx ? *_st->rx_rate[ch] : *_st->tx_rate[ch];

    // ---- tune requests (Protocol §3b): the frontend holds the RF part, the
    // DSP the CORDIC part; the daemon programs the one NCO to rf - dsp (RX) /
    // rf + dsp (TX) and replies with both parts in effect. With
    // set_command_time() the request carries at=<ticks> (§3c).
    auto tune = [this, ctrl, dir, rx](size_t p, double rf, double dsp) {
        fe_cache& fc     = rx ? _rx_fe[p] : _tx_fe[p];
        std::string line = "set_" + dir + "_freq " + std::to_string(p) + " " + fmt_double(rf);
        if (dsp != 0.0 or fc.dsp != 0.0) // a daemon from before §3b knows no dsp=
            line += " dsp=" + fmt_double(dsp);
        line += _at();
        const auto t = ctrl->call_tokens(line);
        if (t.empty())
            throw uhd::runtime_error("ZCU216: empty reply to " + line);
        fc.freq = parse_double(t[0], "tuned rf");
        fc.dsp  = t.size() > 1 ? parse_double(t[1], "tuned dsp") : 0.0;
    };

    // ---- DSP: sample rate, and the DSP part of a tune request (+-rate/2)
    const meta_range_t rates = rates_range(ctrl->call_tokens("get_" + dir + "_rates " + c));
    _tree->create<meta_range_t>(dsp / "rate/range").set(rates);
    _tree->create<double>(dsp / "rate/value")
        .set_coercer([st, rx, ch](double r) { return st->set_rate(rx, ch, r); })
        .set_publisher([&rate_cache] { return rate_cache.load(); });
    _tree->create<meta_range_t>(dsp / "freq/range").set_publisher([&rate_cache] {
        const double r = rate_cache.load();
        return meta_range_t(-r / 2.0, r / 2.0);
    });
    _tree->create<double>(dsp / "freq/value")
        .set_coercer([this, rx, ch, tune, &rate_cache](double f) {
            const size_t p  = _phys(rx, ch);
            fe_cache& fc    = rx ? _rx_fe[p] : _tx_fe[p];
            const double r2 = rate_cache.load() / 2.0;
            f               = std::max(-r2, std::min(r2, f));
            if (f != fc.dsp)
                tune(p, fc.freq, f);
            return fc.dsp;
        })
        .set_publisher([this, rx, ch] {
            const size_t p = _phys(rx, ch);
            return (rx ? _rx_fe[p] : _tx_fe[p]).dsp;
        });
    if (rx) {
        _tree->create<stream_cmd_t>(dsp / "stream_cmd")
            .add_coerced_subscriber([this, st, ctrl, ch](const stream_cmd_t& cmd) {
                // One stream for all channels (§9), and at most one RX
                // streamer: multi_usrp's issue_stream_cmd(ALL_CHANS) visits
                // every channel, so only the streamer's first channel issues
                // it, and channels outside the streamer do nothing.
                const size_t p = _phys(true, ch);
                std::shared_ptr<rx_streamer_impl> s;
                {
                    std::lock_guard<std::mutex> l(_streamers_mutex);
                    for (auto& w : _rx_streamers)
                        if ((s = w.lock()))
                            break;
                }
                if (s) {
                    if (s->device_channels().front() == p)
                        s->issue_stream_cmd(cmd);
                    return;
                }
                if (st->nchan > 1 and ch != 0)
                    return;
                ZLOG_WARN("issue_stream_cmd on channel " << ch
                                                         << " without an RX streamer; forwarding");
                ctrl->call("stream_cmd " + std::to_string(p) + " " + fmt_stream_mode(cmd.stream_mode)
                           + " " + std::to_string(uint64_t(cmd.num_samps) * st->nchan) + " "
                           + (cmd.stream_now ? "1 0" : "0 " + std::to_string(std::max(0LL, cmd.time_spec.to_ticks(st->tick_rate)))));
            });
    }

    // ---- frontend -------------------------------------------------------
    _tree->create<std::string>(fe / "name").set(std::string(rx ? "RF-ADC" : "RF-DAC") + " ch" + c);
    _tree->create<std::string>(fe / "connection").set("IQ");
    _tree->create<bool>(fe / "use_lo_offset").set(false);
    _tree->create<bool>(fe / "enabled").set(true);

    const auto fr = ctrl->call_tokens("get_" + dir + "_freq_range " + c);
    if (fr.size() < 2)
        throw uhd::runtime_error("ZCU216: bad get_" + dir + "_freq_range reply");
    const meta_range_t frange(parse_double(fr[0], "freq start"), parse_double(fr[1], "freq stop"));
    _tree->create<meta_range_t>(fe / "freq/range").set(frange);
    cache.freq = ctrl->call_double("get_" + dir + "_freq " + c);
    try {
        cache.dsp = ctrl->call_double("get_" + dir + "_dsp_freq " + c);
    } catch (const uhd::runtime_error&) {
        cache.dsp = 0.0; // a daemon from before §3b
    }
    auto set_rf = [tune, ch, &cache](double f) {
        tune(ch, f, cache.dsp);
        return cache.freq;
    };
    auto get_rf = [&cache] { return cache.freq; };
    _tree->create<double>(fe / "freq/value").set_coercer(set_rf).set_publisher(get_rf);
    // multi_usrp::get_{rx,tx}_lo_freq() of UHD 4.6 reads "freq/ value" (sic)
    // on a frontend without LOs; keep that path working too
    _tree->create<double>(fe / "freq" / " value").set_coercer(set_rf).set_publisher(get_rf);

    // ---- LOs: the one "LO" is the converter's NCO (it runs on the tile's
    // sample clock: source internal, no export). Its frequency is the tune
    // request's RF part, like the frontend's freq/value.
    for (const std::string lo : {"all", "NCO"}) {
        const fs_path l = fe / "los" / lo;
        _tree->create<std::vector<std::string>>(l / "source/options")
            .set(std::vector<std::string>{"internal"});
        _tree->create<std::string>(l / "source/value")
            .set_coercer([](const std::string& v) {
                if (v != "internal")
                    throw uhd::value_error("ZCU216: the NCO runs from the converter tile clock; "
                                           "LO source '" + v + "' is not available (internal only)");
                return v;
            })
            .set("internal");
        _tree->create<bool>(l / "export")
            .set_coercer([](bool e) {
                if (e)
                    throw uhd::value_error("ZCU216: the NCO cannot be exported");
                return false;
            })
            .set(false);
    }
    _tree->create<double>(fe / "los/NCO/freq/value").set_coercer(set_rf).set_publisher(get_rf);
    _tree->create<meta_range_t>(fe / "los/NCO/freq/range").set(frange);

    // Bandwidth: the (complex) sample rate, fs / the decimation or
    // interpolation factor in force -- the RFDC Gen3 filters' -3 dB width is
    // 0.96 x it at every factor (measured with benchmark/rate_bandwidth.py). It
    // follows the sample rate, so setting it only reads it back.
    _tree->create<double>(fe / "bandwidth/value")
        .set_coercer([&rate_cache](double) { return rate_cache.load(); })
        .set_publisher([&rate_cache] { return rate_cache.load(); });
    _tree->create<meta_range_t>(fe / "bandwidth/range").set_publisher([&rate_cache] {
        return meta_range_t(rate_cache.load(), rate_cache.load());
    });

    const std::string gname = rx ? "DSA" : "VOP";
    const auto gr = ctrl->call_tokens("get_" + dir + "_gain_range " + c);
    if (gr.size() < 2)
        throw uhd::runtime_error("ZCU216: bad get_" + dir + "_gain_range reply");
    double step = gr.size() >= 3 ? parse_double(gr[2], "gain step") : 1.0;
    if (step <= 0.0) // gain_group divides by the step
        step = 0.01;
    _tree->create<meta_range_t>(fe / "gains" / gname / "range")
        .set(meta_range_t(parse_double(gr[0], "gain min"), parse_double(gr[1], "gain max"), step));
    cache.gain = ctrl->call_double("get_" + dir + "_gain " + c);
    _tree->create<double>(fe / "gains" / gname / "value")
        .set_coercer([this, ctrl, dir, c, &cache](double g) {
            cache.gain = ctrl->call_double("set_" + dir + "_gain " + c + " " + fmt_double(g) + _at());
            return cache.gain;
        })
        .set_publisher([&cache] { return cache.gain; });

    // ---- antenna: one port; the usual USRP names select it, the real name
    // is reported
    if (rx) {
        cache.ant = trim(ctrl->call("get_rx_antenna " + c));
        if (cache.ant.empty())
            cache.ant = "RX";
    } else {
        cache.ant = "TX"; // the module never sends a TX antenna command
    }
    _tree->create<std::vector<std::string>>(fe / "antenna/options")
        .set(std::vector<std::string>{cache.ant});
    _tree->create<std::string>(fe / "antenna/value")
        .set_coercer([rx, &cache](const std::string& a) {
            if (a != cache.ant and not antenna_alias(rx, a))
                throw uhd::value_error("ZCU216: " + std::string(rx ? "RX" : "TX") + " antenna '" + a
                                       + "' does not exist; the only port is '" + cache.ant
                                       + "' (aliases: RX2, TX/RX, " + (rx ? "RX1" : "TX1") + ", ...)");
            return cache.ant;
        })
        .set_publisher([&cache] { return cache.ant; });

    // lo_locked: the NCO runs on the converter tile's clock, so it is locked
    // when that tile's PLL is (or, PLL bypassed, its clock was detected):
    // the daemon reads it per channel (§3). An older daemon: the mboard's
    // adc/dac_pll_locked sensor.
    _tree->create<sensor_value_t>(fe / "sensors/lo_locked").set_publisher([ctrl, dir, c] {
        std::string r;
        try {
            r = ctrl->call("get_" + dir + "_lo_locked " + c);
        } catch (const uhd::runtime_error&) {
            try {
                r = ctrl->call("get_sensor " + std::string(dir == "rx" ? "adc" : "dac") + "_pll_locked");
            } catch (const uhd::runtime_error&) {
                r = "bool true";
            }
        }
        const auto v = parse_sensor("LO", r);
        return sensor_value_t("LO", v.to_bool(), "locked", "unlocked");
    });
}

void zcu216_device::_make_pool(const device_addr_t& args)
{
    // dpdk::default_layout(): one worker per physical core other than the
    // first two (main lcore + application, then the RX/TX lcores)
    const dpdk::cpu_layout& L = dpdk::default_layout();
    const bool own_lcores     = args.has_key("dpdk_rx_cores") or args.has_key("dpdk_tx_core")
                            or args.has_key("dpdk_main_core");
    const size_t def_nw = (own_lcores or L.workers.empty()) ? 4 : L.workers.size();
    const long long nw  = parse_ll(args.get("rx_workers", std::to_string(def_nw)), "rx_workers");
    _st->par_min_slots =
        size_t(std::max(1LL, parse_ll(args.get("par_min_slots", "16384"), "par_min_slots")));
    if (nw <= 0) {
        ZLOG_INFO("rx_workers=0: recv()/send() convert in the application thread");
        return;
    }
    if (nw > 64)
        throw uhd::value_error("ZCU216: rx_workers=" + std::to_string(nw) + " (at most 64)");
    std::vector<int> cpus;
    if (args.has_key("worker_cpus") or (not own_lcores and not L.workers.empty())) {
        const auto l = args.has_key("worker_cpus") ? parse_cpus(args["worker_cpus"], "worker_cpus")
                                                   : L.workers;
        for (long long i = 0; i < nw; i++)
            cpus.push_back(int(l[size_t(i) % l.size()]));
    } else {
        // lcores given explicitly: the highest-numbered online CPUs that no
        // lcore and not the EAL main core use
        std::set<unsigned> busy;
        for (unsigned c : parse_cpus(args.get("dpdk_rx_cores", dpdk::cpu_list(L.rx)), "dpdk_rx_cores"))
            busy.insert(c);
        busy.insert(parse_cpus(args.get("dpdk_tx_core", std::to_string(L.tx)), "dpdk_tx_core").at(0));
        busy.insert(parse_cpus(args.get("dpdk_main_core", std::to_string(L.main)), "dpdk_main_core").at(0));
        std::string online;
        std::ifstream f("/sys/devices/system/cpu/online");
        std::getline(f, online);
        std::vector<unsigned> freec;
        if (not online.empty())
            for (unsigned c : parse_cpus(online, "online CPUs"))
                if (not busy.count(c))
                    freec.push_back(c);
        const size_t take = std::min<size_t>(size_t(nw), freec.size());
        for (size_t i = freec.size() - take; i < freec.size(); i++)
            cpus.push_back(int(freec[i]));
        while (cpus.size() < size_t(nw))
            cpus.push_back(-1); // not enough free CPUs: let the scheduler place it
    }
    const double spin = parse_double(args.get("worker_spin_us", "200"), "worker_spin_us");
    for (int c : cpus)
        if (c >= 0)
            _worker_cpus.insert(unsigned(c));
    _st->pool = std::make_shared<worker_pool>(cpus, spin);
    // send()'s own pool: worker_pool::run() executes a second concurrent
    // caller inline, so with one shared pool simultaneous RX and TX left one
    // direction converting single-threaded. Default: as many workers on the
    // same CPUs (each pool's threads sleep once idle, so one direction at a
    // time costs nothing); tx_workers= / tx_worker_cpus= split the cores.
    const long long ntw = parse_ll(args.get("tx_workers", std::to_string(nw)), "tx_workers");
    if (ntw > 0) {
        std::vector<int> tcpus;
        if (args.has_key("tx_worker_cpus")) {
            const auto l = parse_cpus(args["tx_worker_cpus"], "tx_worker_cpus");
            for (long long i = 0; i < ntw; i++)
                tcpus.push_back(int(l[size_t(i) % l.size()]));
            for (unsigned c : l)
                _worker_cpus.insert(c);
        } else {
            for (long long i = 0; i < ntw; i++)
                tcpus.push_back(cpus[size_t(i) % cpus.size()]);
        }
        _st->tx_pool = std::make_shared<worker_pool>(tcpus, spin);
    }
}

namespace {
std::vector<unsigned> cpus_of_file(const std::string& path)
{
    std::string v;
    std::ifstream f(path);
    std::getline(f, v);
    return v.empty() ? std::vector<unsigned>{} : parse_cpus(v, path);
}
std::string cpu_set_str(const std::set<unsigned>& s)
{
    std::string r;
    for (unsigned c : s)
        r += (r.empty() ? "" : ",") + std::to_string(c);
    return r;
}
} // namespace

void zcu216_device::_place_app(const device_addr_t& args)
{
    // What zcu216-uhd's taskset did, for any UHD application started plainly
    // (sudo <app>): the thread that opens the device -- and so every thread it
    // starts afterwards (GNU Radio's block threads, an app's RX/TX threads) --
    // goes to CPUs that no polling lcore and no conversion worker uses, nor
    // their hyperthread siblings. A thread sharing a CPU with a polling lcore
    // starves it and loses packets. app_cpus=<list> picks the CPUs,
    // app_cpus=all leaves the affinity alone, and an affinity already
    // narrower than the online CPUs (taskset, the wrapper) is kept.
    // Default layout on a 6-core / 12-thread x86 host: CPUs 0,6 (C0, beside
    // the EAL main lcore).
    const std::string arg = args.get("app_cpus", "");
    if (arg == "all")
        return;
    const auto online = cpus_of_file("/sys/devices/system/cpu/online");
    cpu_set_t cur;
    CPU_ZERO(&cur);
    if (online.empty() or pthread_getaffinity_np(pthread_self(), sizeof(cur), &cur) != 0)
        return;
    std::set<unsigned> want;
    if (not arg.empty()) {
        for (unsigned c : parse_cpus(arg, "app_cpus"))
            want.insert(c);
    } else {
        size_t n = 0;
        for (unsigned c : online)
            n += CPU_ISSET(c, &cur) ? 1 : 0;
        if (n < online.size()) {
            ZLOG_INFO("application CPUs kept as started (" << n << " of " << online.size()
                                                           << "; app_cpus= overrides)");
            return;
        }
        const dpdk::cpu_layout& L = dpdk::default_layout();
        std::set<unsigned> busy(_worker_cpus);
        for (unsigned c : parse_cpus(args.get("dpdk_rx_cores", dpdk::cpu_list(L.rx)), "dpdk_rx_cores"))
            busy.insert(c);
        busy.insert(parse_cpus(args.get("dpdk_tx_core", std::to_string(L.tx)), "dpdk_tx_core").at(0));
        std::set<unsigned> busy_cores(busy); // with their hyperthread siblings
        for (unsigned c : busy)
            for (unsigned s : cpus_of_file("/sys/devices/system/cpu/cpu" + std::to_string(c)
                                           + "/topology/thread_siblings_list"))
                busy_cores.insert(s);
        for (unsigned c : online)
            if (not busy_cores.count(c))
                want.insert(c);
        // big.LITTLE (e.g. Cortex-X925 + A725): only the fast cores (within 90 % of the
        // highest cpu_capacity) if any is left; recv()'s planning and the
        // inline conversion run on these threads
        {
            auto cap = [](unsigned c) {
                std::ifstream t("/sys/devices/system/cpu/cpu" + std::to_string(c) + "/cpu_capacity");
                long v = 0;
                return (t >> v) ? v : 0L;
            };
            long mx = 0;
            for (unsigned c : online)
                mx = std::max(mx, cap(c));
            std::set<unsigned> fast;
            for (unsigned c : want)
                if (mx > 0 and cap(c) * 10 >= mx * 9)
                    fast.insert(c);
            if (not fast.empty() and fast.size() < want.size())
                want = fast;
        }
        if (want.empty()) // every core busy: at least off the busy CPUs themselves
            for (unsigned c : online)
                if (not busy.count(c))
                    want.insert(c);
        if (want.empty()) {
            ZLOG_WARN("no CPU free of DPDK lcores and conversion workers: the application "
                      "shares theirs (app_cpus= sets its CPUs)");
            return;
        }
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    for (unsigned c : want)
        CPU_SET(c, &set);
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0)
        throw uhd::value_error("ZCU216: app_cpus " + cpu_set_str(want) + ": cannot pin the application there");
    ZLOG_INFO("application threads on CPUs " << cpu_set_str(want)
                                             << " (off the DPDK lcores and workers; app_cpus= overrides)");
}

void zcu216_device::_build_bf()
{
    const fs_path mb = "/mboards/0";
    _bf              = std::make_shared<bf_ctl>(_st, false);
    _rbf             = std::make_shared<bf_ctl>(_st, true);
    // the tree nodes exist only for the beamformers the build has at make()
    // (tools test tree.exists(.../enable)); the registers route to both and
    // say clearly when one is missing
    if (_st->bf) {
        _build_bf_nodes(mb / "tx_beamformer", _bf);
        _build_bf_nodes(mb / "beamformer", _bf); // the pre-RX name, kept as an alias
    }
    if (_st->rbf)
        _build_bf_nodes(mb / "rx_beamformer", _rbf);
    auto regs = std::make_shared<bf_regs>(_bf, _rbf);
    // multi_usrp::set_user_register lands here (on a build without a
    // beamformer: the not_implemented_error that says why)
    _tree->create<std::pair<uint8_t, uint32_t>>(mb / "user/regs")
        .add_coerced_subscriber([regs](const std::pair<uint8_t, uint32_t>& r) { regs->poke(r.first, r.second); });
    if (not(_st->bf or _st->rbf))
        return;
    // multi_usrp::get_user_settings_iface(chan) reads <rx frontend>/user_settings/iface
    auto iface = std::make_shared<bf_user_iface>(regs);
    for (size_t ch = 0; ch < _st->num_rx; ch++)
        _tree->create<uhd::wb_iface::sptr>(mb / "dboards/A/rx_frontends" / std::to_string(ch)
                                           / "user_settings/iface")
            .set(iface);
}

void zcu216_device::_build_bf_nodes(const fs_path& b, std::shared_ptr<bf_ctl> bf)
{
    _tree->create<bool>(b / "enable")
        .set_coercer([bf](bool e) { return bf->set_enable(e); })
        .set_publisher([bf] { return bf->get().enable; });
    _tree->create<double>(b / "angle_deg")
        .set_coercer([bf](double deg) {
            bf->set_angle(deg);
            return deg;
        })
        .set_publisher([bf] { return bf->get().angle; });
    _tree->create<double>(b / "carrier_freq")
        .set_coercer([bf](double f) {
            bf->set_params(f, bf->get().spacing);
            return f;
        })
        .set_publisher([bf] { return bf->get().carrier; });
    _tree->create<double>(b / "element_spacing")
        .set_coercer([bf](double d) {
            bf->set_params(bf->get().carrier, d);
            return d;
        })
        .set_publisher([bf] { return bf->get().spacing; });
    using cvec = std::vector<std::complex<double>>;
    _tree->create<cvec>(b / "weights")
        .set_coercer([bf](const cvec& w) {
            std::vector<std::complex<int>> q;
            for (const auto& x : w)
                q.emplace_back(bf_ctl::q15(x.real()), bf_ctl::q15(x.imag()));
            bf->set_weights(q);
            cvec out;
            for (const auto& x : q)
                out.emplace_back(x.real() / 32767.0, x.imag() / 32767.0);
            return out;
        })
        .set_publisher([bf] {
            cvec out;
            for (const auto& x : bf->get().w)
                out.emplace_back(x.real() / 32767.0, x.imag() / 32767.0);
            return out;
        });
    // raw Q1.15 weights, as the daemon reports them (no scaling)
    _tree->create<std::vector<int>>(b / "weights_q15").set_publisher([bf] {
        std::vector<int> out;
        for (const auto& x : bf->get().w) {
            out.push_back(x.real());
            out.push_back(x.imag());
        }
        return out;
    });
    // the same, as text "re0,im0,re1,im1,..." (the get_bf format): the UHD
    // Python bindings read only bool/int/double/string tree nodes
    _tree->create<std::string>(b / "weights_str").set_publisher([bf] {
        std::string out;
        for (const auto& x : bf->get().w)
            out += (out.empty() ? "" : ",") + std::to_string(x.real()) + "," + std::to_string(x.imag());
        return out;
    });
    if (bf->rx())
        // RX: beam = (sum_c x_c w[c]) >> (15 + shift), 0..15 (reset log2(N))
        _tree->create<int>(b / "shift")
            .set_coercer([bf](int sh) { return bf->set_shift(sh); })
            .set_publisher([bf] { return bf->get().shift; });
}

// ---------------------------------------------------------------------------
// registration
// ---------------------------------------------------------------------------
static device_addrs_t zcu216_find(const device_addr_t& hint_in)
{
    // type=zcu216: any board this module serves (the protocol's name);
    // type=rfsoc4x2: only RFSoC 4x2 boards (product=rfsoc4x2), reported as
    // type=rfsoc4x2
    const std::string type = hint_in.get("type", "zcu216");
    if (type != "zcu216" and type != "rfsoc4x2")
        return {};
    device_addr_t hint = hint_in;
    if (type == "rfsoc4x2") {
        if (hint.get("product", "rfsoc4x2") != "rfsoc4x2")
            return {};
        hint["product"] = "rfsoc4x2";
    }
    // multi-board addr0=,addr1= hints and other device families' selectors
    if (hint.has_key("addr0") or hint.has_key("resource") or hint.has_key("mgmt_addr"))
        return {};
    const double tmo = hint.cast<double>("find_timeout", 0.15);
    device_addrs_t found;
    try {
        found = discover(hint, tmo);
    } catch (const std::exception& e) {
        ZLOG_DEBUG("discovery failed: " << e.what());
    }
    // Fallback: explicit type=zcu216,addr=... but UDP discovery filtered:
    // ask the control port directly.
    if (found.empty() and hint.has_key("addr") and hint_in.has_key("type")) {
        try {
            ctrl_client cc(hint["addr"], uint16_t(hint.cast<int>("ctrl_port", kCtrlPort)), 1.0);
            device_addr_t info = parse_kv(cc.call("info"));
            device_addr_t dev;
            for (const char* k : {"type", "product", "serial", "name", "addr", "data_ip",
                     "claimed", "fpga", "version"})
                if (info.has_key(k))
                    dev[k] = info[k];
            dev["type"] = "zcu216";
            if (not dev.has_key("addr"))
                dev["addr"] = hint["addr"];
            if (not hint.has_key("product") or dev.get("product", "") == hint["product"])
                found.push_back(dev);
        } catch (const std::exception&) {
        }
    }
    // UHD's device cache keys on every discovered key except "claimed". The
    // bitstream name changes when make() selects another build (channels=N,
    // §9) or rate variant (§8), so a second make() in the same process would
    // miss the cache and try a second claim: leave it out of the address
    // (uhd_usrp_probe and the tree still report it, from `info`).
    for (auto& dev : found)
        if (dev.has_key("fpga"))
            dev.pop("fpga");
    // carry the user's transport args (host_data_ip=, spp=, ...) to make()
    for (auto& dev : found)
        for (const auto& k : hint.keys())
            if (not dev.has_key(k) and k != "find_all")
                dev[k] = hint[k];
    if (type == "rfsoc4x2")
        for (auto& dev : found)
            dev["type"] = "rfsoc4x2";
    return found;
}

static device::sptr zcu216_make(const device_addr_t& args)
{
    return std::make_shared<zcu216_device>(args);
}

UHD_STATIC_BLOCK(register_zcu216_device)
{
    device::register_device(&zcu216_find, &zcu216_make, device::USRP);
}

} // namespace zcu216
