// rfsoc_waterfall: capture (UHD rx_streamer or a synthetic source) -> GPU -> lines.
// See rfsoc_waterfall.h.
#include "rfsoc_waterfall.h"

#include "rfsoc_waterfall_gpu.cuh"

#include <uhd/types/stream_cmd.hpp>
#include <uhd/types/tune_request.hpp>
#include <uhd/usrp/multi_usrp.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr size_t kBatchSamples = 131072;  // most new samples per channel and batch
constexpr size_t kBatchBytes = 8u << 20;  // target size of the FFT buffer
constexpr int kSlots = 24;                // pinned capture slots (absorb scheduling stalls)
constexpr int kLineRing = 64;
using clk = std::chrono::steady_clock;
}  // namespace

struct wf {
    wf_config_t cfg{};
    std::string dev_args, otw;
    int nch = 0, nfft = 0, hop = 0, F = 0, bins = 0;
    size_t newS = 0, carry = 0, S = 0;
    double rate = 0, freq = 0;

    uhd::usrp::multi_usrp::sptr usrp;
    uhd::rx_streamer::sptr rx;
    GpuPipe* gpu = nullptr;

    // capture slots
    std::vector<int16_t*> slot;
    std::mutex sm;
    std::condition_variable scv;
    std::deque<int> free_q, ready_q;

    std::atomic<bool> run{false};
    std::thread tcap, tgpu;

    // lines
    std::mutex lm;
    std::condition_variable lcv;
    std::vector<float> lines;
    uint64_t line_head = 0, line_read = 0;  // next to write / next to read

    // sim pattern
    std::vector<int16_t*> pat;  // per channel, patlen samples
    size_t patlen = 0;

    std::atomic<int> detector{0};
    std::atomic<double> line_rate{30.0};
    std::atomic<uint64_t> cap{0}, proc{0}, dropped{0}, ovf{0}, nlines{0}, lines_dropped{0};

    std::mutex em;
    std::string error;

    void set_error(const std::string& s) {
        std::lock_guard<std::mutex> l(em);
        if (error.empty()) error = s;
    }
};

static void fillerr(char* err, int errlen, const std::string& s) {
    if (err && errlen > 0) snprintf(err, errlen, "%s", s.c_str());
}

// ---- synthetic source ------------------------------------------------------
static void make_pattern(wf* w) {
    w->patlen = 1u << 20;
    std::mt19937 gen(12345);
    std::normal_distribution<double> nd(0.0, 1.0);
    const double noise = 32768.0 * std::pow(10.0, -80.0 / 20.0) / std::sqrt(2.0);
    const double amp = 32768.0 * std::pow(10.0, w->cfg.sim_tone_dbfs / 20.0);
    for (int c = 0; c < w->nch; ++c) {
        int16_t* p = (int16_t*)gpu_alloc_pinned(w->patlen * 4);
        double f = std::fmod(w->cfg.sim_tone_hz * (c + 1), w->rate);
        if (f > w->rate / 2) f -= w->rate;
        // an integer number of cycles in the pattern, so it wraps seamlessly
        double k = std::round(f / w->rate * (double)w->patlen);
        for (size_t n = 0; n < w->patlen; ++n) {
            double ph = 2.0 * M_PI * k * (double)n / (double)w->patlen;
            double re = amp * std::cos(ph) + noise * nd(gen);
            double im = amp * std::sin(ph) + noise * nd(gen);
            p[2 * n] = (int16_t)std::max(-32768.0, std::min(32767.0, std::round(re)));
            p[2 * n + 1] = (int16_t)std::max(-32768.0, std::min(32767.0, std::round(im)));
        }
        w->pat.push_back(p);
    }
}

// ---- capture thread --------------------------------------------------------
static int take_free(wf* w) {
    std::unique_lock<std::mutex> l(w->sm);
    while (w->run) {
        if (!w->free_q.empty()) {
            int s = w->free_q.front();
            w->free_q.pop_front();
            return s;
        }
        if (!w->ready_q.empty()) {  // GPU too slow: overwrite the oldest unprocessed batch
            int s = w->ready_q.front();
            w->ready_q.pop_front();
            ++w->dropped;
            return s;
        }
        w->scv.wait_for(l, std::chrono::milliseconds(50));
    }
    return -1;
}

