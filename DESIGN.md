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

**Syscall table.** 9front's `libc/9syscall/sys.h` defines numbers 0–53; 48 and 49 are unused. The underscore entries (`_READ`, `_WRITE`, `_STAT`, `_NSEC` and so on) are old compatibility calls that current libc doesn't use. v1 implements only the current calls; the others post "sys: bad sys call", as the real kernel does for unknown calls. Time comes from `/dev/bintime`, not a syscall.

**Reference:** hyper-linux's `src/shim.S` (648 lines, Apache-2.0) already covers EL1 vectors, MMU setup and W^X page splitting on HVF. Read it before writing ours, and keep its license notice on anything we borrow.

## Process model

One machine is one host process with one VM. Each Plan 9 process is a drawterm Proc plus a host thread that owns a vCPU, and the host OS schedules them, so there is no guest scheduler. Because every process lives in one VM and one kernel, rfork never has to serialize state across host processes. hyper-linux has to, because it can only use one VM per host process.

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

**Notes on blocked and running processes.** A note to a process blocked in a host syscall wakes it through drawterm's sleep/wakeup, and the syscall fails with "interrupted". A note to a process running guest code kicks its vCPU, and the note is delivered at the exit.

**vCPU limits.** v1 is one vCPU per process. Measure each hypervisor's maximum early (`hv_vm_get_max_vcpu_count`, `KVM_CAP_MAX_VCPUS`, WHP's partition property). If a big tree hits the limit, release a process's vCPU while it is blocked in a long host syscall, keep its registers in the Proc, and reacquire a vCPU from a pool when it resumes. On HVF a vCPU is bound to its thread, so the pool has to be pool threads that run the guest on the process's behalf.

## Kernel: drawterm `kern/` and the Zig seam

We vendor 9front drawterm's `kern/`, its libraries (libc, libdraw, libmemdraw, libmemlayer, libsec, libmp, libip, libauthsrv) and its GUI backends. Its `sysfile.c` already implements the file syscalls with Plan 9 semantics, so most syscall handlers are a decode followed by one call. We keep the vendored tree close to upstream so 9front fixes keep merging cleanly.

**Reused as-is:** chan/dev/mount machinery, devroot, devcons, devmnt (the 9P client), devfs-posix and devfs-win32 (the host filesystem), devpipe, devenv, devip, devtls, devssl, devdraw, devmouse, devaudio, devcmd, qio, and the auth code.

**Added by us**

| Piece | Why |
| --- | --- |
| Process model (Proc fields, segments, rfork/exec/await, notes) | drawterm only ever ran its own kprocs |
| devproc `#p` | rc, kill, ps and acid need `/proc/n/{note,notepg,ctl,status,ns,fd,wait,mem,regs}` |
| devsrv `#s` | Guest file servers post themselves; needed for factotum, exportfs and rio |
| devdup `#d` | `/fd/N` |
| `/dev/bintime`, `/dev/time` | 9front's libc reads time from these |
| devshr, devcap | Later: shared /srv namespaces and hostowner capabilities |

**Zig/C seam rules**

1. drawterm raises errors with `waserror()`/`error()`, built on setjmp/longjmp. A longjmp across a Zig frame skips its `defer` and `errdefer`. So Zig code never sits between a `waserror` and an `error`.
2. drawterm already provides the seam. Each `sysX` wrapper in `kern/sysfile.c` (`sysopen`, `syspread`, `sysbind`, `sysmount`, `sysrendezvous` and so on) runs `waserror`; on error it stores the string for `errstr` and returns -1. Zig calls these directly and turns -1 into an error union. New process and segment calls get wrappers in the same style.
3. C calls Zig only for leaf work that cannot fail into the kernel: the vmm layer, page allocation, the a.out parser.
4. drawterm's `up` (`_getproc()`, per host thread) stays authoritative. Every guest thread is created through drawterm's kproc path, so `up` is set before any kernel call. Zig never uses bare `std.Thread` for anything that touches the kernel.
5. drawterm's Proc has no parent, note group, segments or Egrp; the environment is machine-wide. We add these fields, plus a pointer to the Zig-side process record.
6. The build uses `zig build`: C sources go through `addCSourceFiles` with drawterm's flags, and one `build.zig` produces binaries for every host.

