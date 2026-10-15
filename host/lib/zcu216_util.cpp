//
// uhd_zcu216 -- helpers: strings, TCP control client, discovery, interfaces.
//
#include "zcu216_common.hpp"
#include <uhd/transport/if_addrs.hpp>
#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>

namespace zcu216 {

// ---------------------------------------------------------------------------
// strings
// ---------------------------------------------------------------------------
std::vector<std::string> split(const std::string& s, char sep, bool keep_empty)
{
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
        const size_t pos = s.find(sep, start);
        const std::string tok =
            s.substr(start, pos == std::string::npos ? std::string::npos : pos - start);
        if (keep_empty or not tok.empty())
            out.push_back(tok);
        if (pos == std::string::npos)
            break;
        start = pos + 1;
    }
    return out;
}

std::string trim(const std::string& s)
{
    const char* ws = " \t\r\n";
    const size_t b = s.find_first_not_of(ws);
    if (b == std::string::npos)
        return "";
    const size_t e = s.find_last_not_of(ws);
    return s.substr(b, e - b + 1);
}

double parse_double(const std::string& s, const std::string& what)
{
    const std::string t = trim(s);
    char* end = nullptr;
    errno = 0;
    const double v = std::strtod(t.c_str(), &end);
    if (t.empty() or end == t.c_str() or *end != '\0' or errno == ERANGE)
        throw uhd::value_error("ZCU216: cannot parse " + what + " from '" + s + "'");
    return v;
}

long long parse_ll(const std::string& s, const std::string& what)
{
    const std::string t = trim(s);
    char* end = nullptr;
    errno = 0;
    const long long v = std::strtoll(t.c_str(), &end, 0);
    if (t.empty() or end == t.c_str() or *end != '\0' or errno == ERANGE)
        throw uhd::value_error("ZCU216: cannot parse " + what + " from '" + s + "'");
    return v;
}

std::string fmt_double(double v)
{
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.17g", v);
    return buf;
}

uhd::device_addr_t parse_kv(const std::string& s)
{
    uhd::device_addr_t out;
    for (const auto& kv : split(trim(s), ';', false)) {
        const size_t eq = kv.find('=');
        if (eq == std::string::npos)
            continue;
        out[trim(kv.substr(0, eq))] = trim(kv.substr(eq + 1));
    }
    return out;
}

//! "2-5", "2:3:4:5", "2;3;4;5", "2 3", "2,3" (the last one only where UHD's
//! device-arg parser does not split on commas, e.g. the environment)
std::vector<unsigned> parse_cpus(const std::string& s, const std::string& what)
{
    std::vector<unsigned> out;
    std::string tok;
    auto flush = [&] {
        if (tok.empty())
            return;
        const auto dash = tok.find('-');
        try {
            if (dash == std::string::npos) {
                out.push_back(unsigned(std::stoul(tok)));
            } else {
                const unsigned a = unsigned(std::stoul(tok.substr(0, dash)));
                const unsigned b = unsigned(std::stoul(tok.substr(dash + 1)));
                if (b < a or b - a > 256)
                    throw std::invalid_argument(tok);
                for (unsigned c = a; c <= b; c++)
                    out.push_back(c);
            }
        } catch (const std::exception&) {
            throw uhd::value_error("ZCU216: bad " + what + " '" + s
                                   + "' (CPU list like 2-5 or 2:3:4:5)");
        }
        tok.clear();
    };
    for (char c : s) {
        if (c == ',' or c == ':' or c == ';' or std::isspace((unsigned char)c))
            flush();
        else
            tok += c;
    }
    flush();
    if (out.empty())
        throw uhd::value_error("ZCU216: empty " + what);
    return out;
}

// ---------------------------------------------------------------------------
// control client
// ---------------------------------------------------------------------------
std::string resolve_ipv4(const std::string& host)
{
    addrinfo hints{};
    hints.ai_family = AF_INET;
    addrinfo* res   = nullptr;
    const int rc    = getaddrinfo(host.c_str(), nullptr, &hints, &res);
    if (rc != 0 or res == nullptr)
        throw uhd::lookup_error("ZCU216: cannot resolve '" + host + "': " + gai_strerror(rc));
    char buf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET,
        &reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr,
        buf,
        sizeof(buf));
    freeaddrinfo(res);
    return buf;
}