static void capture_thread(wf* w) {
    std::vector<int16_t> tail((size_t)w->nch * w->carry * 2, 0);
    std::vector<void*> ptrs(w->nch);
    uhd::rx_metadata_t md;
    size_t simpos = 0;
    auto next = clk::now();
    int timeouts = 0;
    while (w->run) {
        int s = take_free(w);
        if (s < 0) break;
        int16_t* base = w->slot[s];
        for (int c = 0; c < w->nch; ++c)
            if (w->carry) std::memcpy(base + (size_t)c * w->S * 2, tail.data() + (size_t)c * w->carry * 2,
                                      w->carry * 4);
        if (w->cfg.sim) {
            if (w->cfg.sim == 1) {
                next += std::chrono::duration_cast<clk::duration>(
                    std::chrono::duration<double>((double)w->newS / w->rate));
                std::this_thread::sleep_until(next);
            }
            for (int c = 0; c < w->nch; ++c) {
                int16_t* dst = base + ((size_t)c * w->S + w->carry) * 2;
                size_t off = simpos % w->patlen, n1 = std::min(w->newS, w->patlen - off);
                std::memcpy(dst, w->pat[c] + off * 2, n1 * 4);
                if (n1 < w->newS) std::memcpy(dst + n1 * 2, w->pat[c], (w->newS - n1) * 4);
            }
            simpos += w->newS;
        } else {
            size_t got = 0;
            while (got < w->newS && w->run) {
                for (int c = 0; c < w->nch; ++c)
                    ptrs[c] = base + ((size_t)c * w->S + w->carry + got) * 2;
                size_t n = w->rx->recv(ptrs, w->newS - got, md, 0.5, false);
                switch (md.error_code) {
                    case uhd::rx_metadata_t::ERROR_CODE_NONE:
                        timeouts = 0;
                        break;
                    case uhd::rx_metadata_t::ERROR_CODE_OVERFLOW:
                        ++w->ovf;
                        break;
                    case uhd::rx_metadata_t::ERROR_CODE_TIMEOUT:
                        if (++timeouts > 20) {
                            w->set_error("UHD recv: no samples for 10 s");
                            w->run = false;
                        }
                        break;
                    default:
                        w->set_error("UHD recv: " + md.strerror());
                        w->run = false;
                        break;
                }
                got += n;
            }
            if (got < w->newS) {  // stopping
                std::lock_guard<std::mutex> l(w->sm);
                w->free_q.push_back(s);
                break;
            }
        }
        for (int c = 0; c < w->nch; ++c)
            std::memcpy(tail.data() + (size_t)c * w->carry * 2,
                        base + ((size_t)c * w->S + w->newS) * 2, w->carry * 4);
        w->cap += w->newS;
        {
            std::lock_guard<std::mutex> l(w->sm);
            w->ready_q.push_back(s);
        }
        w->scv.notify_all();
    }
}

// ---- GPU thread ------------------------------------------------------------
static void gpu_thread(wf* w) {
    char err[256] = "";
    std::vector<float> line((size_t)w->nch * w->bins);
    auto last = clk::now();
    int frames = 0;
    struct Pending { int slot, buf; };
    std::deque<Pending> pending;  // slots whose copy to the GPU is still in flight
    auto release = [&](bool block_oldest) {
        while (!pending.empty()) {
            if (!gpu_copy_done(w->gpu, pending.front().buf, block_oldest ? 1 : 0)) break;
            block_oldest = false;
            {
                std::lock_guard<std::mutex> l(w->sm);
                w->free_q.push_back(pending.front().slot);
            }
            w->scv.notify_all();
            pending.pop_front();
        }
    };
    while (w->run) {
        release(false);
        int s;
        {
            std::unique_lock<std::mutex> l(w->sm);
            if (w->ready_q.empty()) w->scv.wait_for(l, std::chrono::milliseconds(pending.empty() ? 50 : 1));
            if (w->ready_q.empty()) continue;
            s = w->ready_q.front();
            w->ready_q.pop_front();
        }
        if (pending.size() >= 2) release(true);  // the GPU is behind: wait for the oldest copy
        int b = 0;
        if (gpu_process(w->gpu, w->slot[s], &b, err, sizeof err) != 0) {
            w->set_error(err);
            w->run = false;
            break;
        }
        pending.push_back({s, b});
        w->proc += w->newS;
        frames += w->F;
        auto now = clk::now();
        if (std::chrono::duration<double>(now - last).count() >= 1.0 / w->line_rate.load()) {
            last = now;
            if (gpu_line(w->gpu, w->detector.load(), frames, line.data(), err, sizeof err) != 0) {
                w->set_error(err);
                w->run = false;
                break;
            }
            frames = 0;
            release(false);
            {
                std::lock_guard<std::mutex> l(w->lm);
                if (w->line_head - w->line_read >= (uint64_t)kLineRing) {  // reader too slow
                    ++w->line_read;
                    ++w->lines_dropped;
                }
                std::memcpy(&w->lines[(w->line_head % kLineRing) * line.size()], line.data(),
                            line.size() * 4);
                ++w->line_head;
            }
            ++w->nlines;
            w->lcv.notify_all();
        }
    }
    w->lcv.notify_all();
}

