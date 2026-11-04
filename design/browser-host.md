---
slug: browser-host
title: A browser host on wasm, with v86
status: draft
created: 2026-11-04
authors: [progrium]
depends: [i386]
areas: [vmm, kern, build, tests]
---

# Proposal: a browser host on wasm, with v86

Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9 builds for wasm32 and runs in a Web Worker, with no VM image, boot or guest kernel, as on every other host. drawterm's kernel runs unchanged above a new OS layer whose kernel processes are coroutines, built on JavaScript Promise Integration (JSPI). Guest code runs on a new vmm backend, v86, which emulates a 32-bit x86 CPU and compiles hot code to wasm, so the browser host runs 9front's 386 binaries ([i386](i386.md)). The same build runs under Node, which is how the integration suite tests it.

## Background

Today h9 needs a host OS: threads for kernel processes, POSIX or Win32 for devfs, and a hypervisor or Unicorn for guest code. None of those exist in a browser.

What does exist:

- **wasm, in a Worker.** It can run for as long as it needs and block only through the event loop.
- **JSPI.** A wasm call into JavaScript can return a Promise, and the wasm stack suspends until the Promise settles. JSPI is phase 4. As of mid-2026 it ships in Chrome and Edge 137 and later and in Safari 27 beta, and in Firefox Nightly behind a pref, with default-on intended for Firefox 153.
- **v86.** A BSD-2-licensed x86 PC emulator whose CPU core is Rust compiled to wasm. Its JIT turns hot guest code into wasm modules. It emulates 32-bit x86 with x87, SSE2, FXSAVE and PAE paging. Its run loop (`main_loop`) runs guest code in slices of about 1 ms and returns early when the CPU halts. Its registers sit at fixed addresses in its linear memory.
- **9front's 386 port,** still released ([i386](i386.md)).

drawterm's kernel reaches its OS through a small layer, `kern/posix.c` or `kern/win32.c`:

- `osproc` starts a kernel process on a thread
- `procsleep` and `procwakeup` block and wake it
- `_getproc` and `_setproc` hold `up`
- `osyield`, `osmsleep`, `seconds`, `ticks` and `randomread` cover time and randomness
- `oscmd` runs host commands

Everything else in kern (chans, devmnt, qio, `sleep`/`wakeup`, qlocks) is built on that layer. Only three other pieces of state are per thread: `up`, h9's `fs_plan` (a `threadlocal` in `src/kern.zig`) and libc's `errno`.

## Proposal

### Shape

```
main thread (page)                 Worker
  terminal UI  ── postMessage ──>  h9-web.js      JS host: coroutines, console, WASI shim, v86 glue
                                   h9.wasm        Zig + drawterm C, wasm32-wasi
                                   v86.wasm       v86's CPU core, sharing h9.wasm's memory
```

One Worker holds one machine. Inside it everything is single-threaded. Concurrency comes from coroutines: one per kernel process, plus a few for h9's own tasks, such as the console reader.

### Coroutines on JSPI

- **Entry.** `h9.wasm` exports `h9_coro_entry(fn, arg)`. The JS host wraps it once with `WebAssembly.promising`. Starting a coroutine is calling the wrapped function without awaiting it, which gives the coroutine its own suspendable wasm stack.
- **Parking.** All blocking goes through one import, `h9_park(token)`, wrapped with `WebAssembly.Suspending`. It returns a Promise that `h9_unpark(token)` resolves. A coroutine that parks gives the event loop back, and the event loop is the scheduler.
- **The OS layer** is `src/kern/os-wasm.c`, built instead of drawterm's `kern/posix.c`. The vendored tree stays unmodified.

  | drawterm | os-wasm.c |
  | --- | --- |
  | `osproc(p)` | Allocates a stack and starts a coroutine running `p->fn` |
  | `procsleep`, `procwakeup` | `h9_park`, `h9_unpark` on the Proc's token |
  | `_getproc`, `_setproc` | A global `up`, swapped on every switch |
  | `osyield` | Parks on a Promise resolved through a `MessageChannel`, which isn't clamped like `setTimeout` |
  | `osmsleep` | Parks on a timer |
  | `seconds`, `ticks` | `Date.now()`, `performance.now()` |
  | `randomread` | `crypto.getRandomValues` |
  | `oscmd` | Not built: `#C` is unavailable |
  | `tas` | Unchanged. With one thread, a contended spin lock is a bug, so `lock` asserts it's free. |