static sockaddr_in make_sin(const std::string& ip, uint16_t port)
{
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port   = htons(port);
    if (inet_pton(AF_INET, ip.c_str(), &sa.sin_addr) != 1)
        throw uhd::value_error("ZCU216: bad IPv4 address '" + ip + "'");
    return sa;
}

ctrl_client::ctrl_client(const std::string& host, uint16_t port, double timeout_s)
    : _timeout(timeout_s), _host(host)
{
    const std::string ip = resolve_ipv4(host);
    _fd                  = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (_fd < 0)
        throw uhd::os_error(std::string("ZCU216: socket(): ") + strerror(errno));
    const sockaddr_in sa = make_sin(ip, port);
    // non-blocking connect with a bounded wait
    const int fl = fcntl(_fd, F_GETFL, 0);
    fcntl(_fd, F_SETFL, fl | O_NONBLOCK);
    int rc = ::connect(_fd, reinterpret_cast<const sockaddr*>(&sa), sizeof(sa));
    if (rc < 0 and errno == EINPROGRESS) {
        pollfd p{_fd, POLLOUT, 0};
        rc = ::poll(&p, 1, int(std::min(timeout_s, 3.0) * 1000));
        int err       = 0;
        socklen_t len = sizeof(err);
        if (rc == 1)
            getsockopt(_fd, SOL_SOCKET, SO_ERROR, &err, &len);
        if (rc != 1 or err != 0) {
            ::close(_fd);
            _fd = -1;
            throw uhd::io_error("ZCU216: cannot connect to control port " + ip + ":"
                                + std::to_string(port) + ": "
                                + (rc == 1 ? strerror(err) : "timeout"));
        }
    } else if (rc < 0) {
        const int e = errno;
        ::close(_fd);
        _fd = -1;
        throw uhd::io_error("ZCU216: cannot connect to control port " + ip + ":"
                            + std::to_string(port) + ": " + strerror(e));
    }
    fcntl(_fd, F_SETFL, fl);
    int one = 1;
    setsockopt(_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

ctrl_client::~ctrl_client()
{
    if (_fd >= 0)
        ::close(_fd);
}

std::string ctrl_client::_read_line(const std::string& cmd, double timeout_s)
{
    const auto deadline = std::chrono::steady_clock::now()
                          + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                              std::chrono::duration<double>(timeout_s));
    while (true) {
        const size_t nl = _rx.find('\n');
        if (nl != std::string::npos) {
            std::string line = _rx.substr(0, nl);
            _rx.erase(0, nl + 1);
            if (not line.empty() and line.back() == '\r')
                line.pop_back();
            return line;
        }
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now())
                              .count();
        if (left <= 0) {
            _broken = true;
            throw uhd::io_error("ZCU216: timeout waiting for reply to '" + cmd + "'");
        }
        pollfd p{_fd, POLLIN, 0};
        const int rc = ::poll(&p, 1, int(left));
        if (rc < 0 and errno == EINTR)
            continue;
        if (rc <= 0)
            continue;
        char buf[4096];
        const ssize_t n = ::recv(_fd, buf, sizeof(buf), 0);
        if (n <= 0) {
            _broken = true;
            throw uhd::io_error("ZCU216: control connection closed by daemon ("
                                + std::string(n < 0 ? strerror(errno) : "EOF") + ")");
        }
        _rx.append(buf, size_t(n));
    }
}

std::string ctrl_client::call(const std::string& line, double timeout_s)
{
    std::lock_guard<std::mutex> lock(_mutex);
    if (_broken)
        throw uhd::io_error("ZCU216: control connection is broken; recreate the device");
    const std::string msg = line + "\n";
    size_t off            = 0;
    while (off < msg.size()) {
        const ssize_t n = ::send(_fd, msg.data() + off, msg.size() - off, MSG_NOSIGNAL);
        if (n < 0 and errno == EINTR)
            continue;
        if (n <= 0) {
            _broken = true;
            throw uhd::io_error(std::string("ZCU216: control send failed: ") + strerror(errno));
        }
        off += size_t(n);
    }
    const std::string reply = _read_line(line, timeout_s < 0.0 ? _timeout : timeout_s);
    ZLOG_TRACE("ctrl> " << line << "  < " << reply);
    if (reply == "OK")
        return "";
    if (reply.compare(0, 3, "OK ") == 0)
        return reply.substr(3);
    if (reply.compare(0, 3, "ERR") == 0)
        throw uhd::runtime_error(
            "ZCU216: daemon rejected '" + line + "': " + trim(reply.substr(3)));
    throw uhd::runtime_error("ZCU216: malformed reply to '" + line + "': '" + reply + "'");
}