// ---- API -------------------------------------------------------------------
wf_t* wf_create(const wf_config_t* cfg, char* err, int errlen) {
    auto w = std::make_unique<wf>();
    w->cfg = *cfg;
    w->nch = cfg->nch;
    w->nfft = cfg->nfft;
    w->bins = cfg->bins;
    if (w->nch < 1 || w->nch > 16) { fillerr(err, errlen, "nch must be 1..16"); return nullptr; }
    if (w->nfft < 64 || w->nfft > 65536 || (w->nfft & (w->nfft - 1))) {
        fillerr(err, errlen, "nfft must be a power of two, 64..65536");
        return nullptr;
    }
    if (w->bins < 1 || w->bins > w->nfft || w->nfft % w->bins) {
        fillerr(err, errlen, "bins must divide nfft");
        return nullptr;
    }
    if (cfg->overlap_pct != 0 && cfg->overlap_pct != 50 && cfg->overlap_pct != 75) {
        fillerr(err, errlen, "overlap must be 0, 50 or 75 %");
        return nullptr;
    }
    w->hop = w->nfft * (100 - cfg->overlap_pct) / 100;
    // frames per batch: up to kBatchSamples new samples per channel, but the FFT
    // buffer (nch * F * nfft complex floats) kept near kBatchBytes so it stays in
    // the GPU's L2 cache (a 33 MB buffer made 16 channels 4x slower per sample)
    size_t fmax = std::max<size_t>(1, kBatchSamples / (size_t)w->hop);
    size_t fcache = std::max<size_t>(1, kBatchBytes / ((size_t)w->nch * w->nfft * 8));
    w->F = (int)std::min(fmax, fcache);
    w->newS = (size_t)w->F * w->hop;
    w->carry = (size_t)(w->nfft - w->hop);
    w->S = w->carry + w->newS;
    w->detector = cfg->detector;
    w->line_rate = cfg->line_rate > 0 ? cfg->line_rate : 30.0;
    w->otw = (cfg->otw && *cfg->otw) ? cfg->otw : "sc16";
    w->dev_args = cfg->dev_args ? cfg->dev_args : "";
    w->rate = cfg->rate;
    w->freq = cfg->center_freq;

    try {
        if (!cfg->sim) {
            if (w->dev_args.find("channels=") == std::string::npos)
                w->dev_args += (w->dev_args.empty() ? "" : ",") + std::string("channels=") +
                               std::to_string(w->nch);
            w->usrp = uhd::usrp::multi_usrp::make(w->dev_args);
            w->usrp->set_rx_rate(cfg->rate);
            w->rate = w->usrp->get_rx_rate(0);
            for (int c = 0; c < w->nch; ++c) {
                w->usrp->set_rx_freq(uhd::tune_request_t(cfg->center_freq), c);
                w->usrp->set_rx_gain(cfg->gain, c);
            }
            w->freq = w->usrp->get_rx_freq(0);
            uhd::stream_args_t sa("sc16", w->otw);
            for (int c = 0; c < w->nch; ++c) sa.channels.push_back(c);
            w->rx = w->usrp->get_rx_stream(sa);
        }
    } catch (const std::exception& e) {
        fillerr(err, errlen, std::string("UHD: ") + e.what());
        return nullptr;
    }

    char gerr[256] = "";
    w->gpu = gpu_create(w->nch, w->nfft, w->hop, w->F, w->bins, cfg->window, gerr, sizeof gerr);
    if (!w->gpu) { fillerr(err, errlen, std::string("GPU: ") + gerr); return nullptr; }
    for (int i = 0; i < kSlots; ++i) {
        int16_t* p = (int16_t*)gpu_alloc_pinned((size_t)w->nch * w->S * 4);
        if (!p) { fillerr(err, errlen, "pinned allocation failed"); return nullptr; }
        w->slot.push_back(p);
        w->free_q.push_back(i);
    }
    w->lines.assign((size_t)kLineRing * w->nch * w->bins, 0.f);
    if (cfg->sim) make_pattern(w.get());
    return w.release();
}