- **Per-coroutine state.** wasm globals aren't per stack, so every switch saves and restores:
  - `__stack_pointer`, the C and Zig shadow stack. Each coroutine gets its own stack region, 256 KiB by default. The pointer is read and set from `src/web/stack.S`, since there's no builtin for it.
  - drawterm's `up`.
  - h9's `fs_plan`.
  - libc's `errno`. devfs reads it after host calls, and another coroutine may have run in between.

  `h9_park` does the save and restore, so no other code needs to know.
- **No JS frame under a park.** JSPI traps if a suspension crosses a JavaScript frame. Parks happen only in kernel code that wasm reached from `h9_coro_entry`. JS imports that wasm calls, such as v86's `microtick` and the WASI shim, return without parking. Imports that do park are wrapped as `Suspending`.
- **Errors.** drawterm's `waserror`/`error` is setjmp and longjmp. In wasm that's the exception-handling proposal:
  - C is compiled with `-mexception-handling -mllvm -wasm-enable-sjlj`.
  - wasi-libc's `setjmp/wasm32/rt.c` is linked in.
  - The link step itself doesn't take `-mexception-handling`.

  With Zig 0.16 this builds and runs under Node 22. A longjmp unwinds only within its own coroutine's stack, which is where seam rule 1 already keeps it.

### h9's own threads

h9 uses `std.Thread` in four places:

- the kernel's boot thread (`kern.zig`)
- the console reader (`consin.zig`)
- the vCPU pool (`cpupool.zig`)
- the CLI's signal watcher (`hostsig.zig`)

On the web host the boot thread and the console reader run as coroutines, through `h9_kern_spawn`'s path or `std.Io.concurrent`. The pool is never needed, since v86's vCPUs are cheap contexts and `maxVcpus` is large. The signal watcher isn't built.

h9 also passes a `std.Io` everywhere. The web host provides `src/web/io.zig`, a `std.Io` whose futex wait parks, whose `concurrent` starts a coroutine, and whose clock is `performance.now()`. Operations the host doesn't have fail with an error.

These are internal changes: on native hosts everything stays on threads as now.

### Filesystem: WASI

`h9.wasm` targets wasm32-wasi, so drawterm's devfs-posix builds as it is against wasi-libc. The root tree is a WASI preopened directory, and the sandbox policy's `h9_fs_check` hooks keep working.

- **Node** provides WASI with real host directories, so the integration suite runs against the same root tree on disk as native runs.
- **In the browser,** the JS host implements the WASI calls devfs uses over an in-memory tree. The tree is loaded from a root archive that `zig build web` makes from the root tree.

WASI imports can be `Suspending` like any other, so a later backing can be asynchronous: files fetched on demand, OPFS for persistence, or a Wanix filesystem. The kernel doesn't change for any of these.

### Console

The machine's console (`#y`) is fed by the page. `Machine.Stdio` is implemented by the JS host:

- writes post messages to the main thread
- reads park until a message brings input
- `rawon` and `rawoff` tell the page's terminal to switch modes

The page sends an interrupt key as `Machine.Signals.interrupt`, which posts `interrupt` to the foreground note group, as Ctrl-C does on a TTY.

### The v86 backend

`src/vmm/v86.zig` implements Backend, AddressSpace and Vcpu over one v86 CPU per machine.

**One memory.** `h9.wasm` and `v86.wasm` share one linear memory, so `AddressSpace.translate` can return a host slice as the contract requires, and the kernel reads syscall arguments in place.

