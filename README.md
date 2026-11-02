# hp9 - Hyper9

Run native Plan 9 (9front) executables directly on host hypervisors. See [DESIGN.md](DESIGN.md).

## Setup (macOS arm64)

Requires Zig 0.16.x and Xcode (for the macOS SDK and `codesign`).

```sh
. scripts/env.sh               # Zig cache and tools live in .local/ (gitignored)
./scripts/fetch.sh             # reference sources + pinned 9front arm64 image into .local/
```

Pinned upstream versions are in [scripts/pins.sh](scripts/pins.sh).

drawterm is committed under `third_party/drawterm` as a squashed git subtree,
so a fresh checkout builds without network access. To move to a new upstream
revision, bump `DRAWTERM_REV` and run `./scripts/vendor-drawterm.sh` on a
clean tree; it merges upstream into the subtree and keeps our local changes.

## Build

```sh
zig build          # builds and ad-hoc signs zig-out/bin/hp9 with hp9.entitlements
zig build test     # unit tests
zig build kern     # compiles drawterm's kern
zig build m0       # M0 demo: hp9 ./hello must print "hello"
```

## Run

```sh
zig-out/bin/hp9 [--trace] ./binary [args...]
```

So far only `pwrite` to fd 1 or 2 and `exits` are served (M0).

`zig build` also writes the M0 test binary to `zig-out/fixtures/hello`. It's a
hand-assembled arm64 a.out (see [tests/fixtures/mkhello.zig](tests/fixtures/mkhello.zig))
because Zig no longer links Plan 9 a.out.

## Layout

| Path | Contents |
| --- | --- |
| `src/main.zig` | CLI |
| `src/root.zig` | library root |
| `src/machine.zig` | one machine: runs a process and serves its syscalls |
| `src/loader.zig` | loads an a.out into an address space, builds the stack and Tos |
| `src/aout.zig` | a.out parser and arch layouts |
| `src/vmm.zig`, `src/vmm/` | hypervisor interface and backends (HVF so far) |
| `src/arch/` | per-architecture Ureg/ABI and the guest shims |
| `third_party/drawterm` | vendored drawterm (git subtree; kern and libraries) |
| `tests/fixtures` | test binary generators |
| `.local/` | gitignored: tools, caches, upstream clones, 9front images |