int wf_start(wf_t* w) {
    if (w->run) return 0;
    try {
        if (!w->cfg.sim) {
            uhd::stream_cmd_t cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
            if (w->nch == 1) {
                cmd.stream_now = true;
            } else {
                cmd.stream_now = false;
                cmd.time_spec = w->usrp->get_time_now() + uhd::time_spec_t(0.2);
            }
            w->rx->issue_stream_cmd(cmd);
        }
    } catch (const std::exception& e) {
        w->set_error(std::string("UHD start: ") + e.what());
        return -1;
    }
    w->run = true;
    w->tcap = std::thread(capture_thread, w);
    w->tgpu = std::thread(gpu_thread, w);
    return 0;
}

int wf_read_line(wf_t* w, float* out, int timeout_ms) {
    std::unique_lock<std::mutex> l(w->lm);
    if (w->line_read >= w->line_head)
        w->lcv.wait_for(l, std::chrono::milliseconds(timeout_ms),
                        [&] { return w->line_read < w->line_head || !w->run; });
    if (w->line_read >= w->line_head) {
        std::lock_guard<std::mutex> e(w->em);
        return w->error.empty() ? 0 : -1;
    }
    size_t n = (size_t)w->nch * w->bins;
    std::memcpy(out, &w->lines[(w->line_read % kLineRing) * n], n * 4);
    ++w->line_read;
    return 1;
}

int wf_set_freq(wf_t* w, double hz) {
    try {
        if (w->usrp) {
            for (int c = 0; c < w->nch; ++c) w->usrp->set_rx_freq(uhd::tune_request_t(hz), c);
            w->freq = w->usrp->get_rx_freq(0);
        } else {
            w->freq = hz;
        }
    } catch (const std::exception& e) {
        w->set_error(std::string("set_rx_freq: ") + e.what());
        return -1;
    }
    return 0;
}

int wf_set_gain(wf_t* w, double db) {
    try {
        if (w->usrp)
            for (int c = 0; c < w->nch; ++c) w->usrp->set_rx_gain(db, c);
    } catch (const std::exception& e) {
        w->set_error(std::string("set_rx_gain: ") + e.what());
        return -1;
    }
    return 0;
}

void wf_set_detector(wf_t* w, int d) { w->detector = d ? 1 : 0; }
void wf_set_line_rate(wf_t* w, double r) { if (r > 0) w->line_rate = r; }

void wf_get_stats(wf_t* w, wf_stats_t* s) {
    s->samples_captured = w->cap;
    s->samples_processed = w->proc;
    s->batches_dropped = w->dropped;
    s->overflows = w->ovf;
    s->lines = w->nlines;
    s->lines_dropped = w->lines_dropped;
    s->gpu_ms_per_batch = w->gpu ? gpu_last_batch_ms(w->gpu) : 0;
    s->batch_ms = 1e3 * (double)w->newS / w->rate;
    s->rate = w->rate;
    s->center_freq = w->freq;
}

const char* wf_error(wf_t* w) {
    static thread_local std::string e;
    std::lock_guard<std::mutex> l(w->em);
    e = w->error;
    return e.c_str();
}

void wf_destroy(wf_t* w) {
    if (!w) return;
    w->run = false;
    w->scv.notify_all();
    w->lcv.notify_all();
    if (w->tcap.joinable()) w->tcap.join();
    if (w->tgpu.joinable()) w->tgpu.join();
    try {
        if (w->rx) w->rx->issue_stream_cmd(uhd::stream_cmd_t(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS));
    } catch (...) {
    }
    w->rx.reset();
    w->usrp.reset();
    gpu_destroy(w->gpu);
    for (auto p : w->slot) gpu_free_pinned(p);
    for (auto p : w->pat) gpu_free_pinned(p);
    delete w;
}
