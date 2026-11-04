---
id: 7
slug: go-compat
title: Go compatibility
status: draft
created: 2026-11-03
authors: [progrium]
depends: [3]
areas: [kern, tests]
---

# Proposal: Go compatibility

Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Run Go's `GOOS=plan9 GOARCH=amd64` binaries. Semaphores, from [semaphores](0003-semaphores.md), are the large missing piece. Four smaller ones are here:

- `/dev/bintime` and `/dev/time` with nanosecond wall time and a monotonic clock, instead of drawterm's whole seconds
- `#c/pid` and `#c/ppid`, which Go reads by device path and drawterm doesn't serve
- `/dev/sysstat`, with a line per vCPU the machine may run, so `runtime.NumCPU` isn't 1
- `_NSEC`, as 9front serves it

All of it is in drawterm's devcons, through small hooks into h9's own code. Go programs then start, schedule goroutines on several processes, keep time, and exec, the same on every backend that runs amd64.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's Go compatibility section, which moved here, was written from Go 1.25. This proposal is checked against Go 1.27.3, the current release, and its `runtime/os_plan9.go`, `runtime/sys_plan9_amd64.s`, `syscall/syscall_plan9.go`, `syscall/exec_plan9.go`, `os/sys_plan9.go` and `os/exec_plan9.go`.

Go has ports for `plan9/386`, `plan9/amd64` and `plan9/arm`, but not `plan9/arm64`. HVF runs arm64 only, so a Go binary on an arm64 Mac runs as amd64 on the emulator (`--backend emu`, Unicorn). On Linux x86\_64 it runs on the emulator too, until [kvm](kvm.md) gives it hardware.

### What the runtime does

- **Entry.** `_rt0_amd64_plan9` saves AX, the Tos pointer, in `_tos`, and points `_privates` at its own stack frame. The goroutine pointer `g` lives there, not in FS, so there's no TLS setup. Each process has its own stack, so each has its own `g`.
- **`osinit`:**
  - reads `/dev/swap` for the page size, falling back to 4 KiB without it;
  - counts the lines of `/dev/sysstat` for the CPU count, falling back to 1;
  - gets the pid by reading `#c/pid`;
  - opens `/dev/bintime`, moves it to fd 18, and fails fatally if it can't.
