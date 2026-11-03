# Design: Plan 9 executables on host hypervisors

Nov 2, 2026 · @Jeff Lindsay

## Overview

We will build a small Zig library and CLI that runs native 9front executables directly on macOS, Linux and Windows, using each host's hypervisor API. Each guest process runs in hardware-isolated user mode, and its syscalls are served by drawterm's Plan 9 kernel running in the host process. Prior art: hyper-linux (the same shape for Linux ELF on macOS) and 9vx (Plan 9 binaries on Linux and OS X x86 through a vx32 sandbox).

**Goals**

- Start and run a 9front binary as fast as a native process: no VM image, no boot, no guest kernel.
- One invocation can hold a whole process tree (rc pipelines, servers posting to /srv, rio and its clients).
- Run native code only: arm64 9front binaries on arm64 hosts, amd64 binaries on x86\_64 hosts.
- One host backend each for Hypervisor.framework (macOS), KVM (Linux) and Windows Hypervisor Platform (Windows).
- Self-hosting: the 9front compilers and mk run inside and can rebuild the 9front userland.

**Non-goals (for now)**

- Running the 9front kernel itself, or drivers for real hardware.
- Translating across architectures (amd64 binaries on arm64 hosts, or the reverse) for users. The emulator can do it, but only for testing.
- Plan 9 4th edition or other forks: their syscall tables differ.
- A long-running daemon. Each invocation is its own machine.

## Decisions

| Area | Decision | Notes |
| --- | --- | --- |
| Product shape | A library plus a thin CLI; each invocation is one machine | One machine can hold a whole process tree. Keep the machine API free of CLI-global state. |
| Plan 9 flavour | 9front only, at a pinned release | One syscall table and one a.out format per architecture |
| Root filesystem | Direct host tree first | 9P mounts (remote servers, cwfs or gefs as guests) come next; devmnt already exists |
| Toolchain inside | The 9front compilers (7c/6c, 7l/6l, mk) must run | It's a milestone, and it's a source of test binaries |
| Language | Zig, latest stable (0.16.x as of writing) | Change versions only when we hit a blocking bug. drawterm's C is compiled with `zig cc`. |
| Terminal | Text mode on the host TTY by default; graphics behind a flag | consctl `rawon`; the interrupt key posts an `interrupt` note |
| Guest exit mechanism | MMIO doorbell (`OUT` on x86) | Works the same on all three hypervisors |
| Emulator | A user-mode emulator backend: Unicorn first, a native Zig interpreter later | For development and CI on hosts and VMs without a usable hypervisor |

## Architecture

&#91;embedded content: architecture · host process, guest VM, host OS\]

Each Plan 9 process runs in user mode on its own vCPU. A syscall traps into the shim, exits through the doorbell, and is served by drawterm's kernel on the host. The new code is the machine library (highlighted), the vmm backends and the shims; the CLI is a thin wrapper.

## Hypervisor layer (`vmm`)

A small Zig interface hides the three hypervisor APIs and the emulator. Everything above it is written once.

```zig
// vmm.create picks a backend at run time: .auto tries the host hypervisor, then the emulator.
pub fn create(gpa, io, want: BackendKind, opts: Options) !Backend;   // Options: { arch: Arch }

// One address space per Plan 9 process. Each backend decides how to realize it:
// the hypervisors build 4K page tables, the emulator keeps a virtual-address -> host-memory map.
const AddressSpace = union(Kind) {             // Kind: hvf, emu (kvm and whp from M8 and M9)
    pub fn map(self, va: u64, mem: []align(4096) u8, perms: Perms) !void;
    pub fn unmap(self, va: u64, len: u64) !void;          // from M3
    pub fn protect(self, va: u64, len: u64, perms: Perms) !void;
    pub fn translate(self, va: u64, len: u64) ?[]u8;      // host view, for syscall arguments
};
const Backend = union(Kind) {
    pub fn kind(self) Kind;
    pub fn allocPages(self, n: usize) ![]align(4096) u8;  // memory that address spaces can map
    pub fn maxVcpus(self) !u32;
    pub fn newAddressSpace(self) !AddressSpace;
    pub fn createVcpu(self) !Vcpu;             // on the thread that will run it
};
const Vcpu = union(Kind) {
    pub fn setAddressSpace(self: *Vcpu, as: AddressSpace) !void;
    pub fn run(self: *Vcpu) !Exit;             // blocks until the next exit
    pub fn getUreg(self: *Vcpu, u: *Ureg) void;        // Plan 9 Ureg layout
    pub fn setUreg(self: *Vcpu, u: *const Ureg) void;
    pub fn kick(self: *Vcpu) void;             // safe from any thread
};
const Ureg = union(Arch) { arm64: arm64.Ureg, amd64: amd64.Ureg };
const Exit = union(enum) { syscall, fault: Fault, interrupted, halted, other: u64 };
```

Each backend is a file under `src/vmm/` with the same method set; the unions dispatch to it. Backends not built into a given hp9 are replaced by a stub whose `create` fails with `BackendNotBuilt`, so every host builds the same code. A backend that can't run the binary's architecture fails with `WrongArch`; HVF runs arm64 only.

The contract is in Plan 9 terms (address spaces, Ureg, syscall exits) rather than hardware terms such as guest-physical memory and page tables. That keeps page-table building inside the hypervisor backends, and lets the emulator implement the contract without emulating kernel mode or an MMU.

| Operation | macOS: Hypervisor.framework | Linux: KVM | Windows: WHP |
| --- | --- | --- | --- |
| Create VM | `hv_vm_create` | `KVM_CREATE_VM` | `WHvCreatePartition` + `WHvSetupPartition` |
| Map memory | `hv_vm_map` | `KVM_SET_USER_MEMORY_REGION` | `WHvMapGpaRange` |
| Run vCPU | `hv_vcpu_run` | `KVM_RUN` | `WHvRunVirtualProcessor` |
| Kick vCPU | `hv_vcpus_exit` | `immediate_exit` + signal to the thread | `WHvCancelRunVirtualProcessor` |
| Access needed | `com.apple.security.hypervisor` entitlement | read/write on `/dev/kvm` | the optional Windows Hypervisor Platform feature |

**Rules that keep the interface portable**

- **Exits:** the shim exits to the host by storing to an unmapped doorbell address (MMIO), or with `OUT` on x86. All three hypervisors hand that exit to userspace, so we don't depend on HVC or VMCALL handling, which differs across them. On arm64 KVM in particular, the kernel handles HVC itself unless hypercall filtering is configured.
- **Threads:** a vCPU is created, run and destroyed on one host thread, which is HVF's rule and the strictest of the three. `kick` is the only call allowed from another thread.
- **Memory:** one large guest-physical region is mapped once at VM creation. A host-side page allocator hands out guest-physical pages from it. We never map per segment, because KVM caps the number of memory slots and mapping calls are slow everywhere.
- **Page size:** guest page tables use 4K pages on every host, matching 9front's page size on both architectures. hyper-linux shows HVF guests can use 4K pages. Only the single host memory region has to be aligned to the host page size (16K on Apple Silicon).
- **No hypervisor:** `create` fails cleanly with a clear message. An interpreter backend could implement the same interface later.

## Emulator backend (`emu`)

The emulator lets the system run anywhere, including VMs without nested virtualization, at reduced speed. It implements the same Backend, AddressSpace, Vcpu and Exit contract, so everything above the vmm layer runs unchanged.

**Scope:** user-mode arm64 and amd64 code only. On an `SVC` or `SYSCALL`, or on a fault, the emulator fills the Ureg and returns the exit itself, doing the shim's job. There's no guest kernel mode, no system registers and no MMU. The shim is tested only on real hypervisors.

**How the Unicorn backend works.** Each vCPU is one Unicorn engine, running arm64 at EL0 or amd64 in flat 64-bit mode. An address space is a list of regions of host memory; when a vCPU runs, any regions it hasn't seen yet are mapped into its engine with `uc_mem_map_ptr`, so the host and the guest share the pages and syscall arguments are read in place. Hooks stop the engine: `UC_HOOK_INTR` for `SVC` (and other exceptions), `UC_HOOK_INSN` for amd64 `SYSCALL`, and `UC_HOOK_MEM_INVALID` for faults. After a syscall stop the PC is already past the instruction, as with a hypervisor; after a fault it's at the faulting instruction. `Ureg.type` holds what the real kernel puts there for a syscall (the ESR on arm64, vector 64 on amd64). `kick` sets a flag and calls `uc_emu_stop`, which Unicorn allows from another thread.

