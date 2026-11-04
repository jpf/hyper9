---
id: 6
slug: ephemeral-writes
title: Ephemeral writes and a private /tmp
status: draft
created: 2026-11-03
authors: [progrium]
depends: []
areas: [sandbox, cli, kern]
---

# Proposal: ephemeral writes and a private /tmp

Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Enforce `--write=ephemeral` with a copy-on-write overlay device, `#O`, in h9's own kernel code. Under it, every path the plan would make writable is an overlay: reads come from the host tree, while creates, writes, removes and renames land in memory and are gone when the machine ends. The host tree is never written.

The same device with nothing underneath is a private in-memory `/tmp` for every machine, replacing the host's temp directory. Overlay memory counts against `--memory`. [overlay](overlay.md) can then put the same device over the root.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's capability table had a row for it:

| Capability | Mechanism |
| --- | --- |
| `fs.write.ephemeral` | A ramfs union-bound with `bind -c` over writable paths; new files go to the ramfs and vanish on exit |

### h9 today

`--write` takes `none`, `scope`, `ephemeral` or `overlay` (`src/policy.zig`):

- **`scope`** is the default. Paths the plan allows read-write are bound from `#U` with `MCREATE`: the cwd in the default profile, each `--writable` path, and `/tmp`. Writes go to the host.
- **`none`** binds everything read-only.
- **`ephemeral` and `overlay`** are accepted but not enforced. They fall back to `none`, are listed as `unenforced`, and `--strict` refuses them with exit 2.

`/tmp` depends on the profile. In the default profile it's the host's temp directory (`$TMPDIR`, `$TEMP` or `/tmp`, from `hostTmp` in `src/main.zig`), bound read-write. In the tight profile it's the root tree's own `/tmp`, read-only. So a default-profile guest's temporary files land on the host, beside the host's own, and the tight profile has no writable scratch space at all.

### Why a ramfs union doesn't do it

A union `bind -c` of a ramfs before a host directory makes *new* files go to the ramfs, which is what the old row described. But in a Plan 9 union, everything else goes to the member where the name is found:

- **Opening an existing host file for writing** opens the host file. A writable host member is written, which defeats the point. A read-only host member gives "permission denied".
- **`remove` and `wstat`** of a host file go to the host member too.
- **`create` of a name that exists in the host member** truncates the host file, or fails on a read-only member.

So the old row's own example, `mk clean && mk`, would either write the host or fail at the first `rm` of an existing object file. Ephemeral writes need copy-on-write: a host file is copied into memory the first time it's changed, and a removed name is hidden by a whiteout.

A guest ramfs process has a second problem: h9 doesn't serve the `mount` syscall, and a 9P server per machine adds a process and round trips to every file operation.

## Proposal

### The overlay device, `#O`

`src/kern/devoverlay.c` is h9's own kernel device, in C, registered in `src/kern/devtab.c`. `O` is used by neither drawterm nor 9front.

**Instances.** An instance is a tree in memory, optionally above a lower directory. The namespace builder creates them from Zig while it builds the machine's namespace:

```c
/* Returns an instance number, or -1 with the error set. lower may be nil: a pure in-memory tree. */
int h9_overlay_new(Chan *lower);
```

It's then bound like any device with `bind '#O<n>' <target>`. Instances belong to the machine: a machine's binds are the only references to them. The last close of the last chan on an instance frees it, which happens at the latest when the machine's namespace is torn down at exit.

**Nodes.** Each node in the memory tree is one of three things:
- **a copy:** a file or directory that exists in memory, with its own data and `Dir`
- **a whiteout:** a name removed from the lower tree
- **a directory marker:** a directory that exists in the lower tree and has changed children in memory, without copying the directory's contents

Walks look in memory first. A whiteout ends the walk with "file does not exist". A miss falls through to the lower tree through the lower chan's device, so the lower tree's own checks apply: devfs's `h9_fs_check`, `--read-deny`, and symlink resolution.

