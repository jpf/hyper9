---
id: 13
slug: 9p-roots
title: 9P roots
status: draft
created: 2026-11-03
authors: [progrium]
depends: [3]
areas: [cli, kern, sandbox]
---

# Proposal: 9P roots

## Abstract

`--root` takes a 9P server as well as a host directory: a dial string (`tcp!fs.example!564`) or a unix socket (`unix!/run/fs.sock`, or the socket's path). h9 connects before the program starts and mounts the server through devmnt as the guest's `/`. Everything else in the namespace, the cwd, `/mnt/term`, `/dev` and the rest, is bound over it as over a host tree. Programs are looked up and loaded through the kernel, so they run from the server unchanged.

## Background

This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's root filesystem list had three entries, of which only the first is built:

1. **Direct host tree:** a directory served through `#U`.
2. **9P mount:** `--root tcp!host!564` (or a unix socket path) dials and mounts through devmnt. Covers remote file servers and u9fs.
3. **Disk image:** [image-roots](0014-image-roots.md).

### h9 today

- **`--root DIR`** must name a host directory. `src/main.zig` resolves it with `realpath` and passes it in `Machine.Options.root`, a host path.
- **The plan** (`src/policy.zig`) binds `#U<root>` at `/`, read-only unless the root is a `--writable` path, and adds an access rule for it.
- **Lookup:** a program given as a guest path or a bare name is opened through the kernel along `$path`, and `exec` reads it through the kernel too. Nothing assumes the root is a host directory except the plan's first bind and its access rule.
- **devmnt** is drawterm's complete 9P client. The `--ns` replay already mounts with `kern.mount`, which wraps drawterm's `sysmount`.
- **Connections from the host:** devip (`#I`) dials TCP on every host. drawterm's devlfd wraps a host fd as a channel (`lfdchan`), which is how drawterm gives its kernel the host's stdio.

## Proposal

### `--root`

| Flag | Meaning |
| --- | --- |
| `--root DIR\|DIAL\|SOCKET` | The root tree: a host directory, a 9P server's dial string, or a unix socket. If omitted, use `$H9ROOT`, then the default install location |
| `--root-spec NAME` | The attach name (mount(1)'s `spec`) sent to a 9P root. Empty by default |

`--root`'s argument is read as:

- **`tcp!host!port`**, or `tcp!host`, which means port 564 (`9fs`): a TCP 9P server.
- **`unix!path`:** a unix-domain socket.
- **Anything else:** a host path. If it's a socket, it's a unix socket root. If it's a directory, it's a host tree, as now. Otherwise it's an error ("root X: not a directory or socket"), exit 125.

`$H9ROOT` takes the same forms.

### `Machine.Options`

`root` becomes a union:

```zig
pub const Root = union(enum) {
    /// A host directory, absolute and resolved, served through #U.
    dir: []const u8,
    /// A TCP 9P server: a dial string, `tcp!host!port`.
    tcp: []const u8,
    /// A unix-domain socket's host path.
    unix: []const u8,
};
root: ?Root = null,
/// The attach name for a 9P root.
root_spec: []const u8 = "",
```

### Connecting and mounting

The namespace builder does it first, in the machine's first Proc, before any other bind and before the device mask is set:

1. **Connect.** A TCP root is dialed through devip, by device path rather than through `/net`, so it works whether or not `#I` is bound or masked later. A unix socket root is connected by h9 on the host and wrapped as a channel with devlfd's `lfdchan`.
2. **Mount** the connection at `/` with `MREPL`, with no auth fd and the spec from `--root-spec`. devmnt sends `Tversion` and `Tattach`, with the machine's user as the attach `uname`.
3. **Keep** the connection's channel for the machine's life, so `--ns` can attach it again (below).

Then the rest of the plan's binds run as they do over a host tree: `#c` and `#y` on `/dev`, `/$cputype/bin` and `/rc/bin` on `/bin`, the cwd at `/mnt/term/cwd` (falling back to `/mnt/term`), `#U/` after `/mnt/term` when needed, and the other devices.

**Failures** before the program runs are h9's: a refused connection, a failed `Tversion` or `Tattach`, or a server that wants authentication exit 125, with the server's error ("root tcp!fs!564: authentication required"). Once the program runs, a server that hangs up makes the guest's file operations fail as devmnt fails them ("i/o on hungup channel"), as on 9front.

**Authentication:** none in this proposal. A 9P root is a server that answers `Tattach` without `Tauth`: u9fs with `-a none`, `exportfs` behind `aux/listen1 -t`, or a 9P server on a unix socket that relies on the socket's permissions.

### The policy and the plan

- **Writes** to a 9P root go to its server, which decides what's writable. h9 can't make devmnt read-only, so:
  - Under `--write=scope`, the default, the root isn't in the access rules, and the plan says "writes to the 9P root go to its server, which decides what can be written". Serve the tree read-only to keep it safe (`exportfs -R`, u9fs on a read-only directory).
  - `--write=none` with a 9P root is a usage error, exit 2: "--write=none can't be enforced on a 9P root".
  - Once [overlay](0011-overlay.md) is built, its default overlay goes over a 9P root as over a host tree, so writes land in memory and the server sees none.
- **The network policy** doesn't apply to the root's own connection. h9 makes it, not the guest, and the guest can't dial anything through it. `--net=disable` still masks `#I`.
- **Host paths** in the access rules (cwd, `--readable`, `--writable`, `--read-deny`, `/tmp`) are unchanged. devfs checks only `#U`, so none of them applies inside the 9P root.

`--print` shows the root as a `mount` line with a `<root>` placeholder, as it shows the console's `<id>`, and the access column says `9p`:

```text
$ h9 --print --root tcp!fs.example!564 ls
...
namespace:
  mount '<root>' /                                        9p  # tcp!fs.example!564
  bind '#c' /dev
  bind -b '#y<id>' /dev
  ...
caveats:
  - writes to the 9P root go to its server, which decides what can be written
  - the 9P root's connection isn't encrypted
  ...
```

**In namespace files,** `mount '<root>' old [spec]` makes a new attach on the machine's root connection, as mounting the same `/srv` file twice does on 9front. So `--print` output replays with `--ns`, and a namespace file can put a second tree from the same server elsewhere (`mount '<root>' /n/other other`).

### `--check`

`--check` runs `/bin/echo` from a 9P root as from a host tree, and reports the connection and attach errors above.

## Rationale

**Mount at `/`, not a union.** A 9P root is the whole tree, as a host root is. Binding everything else over it, rather than special-casing it, keeps one namespace builder and one plan format.

**Connecting from the host, before the mask.** The root belongs to the plan, not to the guest. Dialing it before the device mask is set means a run with `--net=disable` can still have a network root without the guest getting `#I`. It's what 9front's boot does: `bootrc` dials the file server, then the system runs on top of it.

**devip for TCP, devlfd for unix sockets.** devip already dials on every host, including Windows, where a winsock handle can't safely go through devlfd's `ReadFile` and `WriteFile`. devip has no unix sockets, but h9 can connect one on POSIX hosts and hand the fd to `lfdchan`, which is what devlfd is for.

**A socket by stat, a dial string by prefix.** An existing `--root DIR` keeps working, a socket path works the way the original design text said, and `unix!` and `tcp!` are 9front's own dial-string forms. A directory and a socket can't be confused.

**No authentication yet.** Authenticating needs a factotum on the host side of the mount, with keys from somewhere, and h9 has neither. The servers people run for this, u9fs and `exportfs` on a trusted listener, don't need it. It's an open issue rather than a half-measure.

**Refusing `--write=none`, not ignoring it.** `none` promises that nothing is written. h9 can't keep that promise for a server it doesn't control, so it says so rather than printing a plan that isn't true. A caveat is enough for `scope`, whose promise is about host paths.

**`<root>` in namespace files.** It follows the console's `<id>` and [ephemeral-writes](0006-ephemeral-writes.md)'s bare `#O`: a per-machine name that a saved plan can't spell. Re-attaching the open connection is cheaper than dialing again, and means a replayed namespace sees the same server.

**Depending on semaphores.** The test server is 9front's `exportfs`, whose procs share qlocks, and contended qlocks park on `rendezvous`. Without [semaphores](0003-semaphores.md) the cases below would fail at random, not because of anything here.

## Compatibility

- **`--root` and `$H9ROOT`** accept new forms. Every existing directory argument means what it did.
- **`--root-spec`** is new.
- **`Machine.Options.root`** changes type from a host path to `Root`. Embedders write `.root = .{ .dir = path }`. `root_spec` is new.
- **`--print`** gains the `mount '<root>'` line and the `9p` access kind for 9P roots, and `--ns` accepts `<root>`. Plans for host roots are unchanged.
- **Exit codes:** connection and attach failures are 125. `--write=none` with a 9P root is 2.
- **Sandbox defaults** for host roots are unchanged.
- **Vendored tree:** unchanged. devip, devmnt and devlfd are used as they are.

## Security

- **What the guest newly reaches:** the files the server serves, as `/`. It can't reach the server's network, or anything else, through the connection.
- **What the server sees:** every file operation the guest makes on the root, and the host user's name as the attach `uname`. A run trusts its 9P root as it trusts a host root: it runs the server's binaries, inside the same sandbox.
- **Writes** reach the server unless the server refuses them or [overlay](0011-overlay.md) covers the root; the plan's caveat says so, and `--write=none` is refused.
- **The connection** is plain 9P, not encrypted or authenticated, so a TCP root should be on a trusted network or a tunnel. The plan says so.
- **Isolation between machines:** each machine dials its own connection, and its `<root>` is its own.

## Done when

Integration cases tagged `[9p-roots]`. The server is a second h9 serving the test root tree with `aux/listen1 -t tcp!127.0.0.1!PORT /bin/exportfs -R -r /`, so no host 9P server is needed:

- `test "a TCP 9P root runs /bin/ls [9p-roots]"`
- `test "a unix socket 9P root runs /bin/ls [9p-roots]"`: a unix socket that the test relays to the TCP server.
- `test "rc pipelines and exec run from a 9P root [9p-roots]"`
- `test "the host cwd is bound over a 9P root [9p-roots]"`
- `test "a 9P root works under --net=disable [9p-roots]"`
- `test "--root-spec is sent as the attach name [9p-roots]"`
- `test "an unreachable 9P root exits 125 [9p-roots]"`
- `test "a 9P root that wants authentication exits 125 [9p-roots]"`
- `test "--write=none with a 9P root is a usage error [9p-roots]"`
- `test "--print shows a 9P root, and its output replays with --ns [9p-roots]"`
- `test "--check runs /bin/echo from a 9P root [9p-roots]"`

Demo: `h9 --root tcp!localhost!5640 ls /` lists the served tree, with the server started as above.

## Implementation

1. `Machine.Options.Root` and `root_spec`, with `dir` behaving exactly as `root` did. `src/main.zig` and `src/tools.zig` updated.
2. TCP roots: the dial and mount in `src/machine.zig`'s namespace builder, the errors, and `--root`'s parsing in `src/cli.zig` and `src/main.zig`. The TCP cases pass.
3. Unix socket roots on POSIX hosts: the host connect and `lfdchan`.
4. The plan: the `mount '<root>'` line, `9p` access, the caveats and the `--write=none` conflict in `src/policy.zig`, and `<root>` in `src/newns.zig` and the replay.
5. README's `--root` notes. DESIGN.md: the Decisions table's root row, the root filesystem paragraph, the boot sequence, the CLI flag table, and `Machine.Options`. Set `status: implemented`.

## Open issues

- **Authenticated roots:** a host-side factotum, or a key given to h9, so a root can be a 9front file server that wants `p9any`.
- **Unix socket roots on Windows,** which has `AF_UNIX`, but whose sockets don't go through devlfd's handle I/O as they are.
- **Posting from the host.** An embedder could post a host-served 9P connection into a machine's `/srv` before the program starts, for example a host directory served by a 9P server rather than devfs. That's a `Machine.Options` addition. [devsrv](0008-devsrv.md)'s `h9_srvpost` takes a channel rather than a guest fd for this. Posts made before `--ns` replay would also let `mount /srv/x …` lines in a namespace file work.
- **Speed:** a 9P root costs a round trip per walk, open and read, and drawterm's devmnt has no cache. How much that slows `mk` or an rc pipeline over a local socket is to be measured.