std::vector<std::string> ctrl_client::call_tokens(const std::string& line, double timeout_s)
{
    return split(call(line, timeout_s), ' ', false);
}

double ctrl_client::call_double(const std::string& line, double timeout_s)
{
    const auto t = call_tokens(line, timeout_s);
    if (t.empty())
        throw uhd::runtime_error("ZCU216: empty reply to '" + line + "'");
    return parse_double(t[0], "reply to '" + line + "'");
}

// ---------------------------------------------------------------------------
// discovery
// ---------------------------------------------------------------------------
uhd::device_addrs_t discover(const uhd::device_addr_t& hint, double timeout_s)
{
    uhd::device_addrs_t found;
    const uint16_t disc_port =
        uint16_t(hint.cast<int>("disc_port", kDiscPort));

    std::vector<std::string> targets;
    if (hint.has_key("addr")) {
        try {
            targets.push_back(resolve_ipv4(hint["addr"]));
        } catch (const std::exception&) {
            return found;
        }
    } else {
        std::set<std::string> seen;
        for (const auto& ifa : uhd::transport::get_if_addrs()) {
            if (ifa.bcast.empty() or ifa.inet.compare(0, 4, "127.") == 0)
                continue;
            if (seen.insert(ifa.bcast).second)
                targets.push_back(ifa.bcast);
        }
        if (targets.empty())
            targets.push_back("255.255.255.255");
    }

    const int fd = ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return found;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    for (const auto& t : targets) {
        try {
            const sockaddr_in sa = make_sin(t, disc_port);
            ::sendto(fd,
                kDiscRequest,
                std::strlen(kDiscRequest),
                0,
                reinterpret_cast<const sockaddr*>(&sa),
                sizeof(sa));
        } catch (const std::exception&) {
        }
    }

    std::set<std::string> dedup;
    const auto deadline = std::chrono::steady_clock::now()
                          + std::chrono::duration<double>(timeout_s);
    while (true) {
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now())
                              .count();
        if (left <= 0)
            break;
        pollfd p{fd, POLLIN, 0};
        if (::poll(&p, 1, int(left)) <= 0)
            continue;
        char buf[2048];
        sockaddr_in from{};
        socklen_t flen  = sizeof(from);
        const ssize_t n = ::recvfrom(
            fd, buf, sizeof(buf) - 1, 0, reinterpret_cast<sockaddr*>(&from), &flen);
        if (n <= 0)
            continue;
        buf[n]                = '\0';
        const std::string msg = trim(buf);
        const std::string pfx = trim(kDiscReplyPrefix);
        if (msg.compare(0, pfx.size(), pfx) != 0)
            continue;
        uhd::device_addr_t dev = parse_kv(msg.substr(pfx.size()));
        char fbuf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &from.sin_addr, fbuf, sizeof(fbuf));
        if (not dev.has_key("addr") or dev["addr"].empty() or dev["addr"] == "0.0.0.0")
            dev["addr"] = fbuf;
        if (not dev.has_key("type") or dev["type"] != "zcu216")
            continue;
        // user filters
        if (hint.has_key("serial") and dev.get("serial", "") != hint["serial"])
            continue;
        if (hint.has_key("name") and dev.get("name", "") != hint["name"])
            continue;
        // one board answers once per interface a broadcast reached it on
        if (not dedup.insert(dev.get("serial", dev["addr"])).second)
            continue;
        found.push_back(dev);
    }
    ::close(fd);
    return found;
}