**Implementation**

1. **Unicorn Engine first.** It's a C library built on QEMU's CPU core, covers arm64 and x86\_64, and has hooks for syscall instructions and invalid memory accesses. It's GPLv2, so it sits behind a build flag (`-Demu=unicorn`) and is used for development and CI, never in release builds. We link the prebuilt static `libunicorn.a` from Unicorn's PyPI wheels (pinned in `scripts/pins.sh`, fetched by `scripts/fetch.sh`) rather than building its CMake tree: macOS arm64, and Linux arm64 and x86\_64 with musl, which is Zig's default Linux target. There's no Windows arm64 wheel, so emu on Windows waits for M2, built from source with our own `build.zig`. amd64 binaries are tested on Linux x86\_64 only; there's no amd64 on Darwin.
2. **A native Zig interpreter later.** It would be MIT, dependency-free and deterministic. It covers the instruction subset that 9front's compilers and libc's assembly routines emit, arm64 first. Unicorn is the reference: single-step both and compare registers after every instruction.

**What it's for**

- Developing and testing on any host or VM: macOS, Linux, Windows and hosted CI runners.
- Deterministic debugging: single-stepping, instruction tracing, and record and replay at the syscall boundary.
- Cross-architecture runs, for testing only: amd64 binaries on an arm64 Mac, and the reverse.
- Conformance: one test suite runs against every backend, and each backend must produce the same syscall traces.

**Limits and selection.** Measured at M1 on an M3 Max (macOS, release build of Unicorn 2.1.4): a 2-instruction loop of 10⁸ iterations takes 1.1 s on HVF, 5.6 s on emu for arm64 (about 36 M instructions/s; Unicorn's arm64 code generation, not our hooks), and 0.24 s on emu for amd64. A `pwrite` syscall round trip costs about 1 µs on emu, about the same as HVF's 0.86 µs. So syscall-heavy work such as rc pipelines runs at close to hypervisor speed, and arm64 compute runs about 5× slower; that's fine for tests, and tolerable for self-hosted builds. By default `hp9` uses the host's hypervisor when it's available, and otherwise falls back to the emulator with a warning. `--backend emu|hvf|kvm|whp` forces a choice.

## Guest shims and ABI

Each guest architecture gets a few hundred lines of assembly that run in guest kernel mode. The shim holds no policy: it moves control to the host and back, and the host decides everything.

**What the shim does**

- Bring up the CPU: on arm64, EL1 with the MMU on; on amd64, long mode with a GDT, an IDT and the SYSCALL MSRs. Where the hypervisor lets the host set system registers directly (HVF on arm64), the host does this and the shim is only the exception vectors.
- Switch the user page table root (TTBR0 on arm64, CR3 on amd64) when the host asks, unless the host can set it directly.
- On a syscall, fault or interrupt: save the user registers into the per-vCPU page in Ureg layout, ring the doorbell, then restore registers (possibly changed by the host) and return to user mode.

**Per-vCPU shared page:** exit reason, fault address and access type, the saved Ureg, the next page table root, and a sequence number. The host reads and writes it directly, so a typical syscall costs one exit and no register get/set calls.

**Binary ABI (checked against 9front source).** The values below come from `sys/src/9/{arm64,pc64}/mem.h` and `trap.c`, plus `sysexec` in `port/sysproc.c`.

| Item | arm64 (`R_MAGIC`) | amd64 (`S_MAGIC`) |
| --- | --- | --- |
| UTZERO (text start) | 0x10000 | 0x200000 |
| USTKTOP (stack top) | 0x7FFFF0000 (36-bit user addresses) | 0x7FFFFFFFF000 |
| Stack size | 16 MiB | 16 MiB |
| Page size | 4 KiB | 4 KiB |
| Data segment alignment | 64 KiB | 2 MiB |
| Syscall number | R0 | BP (RARG) |
| Syscall arguments | user stack, from SP+8 | user stack, from SP+8 |
| Syscall result | R0 | AX |
| Registers at entry | R0 = Tos pointer; SP points at argc, argv follows | AX = Tos pointer; SP points at argc; R14 and R15 zeroed |
| Note handler entry | R0 = Ureg pointer; SP+8 = Ureg, SP+16 = message | BP = Ureg pointer; same stack layout |

**a.out loading (host side)**

1. Read the Exec header: eight big-endian 32-bit words. Both 64-bit magics set HDR\_MAGIC, so a big-endian 64-bit entry address follows, making the header 40 bytes.
2. Map file bytes \[0, header + text) read-only at UTZERO. The header is part of the text segment, and the entry point must fall inside it.
3. Map the next `data` bytes of the file at the end of text, rounded up to the data alignment. bss starts at the end of data rounded up to 4 KiB, and is zero-filled.
4. The stack is \[USTKTOP − 16 MiB, USTKTOP). A zeroed Tos sits at the very top. Below it go the argument strings, then the argv array, then argc at SP.
5. Tos fields: the host fills `pid` and `cyclefreq` and keeps `kcycles`/`pcycles` current; the profiling pointers stay zero.

**Syscall table.** 9front's `libc/9syscall/sys.h` defines numbers 0–53; 48 and 49 are unused. The underscore entries (`_READ`, `_WRITE`, `_STAT`, `_NSEC` and so on) are old compatibility calls that current libc doesn't use. v1 implements only the current calls; the others post "sys: bad sys call", as the real kernel does for unknown calls. Time comes from `/dev/bintime`, not a syscall. The exception is `_NSEC`, added in M5 for Go (see Go compatibility).

**Reference:** hyper-linux's `src/shim.S` (648 lines, Apache-2.0) already covers EL1 vectors, MMU setup and W^X page splitting on HVF. Read it before writing ours, and keep its license notice on anything we borrow.

## Process model

Each CLI invocation is one machine: one host process with one VM. Each Plan 9 process is a drawterm Proc plus a host thread that owns a vCPU, and the host OS schedules them, so there is no guest scheduler. Because every process lives in one VM and one kernel, rfork never has to serialize state across host processes. hyper-linux has to, because it can only use one VM per host process.

| Plan 9 call | Implementation |
| --- | --- |
| `rfork(RFPROC)` | New Proc, new thread and vCPU, and a copy of the address space (eager copy in v1, copy-on-write later via write faults) |
| `rfork(RFMEM)` | Share the text, data, bss and segattach pages; copy only the stack |
| `RFNAMEG` / `RFFDG` / `RFENVG` / `RFNOTEG` / `RFREND` | Share or copy drawterm's Pgrp, Fgrp, Egrp, note group and rendezvous group |
| `exec` | Load the new a.out into fresh segments, rebuild page tables, reset registers, keep the fds (honouring close-on-exec) |
| `exits` / `await` | Wait records queued on the parent Proc; the thread and vCPU are torn down |
| `brk_` / `segbrk` | Grow the segment and map pages from the guest-physical allocator |
| `segattach` / `segdetach` / `segfree` | Named shared segments, backed by one set of guest-physical pages |
| `rendezvous` / `semacquire` / `tsemacquire` / `semrelease` | Host kernel primitives built on drawterm's sleep/wakeup |
| `notify` / `noted` | Push a Ureg and the note string onto the user stack and point the PC at the handler; `noted` restores or kills the process |

**Threads.** The kernel boots once per host process, on a private thread, because booting turns the calling thread into a Proc for good. Every guest process then runs on a kernel thread made by `hp9_kern_spawn` in `src/kern/glue.c`, which works like drawterm's `kproc` but can be called from a thread that isn't a Proc: it clones from the boot Proc, and the new thread sets up its groups once `up` is set. That thread creates the process's vCPU, which HVF binds to its creating thread, and runs the exit loop. `Machine.run` starts the first process this way and waits for it to exit; `rfork` uses the same path from M3.

**Several machines per host process.** An embedder, or the test suite, can run several machines in one host process. They share the one drawterm kernel, but each machine's first Proc starts with a fresh Pgrp, Fgrp and Egrp, so each has its own namespace, device mask, console and environment. The CLI always runs one.

**Notes on blocked and running processes.** A note to a process blocked in a host syscall wakes it through drawterm's sleep/wakeup, and the syscall fails with "interrupted". A note to a process running guest code kicks its vCPU, and the note is delivered at the exit.

**vCPU limits.** v1 is one vCPU per process. Measure each hypervisor's maximum early (`hv_vm_get_max_vcpu_count`, `KVM_CAP_MAX_VCPUS`, WHP's partition property). If a big tree hits the limit, release a process's vCPU while it is blocked in a long host syscall, keep its registers in the Proc, and reacquire a vCPU from a pool when it resumes. On HVF a vCPU is bound to its thread, so the pool has to be pool threads that run the guest on the process's behalf.

