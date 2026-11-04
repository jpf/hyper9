---
slug: linux-personality
title: Linux personality
status: draft
created: 2026-11-04
authors: [progrium]
depends: []
areas: [kern, vmm, cli, sandbox]
---

# Proposal: Linux personality

## Abstract

h9 runs Linux ELF binaries next to 9front ones, in the same machine. A process's personality is chosen at exec by its binary format. A Linux process's syscalls are served by a second syscall table in the host, translated onto the same drawterm kernel. So Linux processes share the machine's namespace, file descriptors, pipes, notes and sandbox policy with 9front processes, and the two can pipe to each other and exec each other. A Linux root tree, such as Alpine's minirootfs, is bound over `/` for Linux processes, with the 9front tree at `/9`.

## Background

h9 already has the shape of a syscall-translating kernel. Each guest process runs in user mode on a vCPU, a syscall exits to the host, and a kernel in the host serves it (DESIGN.md, Architecture). gVisor has the same shape: its KVM platform is h9's vmm layer, and its Sentry is drawterm's kernel. What's missing is a second ABI.

Linux binaries trap with the same instructions as 9front's: `SVC` on arm64 and `SYSCALL` on amd64. So a Linux syscall already arrives as the vmm's `.syscall` exit, with every register the Linux ABI uses already in the Ureg:

- **arm64:** the number in x8, arguments in x0 to x5, the result in x0.
- **amd64:** the number in rax, arguments in rdi, rsi, rdx, r10, r8 and r9, the result in rax.

Today `syscall.dispatch` reads that exit as a 9front call: on arm64 it takes the number from R0, which for a Linux `write(1, …)` is the valid 9front call 1.

Other pieces already fit:

- **Address space.** HVF's guest page tables already use a 48-bit user address space (`TCR_EL1.T0SZ` = 16 in `src/vmm/hvf.zig`); only the guest-physical space is 36 bits. Linux's usual layout fits: ld.so mapped high, and the stack near the top of the 47-bit range.
- **Thread pointer.** `vmm.Extra.tls` already carries the thread pointer across pooled vCPUs and into rfork children: TPIDR_EL0 on arm64, the FS base on amd64.
- **Prior art.** linuxemu (Russ Cox, then cinap_lenrek) ran Linux/i386 ELF binaries on Plan 9 as an ordinary Plan 9 program. It caught Linux's `int 0x80` as a note, built mmap on segattach and segbrk, and ran Linux programs in a namespace with the Linux root bound over `/` and Plan 9's at `/9`. hyper-linux, already h9's reference for the HVF shim, has a working ELF loader and auxv setup.

## Proposal

### Personality and dispatch

Each process has a personality, `plan9` or `linux`, set by exec from the binary's magic: the a.out magics as today, or `\x7fELF`. On a `.syscall` exit, `Machine.loop` dispatches to `syscall.dispatch` or `linux.dispatch` by personality. Both return the existing `Outcome` union:

- `exits` for `exit_group`
- `rfork` for `fork`, `vfork` and `clone`
- `exec` for `execve`
- `noted` for `rt_sigreturn`, with a Linux frame (see Signals)

A Linux process can execve a 9front binary and the reverse. Each exec picks the personality anew.

### The ELF loader

For a static or dynamic ELF64 executable of the host's architecture:

- Map the `PT_LOAD` segments with their permissions. For a dynamic one, load the `PT_INTERP` interpreter at a fixed high base.
- Build the Linux initial stack: argc, argv, envp, then the auxv with `AT_PHDR`, `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ` (4096), `AT_BASE`, `AT_ENTRY`, `AT_RANDOM`, `AT_HWCAP`, `AT_UID` and friends, and `AT_EXECFN`.
- Give no vDSO (`AT_SYSINFO_EHDR`). musl and glibc fall back to real syscalls without one.

Linux processes have no Tos.

### Syscalls

`src/linux/` holds the table, one entry per Linux syscall number per architecture. Calls map onto drawterm's `sys*` wrappers on the calling Proc, as `syscall.zig`'s do. Results are Linux's: a value, or `-errno`. Anything not in the table returns `-ENOSYS`.

