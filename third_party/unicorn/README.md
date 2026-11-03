# Unicorn (emu backend, GPLv2)

What hp9 needs to build [Unicorn](https://github.com/unicorn-engine/unicorn)
from source with Zig, for the emulator backend (`-Demu=unicorn`). The source
itself isn't vendored: `scripts/fetch.sh` downloads the release tarball pinned
in [scripts/pins.sh](../../scripts/pins.sh) (`UNICORN_VERSION`,
`UNICORN_SRC_URL`, `UNICORN_SRC_SHA256`), unpacks it into `.local/src/unicorn`
and applies the patches here in order. It redoes that only when the tarball
pin or a patch changes (`.local/src/unicorn/.hp9-stamp`).

Unicorn is GPLv2, and so are these patches and config headers (see
[COPYING](COPYING)). It never goes into the MIT `hp9` release build; it ships
only in the separate GPLv2 `hp9-emu` release assets, next to their
corresponding source (see `scripts/release.sh`).

| Path | Contents |
| --- | --- |
| `COPYING` | The GPLv2, which covers this directory |
| `patches/` | Changes to Unicorn, applied with `patch -p1` |
| `config/<host>/` | QEMU's generated config headers for each host: `config-host.h` and `<target>-softmmu/config-target.h` for the x86_64 and aarch64 guest targets |
| `genconfig.sh` | Regenerates `config/` |
| [build/unicorn.zig](../../build/unicorn.zig) | The Zig build: file lists and flags from Unicorn's `CMakeLists.txt`, for the two guest targets |

## Patches

Windows arm64 with mingw-w64 (Zig's libc for `aarch64-windows`). Upstream
2.1.4 doesn't support Windows arm64 hosts; the open PR
[unicorn-engine/unicorn#2286](https://github.com/unicorn-engine/unicorn/pull/2286)
covers MSVC with a different approach.

1. `0001-glib-compat-pointer-sized-gsize`: `gsize` and `gulong` were
   `unsigned long`, which is 32 bits on 64-bit Windows, so sizes stored in
   them were truncated. Not in #2286; worth sending upstream.
2. `0002-tcg-aarch64-ull-movi`: `0xffffUL << 48` in `tcg_out_movi` lost the
   high half of 64-bit constants, for the same reason. Also in #2286.
3. `0003-win32-arm64-mingw-setjmp`: QEMU leaves generated code with
   longjmp, and the CRT's longjmp unwinds the stack on arm64 and crashes with
   generated code on it. mingw-w64's `__mingw_setjmp`/`__mingw_longjmp`
   restore registers without unwinding.
4. `0004-tcg-aarch64-win32-icache`: Zig's compiler-rt has no
   `__clear_cache` for Windows arm64, so the instruction cache is flushed with
   `FlushInstructionCache`.
5. `0005-win32-arm64-code-buffer-handler`: the code buffer is reserved and
   committed page by page from a vectored exception handler, which on Windows
   is bound to its engine by a small x86 trampoline. On arm64 the handler
   instead looks the faulting address up in a table of live engines (up to
   64). It's registered first, so earlier handlers (Zig's segfault handler)
   don't treat the commit faults as crashes.

To change a patch, edit `.local/src/unicorn` (it isn't a git repo; diff
against a fresh unpack), regenerate the patch, and run `scripts/fetch.sh` to
check that the series applies.

## Config headers

QEMU's `configure` writes host and target headers. Unicorn's CMake build runs
it at configure time, which doesn't work when cross-compiling with Zig, so
the output is kept here instead. `genconfig.sh` runs `configure` once per host
with `zig cc -target <host>` as the compiler (dropping `-mthreads`, which
mingw's configure passes and zig cc rejects; macOS needs `SDKROOT` from
`scripts/env.sh`). Run it after bumping `UNICORN_VERSION`:

```sh
./scripts/fetch.sh && third_party/unicorn/genconfig.sh
```

Hosts: `aarch64-macos`, `aarch64-linux-musl`, `x86_64-linux-musl` and
`aarch64-windows-gnu`.