**Operations:**

| Operation | On a lower-only name | In memory |
| --- | --- | --- |
| `open` for reading | The lower file, opened through its device | The copy |
| `open` for writing | Copy up, then the copy | The copy |
| `open` with `OTRUNC` | A new, empty copy with the lower file's `Dir`, without reading the lower data | The copy, truncated |
| `create` | A new copy, replacing a whiteout if there is one | Fails as `create` does on an existing file, or truncates it as 9front does |
| `remove` | A whiteout | The copy is freed; a whiteout is left if the lower tree has the name |
| `wstat` of mode, mtime or length | Copy up, then apply | Apply |
| `wstat` renaming a file | Copy up, rename the copy, and whiteout the old name | Rename; whiteout the old name if the lower tree has it |
| `wstat` renaming a directory | Refused with "permission denied" if the lower tree has it (see Open issues) | Rename |
| Directory read | The lower directory | Memory entries, then lower entries that aren't hidden by a whiteout or shadowed by a copy |

**Copy-up** reads the whole lower file through the lower chan into memory, then sets the copy's `Dir` from the lower file's. A process that already has the lower file open keeps reading the lower file. Copy-up is per name and happens once: later opens find the copy.

**Qids.** Lower files keep their lower qids. Copies get qids from the instance, with the high bit of `path` set so they can't collide with lower qids. A copy-up changes a file's qid, as a file replaced on 9front does.

**Errors.**
- Copy-up and creation fail with "file system full" when the machine's memory is used up, and the operation changes nothing.
- A lower tree that can't be read during copy-up fails the open with the lower device's error.

### Memory

A copy's data lives in pages from the machine's guest-physical page allocator, through a Zig leaf:

```c
void *h9_overlay_alloc(ulong n);
void h9_overlay_free(void *p, ulong n);
```

So the guest's own memory and its ephemeral files share one cap, `--memory`, exactly, as segments do. Nodes, names and `Dir`s are small and come from the kernel heap. A directory marker costs a node and no data.

### `--write=ephemeral`

`ephemeral` stops being unenforced.

- **What becomes an overlay:** every path the plan would bind read-write under `scope` is bound instead as an overlay over its `#U` chan. That's the cwd, and each `--writable` path, including a writable path inside a read-only cwd.
- **The tight profile:** under `ephemeral`, its cwd is an overlay as well. The reason it's read-only under `scope`, keeping the host's files safe from the guest, doesn't apply when nothing reaches the host.
- **The root** stays read-only unless it's a `--writable` path. Putting an overlay over the root by default is [overlay](overlay.md)'s.
- **Host access:** the overlaid host paths go into the plan's access rules as read-only, since the device never writes its lower tree. devfs then refuses any write that reaches it by another route.
- **`enforces:`** gains `fs.write.ephemeral`, and `--strict` accepts `ephemeral`.

### A private `/tmp`

With a root tree, `/tmp` is always a fresh `#O` instance with no lower tree, writable, in both profiles. Under `--write=none` it's the root's read-only `/tmp`, as `none` means.

The host temp directory is no longer bound. `hostTmp` and `Policy.tmp` go away.

### The plan

- **Access:** a new kind, `eph`, beside `ro` and `rw`.
- **Namespace:** overlay binds print as `bind -c '#O0' /mnt/term/cwd`, with the overlaid host path in a trailing comment, so `--print` stays readable.
- **Caveats** for writable paths under `ephemeral`:
  - "ephemeral files count against --memory and are lost when the machine ends"
  - "a file opened for writing is copied into memory whole the first time"
  - The hardlink and `res.disk` caveats aren't listed for overlaid paths, since nothing reaches the host there.

