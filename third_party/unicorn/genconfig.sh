#!/usr/bin/env bash
# Regenerates config/<name>/ (QEMU's config-host.h and per-target
# config-target.h) by running Unicorn's qemu/configure with zig cc for each
# host. Run after bumping UNICORN_VERSION; needs the source from fetch.sh.
#   third_party/unicorn/genconfig.sh [name...]
set -euo pipefail
. "$(dirname "$0")/../../scripts/env.sh"
here="$H9_ROOT/third_party/unicorn"
src="$H9_LOCAL/src/unicorn"
[ -x "$src/qemu/configure" ] || { echo "genconfig: no $src (run scripts/fetch.sh)" >&2; exit 1; }

# Each host name is also its zig target.
hosts="aarch64-macos aarch64-linux-musl x86_64-linux-musl aarch64-windows-gnu x86_64-windows-gnu"
targets="x86_64-softmmu aarch64-softmmu"
[ $# -gt 0 ] || set -- $hosts

for name in "$@"; do
	case " $hosts " in *" $name "*) ;; *) echo "genconfig: unknown host $name" >&2; exit 1 ;; esac
	triple=$name
	extra=""
	# configure links test programs with -framework; zig cc needs the SDK.
	case $name in *-macos) [ -n "${SDKROOT:-}" ] || { echo "genconfig: SDKROOT unset (scripts/env.sh sets it from xcrun)" >&2; exit 1; }
		extra="-F$SDKROOT/System/Library/Frameworks -isystem $SDKROOT/usr/include -L$SDKROOT/usr/lib" ;;
	esac
	work="$H9_LOCAL/cache/unicorn-config-$name"
	rm -rf "$work" && mkdir -p "$work"
	# mingw's configure passes -mthreads, which zig cc rejects as unused.
	cat > "$work/cc" <<CC
#!/bin/sh
for x in "\$@"; do [ "\$x" = -mthreads ] || set -- "\$@" "\$x"; shift; done
exec zig cc -target $triple $extra "\$@"
CC
	chmod +x "$work/cc"
	(cd "$work" && sh "$src/qemu/configure" --cc="$work/cc" \
		"--extra-cflags=-DUNICORN_HAS_X86 -DUNICORN_HAS_ARM64" \
		--target-list="${targets// /,}" >"$work/configure.log" 2>&1) ||
		{ tail -20 "$work/configure.log" >&2; exit 1; }
	out="$here/config/$name"
	rm -rf "$out" && mkdir -p "$out"
	sh "$src/qemu/scripts/create_config" <"$work/config-host.mak" >"$out/config-host.h"
	for t in $targets; do
		mkdir -p "$out/$t"
		sh "$src/qemu/scripts/create_config" <"$work/$t/config-target.mak" >"$out/$t/config-target.h"
	done
	rm -rf "$work"
	echo "config/$name"
done
