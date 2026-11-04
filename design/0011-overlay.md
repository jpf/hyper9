---
id: 11
slug: overlay
title: Copy-on-write overlay as the root's default
status: draft
created: 2026-11-03
authors: [progrium]
depends: [6]
areas: [sandbox, cli, kern]
---
 
# Proposal: copy-on-write overlay as the root's default
 
Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>
 
## Abstract
 
Enforce `--write=overlay` and make it the default: [ephemeral-writes](0006-ephemeral-writes.md)'s copy-on-write device, `#O`, goes over the root, whatever kind of root it is, so writes to the root succeed inside the run and vanish when it ends. The cwd and `--writable` paths still write to the host, as under `scope`. The root tree on the host is never written unless it's a `--writable` path.
 
## Background
 
This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's capability table had a row for it:
 
| Capability | Mechanism |
| --- | --- |
| `fs.write.overlay` | A copy-on-write overlay device, shared with image-backed roots |
 
With it, the default profile's root row was to become: read-only underneath, with an ephemeral overlay, so writes succeed and vanish.
 
### h9 today
 
- **The root is read-only** in both profiles. A write to it fails with "permission denied", and installing into it needs `--writable "$H9ROOT"`, which writes the host tree.
- **`--write=overlay`** is accepted but not enforced: it falls back to `none`, the plan lists `fs.write.overlay` as `unenforced`, and `--strict` refuses it with exit 2.
- **Programs that write the root** fail. 9front programs expect a writable root, as on a 9front terminal: `$home` (`/usr/$user`, which a root tree doesn't have for the host user), `/sys/log`, `/lib/ndb/local` edits, `mk install` into `/$objtype/bin`, and `acme`'s dump file and `rio`'s settings under `$home`.
### What [ephemeral-writes](0006-ephemeral-writes.md) provides
 
- **`#O`,** a kernel device in `src/kern/devoverlay.c`: an instance is a tree in memory over a lower chan, with copy-up, whiteouts and directory markers, and memory from the machine's page allocator, counted against `--memory`.
- **Binds:** `bind -c '#O' <target>` in a plan or namespace file makes a fresh instance over what `<target>` is at that point.
- **Its write modes:** `--write=ephemeral` overlays every path that `scope` would make writable, and a private `/tmp` replaces the host's temp directory. It leaves the root read-only, and says putting an overlay over the root is this proposal's.
## Proposal
 
### The write modes
 
| `--write` | Root | Cwd and `--writable` paths | `/tmp` |
| --- | --- | --- | --- |
| `none` | Read-only | Read-only (a conflict with `--writable`, as now) | Read-only |
| `scope` | Read-only | Write the host | Private, in memory |
| **`overlay`, the new default** | **Overlay: writes succeed and vanish** | Write the host | Private, in memory |
| `ephemeral` | Overlay | Overlays | Private, in memory |
 
So `overlay` is `scope` plus an overlay over the root, and `ephemeral` gains the root overlay too: under it, nothing reaches the host. The tight profile follows the same table. Its cwd stays read-only under `overlay`, since that row is about host paths.
 
`--writable` on the root's own path, `--writable "$H9ROOT"`, still makes the root write the host, with no overlay, under `scope` and `overlay`, as it does today.
 
### The root overlay
 
The namespace builder makes the overlay right after the root itself, before every other bind:
 
```text
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph  # /Users/me/h9root
  bind '#c' /dev
  ...
```
 
- **Any root:** the lower tree is whatever `/` is at that point: a host tree from `#U`, a [9P root](9p-roots.md)'s mount, or an [image root](image-roots.md)'s mount. So writes to a 9P root don't reach its server, and writes to an image root stay above its file server.
- **Binds over the root still work.** `/dev`, `/bin`, `/mnt/term/cwd` and the rest are bound onto directories reached through the overlay. A directory that's only in the lower tree keeps its lower qid, and so does a directory marker, which is what a lower directory becomes when its children change, so the mount table keeps matching it. Only a copied-up file gets a new qid, and nothing is bound onto files of the root.
- **Writable paths inside the root** (`--writable "$H9ROOT"/usr/glenda`) are bound from `#U` over the overlay, so writes there go to the host, as the longest rule decides today.
- **`$home`.** If the root has no `/usr/$user`, the builder creates it in the overlay, so a guest's home directory exists and is writable, and vanishes with the run.
### The plan
 
- **Access:** the root's rule stays `allow_ro` for devfs, since `#O` never writes its lower tree, and prints as `eph`, as ephemeral-writes prints overlaid paths.
- **`enforces:`** gains `fs.write.overlay` under `overlay` and `ephemeral`. `Capability.enforceable` returns true for it, so `--strict --write=overlay` is accepted.
- **Caveats:**
  - "writes to the root are kept in memory, count against --memory, and are lost when the machine ends"
  - For a 9P or image root, the "writes to the 9P root go to its server" caveat and the `--write=none` conflict of [9p-roots](9p-roots.md) don't apply under `overlay` and `ephemeral`, since nothing reaches the server.
```text
$ h9 --print mk
profile:  default
enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation
limits:   write=overlay net=enable
namespace:
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph  # /Users/me/h9root
  ...
access:
  eph  /Users/me/h9root
  rw   /Users/me/src/proj
caveats:
  - writes to the root are kept in memory, count against --memory, and are lost when the machine ends
  ...
```
 
### When writes are discarded
 
At the end of a run, if the root overlay holds any change and stderr is a terminal, h9 prints one line to stderr: "h9: changes to the root were discarded (--writable "$H9ROOT" keeps them)". It's printed by the CLI, not the library, from a count the machine returns with the run's status. Scripts, whose stderr is rarely a terminal, don't see it.
 
## Rationale
 
**The root writable by default.** 9front programs are written for a terminal whose root is the user's own file server. A read-only root makes them fail in ways that look like h9 bugs: rc can't make `$home`, `mk install` fails, acme can't write its dump. An overlay gives every run a fresh, writable 9front, like a VM booted from a snapshot, while the host tree stays as installed.
 
**Writes vanish, rather than persist.** The root is shared by every run and every machine. Persisting one run's writes into it would make runs depend on each other's leftovers, and a guest could change the tools later runs use. `--writable "$H9ROOT"` stays the explicit way to install, and the end-of-run notice tells an interactive user when they've lost something.
 
**Cwd and `--writable` keep writing the host under `overlay`.** They're the paths the user granted, and writing them is the point of `scope`. `ephemeral` is there for runs that should change nothing on the host at all.
 
**`scope` kept as it is.** It's the right mode for a run that should fail loudly on a write to the root, such as a build check, and keeping it unchanged means `--write=scope` scripts see no difference.
 
**One overlay over `/`, before the other binds, for every kind of root.** Putting it there makes it the bottom layer everything else is bound over, so the device sees only the root's own files. Doing it for 9P and image roots as well gives one rule for what a write to `/` does, and takes the server's write policy out of the default plan's trust.
 
**Creating `$home` in the overlay.** The default environment sets `home=/usr/$user`, and root trees have only `/usr/glenda`. With a writable root the directory can exist without touching the host tree, which removes a common first failure.
 
**A notice only on a terminal.** Silent loss of `mk install` output is the cost of this default. A line on an interactive stderr is enough to catch it; anything more, such as a nonzero exit, would turn an ordinary run into a failure.
 
**The cost, gated.** Every walk in the root goes through `#O`: a lookup in its memory tree, then the lower device. For a root nothing has written, that's one hash miss per path element. The proposal is gated on measuring it (Done when). If it costs too much, `#O` gets a fast path for directories with nothing in memory before this becomes the default.
 
## Compatibility
 
- **Default behaviour:** writes to the root succeed and vanish, where they failed with "permission denied". A script that tested writability of the root, or relied on a write failing, sees the difference; `--write=scope` restores the old behaviour.
- **`--write=overlay`** now does what it says, and `--strict --write=overlay` stops being a usage error. `--write=ephemeral` gains the root overlay.
- **`$home`** exists by default, in memory.
- **`--print` and `--ns`:** the root's overlay line and `eph` access, in ephemeral-writes' format, so saved plans replay.
- **`Machine.Options`:** `Policy.write`'s default (null) now means `overlay`. The run's status gains a count of discarded root changes.
- **CLI flags and exit codes:** unchanged.
- **Vendored tree:** unchanged.
## Security
 
- **The root on the host is never written** unless it's `--writable`. `#O` opens its lower tree read-only, and devfs's rule for the root stays read-only, so a write that reached devfs by another route would be refused.
- **Reads are still checked.** Lower lookups go through the lower device, so `--read-deny` and symlink resolution apply in the root as before. A whiteout can hide a file, never reveal one.
- **Memory is capped.** Copies and bookkeeping come from the machine's page allocator, under `--memory`.
- **Servers are protected too.** With a 9P or image root, the overlay keeps the guest's writes from the server or the image's file system.
- **Between machines:** each machine's overlay is its own instance, so machines in one host process never see each other's root changes.
## Done when
 
Integration cases tagged `[overlay]`:
 
- `test "a write to the root under the default profile succeeds and leaves the root tree unchanged [overlay]"`
- `test "mk install into the root works and leaves the root tree unchanged (demo) [overlay]"`: `cd /sys/src/cmd && mk cat.install`, then `/bin/cat` runs the new binary.
- `test "removing a root file hides it in the guest only [overlay]"`
- `test "$home exists and is writable when the root has no /usr/$user [overlay]"`
- `test "the cwd still writes the host under --write=overlay [overlay]"`
- `test "--write=scope keeps the root read-only [overlay]"`
- `test "--writable on the root writes the host, with no overlay [overlay]"`
- `test "--write=ephemeral overlays the root as well [overlay]"`
- `test "--strict --write=overlay is accepted [overlay]"`
- `test "--print output with the root overlay replays with --ns [overlay]"`
- `test "the discarded-changes notice is printed on a terminal and not otherwise [overlay]"`
- With [9p-roots](9p-roots.md) implemented, `test "a write to a 9P root under the default profile doesn't reach the server [overlay]"`.
Backend case: two machines in one process each see only their own root changes.
 
Measurement: the `[baseline]` suite and `zig build bench`, with and without the root overlay, recorded in DESIGN.md. The default changes only if the overlay costs less than 5% of the suite's run time.
 
Demo: `h9 --rc 'echo hi > /lib/x && cat /lib/x'` prints `hi`, and the root tree has no `/lib/x` afterwards.
 
## Implementation
 
1. With [ephemeral-writes](0006-ephemeral-writes.md) implemented: the root overlay under `--write=overlay` and `ephemeral` in `src/policy.zig`, after the root's bind or mount, with `eph` access, `enforces:`, caveats and `--strict`.
2. `$home` in the overlay when the root lacks it.
3. The measurement, and a fast path in `#O` if it's needed.
4. `overlay` as the default of `Policy.write`, the run status's discarded-change count, and the CLI's notice.
5. README's sandbox table, and DESIGN.md: the capability table, the default profile's root row, the CLI table's `--write` row, and the plan example. Set `status: implemented`.
## Open issues
 
- Whether the tight profile should keep the root read-only, as a stricter default, or take the overlay as proposed.
- Exporting a run's root changes at exit, which [ephemeral-writes](0006-ephemeral-writes.md) leaves to its own proposal, would turn the notice into "changes saved to …" for users who want them.
 