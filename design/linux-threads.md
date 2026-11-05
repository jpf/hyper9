---
slug: linux-threads
title: Linux threads
status: draft
created: 2026-11-05
authors: [progrium]
depends: [18]
areas: [kern, vmm]
---

# Proposal: Linux threads

## Abstract

Linux processes under the [Linux personality](0018-linux-personality.md) can create threads with `clone(CLONE_VM | CLONE_THREAD | …)`, wait on and wake futexes, and be signalled per thread. Threads of one process run on several vCPUs at once, sharing one address space, so a change that narrows the address space is shot down on every vCPU running it before the host reuses the pages. This brings pthreads programs and Go's `linux/arm64` and `linux/amd64` binaries to h9.

## Background

The Linux personality runs one vCPU per address space at a time: a `vfork` parent waits for its child. Its VMA layer, and the vmm's range `unmap` and `protect`, take effect on a vCPU at its next run, through the HVF backend's epoch check and the emulator's per-engine sync.

That's not enough once two vCPUs run in one address space. A thread that calls `munmap` while another thread is in guest code leaves the other vCPU with stale TLB entries. If the host frees those pages and reuses them for another process, the running thread reads and writes that process's memory.

Other pieces already fit:

- `vmm.Extra.tls` carries the thread pointer, so `CLONE_SETTLS` is a store.
- drawterm's sleep and wakeup, with notes, already interrupt any blocking call, so a futex wait is interruptible for free.
- `cpupool` already handles more live processes than the hypervisor's vCPU cap, and threads are processes there.

## Proposal

### clone

- **`clone(CLONE_VM | CLONE_THREAD | CLONE_SIGHAND | …)`** creates a process that shares the whole address space, stack included, and the VMA list. That's unlike `RFMEM`, which copies the stack. The child gets the new stack pointer, and with `CLONE_SETTLS` its thread pointer in `vmm.Extra.tls`. `CLONE_FILES`, `CLONE_FS` and `CLONE_SIGHAND` share the fd group, the namespace and dot, and the signal actions; without them they're copied, as `rfork` does.
- **`CLONE_PARENT_SETTID`, `CLONE_CHILD_SETTID`, `CLONE_CHILD_CLEARTID`:** the tid is written where asked. At thread exit, the clear-tid word is zeroed and its futex woken.
- **`clone3`** with the same flags.
- **Thread groups:** a thread group is the processes created with `CLONE_THREAD` from one leader. `getpid` is the leader's pid, `gettid` the thread's own. `/proc/<pid>/task/<tid>` lists the group.
- **`exit_group`** and a fatal signal kill every thread in the group, and the group's exit status is the leader's wait record. **`execve`** from any thread kills the others first, and the new image runs with the leader's pid.

### futex

`futex` wait and wake are host-side queues keyed on the address space and the guest address, built on drawterm's sleep and wakeup, so notes and timeouts interrupt them like any other wait. `FUTEX_WAIT`, `FUTEX_WAKE`, `FUTEX_WAIT_BITSET`, `FUTEX_WAKE_BITSET`, `FUTEX_REQUEUE` and `FUTEX_CMP_REQUEUE` are served, with and without `FUTEX_PRIVATE_FLAG`. Shared futexes across `fork` key on the shared segment and offset instead. PI futexes are `-ENOSYS`. `set_robust_list` records the list, and thread exit walks it, marking each held lock's owner died and waking a waiter.

### TLB shootdown

The vmm gains a shootdown for address spaces with several vCPUs:

- Every `unmap` or `protect` that removes or narrows access, in an address space with other running vCPUs, kicks each of them and waits until each has acknowledged it'll flush before its next guest instruction. Only then does `munmap` return and the host free the pages.
- On HVF, a kicked vCPU exits, sees the changed epoch at its next run and has the shim flush, as today; the waiter only needs to know it has exited. On the emulator, the engine's sync at its next run is the flush.
- Widening changes (`mmap` of new pages, `mprotect` that adds access) need no shootdown; a stale TLB entry for an unmapped page faults, and the fault handler retries after checking the VMA.
- Pages freed by a shootdown that hasn't finished are never reused.

### Signals per thread

- Each thread has its own signal mask and pending set; the group has a shared pending set.
- **`tgkill` and `tkill`** target a thread. A thread running guest code is kicked so it takes the signal at its next exit, as a note does today. Go's preemption sends `SIGURG` this way, often.
- **`kill`** to a group picks any thread that doesn't block the signal.
- **`rt_sigtimedwait`** and `sigwaitinfo` take a pending signal without running a handler.

### Scheduling

- `sched_getaffinity` reports `--cpus`. `sched_setaffinity` is accepted and ignored.
- Threads count toward the vCPU cap and the pool, like processes. A Go program with many Ms is many processes past the cap, so it runs through the pool, as `mk -j` does today.

## Rationale

**Threads as processes.** Linux itself models threads as tasks sharing an address space, and h9's process record already has everything a task needs: its own vCPU lease, Ureg, Extra and kernel Proc. A second kind of record would duplicate all of that.

**Shootdown by kick, not by IPI.** h9 has no guest kernel to send IPIs to, and HVF has no API to flush another vCPU's TLB. A kick makes the vCPU exit, after which the host controls when it runs again. It costs an exit per running thread on each narrowing change, which Linux pays too in IPIs.

**Copy-on-write fork** would help Go and Python, which fork little, less than shells, which fork a lot but are single-threaded. It stays later performance work.

## Compatibility

- **vmm interface:** a shootdown call (`AddressSpace.shootdown`, or a flag on `unmap` and `protect`), and the HVF and emulator backends track which vCPUs are running each address space.
- No CLI flags or exit codes change.

## Security

- **Freed pages are never visible to a stale TLB.** The shootdown completes before any page leaves the address space's ownership. This gets its own stress test: threads read a page in a loop while another unmaps and the host reuses it, and no read sees the new owner's data.
- **futex keys** include the address space, so one machine's or process's futexes can't wake another's.
- **Thread-group kills** go through the same note delivery as today, so `kill` from `/proc/n/ctl` still kills a thread that blocks every signal.

## Done when

Integration cases tagged `[linux-threads]`:

- `test "pthreads program with 8 threads and a mutex [linux-threads]"`
- `test "Go linux binary starts goroutines and sleeps [linux-threads]"`
- `test "munmap while another thread reads: no stale access after return [linux-threads]"`
- `test "exit_group kills every thread [linux-threads]"`
- `test "execve from a non-leader thread [linux-threads]"`
- `test "tgkill interrupts a thread in a busy loop [linux-threads]"`
- `test "CLONE_CHILD_CLEARTID wakes pthread_join [linux-threads]"`

Demo: a Go program built with `GOOS=linux GOARCH=arm64` runs natively on HVF.

## Implementation

1. Thread groups, `clone` with `CLONE_VM`, TLS, the tid words, `exit_group`. A pthreads hello.
2. futex, robust lists. pthreads with mutexes and condition variables.
3. The shootdown in both backends, and its stress test.
4. Per-thread signals and `tgkill`. Go.
5. DESIGN.md's Linux personality section gains threads.

## Open issues

- **Per-thread CPU time** for `CLOCK_THREAD_CPUTIME_ID`, which Go's profiler reads.
- **The vCPU cap.** A Go program can have more threads than HVF has vCPUs. The pool handles it, at the cost of two thread wake-ups per syscall for threads past the cap; whether that matters for Go's scheduler needs measuring.
