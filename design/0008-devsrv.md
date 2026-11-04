---
id: 8
slug: devsrv
title: devsrv, /srv and mount
status: draft
created: 2026-11-03
authors: [progrium]
depends: [semaphores]
areas: [kern]
---

# Proposal: devsrv, /srv and mount

Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Guest file servers can post themselves and be mounted:

- **`#s`:** devsrv, ported from 9front, bound at `/srv`. Each machine gets its own registry, so machines in one host process can't see each other's services.
- **Syscalls:** `mount`, `unmount` and `fauth` are served, through drawterm's existing `sysmount`, `sysunmount` and devmnt's `mntauth`.

With [semaphores](semaphores.md), which serves the `rendezvous` that every lib9p server uses at startup, `ramfs`, `factotum`, `plumber`, `srv` and `srvfs` run. rio's `/srv` and `/mnt/wsys`, which [gfx](gfx.md) needs, work the same way.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's table of kernel pieces added by h9 had two rows for it:

| Piece | Why |
| --- | --- |
| devsrv `#s` | Guest file servers post themselves; needed for factotum, exportfs and rio |
| devshr, devcap | Later: shared /srv namespaces and hostowner capabilities |

### What a server needs

A 9front file server reaches its clients in one of two ways. Both end in `mount`:

- **Through a pipe.** The server holds one end and mounts the other end itself, as acme does with `/mnt/acme`.
- **Through `/srv`.** It creates `/srv/name`, writes the number of an open fd into it, and other processes open `/srv/name` to get that channel and mount it.

lib9p's `postsrv`, which `postmountsrv` and most servers use, does both. It makes a pipe; posts one end to `/srv/name` with `ORCLOSE`, so the entry goes when the server exits; forks the server process with `RFNAMEG|RFNOTEG`; hands it the other end with a `rendezvous`; and returns the posted end for the caller to mount.

The `mount` command goes through libauth's `amount`, which calls `fauth` first and mounts with the auth fd if it gets one, or with -1 if the server needs no authentication. `mount -n` skips `fauth`.

### h9 today

- **devsrv** isn't in `src/kern/devtab.c`, and nothing is bound at `/srv`. The root tree's `/srv` is an empty mount point.
- **The syscalls:** `mount` (46), `unmount` (35) and `fauth` (10) aren't in `src/syscall.zig`, so each posts "sys: bad sys call".
  - So `mount` kills the `mount` command and every server that mounts itself.
  - And `fauth` kills `amount` before it reaches `mount`.
- **The host side** already mounts: `--ns` replay calls `kern.mount` and `kern.unmount`, which wrap drawterm's `sysmount` and `sysunmount`. drawterm's devmnt is a complete 9P client, and its `mntauth` sends `Tauth`. Only the guest can't reach them.

### 9front's devsrv

`port/devsrv.c` at the pinned revision (688 lines):

- **Boards.** There's a root board, and each board holds services and child boards.
  - Opening `clone` makes a child board named by a number. Reading `clone` gives that number. The open fd is the board's lease: closing it closes the board and every service on it.
  - Boards nest, and `#s/id1/id2` walks to one. `/lib/namespace` binds `#s$srvspec` at `/srv`, so a namespace can start from a private board.
- **Posting a service:** `create` it with `OWRITE`, then write a decimal fd number into it. The fd's channel is held until the entry is removed. Writing a second number, posting an auth fd, or creating a name that's in use is an error.
- **Using a service:** opening it returns another reference to the posted channel, in a compatible mode, after the usual permission check.
- **Ownership:** `remove`, and `wstat` of name, owner or mode, need the entry's owner or eve.
- **Locking:** one `RWLock` and one board tree for the whole kernel.

## Proposal

### devsrv in `src/kern/devsrv.c`

A port of 9front's devsrv, kept close to it, with three changes:

1. **A root board per machine.** `srvattach` finds the calling process's machine through its h9 process record (`Hproc.mach`) and attaches that machine's root board, creating it on first use. `Hmach` gains a pointer to it.
   - **Lifetime:** the board is freed when the machine is, after closing every channel still posted on it, as closing a lease does.
   - **Locking:** the board's tree and the `RWLock` are per machine. Boards made with `clone` hang off the machine's root, so `#s/id` addressing works within a machine and not across machines.