```text
$ h9 --print --write=ephemeral --writable ./out
profile:  default
enforces: env.scrub fs.read.scope fs.write.ephemeral fs.write.scope ipc.restrict kernel.isolation
limits:   write=ephemeral net=enable
namespace:
  bind '#U/Users/me/h9root' /                             ro
  ...
  bind -c '#O0' /mnt/term/cwd                             eph  # /Users/me/src/proj
  bind -c '#O1' /mnt/term/cwd/out                         eph  # /Users/me/src/proj/out
  bind -c '#O2' /tmp                                      eph
access:
  ro   /Users/me/h9root
  eph  /Users/me/src/proj
  eph  /Users/me/src/proj/out
caveats:
  - ephemeral files count against --memory and are lost when the machine ends
  ...
```

## Rationale

**Copy-up, not a union.** A union sends every operation on an existing name to the member that has it, so it can't keep writes off the host without refusing them (see Background). A copy-up overlay is what Linux's overlayfs and Docker's layers do, for the same reason.

**A kernel device, not a guest ramfs.** A device needs no `mount` syscall, no process per machine, and no 9P round trip per operation. It can count its memory against the machine's cap through the page allocator, where a guest ramfs would count against it as ordinary heap but only as far as its own process can grow. It also gives [overlay](overlay.md) the device it needs for the root and image-backed roots.

**In C, in `src/kern/`.** A device is chans, qids, walks and `waserror`, which is drawterm's world. Zig on the inside would cross the seam on every operation and break seam rule 1 at every lower-device call that can raise. h9's devproc and devhcons are C for the same reason, with Zig leaves for what Zig owns: here, the pages.

**Whole-file copy-up.** It's simple, and correct for the common writers: compilers, editors, `mk`, and tools that rewrite a file through a temporary. Those truncate or rewrite whole files anyway, and `OTRUNC` skips the copy entirely. Block-level copy-on-write would make appending to a large log cheap, at the cost of a block map per file. It can come later inside the device without changing its interface (see Open issues).

**`/tmp` in memory for everyone.** Sharing the host's temp directory put guest files beside the host's: visible to other host programs, left behind after a crash, and outside the sandbox's view, since the plan had to allow the whole directory read-write. A private `/tmp` per machine keeps each run's scratch files its own, and makes the tight profile usable for programs that need scratch space.

**Charging `--memory`.** One cap for everything a machine holds in host memory keeps `--memory` the exact bound it already is. A separate `--tmp-size` would be one more number to choose, and a guest could still fill memory with a big ephemeral file under it.

**Refusing directory renames of lower directories.** Renaming one means copying up or re-parenting its whole subtree, and whiteouts for every name under the old path. That's rare in what h9 runs, and refusing is honest. A file rename, which `mk` and editors do all the time, is supported.

## Compatibility

- **`/tmp`** in the default profile is no longer the host's temp directory. Files a guest writes there don't appear on the host, and host files there are no longer visible to the guest. Scripts that passed files between host and guest through `/tmp` need a `--writable` path.
- **The tight profile** gains a writable, private `/tmp`.
- **`--write=ephemeral`** now does what it says, and `--strict --write=ephemeral` stops being a usage error.
- **`Machine.Options.policy`:** `Policy.tmp` is removed. Embedders that set it to share a host directory as `/tmp` should use a writable path instead.
- **`--print`:** new namespace lines and access kind, as above. A saved namespace with `#O` lines replays with `--ns` only in a run that has the same instances, since instance numbers are per machine (see Open issues).
- **CLI flags and exit codes:** unchanged.
- **Vendored tree:** unchanged. The device and its leaves are h9's own files.

## Security

- **No host writes.** Under `ephemeral`, the overlaid host trees are opened through devfs read-only, and the access rules make them read-only too, so a write that somehow reached devfs would still be refused. Whiteouts, copies and renames exist only in memory.
- **The policy still decides reads.** Every lower lookup and copy-up goes through the lower chan's device, so `--read-deny`, hidden paths and symlink resolution apply to overlaid trees exactly as to bound ones. A whiteout can hide a host file from the guest, never reveal one.
- **Memory is capped.** Copy data comes from the machine's page allocator, so a guest can't use more host memory through files than `--memory` allows. A full overlay fails the write with an error rather than the machine. The kernel-heap part, nodes and names, grows with the number of names, and is bounded by a per-instance limit on nodes (see Open issues).
- **Isolation between machines.** Instances belong to one machine's namespace, so machines in one host process can't see each other's `/tmp` or ephemeral files.
- **Caveats that go away.** For overlaid paths, the hardlink and uncapped-writes caveats no longer apply, since nothing reaches the host. They stay for `--write=scope`.