// ---------------------------------------------------------------------------
// interfaces
// ---------------------------------------------------------------------------
static std::string mac_of_iface(const std::string& ifname)
{
    const int fd = ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return "";
    ifreq ifr{};
    std::strncpy(ifr.ifr_name, ifname.c_str(), IFNAMSIZ - 1);
    std::string mac;
    if (::ioctl(fd, SIOCGIFHWADDR, &ifr) == 0) {
        const auto* b = reinterpret_cast<const unsigned char*>(ifr.ifr_hwaddr.sa_data);
        char buf[32];
        std::snprintf(buf,
            sizeof(buf),
            "%02x:%02x:%02x:%02x:%02x:%02x",
            b[0],
            b[1],
            b[2],
            b[3],
            b[4],
            b[5]);
        mac = buf;
    }
    ::close(fd);
    return mac;
}

local_iface iface_for_ip(const std::string& ip)
{
    local_iface out;
    out.ip          = ip;
    ifaddrs* list   = nullptr;
    if (getifaddrs(&list) == 0) {
        for (ifaddrs* i = list; i; i = i->ifa_next) {
            if (not i->ifa_addr or i->ifa_addr->sa_family != AF_INET)
                continue;
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET,
                &reinterpret_cast<sockaddr_in*>(i->ifa_addr)->sin_addr,
                buf,
                sizeof(buf));
            if (ip == buf) {
                out.name = i->ifa_name;
                break;
            }
        }
        freeifaddrs(list);
    }
    if (out.name.empty())
        throw uhd::lookup_error("ZCU216: no local interface owns IPv4 address " + ip
                                + " (check host_data_ip=)");
    out.mac = mac_of_iface(out.name);
    return out;
}

local_iface iface_for_route(const std::string& dest_ip)
{
    // connect() on a UDP socket makes the kernel pick the route and source
    // address without sending anything.
    const int fd = ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        throw uhd::os_error(std::string("ZCU216: socket(): ") + strerror(errno));
    const sockaddr_in sa = make_sin(dest_ip, kTxPort);
    if (::connect(fd, reinterpret_cast<const sockaddr*>(&sa), sizeof(sa)) != 0) {
        const int e = errno;
        ::close(fd);
        throw uhd::lookup_error("ZCU216: no route to FPGA data IP " + dest_ip + ": "
                                + strerror(e) + " (is the 100G port up? set host_data_ip=)");
    }
    sockaddr_in local{};
    socklen_t len = sizeof(local);
    getsockname(fd, reinterpret_cast<sockaddr*>(&local), &len);
    ::close(fd);
    char buf[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &local.sin_addr, buf, sizeof(buf));
    return iface_for_ip(buf);
}

// ---------------------------------------------------------------------------
// dev_state
// ---------------------------------------------------------------------------
uint64_t dev_state::ticks_per_sample(double rate) const
{
    if (rate <= 0.0 or tick_rate <= 0.0)
        return 1;
    const double r   = tick_rate / rate;
    const double tps = std::round(r);
    if (tps < 1.0)
        return 1;
    return uint64_t(tps);
}

void dev_state::refresh_rates()
{
    // Every channel of the one stream runs at the same rate (§9): one query
    // per direction, copied to all channels. At N = 1 this is exactly the
    // single get_rx_rate / get_tx_rate it always was.
    if (not rx_rate.empty()) {
        const double r = ctrl->call_double("get_rx_rate 0");
        for (auto& a : rx_rate)
            a->store(r);
    }
    if (not tx_rate.empty()) {
        const double r = ctrl->call_double("get_tx_rate 0");
        for (auto& a : tx_rate)
            a->store(r);
    }
}

void dev_state::set_cur_otw(const std::string& f)
{
    std::lock_guard<std::mutex> l(_info_mutex);
    _cur_otw = f;
}

std::string dev_state::cur_otw()
{
    std::lock_guard<std::mutex> l(_info_mutex);
    return _cur_otw;
}

std::vector<std::string> dev_state::otw_offered(bool rx)
{
    std::lock_guard<std::mutex> l(_info_mutex);
    return rx ? _otw_rx : _otw_tx;
}