## Filesystem, boot and I/O

**Root filesystem, in order of delivery**

1. **Host tree (v1):** a directory holding an extracted 9front root, served through `#U` (devfs-posix or devfs-win32). This is the fastest path: no 9P round trips.
2. **9P mount:** `--root tcp!host!564` (or a unix socket path) dials and mounts through devmnt. Covers remote file servers and u9fs.
3. **Disk image:** cwfs or gefs runs as a guest process over an image file exposed as a host file, and posts to `#s`. This is also a good stress test of the process model.

**Boot sequence**

1. The host binds the root at `/`, and binds `#c`, `#p`, `#s`, `#d`, `#e`, `#|` and `#I` to their usual places.
2. If the binary is given as a host path, it's loaded straight from the host. Otherwise it's looked up in the guest namespace (`/bin`).
3. The CLI runs the binary directly with the given argv. `--rc` runs `/bin/rc -c` on the argument instead, and `--ns file` runs `newns` with that file first.

The host's working directory is bound at the guest's `/mnt/term/cwd` and set as the guest's cwd, so that `hp9 ls` lists what the user expects.

**Terminal (default):** `#c/cons` maps to the host stdin and stdout. Writing `rawon` to `/dev/consctl` switches the host TTY to raw mode (console mode on Windows). Ctrl-C posts an `interrupt` note to the foreground note group. Exit status: an empty `exits` string gives 0; any other string gives 1, and the string is printed to stderr.

**Graphics (`--gfx`):** opens one host window through drawterm's GUI backend (Cocoa/Metal, X11 or Wayland, Win32) and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd`, plus snarf mapped to the host clipboard. One screen per machine: running rio gives the full desktop. A seamless mode, where each rio window becomes a host window, is a later project.

## Security, debugging and testing

**Security stance.** The hypervisor isolates guest memory and the CPU, but the namespace decides what a guest can reach on the host.

- By default the guest sees the root tree, the host cwd, and host networking through `#I`.
- `#U` beyond the root and cwd, and devcmd (running host commands), are off unless asked for with `--host-fs` or `--host-cmd`.
- `--sandbox DIR` exposes only DIR, plus the root tree read-only, with no network.
- Identity: hostowner is the host user's name; devfs maps the host's file ownership onto Plan 9 user strings.

**Debugging**

- `--trace` logs each syscall with its arguments, result and error string, prefixed by pid, like 9front's ratrace.
- devproc's `mem`, `regs` and `ctl` give acid (Plan 9's debugger) inside the guest for free.
- `--dump-on-fault` prints the Ureg, the faulting address and a symbolized PC from the a.out symbol table.
- A gdb stub is optional and comes later.

**Testing and CI**

- Unit tests in Zig for the a.out loader, the page allocator and the syscall decoders.
- Integration tests run real 9front binaries from a pinned root tree: rc scripts, the 9front regression tests where they exist, and a self-build of a few `/sys/src/cmd` programs.
- The full suite runs on the emulator on every hosted CI runner, and Linux CI also runs it on KVM. macOS (HVF) and Windows (WHP) need self-hosted machines, because hosted runners there generally lack nested virtualization.

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
| Contains `/` (`./hello`, `/tmp/x`) | A host path relative to the host cwd, read on the host. It doesn't need to be in the guest namespace. |
| Bare name (`ls`) | Looked up in the guest namespace through `$path` (default `(. /bin)`) |
| `--rc 'cmd'` | Runs `/bin/rc -c 'cmd'`; the remaining arguments become `$*` |
| `--ns file` | Runs `newns` with the file before the program |

**Flags**