2. **drawterm's kernel.**
   - drawterm's `Chan` has no `srvname`, so devsrv doesn't set one (see `/proc/n/ns` below).
   - `ccloseq` becomes `cclose`, since drawterm's `cclose` already runs from any kernel thread.
   - `iseve` and `up->user` are drawterm's.
   - Everything else devsrv uses exists in drawterm: `devwalk`, `devpermcheck`, `fdtochan`, `RWLock`, and the error strings.
3. **Device letter and registration.** `s`, added to `src/kern/devtab.c`.

### The namespace

The namespace builder binds `#s` at `/srv` with `MCREATE`, in both profiles, beside `#d` and `#p`. Since the board is per machine, binding it reveals nothing outside the machine, so it's not a policy decision and isn't in the device mask.

### `mount`, `unmount` and `fauth`

In `src/syscall.zig`, decoded as 9front does:

| Call | Number | Arguments | Served by |
| --- | --- | --- | --- |
| `mount` | 46 | `fd`, `afd`, `old`, `flag`, `aname` | drawterm's `sysmount`, as `kern.mount` already uses it, with `afd` passed through |
| `unmount` | 35 | `name`, `old` | drawterm's `sysunmount`; `name` may be nil |
| `fauth` | 10 | `fd`, `aname` | A new `h9_fauth` wrapper in `src/kern/glue.c`: `fdtochan` the fd, call devmnt's `mntauth`, and return a new fd on the auth channel, as 9front's `sysfauth` does |

The strings are copied into host buffers first, as for `bind`. `--trace` prints the paths, flags and spec. `/proc/n/status` shows `Mount`, `Unmount` and `Fauth` while a process is in one.

`mount` blocks until the server answers `Tversion` and `Tattach`, as on 9front. A note interrupts it, as it interrupts any devmnt RPC.

### `/proc/n/ns`

h9's devproc prints a mount as `mount` with the mounted channel's path. Without `srvname`, a mount of `/srv/x` prints the channel's own path, such as `#|/data1`, where 9front prints `/srv/x`. The line is right, but it can't be replayed with `--ns`, since `#|/data1` names a different pipe in a new namespace (see Open issues).

## Rationale

**Per-machine boards, not 9front's global one.**
- **The problem:** h9 runs several machines in one kernel when an embedder or the test suite asks for it, and each machine is meant to be its own sandbox. A global `/srv` would let one machine open another's posted channels: its factotum, its file servers, its pipes.
- **The fix:** hanging the root board off `Hmach` keeps the port close to 9front's code, and gives each machine what a single 9front kernel gives a single system. `clone` boards still work for namespaces inside a machine.

**`mount` and `fauth` here, not in a proposal of their own.** devsrv without `mount` is a registry nobody can use, since every client of a posted service mounts it. Every other server that mounts itself needs `mount` too. They're one change in practice, and the syscalls are thin, because drawterm already has the code behind them.

**`fauth` through devmnt's `mntauth`.** Without `fauth`, `amount` and the `mount` command die before mounting even unauthenticated servers. With it, they get the server's "authentication not required" and carry on, which is the common case for local servers. Authenticating with factotum and `p9any` also works: it's devmnt's `Tauth` plus a guest factotum, with nothing h9-specific.

**No devshr or devcap.** devshr's shared `/srv` across namespaces, and devcap's capabilities for changing user, have no user in what h9 runs today. They'd each be a proposal once something needs them.

**Depending on semaphores.** lib9p's `postsrv` always does a `rendezvous`, and lib9p and libthread lock with `qlock`, which needs `rendezvous` under contention. Without [semaphores](semaphores.md), devsrv could be tested only with hand-written servers, and the demos below wouldn't run.

## Compatibility

- **New files:** `/srv` is a registry in every machine, empty at start.
- **`mount`, `unmount` and `fauth`** stop posting "sys: bad sys call". Programs that died on them now mount.
- **`--ns`:** `mount /srv/x …` lines in namespace files now work when a guest has posted `/srv/x` before the replay. Replay runs before the program, so in practice only services posted by an earlier stage of a script, or by the `--ns` file's own commands, are there.
- **CLI flags, exit codes, `Machine.Options` and sandbox defaults:** unchanged.
- **Vendored tree:** unchanged. devsrv is a port in `src/kern/`, `h9_fauth` uses `mntauth` from `kern/fns.h`, and `sysmount` and `sysunmount` are used as they are.