void dev_state::apply_info(const uhd::device_addr_t& info)
{
    const double t = parse_double(info.get("tick_rate", "0"), "info tick_rate");
    if (t > 0.0)
        tick_rate = t;
    beat_slots_info = size_t(std::max(0LL, parse_ll(info.get("beat_slots", "0"), "info beat_slots")));
    bf              = info.get("bf", "0") == "1";
    rbf             = info.get("rbf", "0") == "1";
    default_spp     = size_t(parse_ll(info.get("spp", std::to_string(kDefaultSpp)), "spp"));
    mtu             = size_t(parse_ll(info.get("mtu", "9000"), "mtu"));
    // §10: per direction if the daemon says so, else the common list, else sc16
    auto list = [&](const char* key) -> std::vector<std::string> {
        if (info.has_key(key))
            return split(info[key], ',', false);
        if (info.has_key("otw_formats"))
            return split(info["otw_formats"], ',', false);
        return {"sc16"};
    };
    std::lock_guard<std::mutex> l(_info_mutex);
    _otw_rx = list("rx_otw_formats");
    _otw_tx = list("tx_otw_formats");
}

void dev_state::refresh_info()
{
    apply_info(parse_kv(ctrl->call("info")));
}

double dev_state::set_rate(bool rx, size_t ch, double rate)
{
    const double old_rx = rx_rate.empty() ? 0.0 : rx_rate[0]->load();
    const double old_tx = tx_rate.empty() ? 0.0 : tx_rate[0]->load();
    const double old_tick = tick_rate.load();
    const std::string dir = rx ? "rx" : "tx";
    // §3: declare the stream format, so the daemon picks (or refuses) the
    // build for it before reloading anything
    std::string req = "set_" + dir + "_rate " + std::to_string(ch) + " " + fmt_double(rate);
    const std::string otw = cur_otw();
    if (not otw.empty())
        req += " otw=" + otw;
    const auto t0 = std::chrono::steady_clock::now();
    double actual;
    try {
        const auto rep = ctrl->call_tokens(req, rate_timeout);
        if (rep.empty())
            throw uhd::runtime_error("ZCU216: empty reply to '" + req + "'");
        actual = parse_double(rep[0], "reply to '" + req + "'");
        // §3/§8: the 2nd token is the (possibly new) build's tick rate
        if (rep.size() >= 2) {
            const double t = parse_double(rep[1], "tick rate in the reply to '" + req + "'");
            if (t > 0.0)
                tick_rate = t;
        }
    } catch (...) {
        // the daemon may have reloaded (and restored) a bitstream: resync anyway
        fpga_generation++;
        try {
            refresh_rates();
            refresh_info();
        } catch (...) {
        }
        throw;
    }
    // RX and TX are coupled (one converter factor): re-read both directions
    refresh_rates();
    const double new_rx = rx_rate.empty() ? 0.0 : rx_rate[0]->load();
    const double new_tx = tx_rate.empty() ? 0.0 : tx_rate[0]->load();
    if (new_rx != old_rx or new_tx != old_tx or tick_rate.load() != old_tick) {
        fpga_generation++;
        refresh_info(); // the new build's beat, formats, tick rate
        const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        ZLOG_INFO("Rate changed to " << actual / 1e6 << " MS/s per channel (tick rate "
                                     << tick_rate.load() / 1e6 << " MHz, " << beat_slots()
                                     << "-slot beat): the daemon retuned or reloaded the FPGA ("
                                     << secs << " s). Streaming stopped; streamers re-setup on "
                                     << "next use; re-issue set_time if alignment matters.");
    }
    return actual;
}

local_iface dev_state::host_data_iface()
{
    std::lock_guard<std::mutex> lock(_iface_mutex);
    if (_iface_valid)
        return _iface;
    local_iface ifc;
    if (args.has_key("host_data_ip")) {
        try {
            ifc = iface_for_ip(args["host_data_ip"]);
        } catch (const uhd::lookup_error&) {
            if (not args.has_key("host_data_mac"))
                throw;
            ifc.ip = args["host_data_ip"];
        }
    } else {
        ifc = iface_for_route(data_ip);
    }
    if (args.has_key("host_data_mac"))
        ifc.mac = args["host_data_mac"];
    if (ifc.mac.empty())
        ifc.mac = "00:00:00:00:00:00";
    ZLOG_INFO("Host data endpoint " << ifc.ip << " (" << (ifc.name.empty() ? "?" : ifc.name)
                                    << ", " << ifc.mac << "), FPGA data IP " << data_ip);
    _iface       = ifc;
    _iface_valid = true;
    return _iface;
}

} // namespace zcu216
