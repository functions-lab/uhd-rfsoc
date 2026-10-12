//
// uhd_zcu216 -- worker pool (see zcu216_pool.hpp).
//
#include "zcu216_pool.hpp"
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <chrono>
#include <climits>
#include <ctime>

namespace zcu216 {

namespace {
inline void relax()
{
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#endif
}
inline uint64_t now_ns()
{
    return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch())
                        .count());
}
void futex_wait(std::atomic<uint32_t>* w, uint32_t val, long timeout_ns)
{
    timespec ts{timeout_ns / 1000000000L, timeout_ns % 1000000000L};
    ::syscall(SYS_futex, reinterpret_cast<uint32_t*>(w), FUTEX_WAIT_PRIVATE, val, &ts, nullptr, 0);
}
void futex_wake_all(std::atomic<uint32_t>* w)
{
    ::syscall(SYS_futex, reinterpret_cast<uint32_t*>(w), FUTEX_WAKE_PRIVATE, INT_MAX, nullptr, nullptr, 0);
}
} // namespace

worker_pool::worker_pool(const std::vector<int>& cpus, double spin_us)
    : _spin_ns(uint64_t(spin_us > 0 ? spin_us * 1000.0 : 0.0)), _cpus(cpus)
{
    for (size_t i = 0; i < cpus.size(); i++)
        _threads.emplace_back([this, i, c = cpus[i]] { _worker(i, c); });
}

worker_pool::~worker_pool()
{
    _stop.store(true);
    _wake.fetch_add(1);
    futex_wake_all(&_wake);
    for (auto& t : _threads)
        t.join();
}

std::string worker_pool::desc() const
{
    std::string s = std::to_string(_threads.size()) + " worker(s)";
    std::string c;
    for (int x : _cpus)
        c += (c.empty() ? "" : ",") + (x < 0 ? std::string("*") : std::to_string(x));
    return _cpus.empty() ? s : s + " on CPUs " + c;
}

void worker_pool::_worker(size_t idx, int cpu)
{
    char name[16];
    std::snprintf(name, sizeof(name), "zcu216_w%zu", idx);
    pthread_setname_np(pthread_self(), name);
    if (cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    }
    uint32_t seen = _gen(_state.load(std::memory_order_acquire));
    while (not _stop.load(std::memory_order_relaxed)) {
        // wait for a new generation: spin, then sleep on the futex
        uint64_t t0 = now_ns();
        for (unsigned i = 1; _gen(_state.load(std::memory_order_acquire)) == seen; i++) {
            if (_stop.load(std::memory_order_relaxed))
                return;
            if (i % 128) {
                relax();
                continue;
            }
            if (now_ns() - t0 < _spin_ns)
                continue;
            const uint32_t w = _wake.load();
            _sleepers.fetch_add(1);
            if (_gen(_state.load()) == seen and not _stop.load())
                futex_wait(&_wake, w, 100000000L);
            _sleepers.fetch_sub(1);
            t0 = 0; // a timeout sleeps again at once; new work leaves the loop
        }
        // claim tasks
        while (true) {
            const uint64_t s = _state.fetch_add(1, std::memory_order_acq_rel);
            seen             = _gen(s);
            const uint32_t n = uint32_t(s >> 32) & 0xFFFFu, t = uint32_t(s);
            if (t >= n)
                break;
            _fn.load(std::memory_order_relaxed)(_ctx.load(std::memory_order_relaxed), t);
            _done.fetch_add(1, std::memory_order_release);
        }
    }
}

void worker_pool::run(size_t ntasks, task_fn fn, void* ctx)
{
    if (ntasks == 0)
        return;
    std::unique_lock<std::mutex> lk(_busy, std::defer_lock);
    if (_threads.empty() or ntasks < 2 or ntasks > 0xFFFF or not lk.try_lock()) {
        _inl.fetch_add(1, std::memory_order_relaxed);
        for (size_t t = 0; t < ntasks; t++)
            fn(ctx, t);
        return;
    }
    _par.fetch_add(1, std::memory_order_relaxed);
    _fn.store(fn, std::memory_order_relaxed);
    _ctx.store(ctx, std::memory_order_relaxed);
    _done.store(0, std::memory_order_relaxed);
    const uint64_t g = (uint64_t(_gen(_state.load(std::memory_order_relaxed))) + 1) & 0xFFFFu;
    _state.store((g << 48) | (uint64_t(ntasks) << 32), std::memory_order_seq_cst);
    _wake.fetch_add(1, std::memory_order_seq_cst);
    if (_sleepers.load(std::memory_order_seq_cst) > 0)
        futex_wake_all(&_wake);
    // the caller works too
    while (true) {
        const uint64_t s = _state.fetch_add(1, std::memory_order_acq_rel);
        const uint32_t t = uint32_t(s);
        if (t >= ntasks)
            break;
        fn(ctx, t);
        _done.fetch_add(1, std::memory_order_release);
    }
    while (_done.load(std::memory_order_acquire) < ntasks)
        relax();
}

} // namespace zcu216