| Area | Calls | Served by |
| --- | --- | --- |
| Files | `openat`, `read`, `write`, `pread64`, `pwrite64`, `readv`, `writev`, `lseek`, `close`, `dup`, `dup3`, `fcntl`, `pipe2`, `getdents64`, `newfstatat`, `fstat`, `statx`, `faccessat`, `mkdirat`, `unlinkat`, `renameat`, `fchmod`, `ftruncate`, `getcwd`, `chdir` | drawterm's file calls. Relative paths with a dirfd are joined to the dirfd's path from `fd2path`. `stat` is built from a Plan 9 `Dir`: `qid.path` becomes `st_ino`, the device type and number become `st_dev`, and user and group names become numbers through the Linux root's `/etc/passwd` and `/etc/group`. |
| Processes | `clone`, `fork`, `vfork`, `execve`, `exit`, `exit_group`, `wait4`, `getpid`, `getppid`, `gettid`, `set_tid_address`, `kill`, `tgkill` | h9's process model. `wait4` maps onto `await`. |
| Memory | `brk`, `mmap`, `munmap`, `mprotect`, `madvise`, `mremap` | A VMA layer (see Memory) |
| Threads | `clone` with `CLONE_VM`, `futex`, `set_robust_list`, `rseq` (`-ENOSYS`) | See Threads |
| Signals | `rt_sigaction`, `rt_sigprocmask`, `rt_sigreturn`, `sigaltstack` | See Signals |
| Time | `clock_gettime`, `clock_nanosleep`, `nanosleep`, `gettimeofday` | The host clock, the same one [go-compat](0007-go-compat.md) uses for `/dev/bintime` |
| Terminal | `ioctl` `TCGETS`, `TCSETS*`, `TIOCGWINSZ`, `TIOCGPGRP` on the console | `TCSETS` with `ICANON` off writes `rawon` to `/dev/consctl`, and `rawoff` when it's on again. `isatty` and line editing work. |
| Sockets | `socket`, `connect`, `bind`, `listen`, `accept4`, `sendto`, `recvfrom`, `getsockname`, `getpeername`, `setsockopt`, `shutdown` | `/net` clone files. `connect` dials, `bind` and `listen` announce, and `accept4` listens. The policy's devip hooks apply unchanged. |
| Readiness | `poll`, `ppoll`, `pselect6`, `epoll_create1`, `epoll_ctl`, `epoll_pwait`, `eventfd2` | See Readiness |
| Other | `uname`, `getrandom`, `sysinfo`, `getuid` and the other id calls, `prctl` (a few options), `arch_prctl` (amd64 `ARCH_SET_FS`) | Fixed answers, or the host where it's safe |

Error strings map to errno: "file does not exist" is `ENOENT`, "permission denied" is `EACCES`, "interrupted" is `EINTR`, and unknown strings are `EIO`. The table lives in one place and is tested on its own.

### Memory

A Linux address space is a list of VMAs alongside the existing segments, each backed by pages from the backend's allocator and mapped with `AddressSpace.map`, `protect` and `unmap`.

- `brk` grows a heap VMA after the executable's last segment.
- Anonymous mappings are zero pages, allocated on fault, as the stack grows today.
- Private file mappings are read through the kernel into fresh pages: eagerly for small files, or page by page on fault.
- Shared anonymous mappings stay shared across `fork`, like segattach.
- Shared writable mappings of files are refused with `ENODEV`. drawterm has no page cache to write them back through.
- `fork` copies the VMAs eagerly, as `rfork` copies segments.

### Threads

- **`clone(CLONE_VM | CLONE_THREAD | …)`** creates a process that shares the whole address space, stack included. That's unlike `RFMEM`, which copies the stack. The child gets the new stack pointer, and with `CLONE_SETTLS` its thread pointer in `vmm.Extra.tls`.
- **`CLONE_CHILD_CLEARTID`:** the cleared word is written, and its futex woken, when the thread exits.
- **`futex`** wait and wake are host-side queues keyed on the address space and the guest address, built on drawterm's sleep/wakeup, so notes and timeouts interrupt them like any other wait. `FUTEX_WAIT_BITSET` and the private flag are accepted.
- **Thread groups:** a thread group is the processes that share the address space. `getpid` is the group leader's pid.

### Signals

Notes and signals map both ways:

| Note | Signal |
| --- | --- |
| `interrupt` | `SIGINT` |
| `hangup` | `SIGHUP` |
| `sys: trap: fault …` | `SIGSEGV` |
| `sys: write on closed pipe` | `SIGPIPE` |
| `kill` from `/proc/n/ctl` | `SIGKILL` |
| `linux: signal N` | Signal N |

Linux processes signal each other with `linux: signal N` notes, so a 9front process can also signal one by writing to `/proc/n/note`.

`rt_sigaction` handlers are kept on the process. Delivery happens where notes are delivered today: at the top of the exit loop. It builds an `rt_sigframe` (siginfo and ucontext) on the user stack, or the alternate stack, and enters the handler with the restorer as the return address.

