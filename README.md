# hp9 - Hyper9

Run native Plan 9 (9front) executables directly on host hypervisors. See [DESIGN.md](DESIGN.md).

## Setup (macOS arm64)

Requires Zig 0.16.x and Xcode (for the macOS SDK and `codesign`).

```sh
. scripts/env.sh               # Zig cache and tools live in .local/ (gitignored)
./scripts/fetch.sh             # reference sources (9front at the pinned release), 9front arm64 image, prebuilt and patched-source Unicorn into .local/
./scripts/mkroot.py            # extracts the 9front root tree into .local/9front/root (~1 min, ~250 MB)
```

`mkroot.py` boots the pinned image headless in QEMU (`brew install qemu`),
tars the file system out onto a scratch disk, and unpacks it into
`.local/9front/root-<release>`, with `.local/9front/root` linked to it. The
image itself isn't modified. It's the host-tree root that M2 serves as `/`.
Boot kernels, `/sys/doc` and `/sys/src` are left out; pass `--src` to keep
`/sys/src`, which self-hosting (M6) needs.

Pinned upstream versions are in [scripts/pins.sh](scripts/pins.sh).

drawterm is committed under `third_party/drawterm` as a squashed git subtree,
so a fresh checkout builds without network access. To move to a new upstream
revision, bump `DRAWTERM_REV` and run `./scripts/vendor-drawterm.sh` on a
clean tree; it merges upstream into the subtree and keeps our local changes.

## Build

```sh
zig build          # builds and ad-hoc signs zig-out/bin/hp9 with hp9.entitlements
zig build test     # unit tests, and the backend tests on every backend built in
zig build kern     # compiles drawterm's kern and the libraries it uses
zig build m0       # M0 demo: hp9 ./hello must print "hello"
zig build m2       # M2 demos: hp9 /bin/cat /lib/namespace, and a write under --profile=tight fails
zig build m3       # M3 demo, hp9 --rc 'ls /bin | wc -l', and the M3 integration cases
zig build integration  # real 9front binaries from the root tree through the hp9 CLI
```

The M2 and M3 demos and the integration tests use the root tree from
`scripts/mkroot.py`, or `-Droot=DIR`. The integration tests skip when there's
no tree. Cases for the milestone in progress are named `M4: ...` and so on, and
skip in `zig build integration` and `zig build test`. Cases for a finished
milestone are tagged `(M3)` and so on; `zig build m3` runs the M3 ones.