- `v86.wasm` owns the low part of the memory: its fixed register block, its data and its stack.
- `h9.wasm` is linked with `--import-memory`, with its data and stack placed above that part.
- Both modules' heaps grow with `memory.grow`, which hands each grow to the module that asked.
- v86's guest RAM is one allocation from v86 (`allocate_memory`), sized by `--memory`. It's the guest-physical region every backend has, and `allocPages` hands out pages from it.

**Guest kernel and shim.** `src/arch/i386/shim.S` is loaded at a fixed guest-physical address and started in real mode, as a boot sector would be. It:

1. sets up a GDT (kernel and user code and data, a TSS), an IDT and paging
2. enables FXSR
3. halts

The GDT, IDT and TSS are shared by every vCPU, since only one runs at a time. Then:

- **Trap entry.** On any trap or `INT $64`, the shim's vector pushes a frame on the kernel stack and halts. The frame is exactly the 386 Ureg: PUSHAL order, the segment registers, trap and error code, then the hardware's iret frame. A page fault also stores CR2.
- **Exit.** The halt ends v86's run loop, and the backend reads the Ureg straight from the kernel stack page. This differs from the `OUT` doorbell other x86 backends use. v86 hands port I/O to a JS import and keeps running, while a halt returns from `main_loop` with no JS call.
- **Resume.** The backend writes the Ureg into the frame, points ESP at it and EIP at the shim's restore path (pop the registers, `iret`), clears the halt and calls `main_loop`.

**Vcpus are contexts.** A Vcpu is a Ureg, an FXSAVE image and a page-directory address. `run` installs them, with `fxrstor` and `fxsave` in the shim only when the context differs from the one last run. It sets CR3, which flushes v86's TLB, then calls `main_loop` until a halt or the end of the slice.

**Preemption.** When a slice ends without a halt, `run` parks through `osyield` and then returns `.interrupted`. `Machine` already treats that exit as "deliver notes, then run again". A spinning guest gets about 1 ms before every other coroutine and the page's messages get a turn. The vmm interface doesn't change. `kick`, from another coroutine, sets a flag that `run` checks between slices.

**Address spaces.**
- Each address space is a two-level 386 page directory in guest-physical memory, as 9front's pc kernel uses. Text is mapped read-only; as on 9front 386, nothing is marked non-executable.
- `map` and `unmap` write page-table entries.
- `unmap` on the address space that's running also clears v86's TLB through its `clear_tlb` export.

**The JIT and host writes.** v86 notices guest writes to pages it has compiled, but h9's writes go around it. The loader copying text and syscalls filling buffers write the memory directly. So the backend calls v86's `jit_dirty_cache` for a page when it's freed and when it's mapped executable. Recycled pages then never run stale compiled code.

**Faults.** A page fault exits as `.fault` with CR2 and the access type from the error code. Other vectors fault with the vector as the syndrome. `Ureg.trap` holds what 9front's kernel puts there.

**The glue.** v86's own JavaScript (`cpu.js`, `starter.js`) isn't used. `h9-web.js` provides the imports `v86.wasm` needs:
- `microtick`
- `run_hardware_timers`, which returns at once since there are no devices
- `codegen_finalize` and `jit_clear_func` for the JIT: compile the generated module, which a Worker may do synchronously, and set it in the shared function table
- stubs for the port and MMIO imports, which a guest at ring 3 can't reach

**Selection.** `vmm.Kind` and `BackendKind` gain `v86`. It's the only backend in web builds, and `auto` picks it. It runs i386 only; anything else fails with `WrongArch`.

### Build and API

- `zig build web` produces `zig-out/web/`: `h9.wasm`, `h9-web.js`, `v86.wasm` with its BSD-2 notice, a root archive, and a demo page.
- `v86.wasm` is a pinned release build, fetched by `scripts/fetch.sh` and checked against a hash in `scripts/pins.sh`, as Unicorn's wheels are. `-Dv86=source` builds it from the pinned source with cargo instead.
- The CLI's `cli.zig` and `main.zig` build into `h9.wasm` too, so Node can run `h9` with the same flags (`zig-out/web/h9-node`).
- In the page, `h9-web.js` exports `createMachine({ root, memory, policy, terminal })` and `machine.run(argv)`. Both mirror `Machine.init` and `run` and return the same exit status.