## Done when

Integration cases tagged `[ephemeral-writes]`, using rc and the root tree's tools in a scratch cwd:

- `test "a new file in an ephemeral cwd is readable and absent on the host afterwards [ephemeral-writes]"`
- `test "writing an existing host file changes it in the guest only [ephemeral-writes]"`
- `test "removing a host file hides it in the guest only [ephemeral-writes]"`
- `test "rm then recreate, as mk clean && mk does, works [ephemeral-writes]"`
- `test "a file rename moves it in the guest only [ephemeral-writes]"`
- `test "renaming a host directory is refused [ephemeral-writes]"`
- `test "ls of an overlaid directory lists each name once [ephemeral-writes]"`
- `test "a --writable path inside a read-only cwd is ephemeral [ephemeral-writes]"`
- `test "--read-deny still hides a path inside an ephemeral tree [ephemeral-writes]"`
- `test "the tight profile's cwd is ephemeral under --write=ephemeral [ephemeral-writes]"`
- `test "/tmp is private and writable in both profiles [ephemeral-writes]"`: a file written to `/tmp` isn't in the host's temp directory, and the tight profile can write there.
- `test "/tmp is read-only under --write=none [ephemeral-writes]"`
- `test "filling an overlay fails with file system full and the machine carries on [ephemeral-writes]"`, under `--memory 32m`
- `test "--strict accepts --write=ephemeral, and --print shows the overlays [ephemeral-writes]"`

Backend cases in `tests/backends.zig`: two machines in one host process each get their own `/tmp`, and a copy-up while another process has the lower file open leaves that reader on the old contents.

Demo: in a copy of a 9front source directory, `h9 --write=ephemeral --rc 'rm -f *.c && echo gone > x && ls'` lists only `x`, and afterwards the host directory is unchanged.

## Implementation

1. `src/kern/devoverlay.c` with in-memory instances only (no lower tree), the page leaves in `src/kern.zig`, and `/tmp` as a private instance in both profiles. Remove `hostTmp` and `Policy.tmp`. The `/tmp` cases pass.
2. Lower trees: walk, open and directory-read fall-through, copy-up, whiteouts, `OTRUNC`, renames.
3. `--write=ephemeral` in `src/policy.zig`: overlay binds, the `eph` access kind, `enforces:`, caveats, `--print`, and `--strict`. The `ephemeral-writes` cases pass.
4. README's sandbox table, and DESIGN.md: the capability table, the default profile's `/tmp` row and the tight profile's paragraph, `devoverlay.c` in the kernel's "Added by us" table, and the CLI table's `--write` row. Set `status: implemented`.

## Open issues

- **Large files.** Whole-file copy-up makes appending to a large host file cost a copy of it, and can fail with "file system full" for a file bigger than the free memory. Block-level copy-on-write inside the device would fix that.
- **Directory renames.** Supporting renames of lower directories, by re-parenting the subtree in memory with a whiteout at the old name, if something in the tree needs it.
- **Replaying `--print`.** `#O` lines name per-machine instances. Should `--ns` accept an `overlay` directive that creates an instance over a path, so a printed namespace replays as written?
- **Node limit.** How many names an instance may hold before `create` fails with "file system full", so a guest can't grow the kernel heap without bound with empty files. A fixed limit, or one derived from `--memory`?
- **Keeping the changes.** A `--write=ephemeral` run could export its changes at exit, as a tar or a diff of the overlay, for a caller that wants to inspect them. That would be its own proposal.