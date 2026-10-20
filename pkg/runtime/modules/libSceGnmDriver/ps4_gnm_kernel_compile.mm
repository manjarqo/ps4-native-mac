// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PS4Recomp - background compilation of compute kernels (see ps4_gnm_kernel_compile.h).
 */
#include "ps4_gnm_kernel_compile.h"

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

namespace ps4gnm_kernels {

id<MTLFunction> Job::Wait(double* waited_ms) {
    if (Done()) {
        if (waited_ms) *waited_ms = 0;
        std::lock_guard<std::mutex> lk(mu_);
        return fn_;
    }
    const double t0 = CFAbsoluteTimeGetCurrent();
    std::unique_lock<std::mutex> lk(mu_);
    cv_.wait(lk, [this] { return done_.load(std::memory_order_relaxed); });
    if (waited_ms) *waited_ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    return fn_;
}

std::string Job::Error() const {
    std::lock_guard<std::mutex> lk(mu_);
    return err_;
}

void Job::Finish(id<MTLFunction> fn, const std::string& err, double ms) {
    {
        std::lock_guard<std::mutex> lk(mu_);
        fn_ = fn;
        err_ = err;
        compile_ms_ = ms;
        done_.store(true, std::memory_order_release);
    }
    cv_.notify_all();
}

Compiler::Compiler(id<MTLDevice> dev, MTLCompileOptions* (*make_options)(), unsigned max_parallel)
    : dev_(dev), make_options_(make_options),
      queue_(dispatch_queue_create("ps4.gnm.kernel_compile",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,
                                                                           QOS_CLASS_USER_INTERACTIVE, 0))),
      max_parallel_(max_parallel ? max_parallel : 1) {}

Compiler::~Compiler() {
    std::unique_lock<std::mutex> lk(mu_);
    idle_.wait(lk, [this] { return running_ == 0 && queued_.empty(); });
}

std::shared_ptr<Job> Compiler::Find(uint64_t mh) const {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = jobs_.find(mh);
    return it == jobs_.end() ? nullptr : it->second;
}

std::shared_ptr<Job> Compiler::Start(uint64_t mh, const std::string& msl, bool* started) {
    std::lock_guard<std::mutex> lk(mu_);
    auto& slot = jobs_[mh];
    if (slot) {
        if (started) *started = false;
        return slot;
    }
    slot = std::make_shared<Job>(mh);
    if (started) *started = true;
    started_.fetch_add(1, std::memory_order_relaxed);
    in_flight_.fetch_add(1, std::memory_order_relaxed);
    queued_.emplace_back(slot, std::make_shared<std::string>(msl));
    StartQueued();
    return slot;
}

void Compiler::StartQueued() {
    while (running_ < max_parallel_ && !queued_.empty()) {
        std::shared_ptr<Job> job = std::move(queued_.front().first);
        std::shared_ptr<std::string> src = std::move(queued_.front().second);
        queued_.pop_front();
        running_++;
        for (uint64_t p = peak_.load(std::memory_order_relaxed);
             running_ > p && !peak_.compare_exchange_weak(p, running_, std::memory_order_relaxed);) {
        }
        dispatch_async(queue_, ^{
            Run(job, src);
        });
    }
}

void Compiler::Run(std::shared_ptr<Job> job, std::shared_ptr<std::string> src) {
    @autoreleasepool {
        NSError* e = nil;
        const double t0 = CFAbsoluteTimeGetCurrent();
        id<MTLLibrary> lib = [dev_ newLibraryWithSource:[NSString stringWithUTF8String:src->c_str()]
                                                options:make_options_()
                                                  error:&e];
        id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"main0"] : nil;
        const double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        std::string err;
        if (!fn) {
            err = e ? e.localizedDescription.UTF8String : lib ? "no main0" : "unknown error";
            failed_.fetch_add(1, std::memory_order_relaxed);
        }
        compile_us_.fetch_add((uint64_t)(ms * 1000.0), std::memory_order_relaxed);
        in_flight_.fetch_sub(1, std::memory_order_relaxed);
        job->Finish(fn, err, ms);
    }
    std::lock_guard<std::mutex> lk(mu_);
    running_--;
    StartQueued();
    // under mu_: the destructor cannot return before this call has released it
    if (running_ == 0 && queued_.empty()) idle_.notify_all();
}

} // namespace ps4gnm_kernels