## Kernel: drawterm `kern/` and the Zig seam

We vendor 9front drawterm's `kern/`, its libraries (libc, libdraw, libmemdraw, libmemlayer, libsec, libmp, libip, libauthsrv) and its GUI backends. Its `sysfile.c` already implements the file syscalls with Plan 9 semantics, so most syscall handlers are a decode followed by one call. We keep the vendored tree close to upstream so 9front fixes keep merging cleanly.

**Reused as-is:** chan/dev/mount machinery, devroot, devcons (for everything but `cons` itself), devmnt (the 9P client), devfs-posix and devfs-win32 (the host filesystem), devpipe, devip, devtls, devssl, devdraw, devmouse, devaudio, devcmd, qio, and the auth code. We compile drawterm's `.c` files but not its `kern/devtab.c` or `kern/devenv.c`; our own copies live in `src/kern/`, so the vendored tree stays unmodified.

**Added by us**

| Piece | Why |
| --- | --- |
| Process model (Proc fields, segments, rfork/exec/await, notes) | drawterm only ever ran its own kprocs |
| `src/kern/devtab.c` | The device table, listing drawterm's devices plus ours |
| Per-machine console device `#y` (`src/kern/devhcons.c`) | drawterm's `#c/cons` reads and writes the host's fds 0 and 1 directly. `#y<id>` serves machine `id`'s `Stdio` through leaf calls into Zig, and is bound before `#c` on `/dev`, so `/dev/cons` is ours and the rest of `#c` stays visible. It also has `/dev/stderr`, which the guest's fd 2 is opened on, so fd 2 reaches the host's stderr. |
| devenv `#e`, from 9front (`src/kern/devenv.c`) | drawterm's has one machine-wide environment and imports the host process's environment on first attach, which breaks `env.scrub`. 9front's keeps one environment per Egrp, which `RFENVG` needs anyway. drawterm's Proc has no `egrp` and `kern/dat.h` stays unmodified, so until M3 adds the Proc record a small table maps each Proc to its group. `#ec` isn't supported. |
| devproc `#p` | rc, kill, ps and acid need `/proc/n/{note,notepg,ctl,status,ns,fd,wait,mem,regs}` |
| devsrv `#s` | Guest file servers post themselves; needed for factotum, exportfs and rio |
| devdup `#d` | `/fd/N` |
| `/dev/bintime`, `/dev/time` | 9front's libc reads time from these |
| devshr, devcap | Later: shared /srv namespaces and hostowner capabilities |

**Zig/C seam rules**

