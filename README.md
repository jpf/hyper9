# hp9 - Hyper9

Run native Plan 9 (9front) executables directly on host hypervisors. See [DESIGN.md](DESIGN.md).

## Setup (macOS arm64)

Requires Zig 0.16.x and Xcode (for the macOS SDK and `codesign`).

```sh
. scripts/env.sh               # Zig cache and tools live in .local/ (gitignored)
./scripts/fetch.sh             # reference sources, pinned 9front arm64 image, prebuilt Unicorn into .local/
```

Pinned upstream versions are in [scripts/pins.sh](scripts/pins.sh).

drawterm is committed under `third_party/drawterm` as a squashed git subtree,
so a fresh checkout builds without network access. To move to a new upstream
revision, bump `DRAWTERM_REV` and run `./scripts/vendor-drawterm.sh` on a
clean tree; it merges upstream into the subtree and keeps our local changes.

## Build

```sh
zig build          # builds and ad-hoc signs zig-out/bin/hp9 with hp9.entitlements
zig build test     # unit tests, and the backend tests on every backend built in
zig build kern     # compiles drawterm's kern
zig build m0       # M0 demo: hp9 ./hello must print "hello"
```

The emulator backend links the prebuilt Unicorn (GPLv2) fetched by
`scripts/fetch.sh`, so it's opt-in and for development and CI only:

```sh
zig build -Demu=unicorn                              # macOS arm64
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl  # Linux arm64 (also x86_64-linux-musl)
zig build m1 -Demu=unicorn                           # M1 demo: hp9 --backend emu ./hello
```

Prebuilt Unicorn exists for macOS arm64 and Linux musl only. Windows builds
(`-Dtarget=aarch64-windows`) produce hp9.exe without kern or the emulator
until M2.

## Run

```sh
zig-out/bin/hp9 [--backend auto|hvf|kvm|whp|emu] [--trace] ./binary [args...]
```

`--backend auto` (the default) uses the host hypervisor and otherwise falls
back to the emulator with a warning. The emulator also runs amd64 binaries on
arm64 hosts, for testing; HVF runs arm64 only.

So far only `pwrite` to fd 1 or 2 and `exits` are served (M0/M1).
`--trace` prints one line per syscall to stderr.

`zig build` also writes the test binaries `zig-out/fixtures/hello` (arm64) and
`zig-out/fixtures/hello-amd64`. They're hand-assembled a.outs (see
[tests/fixtures/hello.zig](tests/fixtures/hello.zig)) because Zig no longer
links Plan 9 a.out.

[tests/backends.zig](tests/backends.zig) runs small programs on every backend
built in and checks that each gives the same output and syscall trace.
`zig build install-tests` installs it as `zig-out/bin/backend-tests`, to run
in a VM.

## Test VMs

[scripts/lima](scripts/lima/README.md) has Lima VMs (arm64 Linux, macOS and
Windows, plus emulated x86\_64 Linux) for testing the emu backend on hosts
without a usable hypervisor:

```sh
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm up linux
scripts/lima/vm push linux zig-out/linux/bin/hp9 zig-out/fixtures/hello
scripts/lima/vm shell linux ./hp9/hp9 --backend emu ./hp9/hello
```

## Layout

| Path | Contents |
| --- | --- |
| `src/main.zig`, `src/cli.zig` | CLI: entry point, and flag parsing with no I/O |
| `src/root.zig` | library root |
| `src/machine.zig` | one machine: runs a process and serves its syscalls |
| `src/loader.zig` | loads an a.out into an address space, builds the stack and Tos |
| `src/aout.zig` | a.out parser and arch layouts |
| `src/vmm.zig`, `src/vmm/` | hypervisor interface and backends (HVF, and emu on Unicorn) |
| `src/arch/` | per-architecture Ureg/ABI and the guest shims |
| `third_party/drawterm` | vendored drawterm (git subtree; kern and libraries) |
| `tests/backends.zig` | backend conformance tests |
| `tests/fixtures` | test programs and binary generators |
| `.local/` | gitignored: tools, caches, upstream clones, 9front images, prebuilt Unicorn, test VMs |