| Flag | From | Meaning |
| --- | --- | --- |
| `--backend auto\|hvf\|kvm\|whp\|emu` | M1 | `auto` (the default) uses the host hypervisor, and otherwise falls back to the emulator with a warning |
| `--root DIR\|tcp!host!port\|/path.sock` | M2, M10 | The root tree. If omitted, use `$HP9ROOT`, then the default install location |
| `--env name=value` (repeatable) | M2 | Sets a guest environment variable. The host environment isn't imported. |
| `--cwd PATH` | M2 | The guest cwd. Defaults to `/mnt/term/cwd`, the host cwd bound into the guest |
| `--rc 'cmd'` | M3 | See program resolution |
| `--ns file` | M3 | See program resolution |
| `--gfx` | M7 | Opens a host window and serves `/dev/draw`, `/dev/mouse` and `/dev/kbd` |
| `--host-fs` | M2 | Exposes all of `#U`, not just the root and cwd |
| `--host-cmd` | M2 | Enables devcmd |
| `--sandbox DIR` | M2 | Exposes only DIR plus a read-only root, with no network. Can't be combined with `--host-fs` or `--host-cmd` |
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
    exposure: Exposure = .default,      // .default, .host_fs or .sandbox(dir)
    host_cmd: bool = false,
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
3. **M2, one process:** syscalls go through drawterm's `sys*` wrappers; the host-tree root and the terminal work. Unicorn built from source for Windows, and kern for Windows. Demo: `hp9 /bin/cat /lib/namespace`, plus the M1 demo on Windows.
4. **M3, trees:** rfork, exec, await, devdup and pipes. Demo: `hp9 --rc 'ls /bin | wc -l'`.
5. **M4, notes and /proc:** notify/noted, interrupt on Ctrl-C, devproc. Demo: an interactive rc session where `kill` and `ps` work.
6. **M5, servers:** devsrv, rendezvous and semaphores, segattach. Demo: ramfs posts to /srv and is mounted; factotum runs.
7. **M6, self-host:** the compilers, linkers and mk run. Demo: rebuild `/sys/src/cmd/ls` inside, and the rebuilt binary runs.
8. **M7, graphics:** `--gfx` with devdraw. Demo: rio and acme run in a host window.
9. **M8, Linux:** KVM backend; arm64 first, then the amd64 shim on x86\_64. Demo: M0 to M7 pass in CI on KVM.
10. **M9, Windows:** WHP backend on x86\_64, then Windows on ARM. Demo: the same suite.
11. **M10, 9P roots:** `--root` over 9P, then cwfs or gefs over an image.


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
- [ ] Pin a 9front release. The newest is "THIS WAS SUPPOSED TO BE FUN", released August 2026 ([OSnews](https://www.osnews.com/?p=145669)).
- [ ] Build the arm64 root tree. The git repo holds source only, and the arm64 release ships as a QEMU qcow2 image. Plan: boot it in QEMU once, then tar `/arm64`, `/rc`, `/lib` and `/sys` out through drawterm's `/mnt/term`. Script this so the tree can be rebuilt for each pinned release.
- [ ] vCPU limits. hyper-linux caps threads at 64 (`MAX_THREADS`), which hints at HVF's practical limit. Measure each hypervisor before M3.
- [ ] Whether the Windows Hypervisor Platform's arm64 support is solid enough to target, or whether Windows on ARM waits.
- [ ] macOS builds: the Cocoa backend (`screen.m`) is Objective-C, and HVF needs the macOS SDK plus an entitlement signature. So macOS builds run on a Mac, or use rcodesign when cross-building. Windows builds need a WinHvPlatform import library (a .def file for Zig).
- [ ] Startup budget: set a target for `hp9 /bin/echo` wall time (VM create through exit) and measure it at M2.
- [ ] Should the host-tree root go through devfs as-is, or get a faster read path for exec and compilers?
- [ ] When to add the binfmt\_misc registration on Linux, so that `./prog` runs directly.
- [x] Emulator speed: measured at M1 (see Limits and selection). About 5× slower than HVF for arm64 compute and on par for syscalls, so the native interpreter isn't urgent.

## Sources

- [9front source (GitHub mirror)](https://github.com/9front/9front): `sys/src/9/arm64`, `sys/src/9/pc64`, `sys/src/9/port/sysproc.c`, `sys/include/a.out.h`, `sys/include/tos.h`, `sys/src/libc/9syscall/sys.h`
- [9front drawterm (GitHub mirror)](https://github.com/9front/drawterm): `kern/sysfile.c`, `kern/dat.h`, `kern/devtab.c`, `LICENSE`
- [hyper-linux](https://github.com/zw3rk/hyper-linux): `src/shim.S`, `src/thread.h`, `LICENSE`
- [9front release announcement, OSnews](https://www.osnews.com/?p=145669)