1. drawterm raises errors with `waserror()`/`error()`, built on setjmp/longjmp. A longjmp across a Zig frame skips its `defer` and `errdefer`. So Zig code never sits between a `waserror` and an `error`.
2. drawterm already provides the seam. Each `sysX` wrapper in `kern/sysfile.c` (`sysopen`, `syspread`, `sysbind`, `sysmount`, `sysrendezvous` and so on) runs `waserror`; on error it stores the string for `errstr` and returns -1. Zig calls these directly and turns -1 into an error union. New process and segment calls get wrappers in the same style.
3. C calls Zig only for leaf work that cannot fail into the kernel: the vmm layer, page allocation, the a.out parser, console I/O. A leaf returns a status, and the C side raises any kernel error.
4. drawterm's `up` (`_getproc()`, per host thread) stays authoritative. Every guest thread is created through drawterm's kproc path (`hp9_kern_spawn`), so `up` is set before any kernel call. Zig never uses bare `std.Thread` for anything that touches the kernel, and never boots the kernel on a caller's thread.
5. drawterm's Proc has no parent, note group, segments or Egrp. We add these fields, plus a pointer to the Zig-side process record.
6. The build uses `zig build`: C sources go through `addCSourceFiles` with drawterm's flags, and one `build.zig` produces binaries for every host.
7. Guest memory reaches the kernel through `GuestBuf`, because drawterm's `validaddr` is a no-op and hp9's translation is the only check. A data buffer (`pread`, `pwrite`, `stat`) is passed to the `sys*` wrapper in place when it lies in one mapping, split into one call per mapping when it spans several, and split into chunks below 2 GiB (drawterm's `long` is 32 bits). Any unmapped byte posts "sys: bad address in syscall". Strings (paths, `errstr`) are always copied into a bounded host buffer first, so no other guest thread can change one during the call.

## Filesystem, boot and I/O

**Root filesystem, in order of delivery**

1. **Host tree (v1):** a directory holding an extracted 9front root, served through `#U` (devfs-posix or devfs-win32). This is the fastest path: no 9P round trips.
2. **9P mount:** `--root tcp!host!564` (or a unix socket path) dials and mounts through devmnt. Covers remote file servers and u9fs.
3. **Disk image:** cwfs or gefs runs as a guest process over an image file exposed as a host file, and posts to `#s`. This is also a good stress test of the process model.

**Boot sequence**

1. The kernel boots once per host process, on its own thread (see Process model).
2. For each machine, the namespace builder gives the first Proc a fresh Pgrp. It binds the root at `/`, the cwd and other allowed host paths from `#U`, and `#c`, `#p`, `#s`, `#d`, `#e`, `#|` and (unless the network is off) `#I` to their usual places. It binds the machine's console over `/dev/cons` and opens fds 0–2 on it. Then it sets the device mask: `#U` and `#C` always (unless `--host-fs` or `--host-cmd`), and `#I` when the network is off. Existing binds keep working, but the guest can't attach a masked device again to reach more of the host.
3. If the binary is given as a host path, it's loaded straight from the host. Otherwise it's looked up through the kernel along `$path`, so lookup works the same over 9P roots.
4. The CLI runs the binary directly with the given argv. `--rc` runs `/bin/rc -c` on the argument instead, and `--ns file` runs `newns` with that file first.

The host's working directory is bound at the guest's `/mnt/term/cwd` and set as the guest's cwd, so that `hp9 ls` lists what the user expects.

**Terminal (default):** `/dev/cons` is the machine's console device, which maps to the `Stdio` in `Machine.Options`: the host stdin and stdout for the CLI. Writing `rawon` to `/dev/consctl` switches the host TTY to raw mode (console mode on Windows). Ctrl-C posts an `interrupt` note to the foreground note group. Exit status: an empty `exits` string gives 0; any other string gives 1, and the string is printed to stderr.

**Graphics (`--gfx`):** opens one host window through drawterm's GUI backend (Cocoa/Metal, X11 or Wayland, Win32) and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd`, plus snarf mapped to the host clipboard. One screen per machine: running rio gives the full desktop. A seamless mode, where each rio window becomes a host window, is a later project.

## Go compatibility

Go's `GOOS=plan9` binaries are a target from M5. Go has ports for `plan9/386`, `plan9/amd64` and `plan9/arm`, but not `plan9/arm64`, so on arm64 hosts Go binaries run as amd64 under the emulator (`--backend emu`) until someone ports Go to plan9/arm64. These notes are from Go 1.25's `runtime/os_plan9.go`, `runtime/sys_plan9_amd64.s` and `syscall/syscall_plan9.go`.

**What the runtime needs**

| Need | Used for | Milestone |
| --- | --- | --- |
| AX holds the Tos pointer at entry | `_rt0_amd64_plan9` saves it in `_tos`; g lives in `_privates` on the stack, not in FS, so there's no TLS setup | Done (M1) |
| `open`, `pread`, `pwrite`, `seek`, `close`, `dup`, `errstr`, `exits`, `brk_`, `sleep` | Basic I/O, the heap, `osyield` | M2 |
| `rfork(RFPROC\|RFMEM\|RFNOWAIT)` | One Plan 9 process per M (OS thread) | M3 |
| `notify` / `noted`, `/proc/n/note` | `sigtramp` turns notes into panics; the runtime posts notes to its own Ms | M4 |
| `semacquire`, `tsemacquire`, `semrelease` | `semasleep`/`semawakeup`, so every lock and park | M5 |
| `/dev/bintime`, 4 words, nanoseconds | `nanotime` and `walltime` (below) | M5 |
| `_NSEC` (53) | `syscall.Gettimeofday` only; the runtime doesn't use it | M5 |
| `/env`, `/dev/random` | `os.Getenv`, `crypto/rand` | `/env` at M2; `/dev/random` comes from drawterm's devcons |
| `/dev/sysstat`, `/dev/swap` | CPU count and page size; the runtime falls back to 1 CPU and 4 KiB if they're missing | Optional |

**Time.** The runtime opens `/dev/bintime` at startup, moves it to fd 18, and `pread`s it for every clock read. It asks for four big-endian 64-bit words: nanoseconds since the epoch, ticks, tick frequency and monotonic nanoseconds. If the read returns only three, it uses the wall-clock word as the monotonic clock. drawterm's `readbintime` in `kern/devcons.c` has two problems: it computes the time as `seconds()*1000000000`, so the clock only moves once a second, and it returns at most three words. Under it, Go's timers, `time.Sleep`, timeouts and the scheduler's clock would all be off by up to a second, and the monotonic clock would follow host wall-clock changes. 9front's libc `nsec()` reads the same file, so native programs see whole seconds too. The fix is to serve `bintime` from our console device (`src/kern/devhcons.c`), bound over `/dev` like `cons`, with 9front's four-word layout: wall time in nanoseconds, ticks and frequency from the host's monotonic clock, and monotonic nanoseconds. The vendored tree stays unmodified.

**`_NSEC`.** 9front still implements `_NSEC` for binary compatibility (`sys_nsec` in `port/sysproc.c`), returning the time in the return register on 64-bit machines. Go's `syscall.nsec` reads the return value and only falls back to the pointer argument if it's 0. hp9 implements it the same way, from the same clock as `bintime`. The other underscore calls stay unimplemented.

**Demo:** a Go program built with `GOOS=plan9 GOARCH=amd64` that starts goroutines, sleeps for 100 ms and prints the elapsed time runs under `hp9 --backend emu`, and the elapsed time it prints is at least 100 ms and under 200 ms.

## Security, debugging and testing

**Security stance.** The hypervisor isolates guest memory and the CPU, and every guest syscall is served by drawterm's kernel rather than the host's, so the guest never reaches host syscalls, ioctls or the host environment directly. The namespace decides what a guest can reach on the host. Identity: hostowner is the host user's name; devfs maps the host's file ownership onto Plan 9 user strings.

### Sandbox policy

Sandboxing is a `Policy` in `Machine.Options`: a set of capabilities, host paths, network rules and limits. The capability model follows [isobox](https://github.com/can1357/isobox): named capabilities, profiles that set defaults, explicit flags that override them, a printable plan with caveats, and `--strict` to refuse anything the build can't enforce. Unlike isobox, enforcement lives in the shared kernel, so the capability set is the same on every vmm backend; there's no per-host intersection to compute.

| Capability | Mechanism | From |
| --- | --- | --- |
| `env.scrub` | The host environment is never imported | M2 |
| `kernel.isolation` | Guest syscalls are served by drawterm's kernel | M2 |
| `ipc.restrict` | Host sockets are reachable only through `#U`, `#I` or `#C`, which the policy controls | M2 |
| `fs.read.scope`, `fs.write.scope` | The namespace is an allowlist: only listed host paths are bound from `#U`, each read-only or read-write | M2 |
| `fs.read.deny` | Unbound paths don't exist; denied paths inside a bound tree are filtered in devfs | M2 |
| `net.disable` | `#I` is masked in the init Pgrp (drawterm's `devmasked`), so the guest can't re-attach it | M2 |
| `res.memory` | A cap on the guest-physical page allocator; exact, not a watchdog | M2 |
| `proc.timeout` | A machine deadline; hard teardown in M2, a `hangup` note and grace period from M4 | M2, M4 |
| `res.pids`, `res.cpu` | A Proc cap in `rfork`; a limit on concurrently running vCPUs | M3 |
| `net.outbound` | devip refuses `announce` | M5 |
| `net.allow` | devip checks each `connect` against dial-string patterns (`tcp!10.0.0.0/8!564`); an egress allowlist isobox can't offer | M5 |
| `fs.write.ephemeral` | A ramfs union-bound with `bind -c` over writable paths; new files go to the ramfs and vanish on exit | M5 |
| `fs.write.overlay` | A copy-on-write overlay device, shared with image-backed roots | M10 |

**Vendor hooks.** The policy lives in Zig. drawterm calls it through leaf functions, following seam rule 3. devfs-posix and devfs-win32 call `hp9_fs_check(path, op)` (in `src/kern/fscheck.c`) before each walk, open, create, remove, wstat and directory entry. It resolves the host path and asks the Zig leaf `hp9_policy_check` for a verdict: allowed, hidden (the walk fails, or the entry is left out of the listing) or read-only ("permission denied"). The machine's compiled plan is set per host thread, because each guest process runs on its own thread. From M5, `hp9_net_check(op, addr, port)` in devip does the same for the network. The leaves return an int and never raise kernel errors themselves.

**Access rules.** The plan's rules are the root, the cwd, `/tmp`, each `--readable` and `--writable` path and each `--read-deny` path, all as resolved host paths. A deny rule covering a path wins. Otherwise the longest allow rule covering the path decides between read-only and read-write. Ancestors of allowed paths can be walked and listed but not changed, so `/mnt/term/<path>` works when the host's `/` is unioned after the tree's `/mnt/term`. Anything else is hidden. Bind-level read-only (no `MCREATE`) is a second, coarser check.

**Path resolution.** devfs-posix follows symlinks with `stat`, so a symlink inside a bound tree can point anywhere on the host. Every devfs path is resolved (`realpath`; on Windows the final path of an opened handle, which follows symlinks and junctions and refuses UNC and device paths) and the resolved path is checked against the access rules, on every host. Create, remove and rename act on the name rather than a link's target, so an existing entry is checked by its own canonical name without following it. On macOS that's `F_GETPATH` on an `O_SYMLINK` open, and on Windows the final path of a reparse-point open, so another case, an 8.3 short name or a trailing dot can't dodge a rule on a case-insensitive file system. A new name is appended to its resolved parent. A create over an existing symlink also checks the link's target for writing. Renaming a directory that has any rule strictly beneath it is refused ("permission denied"), because it would move those paths out from under their rules. The check and the host call aren't atomic, so a host process renaming paths at the same time can race it; the plan reports that, and hardlinks under writable paths, as caveats.

**Default profile.** With no sandbox flags the guest can work in the host cwd and nothing else:

| Area | Default |
| --- | --- |
| Root tree (`/`) | Read-only. Installing into the root needs `--writable "$HP9ROOT"`; from M10 the root gets an ephemeral overlay, so writes succeed and vanish. |
| Host cwd (`/mnt/term/cwd`) | Read-write |
| Rest of the host filesystem | Not visible |
| `/tmp` | The host temp dir until M5, then a private ramfs |
| Network | Full until M5, then outbound only (`--net=enable` for servers) |
| Host commands (`#C`) | Masked |
| Environment | Only the default guest variables plus `--env` |
| Memory | The guest-physical region size (1 GiB; `--memory` sets it, up to 32 GiB) |
| Processes, CPU, timeout | Unlimited, so interactive sessions and long builds aren't cut off |
| Terminal | `cons` and `consctl` only; no host ioctls such as `TIOCSTI` |

`--profile=tight` differs in four ways: the cwd is read-only, `#I` is masked, `/tmp` isn't writable until M5 and is then a private ramfs, and a default timeout of 10 minutes applies. `--sandbox DIR` is the tight profile with only DIR bound, read-write, as the cwd; the host cwd isn't bound.

**Plan output.** `--print` compiles the policy and exits without running. The namespace is printed in `newns` format, so from M3 it can be saved and replayed with `--ns`:

```text
$ hp9 --print --profile=tight --writable ./out --memory 512m --timeout 1m mk
profile:  tight
enforces: env.scrub fs.read.scope fs.write.scope ipc.restrict kernel.isolation net.disable proc.timeout res.memory
limits:   write=scope net=disable memory=512M timeout=1m
devmask:  #C #I #U
namespace:
  bind '#U/Users/me/hp9root' /                             ro
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#|' /fd
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind '#U/Users/me/src/proj' /mnt/term/cwd                ro
  bind -c '#U/Users/me/src/proj/out' /mnt/term/cwd/out     rw
access:
  ro   /Users/me/hp9root
  ro   /Users/me/src/proj
  rw   /Users/me/src/proj/out
caveats:
  - hardlinks under writable paths can modify host files outside them
  - writes to writable paths are not capped (no res.disk)
  - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
  - the hp9 process itself is not host-sandboxed
```

Requested capabilities the build can't enforce yet are listed on an `unenforced:` line, and the setting falls back to the safer choice: `--write=ephemeral` and `--write=overlay` deny writes, and `--net=outbound` leaves the network as it is until M5. `--strict` refuses them with exit 2 instead.

**Examples**

```sh
hp9 --profile=tight ls -l                                  # read-only, no network
hp9 --net=disable --writable ./out --rc 'mk install'        # writes only to ./out
hp9 --write=ephemeral --rc 'mk clean && mk && ./6.out'      # writes vanish (M5)
hp9 --net=outbound hget https://9front.org/ > index.html    # clients work, listening fails (M5)
hp9 --net-allow 'tcp!10.0.0.0/8!564' --net-allow 'tcp!*!443' \
    --rc 'srv tcp!10.0.0.5!564 fs && mount /srv/fs /n/fs'   # egress allowlist (M5)
hp9 --memory 256m --pids 32 --cpus 2 --timeout 30s rc       # resource caps
hp9 --readable ~/src/proj --read-deny ~/src/proj/.env \
    --rc 'grep -n TODO /mnt/term/$home/src/proj/*.c'       # read a tree, hide secrets
hp9 --strict --write=overlay mk                             # before M10: usage error, exit 2
```

Host paths given to `--readable` and `--writable` appear in the guest under `/mnt/term/<host path>`, as in drawterm; the cwd stays at `/mnt/term/cwd`.

### Host self-sandboxing (future)

The guest is contained, but the hp9 process runs drawterm's C kernel with the host user's full rights, and drawterm's `validaddr` is a no-op, so hp9's own guest-address translation is the memory-safety boundary. Defence in depth is to compile the same policy into a host sandbox and apply it to hp9 after VM creation and root setup, in a `src/hostjail.zig` with one implementation per OS, following the vmm pattern. Running hp9 under gVisor doesn't work, because gVisor can't pass `/dev/kvm` through.

This is future work. Each backend milestone records research notes so it can be built later:

- **M2 (macOS):** whether `sandbox_init` with a generated SBPL profile can be applied after `hv_vm_create` and still allow HVF calls, and which profile rules that needs. See the research note below.
- **M7 (macOS):** which Mach and WindowServer lookups `--gfx` needs under Seatbelt.
- **M8 (Linux):** Landlock for paths and TCP ports plus seccomp, with `/dev/kvm` already open; the syscalls `KVM_RUN` and vCPU threads need; the Landlock ABI each target distro ships.
- **M9 (Windows):** whether an AppContainer or restricted token can still use WHP.

**Research note: Seatbelt with HVF (M2).** Tested on macOS 15.8.1 on an M3 Max with a small C program, ad-hoc signed with the hypervisor entitlement. It calls `hv_vm_create` and `hv_vm_map` on 16 MiB of guest RAM, then applies a profile with `sandbox_init_with_parameters`. That call is exported from libsystem_sandbox but not declared in `<sandbox.h>`, so it needs its own prototype. The profile was:

```scheme
(version 1)
(deny default)
(allow file-read* (subpath (param "ALLOWED")))
```

After that it creates a vCPU on each of two new pthreads, runs them to an `hvc #0`, maps and unmaps a second region, and opens files. Everything HVF worked under `(deny default)` with no other rules: `hv_vcpu_create` on new threads, `hv_vcpu_run` (exit reason exception, syndrome `0x5a000000`), `hv_vm_map`/`hv_vm_unmap` of new memory and `hv_vm_destroy`. Thread creation needed no rule either. HVF needs no `iokit-open` or `mach-lookup` rule, because the VM and vCPUs are reached through the process's existing hypervisor handle, which is allowed by the entitlement rather than by the sandbox. Applying the same profile *before* `hv_vm_create` also worked, so ordering isn't forced by HVF. File rules behaved as expected, with one catch: `ALLOWED` must be the resolved path (`/private/var/...`, not `/var/...`), because the sandbox matches resolved paths. Reads inside it worked, writes there and reads elsewhere (`/etc/hosts`) failed with EPERM, and the process kept running. `sandbox_init*` fails with EPERM when the process is already sandboxed, so hostjail has to treat that as "already contained" or fail closed under `--strict`. For `src/hostjail.zig`, the plan is a generated `(deny default)` profile listing the resolved root, cwd and `--readable`/`--writable` paths (read or read-write), `/dev/null`, the TTY, and `network-outbound` only when the policy allows the network. It's applied after the backend and root setup, and before the first guest instruction runs.

### Debugging

- `--trace` logs each syscall with its arguments, result and error string, prefixed by pid, like 9front's ratrace.
- devproc's `mem`, `regs` and `ctl` give acid (Plan 9's debugger) inside the guest for free.
- `--dump-on-fault` prints the Ureg, the faulting address and a symbolized PC from the a.out symbol table.
- A gdb stub is optional and comes later.

### Testing and CI

- Unit tests in Zig for the a.out loader, the page allocator and the syscall decoders.
- Integration tests run real 9front binaries from a pinned root tree: rc scripts, the 9front regression tests where they exist, and a self-build of a few `/sys/src/cmd` programs.
- The full suite runs on the emulator on every hosted CI runner, and Linux CI also runs it on KVM. macOS (HVF) and Windows (WHP) need self-hosted machines, because hosted runners there generally lack nested virtualization.
- `zig build integration` runs real binaries from the root tree through the `hp9` CLI as subprocesses, so each case gets a fresh kernel and checks exit codes end to end; it skips when there's no tree. `zig build m2` runs the M2 demo. The Lima test VMs get the tree with `scripts/lima/vm push-root`.
- CI isn't set up yet. When it is, one Linux job runs `scripts/fetch.sh` and `scripts/mkroot.py` and caches `.local/9front/root-<release>` keyed on `NINEFRONT_RELEASE` and a hash of `mkroot.py`; the other jobs restore that cache, so QEMU (slow without hardware acceleration on hosted runners) only runs when the pin or the script changes. The prebuilt Unicorn in `.local/unicorn` is cached the same way, keyed on `UNICORN_VERSION`. Integration tests skip, rather than fail, when no root tree is present.

## CLI

The CLI is a thin wrapper: it parses argv into `Machine.Options`, runs one machine and maps the result to an exit code.

```
hp9 [hp9-flags] [--] program [args...]
hp9 [hp9-flags] --rc 'command line'
hp9 [hp9-flags]                       # interactive rc if stdin is a TTY, otherwise a usage error
```

**Parsing rules**

- No subcommands. `hp9 ls` must run 9front's `ls`, so tool functions such as `--version` and `--check` are flags instead.
- Flag parsing stops at the first non-flag, as with `env` and `nice`, so `hp9 ls -l` passes `-l` to `ls`. `--` ends hp9's flags explicitly.
- Long flags only, so hp9's flags are never confused with Plan 9-style short flags. Short aliases come later, and only for the most-used flags.

**Program resolution**

| Argument | Resolution |
| --- | --- |
| Starts with `./` or `../` (`./hello`, `../out/x`) | A host path relative to the host cwd, read on the host. It doesn't need to be in the guest namespace. |
| Absolute (`/bin/cat`) | A guest path, resolved in the guest namespace. To run an absolute host path, use the guest view of it (`/mnt/term/...`) or a relative path. |
| Bare name or other relative path (`ls`, `aux/vga`) | Looked up in the guest namespace through `$path` (default `(. /bin)`) |
| `--rc 'cmd'` | Runs `/bin/rc -c 'cmd'`; the remaining arguments become `$*` |
| `--ns file` | Runs `newns` with the file before the program |

**Flags**

| Flag | From | Meaning |
| --- | --- | --- |
| `--backend auto\|hvf\|kvm\|whp\|emu` | M1 | `auto` (the default) uses the host hypervisor, and otherwise falls back to the emulator with a warning |
| `--root DIR\|tcp!host!port\|/path.sock` | M2, M10 | The root tree. If omitted, use `$HP9ROOT`, then the default install location (`.local/9front/root` in development builds until there's an installer) |
| `--env name=value` (repeatable) | M2 | Sets a guest environment variable. The host environment isn't imported. |
| `--cwd PATH` | M2 | The guest cwd. Defaults to `/mnt/term/cwd`, the host cwd bound into the guest |
| `--rc 'cmd'` | M2 | See program resolution. rc can't fork until M3, so only commands without pipes or subprocesses work |
| `--ns file` | M3 | See program resolution |
| `--gfx` | M7 | Opens a host window and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd` |
| `--profile default\|tight` | M2 | Sets the sandbox defaults (see Sandbox policy). Explicit flags override it. |
| `--readable PATH` (repeatable) | M2 | Binds a host path read-only at `/mnt/term/PATH` |
| `--writable PATH` (repeatable) | M2 | Binds a host path read-write; under the cwd it overrides a read-only cwd |
| `--read-deny PATH` (repeatable) | M2 | Hides a host path inside a bound tree |
| `--write none\|scope\|ephemeral\|overlay` | M2, M5, M10 | Deny writes, persist only writable paths, discard all writes (M5), or copy-on-write over the root (M10) |
| `--net disable\|outbound\|enable` | M2, M5 | Network policy; `outbound` refuses `announce` (M5) |
| `--net-allow DIALSTRING` (repeatable) | M5 | Allows `connect` only to matching addresses, such as `tcp!10.0.0.0/8!564` |
| `--memory SIZE` | M2 | Caps guest memory (`512m`, `2g`) |
| `--pids N`, `--cpus N` | M3 | Caps processes and concurrently running vCPUs |
| `--timeout DURATION` | M2, M4 | Tears down the machine after a deadline; from M4, posts `hangup` first |
| `--strict` | M2 | Refuses any requested capability this build can't enforce (exit 2) |
| `--print` | M2 | Prints the compiled policy and namespace, then exits |
| `--host-fs` | M2 | Exposes all of `#U`, not just the root and cwd |
| `--host-cmd` | M2 | Enables devcmd |
| `--sandbox DIR` | M2 | The tight profile with only DIR bound, read-write, as the cwd. Can't be combined with `--host-fs` or `--host-cmd` |
| `--trace[=FILE]` | M2 | ratrace-style syscall log, to stderr by default |
| `--dump-on-fault` | M2 | Prints the Ureg and a symbolized PC when the guest faults |
| `--check` | M0 | Probes the backend, the entitlement or `/dev/kvm` access, the vCPU limit and the root tree, then exits |
| `--version` | M0 | Prints the hp9 version, the pinned 9front release and the available backends |

**Default guest environment:** `user` is the host user name, `home=/usr/$user`, `path=(. /bin)`, `cputype` and `objtype` come from the backend's architecture, `sysname=hp9` and `service=terminal`. Everything else has to be passed with `--env`, which keeps host secrets out of the guest by default.

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | `exits(nil)` or `exits("")` |
| 1 | Any other `exits` string, which is also printed to stderr |
| 2 | Usage error |
| 125 | hp9 itself failed: no hypervisor, VM creation failed, or the root wasn't found |
| 126 | The program was found but isn't a runnable a.out (bad magic or wrong architecture) |
| 127 | The program wasn't found |

The 125–127 codes follow `env` and `docker run`, so scripts can tell hp9 failures from guest failures.

**Signals and TTY**

- **Ctrl-C:** posts an `interrupt` note to the foreground note group. A second Ctrl-C within a second tears down the machine.
- **SIGTERM and SIGHUP:** post a `hangup` note to every process, then exit after a grace period.
- **Raw mode:** the host TTY goes raw only when the guest writes `rawon` to `/dev/consctl`. It's always restored on exit, including after a panic.

**Code structure**

| File | Role |
| --- | --- |
| `src/main.zig` | About 50 lines: argv to `cli.parse`, then `Machine.init` and `run`, then the exit code |
| `src/cli.zig` | Pure parsing from `[]const []const u8` to a `Config` or a usage error. No I/O; unit-tested. |
| `src/root.zig` | Exports `Machine` and `Machine.Options`. No CLI types. |

```zig
pub const Options = struct {
    backend: vmm.BackendKind = .auto,
    root: Root,                         // union { host_dir: []const u8, dial: []const u8 }
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    policy: Policy = .default,          // profile, binds, read-deny, net rules, limits, host_fs, host_cmd
    gfx: bool = false,
    ns_file: ?[]const u8 = null,
    trace: ?*std.Io.Writer = null,
    dump_on_fault: bool = false,
    stdio: Stdio,                       // host fds behind #c/cons
};
pub fn run(m: *Machine, prog: Program, argv: []const []const u8) !ExitStatus;
```

`cli.zig` is the only code that knows flag strings; tests and other embedders build `Options` directly. `stdio` and `trace` are passed in rather than taken from the process. That keeps the machine API free of CLI-global state and lets integration tests capture a machine's output and syscall trace.

## Milestones

Each milestone ends with a demo command that must pass. M0 targets macOS arm64. From M1 on, the emulator lets M2 to M7 be developed and tested on any host. The hypervisor backends for the other hosts follow once the process model settles.

1. **M0, hello:** `zig build` compiles drawterm's kern. The HVF backend, the arm64 shim and the a.out loader run a static binary that calls `pwrite` on fd 1 and `exits`. Demo: `hp9 ./hello`.
2. **M1, emulator:** the AddressSpace interface, plus the Unicorn backend for arm64 and amd64. Demo: `hp9 --backend emu ./hello` on macOS and Linux arm64, including inside VMs, and the amd64 hello on Linux x86\_64.
3. **M2, one process:** syscalls go through drawterm's `sys*` wrappers; the host-tree root and the terminal work. Unicorn built from source for Windows, and kern for Windows, as a parallel track that joins once the device table and console device settle (see the M2 changelog). Sandbox policy core: profiles, the namespace builder and device mask, devfs read-only, read-deny and beneath-root path resolution, the memory cap, a hard timeout, `--print` and `--strict`. Research note on Seatbelt with HVF. Demo: `hp9 /bin/cat /lib/namespace`, `hp9 --profile=tight --rc 'echo x > /mnt/term/cwd/f'` fails, plus the M1 demo on Windows.
4. **M3, trees:** rfork, exec, await, devdup and pipes. Process and CPU caps; `--print` namespaces replay with `--ns`. Demo: `hp9 --rc 'ls /bin | wc -l'`.
5. **M4, notes and /proc:** notify/noted, interrupt on Ctrl-C, devproc. `--timeout` posts `hangup` before teardown. Demo: an interactive rc session where `kill` and `ps` work.
6. **M5, servers:** devsrv, rendezvous and semaphores, segattach. `net.outbound` becomes the default, plus `--net-allow` and `--write=ephemeral`; `/tmp` becomes a private ramfs. Go compatibility: `/dev/bintime` with nanosecond and monotonic time, and `_NSEC` (see Go compatibility). Demo: ramfs posts to /srv and is mounted; factotum runs; `aux/listen1` fails under the default profile; the Go demo passes.
7. **M6, self-host:** the compilers, linkers and mk run (installing into the read-only root needs `--writable "$HP9ROOT"`). Demo: rebuild `/sys/src/cmd/ls` inside, and the rebuilt binary runs.
8. **M7, graphics:** `--gfx` with devdraw. Research note on Seatbelt with `--gfx`. Demo: rio and acme run in a host window.
9. **M8, Linux:** KVM backend; arm64 first, then the amd64 shim on x86\_64. Research note on Landlock and seccomp with KVM. Demo: M0 to M7 pass in CI on KVM.
10. **M9, Windows:** WHP backend on x86\_64, then Windows on ARM. Research note on AppContainer with WHP. Demo: the same suite.
11. **M10, 9P roots:** `--root` over 9P, then cwfs or gefs over an image. The copy-on-write overlay device (`--write=overlay`), which becomes the root's default.

After M10, host self-sandboxing of the hp9 process (see Security) builds on the research notes from M2, M7, M8 and M9.


## Changelog

Record design changes as they are made using `- YYYY-MM-DD: <design change> (reason).` Keep each entry under the milestone in progress; after M10, use the relevant release heading.

### Milestone changes

#### M0

- 2026-11-02: On HVF the host programs the arm64 system registers (SCTLR, TCR, MAIR, TTBR0/1, VBAR, SP_EL1) with `hv_vcpu_set_sys_reg`, and the shim is reduced to exception vectors that save the Ureg and ring the doorbell. The shim, doorbell page and per-vCPU shared pages sit at fixed kernel addresses under TTBR1; user space uses TTBR0 (simpler than a shim boot path, and HVF allows it; other backends may still need shim bring-up).

#### M1

- 2026-11-02: The vmm interface is a set of tagged unions over backend structs, and `vmm.create` selects the backend at run time instead of at compile time. `translate`, `allocPages` and `maxVcpus` are part of the interface. `Ureg` is a union over the arm64 and amd64 layouts, since the emulator runs both on one host (so `hp9 --backend auto|hvf|emu` can choose per run, and every host builds the same code).
- 2026-11-02: Unicorn comes from the prebuilt static libraries in its PyPI wheels, not a source build; Windows emu moves to M2 (no Windows arm64 wheel exists, and Unicorn's CMake build doesn't cross-compile with Zig). amd64 is tested on Linux x86\_64 only.
- 2026-11-02: `Machine.Options` takes `stdio` writers and an optional `trace` writer, as planned in the CLI section, so the backend conformance tests (`tests/backends.zig`) can run the same programs on every backend built in and compare output and syscall traces.
- 2026-11-02: kern isn't built for Windows targets until M2; hp9.exe builds without it (kern isn't linked into hp9 yet, and drawterm's Windows configuration needs porting to the Zig build).

#### M2

- 2026-11-02: `scripts/mkroot.py` builds the root tree by booting the pinned image in QEMU with its kernel loaded directly (`-kernel`, plus `plan9.ini` set to boot without prompting), then running `tar` in the guest onto a second raw disk and unpacking it on the host. It keeps everything programs might read (`/arm64`, `/rc`, `/lib`, `/sys/lib`, `/sys/include`, `/acme`, `/mail`, `/cfg`, `/usr` and so on) and adds empty mount points (`/dev`, `/env`, `/proc`, `/srv`, `/mnt/term`), but leaves out `/dist`, the boot kernels for real hardware, `/sys/doc` and, unless `--src` is given, `/sys/src`. That's about 250 MB instead of 420 MB; `/arm64/bin` alone is 135 MB. `/sys/src` comes back for M6 (self-host). (Tarring in the guest needs no drawterm, auth or network setup.)
- 2026-11-02: kern is built with drawterm's libc, libsec, libmp, libauthsrv, libip, libmemdraw, libmemlayer, libdraw and posix-port into one static library, which the `hp9` module links. drawterm's `main.c`, `cpu.c`, GUI backends, exportfs and libauth are replaced by `src/kern/glue.c`, which holds the boot sequence (`hp9_kern_boot`) and no-op GUI and factotum stubs until M5 and M7. `#U` always attaches the host's `/`, so the root tree is bound to the guest's `/` with `bind("#U<dir>", "/")`, with no vendor changes. This boot namespace is provisional: `#U` still reaches the whole host and `#I` is bound unconditionally until the policy's namespace builder and device mask replace it. kern is a process-wide singleton (its devtab, env and Proc table are globals), so there's one booted kernel per host process, and `kern.boot` refuses a second boot. (No vendor changes, and it matches drawterm's own process model.)

- 2026-11-02: Sandboxing becomes an isobox-style capability policy (`Machine.Options.policy`, profiles, `--print`, `--strict`) enforced in the namespace, the device mask and two leaf hooks in devfs and devip, replacing the `exposure` and `host_cmd` options. The default profile makes the root read-only and, from M5, the network outbound-only; `--sandbox DIR` becomes a tight-profile shorthand. Work is spread over M2–M5 and M10 as each mechanism arrives (one policy model instead of ad hoc flags; the shared kernel lets every backend enforce the same set).
- 2026-11-02: Each guest process runs on a thread made through drawterm's `kproc`, and the kernel boots once per host process on a private thread, not the caller's (`up` is set before any kernel call, and HVF binds a vCPU to the thread that creates it).
- 2026-11-02: Several machines can share one host process and one kernel. Each machine's first Proc gets a fresh Pgrp, Fgrp and Egrp, its own console device bound over `/dev/cons`, and its own device mask. drawterm's `kern/devtab.c` and `kern/devenv.c` aren't compiled; `src/kern/` has our device table and a devenv ported from 9front, with one environment per Egrp. This supersedes the earlier "one booted kernel per host process" as the limit on machines. (Namespaces are already per Pgrp; drawterm's devenv imports the host environment, which breaks `env.scrub`; drawterm's cons is wired to the host's fds; and the backend tests run several machines in one process.)
- 2026-11-02: Guest memory reaches the kernel through `GuestBuf`: data buffers are passed in place, split at mapping boundaries and into chunks below 2 GiB; strings are copied into bounded host buffers (`validaddr` is a no-op in drawterm, and copying strings makes them safe against other threads once memory is shared in M3).
- 2026-11-02: `#U` is restricted with drawterm's device mask after the namespace builder has bound the allowed host paths, rather than with a new filtering device. `#C` is always masked unless `--host-cmd`, and `#I` when the network is off. Symlink escapes from bound trees are still handled by the beneath-root check in devfs. (The mask exists in drawterm already and keeps existing binds working.)
- 2026-11-02: M2 order: one process end to end first (`Options.root`, `cwd` and `env`, a `Program` that is a host path or a guest name, and a Zig syscall table for what `cat` needs), then the console and devenv devices, then the namespace builder and device mask, then the policy flags, `--print` and `--strict`. Bare program names are looked up through the kernel along `$path`. `main.zig` maps failures to exit codes 125–127. In development builds the default root is `.local/9front/root`. (Sandbox features need a working process to test against.)
- 2026-11-02: Program resolution: absolute paths (`/bin/cat`) are guest paths, and only `./` or `../` paths are read from the host; previously any argument containing `/` was a host path (the M2 demo `hp9 /bin/cat /lib/namespace` names a guest binary, and `/mnt/term` covers absolute host paths).
- 2026-11-02: Startup budget: `hp9 /bin/echo` under 20 ms wall time on HVF, VM create through exit (sets a pass/fail target for M2's measurement).
- 2026-11-02: Unicorn is built from its source tarball with Zig (`build/unicorn.zig`), for the x86\_64 and aarch64 guest targets only, rather than with its CMake build. `fetch.sh` applies the patches in `third_party/unicorn/patches` to the source in `.local/src/unicorn`, and QEMU's `configure` output for each host is kept in `third_party/unicorn/config` (generated once with `zig cc`). Five patches make it work on Windows arm64 with mingw-w64; three of them are LLP64 fixes (`long` is 32 bits on Windows). The source isn't vendored, and the patches are GPLv2 like Unicorn. `-Dunicorn=prebuilt|source` chooses between them; the wheels stay the default on macOS and Linux until the source build replaces them, and Windows always builds from source (Windows arm64 has no wheel; the source build matches the wheel on tests and speed on macOS; patch files instead of a fork, since the set is small and easy to drop as upstream catches up).
- 2026-11-02: The Windows work in M2 (Unicorn from source, then kern for Windows and the M2 demo on Windows) is a parallel track off the critical path. The source build of Unicorn sits behind a build flag, with the prebuilt wheels staying the default on macOS and Linux until it matches them, and kern's Windows port starts once M2's device table and console device have settled. (They touch different files from the one-process work, and porting kern before the device table settles would mean doing it twice.)
- 2026-11-02: The guest's fd 2 is opened on `/dev/stderr` from the machine's console device, which writes to `Stdio.err`, so guest error output reaches the host's stderr as it does for native programs. 9front has no such file (fd 2 is `/dev/cons` there).
- 2026-11-02: drawterm's `_sysfd2path` passes an uninitialised length and has no `sys*` wrapper, so `src/kern/glue.c` has `hp9_fd2path` instead, rather than fixing the vendored tree.
- 2026-11-02: Host self-sandboxing of the hp9 process (Seatbelt, Landlock/seccomp, AppContainer) is deferred to after M10; M2, M7, M8 and M9 each record a research note for their host (keeps the backend milestones focused while gathering what the later work needs).
- 2026-11-03: devfs checks the *resolved* host path against the plan's access rules on every host, instead of `openat2(RESOLVE_BENEATH)` on Linux and a prefix check elsewhere. One `realpath` (on Windows, the handle's final path) plus a Zig rule lookup covers symlink escapes, `--read-deny`, read-only paths and `/mnt/term` ancestors in one place, and works the same in devfs-posix and devfs-win32. The cost is a check-then-use race against concurrent host renames, which the plan lists as a caveat. (`openat2` would mean rewriting devfs-posix around directory fds, and has no Darwin or Windows equivalent.)
- 2026-11-03: The vendored devfs-posix.c and devfs-win32.c carry hp9's sandbox hooks, one call per operation plus a header (`src/kern/fscheck.h`), so the vendor tree is no longer unmodified. They also return nil from a walk that matches no name, as devwalk does, so a union bind such as the host's `/` after the tree's `/mnt/term` falls through to the next member. Without that, `/mnt/term/<host path>` wouldn't resolve. (devfs has no other seam, and the hooks are small enough to merge across upstream updates.)
- 2026-11-03: Policy paths outside the root and cwd appear at `/mnt/term/<host path>` through one `bind -a '#U/' /mnt/term`. The access rules hide everything but the bound paths and their ancestors, instead of binding each path's parent directories. Paths inside the root or cwd are bound over their place there, so `--writable ./out` under a read-only cwd is `/mnt/term/cwd/out`. (One union keeps the namespace short, and the rules have to filter it anyway.)
- 2026-11-03: `#U` is masked after the namespace is built unless `--host-fs`, as the boot sequence describes. `--host-fs` adds the host's `/` read-only at `/mnt/term`, and `--writable` still decides what's writable. Without a `--writable`, `--write=none` and the tight profile's defaults make no host path writable. `/tmp` is the host temp dir, read-write, in the default profile only. (Read-write `--host-fs` would make every other flag moot.)
- 2026-11-03: Unenforceable modes (`--write=ephemeral|overlay`, `--net=outbound`) fall back to the safer choice and are listed as `unenforced` in the plan, rather than failing without `--strict`. Writes are denied for the write modes, and the network is left as it is for outbound, since M2 can't half-enable it. (isobox's model: run with what can be enforced, and let `--strict` refuse.)
- 2026-11-03: `res.memory` sizes the backend's guest-physical region: HVF maps exactly `--memory` bytes (default 1 GiB, at most 32 GiB) and the emulator counts pages against the same cap. Page tables and per-vCPU pages count too, so the cap is exact. A program that doesn't fit exits 125 (`OutOfGuestMemory`), not with a guest note. (There's no guest allocator to fail softly until segments come in M3.)
- 2026-11-03: `proc.timeout`'s hard teardown kicks the vCPU and interrupts the Proc (`procinterrupt`), and the process is killed with `hp9: timeout` at its next exit. A process stuck in a host call that can't be interrupted, such as a console read on the host's stdin, gets a 500 ms grace period. After that `Machine.run` returns anyway and marks the machine `stuck`, leaking its resources rather than freeing memory a kernel thread still uses, and the CLI exits at once. `sleep` is served (drawterm has no `tsleep`, so it sleeps in 20 ms slices and checks for a pending note), which gives tests an interruptible blocking call. (M4's `hangup` note and grace period replace this.)
- 2026-11-03: `--rc` arrives in M2 rather than M3, since the M2 demo uses it for a redirection. Until rfork and exec it runs only commands that need no subprocess. `--trace=FILE` writes the trace to a file. (The demo is a redirection, which rc does in-process.)
- 2026-11-03: kern builds for Windows with drawterm's Make.win64 files (`devfs-win32`, `devip-win32`, `devlfd-win32`, `win32.c`) and `-DWINDOWS -DUNICODE`. It also uses posix-port's `getcallerpc` and `tas`, which are compiler builtins, and a `src/kern/glue-win32.c` for the host user and drawterm's unused `mymain`. On Windows, host paths go to `#U` and the plan in devfs-win32's form, `/C:/Users/...`, and `.\` and `..\` programs are host paths like `./` and `../`. hp9.exe runs the M1 and M2 demos on the emulator in the Windows arm64 VM. (`<windows.h>` clashes with draw.h, hence a separate file.)
- 2026-11-02: Go `plan9/amd64` binaries become an M5 target, with a new Go compatibility section. `/dev/bintime` is served by hp9's console device with nanosecond wall time and a fourth monotonic word, replacing drawterm's whole-second, three-word version, and `_NSEC` is implemented as 9front does for binary compatibility. All other underscore calls still post "bad sys call". (Go reads every clock from `/dev/bintime`, so drawterm's version would give it one-second timers. `syscall.Gettimeofday` uses `_NSEC`. M5 is the first milestone with everything Go's runtime needs: rfork from M3, notes and `/proc` from M4, and semaphores.)

#### M3

#### M4

#### M5

#### M6

#### M7

#### M8

#### M9

#### M10

### Post-M10 release changes

#### Unreleased

<!-- Add a version heading (for example, `#### v1.0.0`) for changes made in a release. -->

## Open questions

- [x] Name: keep `hp9`.
- [x] Syscall conventions, Tos, UTZERO and USTKTOP: verified (Guest shims section).
- [x] Page size: 9front uses 4 KiB pages on arm64 and amd64, so there's no mismatch with any host.
- [x] Licensing: drawterm is MIT (Plan 9 Foundation, Russ Cox, 9front authors). hyper-linux is Apache-2.0, so code borrowed from it keeps its notice. The project can be MIT.
- [x] Pin a 9front release: 11952, "THIS WAS SUPPOSED TO BE FUN", released August 2026 ([OSnews](https://www.osnews.com/?p=145669)), pinned in `scripts/pins.sh` along with its source revision (`NINEFRONT_REV`, read from `/dist/9front` in the release image), which `scripts/fetch.sh` checks out in `.local/src/9front`. Port 9front code from that checkout, not from upstream HEAD.
- [x] Build the arm64 root tree: `scripts/mkroot.py` boots the pinned qcow2 headless in QEMU and tars the disk's file system out onto a second raw disk (see the M2 changelog).
- [ ] vCPU limits. hyper-linux caps threads at 64 (`MAX_THREADS`), which hints at HVF's practical limit. Measure each hypervisor before M3.
- [ ] Whether the Windows Hypervisor Platform's arm64 support is solid enough to target, or whether Windows on ARM waits.
- [ ] macOS builds: the Cocoa backend (`screen.m`) is Objective-C, and HVF needs the macOS SDK plus an entitlement signature. So macOS builds run on a Mac, or use rcodesign when cross-building. Windows builds need a WinHvPlatform import library (a .def file for Zig).
- [x] Startup budget: `hp9 /bin/echo` (VM create through exit) should take under 20 ms of wall time on HVF. Measured at M2 on an M3 Max, release build: about 5 ms median (4.4 ms for the hand-assembled hello with no root tree, so kern and the namespace add about 0.5 ms).
- [ ] Should the host-tree root go through devfs as-is, or get a faster read path for exec and compilers?
- [ ] When to add the binfmt\_misc registration on Linux, so that `./prog` runs directly.
- [x] Emulator speed: measured at M1 (see Limits and selection). About 5× slower than HVF for arm64 compute and on par for syscalls, so the native interpreter isn't urgent.

## Sources

- [9front source (GitHub mirror)](https://github.com/9front/9front): `sys/src/9/arm64`, `sys/src/9/pc64`, `sys/src/9/port/sysproc.c`, `sys/include/a.out.h`, `sys/include/tos.h`, `sys/src/libc/9syscall/sys.h`
- [9front drawterm (GitHub mirror)](https://github.com/9front/drawterm): `kern/sysfile.c`, `kern/dat.h`, `kern/devtab.c`, `LICENSE`
- [hyper-linux](https://github.com/zw3rk/hyper-linux): `src/shim.S`, `src/thread.h`, `LICENSE`
- [9front release announcement, OSnews](https://www.osnews.com/?p=145669)
- [isobox](https://github.com/can1357/isobox): capability model, profiles, plan caveats and `--strict`
