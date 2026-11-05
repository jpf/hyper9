---
slug: linux-net
title: Linux readiness and sockets
status: draft
created: 2026-11-05
authors: [progrium]
depends: [18]
areas: [kern, sandbox]
---

# Proposal: Linux readiness and sockets

## Abstract

Linux processes under the [Linux personality](0018-linux-personality.md) can use BSD sockets, non-blocking fds and the readiness calls: `poll`, `ppoll`, `pselect6`, `epoll` and `eventfd`. Sockets are served by `/net`, so the policy's network rules apply unchanged. Readiness is new kernel code in h9: a leaf that asks each fd's channel whether a read or write would block, woken by the queues and host sockets behind it. This brings curl, Python's `asyncio` and `http.server`, Node-style event loops and Go's network poller to h9.

## Background

Plan 9 has no readiness API: a program that wants to wait on several fds uses a process per fd. Linux programs almost all use `poll` or `epoll`, often with `O_NONBLOCK` fds, and treat `EAGAIN` as "try again when ready".

What's behind an fd in h9 decides how readiness can be known:

- **Pipes and the console** are backed by qio `Queue`s. `qcanread` and `qfull` say whether a read or write would block, and the queue's wakeups say when that changes.
- **devip's data files** are not. `Qdata` reads call `so_recv` on a host socket directly (`kern/devip.c`), and `accept` calls `so_accept`. There's no queue to inspect: readiness is the host socket's.
- **devfs files** are always ready, as on Linux.
- **devmnt files** are ready when the server answers, which can't be known without asking.

## Proposal

### Sockets

`socket`, `socketpair`, `connect`, `bind`, `listen`, `accept4`, `sendto`, `recvfrom`, `sendmsg`, `recvmsg`, `getsockname`, `getpeername`, `setsockopt`, `getsockopt` and `shutdown`, for `AF_INET` and `AF_INET6` with `SOCK_STREAM` and `SOCK_DGRAM`, over `/net` clone files:

- `socket` opens `/net/tcp/clone` or `/net/udp/clone` and keeps the ctl fd with the data fd.
- `connect` writes `connect`, `bind` and `listen` write `announce`, and `accept4` opens the conversation's `listen` file.
- `getsockname` and `getpeername` read `local` and `remote`.
- Socket options that h9 can honour (`SO_REUSEADDR`, `TCP_NODELAY`, `SO_KEEPALIVE`) become ctl messages; the rest are accepted and recorded, so `getsockopt` returns them.
- `AF_UNIX` sockets are served by pipes for `socketpair`, and by `/srv`-style posting for named sockets once [devsrv](0008-devsrv.md) is built; until then, `bind` on `AF_UNIX` is `-EAFNOSUPPORT`.
- DNS goes through the Linux root's `/etc/resolv.conf`, as Linux's libc does (see Open issues).

The policy's devip hooks apply, so `--net=disable` masks sockets entirely (`socket` is `-EACCES`), and [net-policy](0005-net-policy.md)'s rules apply once it's built.

### Readiness in the kernel

A leaf `h9_poll(fds, n, timeout)` in `src/kern/` asks each fd's channel whether it's readable, writable or hung up, and sleeps until one is or the timeout passes:

- **qio-backed channels:** `qcanread`, `qfull` and the queue's closed state. A hook called from qio's existing wakeups wakes pollers on that queue.
- **devip conversations:** the host socket's readiness, from a per-machine host poller thread (`kqueue` on macOS, `epoll` on Linux, `WSAPoll` or IOCP on Windows) watching the `sfd`s pollers ask about. It wakes the pollers when a socket changes.
- **The console:** the console reader's queue, as for other qio channels.
- **devfs files:** always ready.
- **devmnt and other channels:** reported ready, so a read blocks as it would without `poll`. This is wrong for a 9P-served pipe, but right for files.

`poll`, `ppoll` and `pselect6` call `h9_poll` directly. **`epoll`** keeps an interest list per epoll fd, level-triggered and edge-triggered, and `epoll_pwait` calls `h9_poll` on it, filtering edges by a per-entry sequence number bumped on each wakeup. **`eventfd2`** is a small device with a counter, readable when non-zero.

### Non-blocking fds

`O_NONBLOCK`, set at open or with `fcntl`, makes `read`, `write`, `accept4` and `connect` check readiness first and return `-EAGAIN` (or `-EINPROGRESS` for `connect`) instead of blocking. The check and the call aren't atomic: if another reader takes the data in between, the read blocks. For qio channels the check and the read are one step under the queue's lock, a read that takes what's queued and never sleeps, so there's no gap. For sockets it calls the host with `MSG_DONTWAIT`.

## Rationale

**Readiness in h9's kernel code, not in a translator.** A translator running as a guest program could only build `poll` from helper processes, one per fd, as linuxemu did. h9 owns the kernel, so it can ask the channels directly.

**Asking host sockets, not adding queues to devip.** A queue in front of each socket would need a reader thread per socket and copy every byte twice. The host already knows when a socket is ready.

**Hooks rather than vendor changes.** qio's wakeups get one call to a leaf, and devip's conversations expose their `sfd` through a leaf. Where a hook can't be added without editing the vendored file, the edit is one line, marked `h9:`, as devfs's hooks are.

## Compatibility

- **Vendored tree:** a wakeup hook in `qio.c` and an `sfd` accessor for devip, each a line or two, marked `h9:`.
- No CLI flags change. `--net` governs sockets as it governs `/net`.

## Security

- **No new reach:** every socket is a `/net` conversation, so `--net` and the policy's devip hooks apply. A Linux program can't open a host socket that a 9front program couldn't.
- **The host poller** watches only sockets devip has already opened for the guest, and never accepts or reads on them itself.

## Done when

Integration cases tagged `[linux-net]`:

- `test "poll on a pipe wakes when the writer writes [linux-net]"`
- `test "epoll edge-triggered on a pipe [linux-net]"`
- `test "O_NONBLOCK read on an empty pipe is EAGAIN [linux-net]"`
- `test "TCP echo between a Linux client and a 9front server [linux-net]"`
- `test "socket under --net=disable is EACCES [linux-net]"`
- `test "eventfd counts and wakes epoll [linux-net]"`

Demos: `h9 --linux-root alpine curl -sI https://example.com` under the default network policy, and `h9 --net=enable --linux-root alpine python3 -m http.server` serving a page to the host.

## Implementation

1. Sockets over `/net`, blocking only. A blocking TCP client and server.
2. `h9_poll` for qio channels, `poll`, `ppoll`, `pselect6`, `O_NONBLOCK`.
3. The host poller for devip, and sockets in `h9_poll`.
4. `epoll` and `eventfd`. curl and `http.server`.
5. DESIGN.md's Linux personality section gains sockets and readiness.

## Open issues

- **`/etc/resolv.conf`.** Alpine's minirootfs has none, and the Linux root is read-only by default. Serving one from the host's resolver needs a place to put it: devlinux can't add a file inside the root's `/etc` without shadowing the rest of it, since Plan 9 unions don't merge below the top. A bind of a devlinux file over an existing one works only if the root has the file. Options: write it into an overlay once [overlay](0011-overlay.md) is built, or have fetch.sh add one to the fixture.
- **Readiness for devmnt.** A 9P server that serves a pipe-like file can't report readiness in 9P2000. A `Tread` with a zero count, or a dotl-style extension, might.
- **`AF_NETLINK`**, which `ip` and some libraries probe, is `-EAFNOSUPPORT`. Is anything common blocked by that?
- **`SO_PEERCRED`** for `AF_UNIX`, and passing fds with `SCM_RIGHTS`, once named Unix sockets exist.