## Security

- **No host reach.**
  - `mount` takes an fd the guest already has, and speaks 9P over it to whatever is on the other end: another guest process, or a network connection the policy already allowed.
  - It can't attach a device, so the device mask and `#U` masking are unaffected.
  - `unmount` only takes things out of the guest's namespace, and masked devices can't be attached again, so it can't widen what the guest reaches.
- **Isolation between machines.** Each machine's `/srv` is its own board tree. A posted channel can be reached only from that machine.
- **Within a machine,** devsrv's owner and permission checks apply, with the machine's user as `up->user`, as on 9front. Every process in a machine runs as the same user, so they protect against mistakes rather than other users, as on a single-user 9front terminal.
- **Resources.** A posted channel holds a reference until it's removed or the machine ends, and every posting process is counted against `--pids`. The board structures are small kernel allocations bounded by the fds a guest can open.
- **Blocking.** `mount` blocks only the calling process, and notes, `--timeout` and `/proc/n/ctl kill` interrupt it through devmnt, as for any 9P RPC.

## Done when

Integration cases, tagged `[devsrv]`, using the root tree's own servers:

- `test "ramfs posts to /srv and another process mounts it [devsrv]"`: `ramfs -S r; mount -c /srv/r /n/r; echo hi > /n/r/x; cat /n/r/x` prints `hi`.
- `test "a posted pipe is a named pipe [devsrv]"`, from srv(3)'s example.
- `test "mount without auth works through fauth [devsrv]"`: `mount` (not `mount -n`) of a ramfs.
- `test "unmount takes a mount out of the namespace [devsrv]"`
- `test "srvfs reexports a directory through /srv [devsrv]"`
- `test "a server's /srv entry goes when it exits [devsrv]"`, through `ORCLOSE`.
- `test "a second create of a /srv name fails [devsrv]"`
- `test "clone makes a private board, and closing it clears it [devsrv]"`
- `test "factotum starts and serves /mnt/factotum [devsrv]"`
- `test "plumber starts and serves /mnt/plumb [devsrv]"`

Backend cases in `tests/backends.zig`, since only they put two machines in one host process:

- `test "two machines in one process have separate /srv [devsrv]"`
- `test "a machine's posted channels are closed when it ends [devsrv]"`

Demo: `h9 --rc 'ramfs -S tmp && mount -c /srv/tmp /n/tmp && touch /n/tmp/a && ls /n/tmp'` lists `/n/tmp/a`.

## Implementation

1. `mount`, `unmount` and `fauth` in `src/syscall.zig`, `h9_fauth` in `glue.c`, and the bindings in `src/kern.zig`. A mount over a pipe from a guest that serves 9P itself works now.
2. `src/kern/devsrv.c`, the port with per-machine root boards, `Hmach`'s board pointer and teardown, and the `s` entry in `devtab.c`.
3. The `/srv` bind in `src/policy.zig`'s namespace builder, and `--print`'s line for it.
4. With [semaphores](semaphores.md) implemented, the integration and backend cases.
5. DESIGN.md:
   - the kernel's "Added by us" table: devsrv, per machine
   - the boot sequence's bind list
   - the syscall paragraph: `mount`, `unmount` and `fauth` are served
   
   Then set `status: implemented`.

## Open issues

- **`srvname`.** Should h9 track the `/srv` name a mounted channel came from, in a table beside devsrv rather than in drawterm's `Chan`? That would let `/proc/n/ns` print `mount /srv/x /n/x` as 9front does, so a printed namespace replays with `--ns`.
- **exportfs.** `exportfs -s` and `-a` serve a namespace over a fd. With `mount` and `/srv`, it should run, but whether its auth paths need more than `fauth` hasn't been checked.
- **Posting from the host.** An embedder could post a host-served 9P connection into a machine's `/srv` before the program starts, for example a host directory served by a 9P server rather than devfs. That's a `Machine.Options` addition, and would come with [9p-roots](9p-roots.md).