## Rationale

**Why v86 rather than waiting for the interpreter.** v86 is mature and already compiles x86 to wasm, which is the fastest way to run guest code in a browser. It needs no new CPU work, only a backend, a shim and glue. The [zig-interpreter](zig-interpreter.md) is complementary: once it exists it can run arm64 binaries on the web host from the same root tree, and v86 stays for x86. Neither proposal depends on the other.

**Why 386.** v86 has no long mode, so amd64 isn't possible on it. 9front still builds and releases 386, and its compilers are the same family as 7c and 6c.

**Why JSPI.** It keeps drawterm's blocking code as it is. Each kernel process blocks on its own stack, as it does on a thread.

- **Asyncify** instruments every function that could be on the stack during a suspend, which here is most of the kernel. It grows code size and slows every call. It stays available as a fallback for browsers without JSPI (Open issues).
- **wasm threads with SharedArrayBuffer** map more directly onto drawterm's threads. But they need the page to be cross-origin isolated, which limits where h9 can be embedded. They need wasi-threads support in Zig and libc. And they gain little, since one v86 CPU runs one context at a time.
- **An event-driven rewrite of the kernel** would leave drawterm behind for good.

**Why share one memory.** The vmm contract hands the kernel host slices of guest memory. With two memories, every syscall argument, read and write would be a copy through JavaScript.

**Why WASI for files.** devfs-posix, and the sandbox hooks in it, work unchanged. Node's WASI gives the test suite real directories, and the browser only needs a WASI shim, for which there are existing implementations to start from. A dedicated device would duplicate devfs.

**Alternatives rejected.**
- **Booting 9front itself in v86.** That's already possible with v86 alone, and it's what h9 exists to avoid.
- **Wanix as the kernel.** h9 would lose drawterm's semantics and its own process model. Wanix fits better as something the root or namespace is backed by.
- **Unicorn compiled to wasm.** It's GPL, interprets in wasm without a JIT to wasm, and is a large build.

## Compatibility

- **DESIGN.md's goals.** "Run native code only" and the non-goal of translating across architectures for users assume a CPU to run natively on. A browser has none. DESIGN.md would say that the web host runs 386 binaries on v86, and that this is its only mode.
- **vmm.** `Kind` and `BackendKind` gain `v86`. `--backend v86` is accepted everywhere and fails with `BackendNotBuilt` outside web builds. The [i386](i386.md) proposal changes `Extra`; this one changes nothing else in the interface.
- **Machine and CLI.** `Machine.Options` is unchanged. In web builds the policy always masks `#C`, which doesn't exist, and `#I`, since there's no socket API. `--net` other than `disable` is listed as unenforced, and `--strict` refuses it. `--host-cmd` is a usage error.
- **Build and releases.** A new step, `zig build web`, and a new release archive, `h9-web-<version>.tar.gz`. Native builds are unchanged. h9 stays MIT. The archive carries v86's BSD-2 notice and the root archive's 9front licence.
- **Root tree.** The [i386](i386.md) root. The browser gets an archive of it.
- **`third_party/`.** Unchanged. v86 isn't vendored: the build fetches or builds it from a pin.

## Security

**The boundary.** In a browser the outermost sandbox is the browser's: the Worker reaches nothing beyond what `h9-web.js` gives it. Inside it, the guest is isolated from the kernel by v86's emulation and by the kernel itself, which serves every syscall, as on the emulator backend.

**One memory.** Because guest RAM and h9's heap are one linear memory, a bug in v86 that reaches outside guest RAM could corrupt the kernel. A Unicorn bug can corrupt the native h9 process the same way, but two separate memories would have contained it. That's the cost of in-place syscall arguments.

**Guest reach.** It's only the namespace the policy builds:
- the root archive or a directory the embedder lends through WASI
- the console
- no network
- no host commands

Nothing in the page is reachable except through those imports.