`rt_sigreturn` restores the saved registers only after sanitizing them as `noted` does. On arm64 that means keeping only NZCV from the guest's PSR; on amd64, forcing the selectors and system flags. The HVF shim loads the PSR straight into `SPSR_EL1`, so this is the one place a forged frame could reach EL1.

### Readiness

Plan 9 has no readiness API, so h9 adds one in its own kernel code.

- A leaf `h9_poll` asks each fd's channel whether a read or write would block, using qio's queue state for pipes and devip, the console reader thread for the console, and "always ready" for devfs files. It sleeps on a per-machine rendezvous that queue changes wake.
- `poll`, `ppoll` and `pselect6` call it directly.
- `epoll` keeps an interest list per epoll fd and calls it the same way.
- `eventfd2` is a small device.

This goes in project-owned code, through a hook that qio's existing wakeups call, rather than through changes to the vendored tree, if that's possible (see Open issues).

### Files Linux expects

A Linux process's namespace is built from the machine's.

- **The Linux root.** `--linux-root DIR` binds DIR over `/`, read-only by default and under the same access rules as the 9front root. The 9front tree is bound at `/9`, as linuxemu did.
- **`/dev`:** `null`, `zero`, `full`, `random`, `urandom` and `tty` are bound to their drawterm equivalents.
- **`/proc`:** a small synthetic device serves `/proc/self` and `/proc/<pid>/{exe,maps,fd,stat,status,cmdline}`, plus `/proc/cpuinfo`, `/proc/meminfo` and `/proc/sys/kernel/random/uuid`. glibc, musl and common tools read these.
- **`/sys`:** absent.

**Symlinks.** Linux root trees are full of absolute symlinks: on Alpine, `/bin/ls` is `/bin/busybox`. devfs-posix follows a symlink on the host, so an absolute target resolves against the host's `/`. The policy's resolved-path check then hides it, correctly. So devfs resolves symlinks inside a bound root when the bind asks for it, as `openat2`'s `RESOLVE_IN_ROOT` does: an absolute target is taken relative to the bound tree, and `..` stops at its top. This changes the vendored devfs-posix and devfs-win32, which already carry h9's sandbox hooks. `readlink` and `readlinkat` return a link's target for those paths, and `EINVAL` elsewhere, since Plan 9 has no symlinks.

**Environment.** A Linux process keeps its environment in its own memory, as Linux does. Going from 9front to Linux, execve builds envp from `/env`. Going from Linux to 9front, it writes envp into a new Egrp, so `rc` sees `$path` and friends as usual.

### CLI and API

- **`--linux-root DIR`**: the Linux root, and the Linux personality's `$PATH` lookup for bare names. Without it, a Linux binary can still run from a host path (`h9 ./prog`), with only `/9`, `/dev` and `/proc`.
- **`Machine.Options.linux_root`**: the same, for embedders.
- **Program resolution:** with `--linux-root`, a bare name is also looked up in the Linux root's `/usr/local/bin`, `/usr/bin` and `/bin`. Which tree wins when both have the name is an open issue.

## Rationale

**gVisor compiled for Plan 9.**
- Go has no `plan9/arm64` port, so on arm64 hosts the Sentry would run under the emulator.
- gVisor needs a platform that runs untrusted code in an address space it controls and traps that code's syscalls: ptrace, seccomp traps or KVM. A Plan 9 process has nothing like that.
- Its memory model maps a memfd into the guest at fixed addresses, and Plan 9 has no mmap.
- Each Linux syscall would cross four layers: Sentry, a Plan 9 syscall, an h9 exit, and drawterm.

h9's host process already sits where the Sentry would.

**linuxemu's approach, a translator running as a 9front program.** On arm64 and amd64, a Linux syscall doesn't fault; it reaches `syscall.dispatch` as a 9front call with the wrong registers, so there's no note to catch. The translator would also have to build epoll out of helper processes, one per fd, because it can't add readiness to a kernel it doesn't own.

**A Linux microVM beside h9.** It's the simplest way to run Linux, and Linux processes there are complete. But they aren't part of the machine: no shared namespace, no pipes to 9front processes, no 9P mounts in their file tree, and none of h9's sandbox policy. If that's all that's wanted, a microVM is the better tool, and h9 doesn't need this proposal.

**One proposal or several.** Memory, threads and readiness could each be their own proposal. Here they're stages of one, because none is useful alone: a dynamic binary needs mmap, almost everything needs `poll`, and Go needs threads. See Open issues.

## Compatibility

