//
// uhd_rfsoc -- a small pool of pinned worker threads for the per-sample work
// of recv()/send() (de-interleave + format conversion, rfsoc_kernels.hpp).
//
// run(n, fn, ctx) hands tasks 0..n-1 to the workers AND the calling thread
// and returns when every task has finished. The work is split by the caller
// into disjoint output ranges, so tasks never synchronise with each other.
//
// Dispatch is a single 64-bit atomic (generation | task count | next task):
// a worker claims a task with one fetch_add; a claimed task index below the
// count is always valid for the parameters published with that generation,
// because the caller does not publish the next generation before every task
// of the current one is done. Workers busy-wait (pause) for spin_us after
// their last task, so back-to-back calls cost ~100 ns to dispatch, then sleep
// on a futex. If another thread holds the pool (RX and TX in two application
// threads), run() does all the tasks on the calling thread instead of
// waiting: the caller never blocks on the pool.
//
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace rfsoc {

class worker_pool
{
public:
    using task_fn = void (*)(void* ctx, size_t task);

    //! one worker per entry of cpus (pinned there; -1 = not pinned)
    worker_pool(const std::vector<int>& cpus, double spin_us);
    ~worker_pool();
    worker_pool(const worker_pool&) = delete;
    worker_pool& operator=(const worker_pool&) = delete;

    size_t workers() const
    {
        return _threads.size();
    }
    //! run fn(ctx, t) for t = 0..ntasks-1 (ntasks < 65536), in parallel;
    //! returns when all are done
    void run(size_t ntasks, task_fn fn, void* ctx);
    //! "4 worker(s) on CPUs 8,9,10,11"
    std::string desc() const;
    //! calls that ran on the workers / fell back to the caller alone (busy)
    uint64_t parallel_calls() const
    {
        return _par.load(std::memory_order_relaxed);
    }
    uint64_t inline_calls() const
    {
        return _inl.load(std::memory_order_relaxed);
    }

private:
    void _worker(size_t idx, int cpu);
    static uint32_t _gen(uint64_t s)
    {
        return uint32_t(s >> 48);
    }

    alignas(64) std::atomic<uint64_t> _state{0}; // gen[63:48] | ntasks[47:32] | next[31:0]
    alignas(64) std::atomic<uint32_t> _done{0};
    alignas(64) std::atomic<uint32_t> _wake{0}; // futex word
    std::atomic<int> _sleepers{0};
    std::atomic<task_fn> _fn{nullptr};
    std::atomic<void*> _ctx{nullptr};
    std::atomic<bool> _stop{false};
    std::atomic<uint64_t> _par{0}, _inl{0};
    std::mutex _busy;
    uint64_t _spin_ns = 200000;
    std::vector<int> _cpus;
    std::vector<std::thread> _threads;
};

} // namespace rfsoc