**v86's JIT** generates wasm from guest code. That wasm runs inside the same Worker sandbox with access to the same linear memory, so it adds nothing a v86 interpreter bug wouldn't.

**The embedder** decides what the root and lent directories contain, and whether OPFS persistence is used. The JS API takes the same `Policy` as native embedders.

## Done when

- `zig build web` builds `zig-out/web/` from a clean checkout, with `v86.wasm` checked against its pin.
- Under Node with JSPI, `zig build integration -Dweb` passes the `[baseline]` cases on `H9_TEST_BACKENDS=v86` and the 386 root. The exceptions are cases that need a host TTY or POSIX signals, which the web host doesn't have: raw mode, Ctrl-C, SIGTERM and hangup. Those skip on web builds, by name.
- `tests/backends.zig` passes on v86 under Node for its i386 cases.
- New cases tagged `[browser-host]`:
  - `test "a spinning process doesn't starve a pipeline [browser-host]"`
  - `test "a console read parks and resumes on input [browser-host]"`
  - `test "a note interrupts a parked console read [browser-host]"`
  - `test "errno survives a park [browser-host]"`
  - `test "exec into recycled pages doesn't run stale JIT code [browser-host]"`
  - `test "RFMEM processes see each other's writes [browser-host]"`
- **Demo:** the page from `zig build web` runs an interactive rc in Chrome. `ls /bin | wc -l` prints the count, and the interrupt key stops `cat` and returns to rc. A Playwright test in CI does the same.

## Implementation

1. **Spike in Node.** Get kern building for wasm32-wasi with the sjlj flags. Run one coroutine that parks in `procsleep` and is woken from JS, with the `__stack_pointer`, `up` and `errno` swap in place. This tests JSPI, the stack switching and setjmp together before anything else depends on them.
2. **Shared memory spike.** Instantiate `v86.wasm` and `h9.wasm` on one memory and check the layout. Decide between the prebuilt v86 and a source build with `--import-memory` (Open issues).
3. **The OS layer and Io.** `src/kern/os-wasm.c`, `src/web/stack.S`, `src/web/io.zig`, and the four `std.Thread` uses moved behind them.
4. **WASI root under Node.** `h9-node` runs `echo` from a 386 root on a stub backend that only executes syscalls.
5. **The v86 backend.** The shim, contexts, faults, preemption and JIT dirtying. Then the integration suite under Node.
6. **Browser.** The WASI shim over the root archive, the console over messages, the demo page and the Playwright test.
7. **Release and docs.** The `h9-web` archive in `scripts/release.sh`, the README, and DESIGN.md's host and backend sections. Set `status: implemented`.

## Open issues

- **The memory layout.** It's not yet checked whether the prebuilt `v86.wasm`'s data, stack and allocator leave room for a second module on its memory. If not, v86 is built from source with `--import-memory` and a fixed base, which puts cargo in the build.
- **Browsers without JSPI.** Firefox until it ships JSPI by default, and Safari until 27. An Asyncify build is the fallback. It needs measuring for size and speed, and deciding whether it's shipped or only documented.
- **Delivering the root.** A 386 root is large to load up front. Files could be fetched on demand through `Suspending` WASI calls, cached in OPFS, or served by Wanix. Once [9p-roots](9p-roots.md) exists, a 9P root over a WebSocket or a MessagePort is another option.
- **Network.** None, at first. A WebSocket relay or Wanix's network could back devip later, as a separate proposal.
- **Graphics.** [gfx](gfx.md) on a canvas, through devdraw, would be its own proposal.
- **Coroutine stack size.** 256 KiB is a guess. Kernel paths with large frames may need more, and memory for many processes adds up, since wasm memory never shrinks.
- **Time.** `Tos.cyclefreq` and `kcycles` on the web host, and whether `/dev/bintime` can be finer than devcons's one second here ([go-compat](0007-go-compat.md)).
- **arm64 on the web host.** Once [zig-interpreter](zig-interpreter.md) exists, the web host can run arm64 binaries on it. The question is whether the browser then gets an arm64 root, or both.