- **New CLI flag** `--linux-root DIR`, and a new `Machine.Options` field. Nothing existing changes meaning.
- **Exit codes:** an ELF binary for the wrong architecture is exit 126, like a bad a.out.
- **Vendored tree:** devfs-posix and devfs-win32 gain root-relative symlink resolution, behind a per-bind flag that 9front roots don't set.
- **9front processes** see no change unless they exec a Linux binary or open the Linux `/proc` device.

## Security

- **The guest reaches nothing new on the host.** Every Linux call is served by drawterm's kernel through the same namespace, device mask and policy hooks. Sockets go through devip, so `net.disable` and, once built, [net-policy](0005-net-policy.md) apply.
- **`rt_sigreturn`** must sanitize the restored state exactly as `noted` does (see Signals). It gets its own tests, including a forged frame that asks for EL1, or for kernel selectors on amd64.
- **Symlink resolution inside a root** must never step above the bound tree, and must still pass the resolved path through `h9_fs_check`. The existing escape tests in `tests/integration.zig` get Linux-root variants.
- **The synthetic `/proc`** must not reveal host details beyond what the policy already does. `/proc/cpuinfo` and `/proc/meminfo` report the machine's limits (`--cpus`, `--memory`), not the host's. `/proc/<pid>/exe` shows guest paths.
- **New attack surface:** the ELF loader and the VMA layer turn guest-supplied sizes and offsets into host mappings. Both validate against the address-space limits before mapping, as the a.out loader does.

## Done when

Each stage has integration cases tagged `[linux-personality]`. The fixtures are static and dynamic musl binaries and an Alpine minirootfs, fetched by `scripts/fetch.sh` at a pinned release.

1. **Static binaries:** `h9 ./hello-musl` prints hello on HVF and on the emulator, for arm64, and for amd64 on the emulator.
2. **busybox:** with `--linux-root alpine`, `h9 --linux-root alpine sh -c 'ls / | wc -l'` runs busybox's shell. A mixed pipeline works: `h9 --linux-root alpine --rc 'ls /9/bin | /bin/busybox wc -l'`.
3. **Dynamic binaries:** Alpine's dynamically linked tools (`apk --version`, `python3 -c 'print(1)'`) run.
4. **Threads:** a C program with pthreads and a Go program built with `GOOS=linux GOARCH=arm64`, which starts goroutines and sleeps, both run, natively on HVF.
5. **Readiness and sockets:** `curl` fetches a page under the default network policy, and `python3 -m http.server` serves one under `--net=enable`.

Plus:
- A forged `rt_sigreturn` frame can't raise privilege.
- An absolute symlink in the Linux root can't escape it.

## Implementation

1. A personality on the process record, the dispatch switch in `Machine.loop`, the ELF loader, and the stack and auxv. Static musl hello, on arm64 and then amd64.
2. File, process and terminal calls; errno mapping; `stat` translation; `wait4`; signals for the common notes; root-relative symlinks in devfs; `--linux-root`; the Linux `/dev` binds. busybox and the mixed pipeline.
3. The VMA layer and `PT_INTERP`. Dynamic binaries.
4. `clone` threads, `futex`, TLS, `set_tid_address` and `CLONE_CHILD_CLEARTID`. pthreads and Go.
5. `h9_poll`, `poll`/`ppoll`/`pselect6`, `epoll`, `eventfd`, and sockets over `/net`. curl and a server.
6. The synthetic `/proc` grows as each stage needs it. DESIGN.md gets a "Linux personality" section at the end.

## Open issues

- **Splitting.** Should threads (`linux-threads`) and readiness with sockets (`linux-net`) be separate proposals that depend on this one, so stages 1 to 3 can be accepted and finished first?
- **Readiness hook.** Can `h9_poll` get its wakeups from a hook in project-owned code, or does it need a small change to qio in the vendored tree?
- **Name lookup.** Which wins for a bare name when both trees have it, such as `ls`? Should Linux processes see the 9front `$path` at all, or only `/9/bin`?
- **Uid and gid mapping.** Read the Linux root's `/etc/passwd`, or hash the names? What uid does the machine's user get: 1000, or 0 inside the Linux root?
- **A vDSO.** Worth adding later for `clock_gettime` speed, since every call is an exit?
- **Shared file mappings.** Some programs (SQLite in some modes, LMDB) map files shared and writable. Refusing them may be fine, or it may need a write-back path through the kernel.
- **ptrace, Linux namespaces, cgroups, io_uring, bpf and `/sys`** are out of scope. Is anything common blocked by their absence that should be stubbed?