- **Ms.** Each M (OS thread) is a Plan 9 process from `rfork(RFPROC|RFMEM|RFNOWAIT)`. `tstart_plan9` reads the new process's pid from `_tos->pid` and lays out a 64 KiB scheduler stack on the process's stack.
- **Locks and parking.**
  - `semasleep` and `semawakeup` are `tsemacquire` (or `semacquire` when there's no timeout) and `semrelease` on a word in the M.
  - `osyield` is `sleep(0)`, and `usleep` rounds up to `sleep(1)`.
- **Time.** `nanotime` and `walltime` `pread` fd 18 at offset 0. `nanotime` asks for four big-endian 64-bit words and uses the fourth, the monotonic clock, if it gets all four. Otherwise it uses the first, wall time in nanoseconds. `walltime` uses the first.
- **Notes.**
  - `sigtramp` turns notes into signals. The fault notes `sys: trap: fault read` and `sys: trap: fault write` become panics, using the `addr=` in the note, and `interrupt` and `hangup` reach `os/signal`.
  - On exit, `goexitsall` writes "go: exit …" to `/proc/n/note` of every other M, then calls `exits`.
- **Memory** comes from `brk_`, as for C programs.

Go doesn't preempt goroutines by signals on Plan 9 (`preemptMSupported = false`), so nothing here needs asynchronous notes into a running M.

### What the standard library does

- **`syscall`:** `Getpid` and `Getppid` read `#c/pid` and `#c/ppid`. `Gettimeofday` uses `_NSEC` (53) and takes the time from the return register, or from the pointer argument when the register is 0.
- **`os.Hostname`** reads `#c/sysname`.
- **`os/exec`** (`syscall.forkExec`):
  - forks with `RFPROC|RFFDG|RFREND`, plus `RFCENVG` for a custom environment;
  - lists open fds by reading `#d` and closes the ones it doesn't pass;
  - writes the environment into `/env`;
  - execs, and reports a failed exec through a pipe;
  - waits with `await`.
- **`os.Process.Kill` and `Signal`** write `/proc/n/note`.
- **`os.Executable`** reads `/proc/n/text`.
- **`os.Getenv`** reads `/env`, and the `time` package's local zone comes from `$timezone`.
- **`net`** dials through `/net/cs` and `/net/tcp`.

### h9 today

Everything above is served except the following:

| Need | Today | |
| --- | --- | --- |
| `semacquire`, `tsemacquire`, `semrelease` | "sys: bad sys call" | [semaphores](0003-semaphores.md) |
| `/dev/bintime` | drawterm's `readbintime`: `seconds()*1000000000`, so the clock moves once a second, and at most three words | Here |
| `/dev/time` | drawterm's `readtime`, from `seconds()` too | Here |
| `#c/pid`, `#c/ppid` | Not in drawterm's devcons, so the open fails. The runtime then parses an empty read as pid 0 for the main M, and `syscall.Getpid` fails. | Here |
| `/dev/sysstat` | Empty, so `runtime.NumCPU()` is 1 and `GOMAXPROCS` defaults to 1 | Here |
| `_NSEC` | "sys: bad sys call" | Here |
| `/proc/n/text` | Not served | [self-host](self-host.md) |
| `/dev/swap` | Not served; the runtime's fallback is right for h9 | - |

Two details checked along the way:

- **Byte order.** drawterm's `readbintime` encodes with a function named `vlong2le`, but it's 9front's `vlong2be` under another name, with the same order constant and loop. The bytes are big-endian, as Go and 9front's `nsec()` expect. Only the resolution and the missing fourth word are wrong.
- **Fault notes.** h9's text is "sys: trap: fault read addr=0x… pc=0x…", and Go's `sigpanic` finds `addr=` in it, so nil-pointer dereferences already become panics once the rest works.

9front's own libc reads the pid from `_tos->pid` and the clock from `/dev/bintime` by path, so native programs never needed `#c/pid`. They do get whole-second `nsec()` today.

## Proposal

### The clock

h9 keeps one clock per host process, read through a Zig leaf. It has two parts, both nanoseconds:

- **Wall time** from the host's real-time clock (`std.Io.Clock.real`).
- **Monotonic time** from the host's monotonic clock, offset so it starts at the wall time when the kernel boots. Its values then look like wall time to a program that prints them, but never jump with the host's clock.

`ticks` are the monotonic nanoseconds, and `fasthz` is 1 000 000 000. `Tos.cyclefreq` keeps its current value, since nothing here reads it.

### devcons hooks

drawterm's devcons is vendored. Go reads `#c/pid` by device path, so serving it from h9's own console device, `#y`, which is bound over `/dev`, wouldn't reach it. So devcons gains leaf hooks, as devfs and devip carry h9's sandbox hooks. The leaves are in `src/kern/consx.c` and `src/kern.zig`; `third_party/drawterm/kern/devcons.c` gains:

1. Two `Dirtab` entries, `pid` and `ppid`, mode 0444. Their reads return `h9_cons_pid()` and `h9_cons_ppid()` as 9front formats them: right-justified in `NUMSIZE` (12) characters, plus a space. The pids are the machine-local ones from h9's process record, the same as `$pid`, `_tos->pid` and `/proc`.
2. `readbintime` returns `h9_cons_bintime(buf, n)`: up to four big-endian words, as 9front's does. The words are wall nanoseconds, ticks, `fasthz`, and monotonic nanoseconds, and a short read gets the leading words that fit.
3. `readtime` returns `h9_cons_time(…)`: seconds, nanoseconds, ticks and `fasthz`, in 9front's text format.
4. `Qsysstat`'s read returns `h9_cons_sysstat(…)`: one line per CPU the machine may use, in 9front's column layout. Each line has its index and zeros for the counters h9 doesn't keep (context switches, interrupts, syscalls, faults, TLB and load). The count is `--cpus` when given, else the host's CPU count, capped by the backend's vCPU limit.

Writes are unchanged: drawterm refuses writes to `time` and `bintime` with "Egreg", and `sysstat` writes are a no-op.

Each hook is a one-line call. The leaves can't fail and raise no kernel errors (seam rule 3). With the hooks, `#c` and `/dev`, which `#y` shadows only for `cons`, `consctl` and `stderr`, give the same answers.

### `_NSEC`

Syscall 53 returns the wall nanoseconds in the return register, as 9front's `sys_nsec` does on 64-bit machines, and writes nothing through its argument. It's the only underscore call h9 serves: the others keep posting "sys: bad sys call". `--trace` prints it as `_nsec`.

### Fixtures and the Go toolchain

The tests need Go binaries.

- **Sources:** `tests/fixtures/go/` holds a Go module with a small program per behaviour.
- **Building them:** `zig build go-fixtures` builds them with `GOOS=plan9 GOARCH=amd64 CGO_ENABLED=0` and `GOTOOLCHAIN=go$GO_VERSION`. `GO_VERSION` is pinned in `scripts/pins.sh`, initially 1.27.3. Any installed Go fetches that exact toolchain, so every host builds the same binaries.
- **Without Go:** if `go` isn't on `PATH`, the step is skipped and the Go cases skip, as cases without a root tree do.
- **Runner:** the cases run on the emulator, `H9_TEST_BACKENDS=emu`, with `-Demu=unicorn`.

## Rationale

**Hooks in devcons, not a shadow file in `#y`.**
- **The old plan:** DESIGN.md planned to serve `bintime` from h9's console device, bound over `/dev` before `#c`, keeping the vendored tree unmodified. That works for `/dev/bintime`.
- **Why it isn't enough:** Go reads `#c/pid`, `#c/ppid` and `#c/sysname` by device path, which no bind can change. So devcons has to change for `pid` and `ppid` anyway.
- **Why the clocks go there too:** putting them in devcons through the same hooks means `#c/bintime` and `/dev/bintime` can't disagree.
- **The cost:** the change is four call sites and two table entries, which `scripts/vendor-drawterm.sh` carries across upstream merges like the devfs and devip hooks.

**A wrapper device in h9's devtab.** h9's own `devtab.c` could register a `#c` that serves the new files and delegates the rest to drawterm's. It would have to merge directory listings and route by drawterm's private qid numbers, which is more code than the hooks and breaks quietly when upstream renumbers.

**Monotonic time offset to the boot's wall time.** Go uses the monotonic word only for differences, so any base works. Starting it at the wall time keeps 9front programs that print `ticks` or the fourth word plausible, as on 9front, where the monotonic clock starts near the time of day at boot.

**`sysstat` lines for CPUs, not real counters.** Go only counts the lines, and 9front's `stats` and `cpu` tools are the only other readers. Counting real context switches and syscalls per vCPU would need accounting h9 doesn't have. Zeros keep the format valid without pretending.

**Why not `/proc/n/text` here.** `os.Executable` needs it, but it's part of devproc's debugging files, which [self-host](self-host.md) adds for acid. Go programs rarely call it, and it fails cleanly with an error when it's missing.

**Go on arm64 hosts.** DESIGN.md treats cross-architecture emulation as testing-only. So on an arm64 Mac, Go `plan9/amd64` binaries run, but slowly and through Unicorn, which isn't in the MIT build. Two other proposals change that:
- [linux-personality](linux-personality.md) runs `linux/arm64` Go binaries natively on HVF.
- Someone porting Go to `plan9/arm64` would make this proposal's work apply natively.

Neither is a dependency. And [i386](0009-i386.md) would let `plan9/386` binaries run as well.

## Compatibility

- **Native programs:** `nsec()` and `time()` gain nanosecond resolution, and `/dev/bintime` gains its fourth word. Programs that timed intervals in whole seconds see the right durations. Reads of `/dev/time` keep their format.
- **`#c/pid` and `#c/ppid`:** new files, so `ls '#c'` lists two more entries.
- **`/dev/sysstat`:** now has content. `runtime.NumCPU()` in Go, and any 9front tool that counts CPUs, see the machine's limit rather than 1.
- **`_NSEC`:** stops posting "sys: bad sys call".
- **CLI, `Machine.Options`, the vmm interface and sandbox defaults:** unchanged.
- **Vendored tree:** devcons gains the hooks above.
- **Build:** a `go-fixtures` step, which `zig build test` depends on when `go` is available.

## Security

- **The pid files** expose the machine-local pids, which a guest can already see in `/proc`. They reveal nothing about the host's processes, or other machines in the same host process.
- **`sysstat`** reveals the machine's CPU limit and, without `--cpus`, the host's CPU count, which `/dev/sysstat` reveals on 9front too. A profile that wants to hide the host's count can set `--cpus`.
- **The clock** is read-only to the guest, as before. drawterm's writes to `time` and `bintime` already fail, and the hooks keep it that way. Nanosecond time makes timing measurements finer inside the guest. That's what every OS gives its programs, and the boundary doesn't rely on coarse time.
- **`_NSEC`** writes nothing to guest memory, so it has no pointer to check.

## Done when

The cases are tagged `[go-compat]`, built from `tests/fixtures/go/`, and run on the emulator. They need [semaphores](0003-semaphores.md) implemented first.

- `test "a Go hello world prints and exits 0 [go-compat]"`
- `test "goroutines sleep 100 ms and the elapsed time is right [go-compat]"`: the program starts goroutines, sleeps 100 ms, and prints the elapsed time, which is at least 100 ms and under 200 ms. This is the demo DESIGN.md's Go section promised.
- `test "time.Now has sub-second resolution and matches the host [go-compat]"`: two readings 10 ms apart differ by 10 ms or more, and the time is within a second of the host's.
- `test "runtime.NumCPU follows --cpus [go-compat]"`: it prints 2 under `--cpus 2`.
- `test "os.Getpid and os.Getppid match /proc [go-compat]"`: they print the same pids as `/proc/n/status` and `/proc/n/ppid`.
- `test "CPU-bound goroutines run on several processes [go-compat]"`: with `GOMAXPROCS=4` and `--cpus 4`, `/proc` shows at least four processes during the run, and it finishes. It also finishes with `--cpus 1`.
- `test "os/exec runs a child and gets its exit status [go-compat]"`: the fixture re-execs itself from `/mnt/term/cwd`, with an environment variable telling the child what to do.
- `test "a nil dereference becomes a panic that recover catches [go-compat]"`
- `test "os/signal receives interrupt on Ctrl-C [go-compat]"`, on a pty as the existing Ctrl-C cases are.
- `test "os.Exit(3) exits with status 3 [go-compat]"`: h9 exits 1 and prints "3", as for any exits string.
- `test "net/http fetches from a listener the test opens [go-compat]"`
- `test "syscall.Gettimeofday has microsecond resolution [go-compat]"`, through `_NSEC`.
- `test "/dev/bintime has four words and a monotonic clock [go-compat]"`: an rc case reads 32 bytes from `/dev/bintime` twice, and the fourth word grows by at least the time slept between the reads.

## Implementation

1. The clock leaf and `_NSEC` in `src/syscall.zig`, with its trace.
2. `src/kern/consx.c` and the leaves in `src/kern.zig`, then the hooks in `third_party/drawterm/kern/devcons.c`. The `/dev/bintime` case passes.
3. `tests/fixtures/go/`, `GO_VERSION` in `scripts/pins.sh`, and `zig build go-fixtures`.
4. With [semaphores](0003-semaphores.md) implemented, the Go cases.
5. DESIGN.md:
   - the syscall table paragraph: `_NSEC` is served and `/dev/bintime` is nanosecond and monotonic
   - the kernel's "Added by us" table: the devcons hooks
   - a short "Go programs" section on what runs and where
   
   Then set `status: implemented`.

## Open issues

- **Exit codes from Go.** `os.Exit(n)` becomes `exits("n")`, so h9 exits 1 for every non-zero code. Should the CLI map an exits string that's a decimal number from 1 to 255 to that exit code, for every program? That's a CLI change wider than Go.
- **An amd64 root tree.** A Go program that execs 9front commands needs `/amd64/bin`. `scripts/mkroot.py` builds an arm64 tree only, so on amd64 those execs fail with "file does not exist". Building an amd64 tree is a change to `mkroot.py`, and perhaps its own proposal.
- **Go's own test suite.** Running `go test` for `runtime`, `os`, `syscall` and `time` built for `plan9/amd64` would find gaps the fixtures miss. It needs the Go source tree in the guest, which waits for an amd64 root tree.
- **`/dev/swap`.** The runtime does fine without it, but 9front's `memory` and `stats` read it. Serving the machine's `--memory` and page counts there would be one more devcons hook.