The emulator backend links the prebuilt Unicorn (GPLv2) fetched by
`scripts/fetch.sh`, so it's opt-in and never part of the MIT `hp9` build. It
ships separately as `hp9-emu` (see [Releases](#releases)):

```sh
zig build -Demu=unicorn                              # macOS arm64
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl  # Linux arm64 (also x86_64-linux-musl)
zig build m1 -Demu=unicorn                           # M1 demo: hp9 --backend emu ./hello
zig build bench -Demu=unicorn                        # compute and syscall speed, emu vs the hypervisor
```

`-Dunicorn=source` builds Unicorn from the patched source instead
([third_party/unicorn](third_party/unicorn/README.md)); `scripts/fetch.sh`
fetches it. The prebuilt libraries exist for macOS arm64 and Linux musl only,
so Windows arm64 (`-Dtarget=aarch64-windows`) always builds from source. kern
builds for Windows with drawterm's win32 files, so hp9.exe runs programs on
the emulator, and host paths are `/C:/...` in `#U`.

## Releases

Each GitHub release has two sets of binaries, built by
`scripts/release.sh [version]` into `dist/<version>/` from a clean checkout:

| Asset | License | Contents |
| --- | --- | --- |
| `hp9-<version>-<target>` | MIT | `hp9` with the hypervisor backends only (macOS arm64 for now) |
| `hp9-emu-<version>-<target>` | GPLv2 | `hp9-emu`: hp9 built with `-Demu=unicorn`, for macOS arm64, Linux arm64 and x86_64 (musl, static) and Windows arm64 |
| `hp9-emu-<version>-source.tar.gz` | GPLv2 and MIT | complete corresponding source for `hp9-emu`: the hp9 tree plus Unicorn's patched source in `.local/src/unicorn` |
| `SHA256SUMS` | | checksums |

`hp9-emu` takes the same flags as `hp9` and runs on hosts without a usable
hypervisor. It links Unicorn Engine, so the binary as a whole is GPLv2, with
`COPYING`, `NOTICE` and the MIT notices in each archive; see [LICENSE](LICENSE).
The script builds every binary from the unpacked source tarball, with Unicorn
from source (`-Dunicorn=source`), so the tarball is exactly what was built. It
needs `scripts/fetch.sh` to have been run and runs on macOS, which
cross-compiles the other targets.

## Run

```sh
zig-out/bin/hp9 [hp9-flags] [--] program [args...]
zig-out/bin/hp9 [hp9-flags] --rc 'command' [args...]

zig-out/bin/hp9 /bin/cat /lib/namespace    # M2 demo
zig-out/bin/hp9 ls -l /bin/cat             # bare names search $path: . and /bin
zig-out/bin/hp9 ./hello                    # ./ and ../ are host paths
```

A program starting with `./` or `../` is read from the host. Anything else is
a guest path or name in the machine's namespace: `/` is the root tree
(`--root`, else `$HP9ROOT`, else `.local/9front/root` next to a development
build), `/bin` is `/arm64/bin` plus `/rc/bin`, and the host cwd (or `--cwd`)
is at `/mnt/term/cwd` and is the guest's cwd. The host environment isn't
imported: the guest gets `user`, `home`, `cputype`, `objtype`, `sysname`,
`service`, `path` and `timezone`, plus any `--env`. Exit codes: 0 for an empty
`exits` string, 1 for any other (printed to stderr), 2 for a usage error, 125
when hp9 itself fails, 126 when the program isn't a runnable a.out and 127
when it isn't found.

Flags: `--backend auto|hvf|kvm|whp|emu`, `--root DIR`, `--cwd DIR`, `--env
name=value` (repeatable), `--rc 'cmd'`, `--ns FILE`, `--trace[=FILE]`,
`--dump-on-fault`, and the sandbox flags below. `--rc` runs `/bin/rc -c`.
`--ns FILE` replays a namespace file in newns syntax (`bind`, `mount`,
`unmount`, `cd`, `clear`) before the program runs; it's a guest path, so a
relative one is in the guest's cwd, and `--print`'s namespace section can be
saved and replayed as is.

`--backend auto` (the default) uses the host hypervisor and otherwise falls
back to the emulator with a warning. The emulator also runs amd64 binaries on
arm64 hosts, for testing; HVF runs arm64 only.

Syscalls go through drawterm's kern: open, create, close, dup, pread, pwrite,
seek, stat, fstat, wstat, fwstat, fd2path, bind, chdir, remove, errstr, brk_,
sleep, notify, exits, and for process trees rfork, exec (including `#!`
scripts), await and pipe; `/fd` is devdup. Each process has its own kernel
thread and normally its own vCPU. HVF allows 64 vCPUs, so past 56 processes
the rest share a pool of 8 vCPUs, which costs a thread handoff per syscall.
`--trace` prints one line per syscall
to stderr, or to a file with `--trace=FILE`. `--dump-on-fault` prints the
registers and the symbolized PC when the guest faults.

### Sandbox

By default the guest sees the root tree read-only, the host cwd read-write
at `/mnt/term/cwd`, the host temp dir at `/tmp`, and nothing else of the
host. `#U` and `#C` are masked, so the guest can't attach more of the host,
and symlinks are resolved before access is checked, so a link inside a bound
tree can't reach outside it. See [DESIGN.md](DESIGN.md), "Sandbox policy".

```sh
hp9 --profile=tight ls -l            # read-only cwd, no network, 10m timeout
hp9 --sandbox ./work touch f         # tight, with only ./work bound, writable
hp9 --profile=tight --writable ./out touch out/x
hp9 --readable ~/src --read-deny ~/src/.env ls /mnt/term/$HOME/src
hp9 --memory 256m --timeout 30s ls   # resource caps
hp9 --pids 32 --cpus 2 --rc 'mk'     # at most 32 processes, 2 running at once
hp9 --print --profile=tight mk       # print the compiled plan and exit
hp9 --strict --write=overlay mk      # exit 2: not enforceable before M10
```

| Flag | Meaning |
| --- | --- |
| `--profile default\|tight` | Sandbox defaults; explicit flags override them |
| `--readable PATH`, `--writable PATH` | Bind a host path read-only or read-write; outside the root and cwd it appears at `/mnt/term/PATH` |
| `--read-deny PATH` | Hide a host path, even inside a bound tree |
| `--write none\|scope` | Deny all writes, or allow them only in writable paths (`ephemeral` and `overlay` come in M5 and M10, and deny writes until then) |
| `--net disable\|enable` | Mask `#I`, or leave it (`outbound` comes in M5) |
| `--memory SIZE`, `--timeout DURATION` | Cap guest memory (`512m`); stop the machine after a deadline (`30s`, `1m`) |
| `--pids N`, `--cpus N` | Cap live processes (rfork fails with "no procs"); cap vCPUs running guest code at once |
| `--host-fs`, `--host-cmd` | Show the whole host read-only at `/mnt/term`; unmask devcmd |
| `--print`, `--strict` | Print the plan and exit; refuse (exit 2) capabilities this build can't enforce |

`zig build` also writes the test binaries `zig-out/fixtures/hello` (arm64) and
`zig-out/fixtures/hello-amd64`. They're hand-assembled a.outs (see
[tests/fixtures/hello.zig](tests/fixtures/hello.zig)) because Zig no longer
links Plan 9 a.out.

[tests/backends.zig](tests/backends.zig) runs small programs on every backend
built in and checks that each gives the same output and syscall trace.
`zig build install-tests` installs it as `zig-out/bin/backend-tests`, to run
in a VM. [tests/integration.zig](tests/integration.zig) runs real binaries
from the root tree through `hp9` itself, checking output and exit codes.

## Test VMs

[scripts/lima](scripts/lima/README.md) has Lima VMs (arm64 Linux, macOS and
Windows, plus emulated x86\_64 Linux) for testing the emu backend on hosts
without a usable hypervisor:

```sh
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm up linux
scripts/lima/vm push linux zig-out/linux/bin/hp9 zig-out/fixtures/hello
scripts/lima/vm shell linux ./hp9/hp9 --backend emu ./hp9/hello
scripts/lima/vm push-root linux             # the root tree, into ~/hp9/root
```

## Layout

| Path | Contents |
| --- | --- |
| `src/main.zig`, `src/cli.zig` | CLI: entry point, and flag parsing with no I/O |
| `src/root.zig` | library root |
| `src/machine.zig` | one machine: builds its namespace, runs a process and serves its syscalls |
| `src/policy.zig` | the sandbox policy: profiles, the compiled plan, `--print` and the access rules devfs checks |
| `src/kern.zig`, `src/kern/` | the Zig/C seam into drawterm's kern; boot and spawn (`glue.c`), our device table, the machine console `#y`, devenv ported from 9front, and the devfs policy hooks (`fscheck.c`) |
| `src/syscall.zig`, `src/guestmem.zig` | the 9front syscall table, and checked access to guest memory |
| `src/loader.zig` | loads an a.out into an address space, builds the stack and Tos |
| `src/aout.zig` | a.out parser and arch layouts |
| `src/vmm.zig`, `src/vmm/` | hypervisor interface and backends (HVF, and emu on Unicorn) |
| `src/arch/` | per-architecture Ureg/ABI and the guest shims |
| `third_party/drawterm` | vendored drawterm (git subtree; kern and libraries). Local changes: the sandbox hooks in `kern/devfs-posix.c` and `kern/devfs-win32.c` |
| `third_party/unicorn`, `build/unicorn.zig` | patches, per-host config headers and the Zig build for Unicorn from source (GPLv2; source fetched, not vendored) |
| `tests/backends.zig` | backend conformance tests |
| `tests/integration.zig` | real 9front binaries through the hp9 CLI |
| `tests/fixtures` | test programs and binary generators |
| `scripts/mkroot.py` | builds the 9front root tree from the pinned image |
| `scripts/release.sh` | builds the release assets (`hp9`, `hp9-emu` and its source) into `dist/` |
| `.local/` | gitignored: tools, caches, upstream clones, 9front images, prebuilt Unicorn, test VMs |
