---
slug: image-roots
title: Disk-image roots
status: draft
created: 2026-11-03
authors: [progrium]
depends: [8, 13]
areas: [cli, kern, sandbox]
---
 
# Proposal: disk-image roots
 
Nov 4, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>
 
## Abstract
 
`--root` takes a raw 9front disk image. h9 serves the image to the guest as a disk, `#S`, partitions it with 9front's own `diskparts`, and runs 9front's file server for it (gefs, cwfs or hjfs) as a guest process, from the host root tree. The server posts itself to `/srv`, and h9 mounts it at `/`, as [9p-roots](0013-9p-roots.md) mounts a server, before the program runs. Writes the file server makes land in memory unless the image is `--writable`, so the image is never changed by default.
 
## Background
 
This was part of milestone M10 in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)). DESIGN.md's root filesystem list had it third:
 
3. **Disk image:** cwfs or gefs runs as a guest process over an image file exposed as a host file, and posts to `#s`. This is also a good stress test of the process model.
### What a 9front disk looks like
 
9front's own boot (`bootrc`) finds the root like this:
 
1. **Disks** are devsd (`#S`) directories, `/dev/sdXX/`, each with `ctl` and `data`.
2. **Partitions:** `diskparts` runs `fdisk -p` on each disk's `data` (the MBR or GPT) and `prep -p` on its `plan9` partition (9front's own partition table, in the partition's second sector), and writes the resulting `part name start end` lines to the disk's `ctl`. devsd then serves each partition as a file beside `data`: `plan9`, `9fat`, `fs`, `fscache`, `fsworm`, `nvram`.
3. **The file server** runs over a partition and posts to `/srv`: gefs or hjfs over `fs`, cwfs over `fscache` and `fsworm`.
4. **The root** is a mount of the posted service.
The pinned release's arm64 image, which `scripts/fetch.sh` downloads and `scripts/mkroot.py` boots in QEMU to build the root tree, is such a disk: `mkroot.py` boots it with `nobootprompt=local!/dev/sdF0/fs`.
 
### h9 today
 
- **No disk device.** There's no `#S`, and devfs can only serve a host file as a file, without partitions.
- **No posting or mounting from the guest** until [devsrv](0008-devsrv.md).
- **[9p-roots](0013-9p-roots.md)** makes `--root` a union and mounts a 9P connection at `/` before the plan's other binds. A posted service is a 9P connection.
- **The file servers** are in the root tree: `/arm64/bin/gefs`, `cwfs64x` and `hjfs`. They use `semacquire`, `rendezvous` and many procs, which is why [semaphores](0003-semaphores.md), and through it devsrv, come first.
## Proposal
 
### `--root IMAGE`
 
`--root` (and `$H9ROOT`) accept a host path to a regular file as a raw disk image. [9p-roots](0013-9p-roots.md)'s reading of `--root` gains that case: a directory is a host tree, a socket is a 9P root, and a regular file is an image. `Machine.Options.Root` gains `image: []const u8`, an absolute and resolved host path.
 
| Flag | Meaning |
| --- | --- |
| `--root IMAGE` | Boots the 9front file system on a raw disk image as the root |
| `--root-fs auto\|gefs\|cwfs\|hjfs` | Which file server runs over the image. `auto`, the default, picks by partition (below) |
| `--boot-root DIR` | The host tree the file server and `diskparts` run from. Defaults to `$H9ROOT`, then the default install location, as `--root` does |
 
Images in other formats (qcow2) are converted first (`qemu-img convert -O raw`). The image's binaries must be for the machine's architecture, as a host tree's must.
 
### The disk device, `#S`
 
`src/kern/devhsd.c` is h9's own kernel device. It serves each of the machine's images as `/dev/sdH0`, `/dev/sdH1` and so on, in devsd's layout and `ctl` format, so 9front's tools work on it unchanged:
 
- **`data`:** the whole image, in 512-byte sectors.
- **`ctl`:** reading gives devsd's `inquiry`, `geometry` and one `part` line per partition. Writing takes devsd's `part name start end` and `delpart name`, as `diskparts`, `fdisk -p` and `prep -p` write them.
- **Partitions:** a file per `part` line, reading and writing its sector range of `data`.
Images are added by the namespace builder with `h9_disk_add`, and belong to the machine. I/O goes to the host file through Zig leaves (seam rule 3), with the fd that h9 opened when the machine was set up:
 
```c
int h9_disk_add(int hostfd, uvlong size, int writable);  /* returns the unit, or -1 */
long h9_disk_read(int unit, void *buf, long n, uvlong off);
long h9_disk_write(int unit, void *buf, long n, uvlong off);
```
 
**Copy-on-write.** Unless the image is a `--writable` path, the host file is opened read-only, and writes land in memory: a written 4 KiB block is copied up whole the first time, and later reads of it come from the copy. Blocks come from the machine's guest-physical page allocator, as [ephemeral-writes](0006-ephemeral-writes.md)'s overlay pages do, so they count against `--memory`. A write past the cap fails with "file system full", and the file server reports it as it would a full disk. With `--writable IMAGE`, writes go to the host file.
 
### Booting the root
 
For an image root, the namespace builder runs a boot step in the machine's first Proc before building the program's namespace:
 
1. **The boot namespace:** the boot tree at `/`, read-only, from `#U`, with `#c` and `#y` on `/dev`, `#S` appended to `/dev`, `#s` at `/srv`, and `/$cputype/bin` and `/rc/bin` on `/bin`.
2. **Partitions:** run `diskparts` from the boot tree.
3. **The file server:** run it from the boot tree, over the image's partitions, posting to `/srv/root`. With `--root-fs auto`:
   - `fscache` and `fsworm` partitions mean cwfs, over both.
   - An `fs` partition means gefs or hjfs, told apart by the magic in the partition's first block.
   - Anything else is an error: "root IMAGE: no 9front file system found", exit 125.
4. **Wait** until `/srv/root` is posted, up to 30 s, or until the server exits. A server that exits or times out is exit 125, with its stderr.
5. **The program's namespace:** a fresh Pgrp, as `newns`'s `clear` gives, in which `/srv/root` is mounted at `/` with `MREPL`. The rest of the plan's binds follow, as over a 9P root.
6. **The device mask** gains `S`, so the program can't reach the raw image under its file server.
The file server's processes belong to the machine. They count against `--pids`, show up in `ps`, and keep running in their own namespace, which the server's `rfork(RFNAMEG)` gives it, while the program runs.
 
**At the end of a run,** h9 posts `hangup` to the program's processes first, as now, then, if the image is writable, asks the file server to write out its state through its console in `/srv` (`halt`, for each of the three servers), and waits for it to exit, up to the 2 s grace period, before the teardown. With the default copy-on-write there's nothing to keep, so the server is torn down with everything else.
 
### The policy and the plan
 
- **The image** is a host file h9 opens itself. It's in the access rules as `eph` (copy-on-write) or `rw` (`--writable`), like the overlaid paths of [ephemeral-writes](0006-ephemeral-writes.md), so devfs refuses it to the guest by any other route. The boot tree is `ro`.
- **Writes to the root** succeed and vanish by default: the file server writes the copy-on-write disk. So the root's access is `eph`, under `--write=scope`, the default, as well. `--write=none` with an image root is a usage error, exit 2, as for a 9P root: the file server has to write.
- **`#S`** is in the device mask for the program, and for every machine without an image.
`--print` shows the boot step and the root mount:
 
```text
$ h9 --print --root ./9front.img ls
...
boot:
  disk    sdH0  /Users/me/9front.img                       eph
  fs      gefs  /dev/sdH0/fs                               # from /Users/me/h9root
namespace:
  mount -c '/srv/root' /                                   eph  # /Users/me/9front.img
  bind '#c' /dev
  ...
devmask:  #C #S #U
caveats:
  - disk writes count against --memory and are lost when the machine ends
  ...
```
 
The `boot:` section isn't part of the namespace, so `--ns` doesn't replay it. A saved plan replays against a machine that was started with the same `--root`.
 
## Rationale
 
**Run 9front's file server, don't write one.** gefs, cwfs and hjfs are the file systems 9front installs, and reading their on-disk formats from the host would mean reimplementing each. Running them as guest processes is what the original design text asked for, and exercises the process model with real multi-proc servers.
 
**A disk device, not the image as a file.** The servers expect a partition, and the image is a whole disk with an MBR or GPT and 9front's own partition table. devsd's layout and `ctl` format let `diskparts`, `fdisk` and `prep` do the partitioning, so h9 parses no partition tables itself. Binding the image from `#U` and running the servers on byte ranges of it would need offsets passed to each server, which none of them takes.
 
**`#S`, devsd's letter, with `sdH` units.** 9front's tools look for `/dev/sd*`, and the letter matches what 9front users expect. `H` keeps the units from looking like real controllers' (`sdE`, `sdF`).
 
**Copy-on-write at the disk, not only above the root.** A file server writes its disk even when nothing in the tree changes: access times, its log, and its superblock at mount. So keeping the image unchanged needs copy-on-write under the server, whatever happens above it. [overlay](0011-overlay.md) can still put its device over the mounted root, so writes by the program stay above the file server; the two don't conflict.
 
**The boot tree from the host.** The file server has to come from somewhere before the image's tree is mounted. The host tree is already there, is the same release when it's the pinned one, and keeps the boot step free of an embedded binary. `--boot-root` covers an image of another release.
 
**A fresh namespace for the program.** The boot namespace has the raw disk and the boot tree. Starting the program from a clean Pgrp with the device mask set means it sees only the image's tree and the usual devices, as a 9front system does after `bootrc`.
 
**Refusing `--write=none`,** as [9p-roots](0013-9p-roots.md) does: the server has to write, and `none` promises that nothing is written.
 
## Compatibility
 
- **`--root` and `$H9ROOT`:** a regular file now means an image rather than an error.
- **New flags:** `--root-fs` and `--boot-root`.
- **`Machine.Options.Root`** gains `image`, and `Machine.Options` gains `root_fs` and `boot_root`.
- **`--print`** gains the `boot:` section and `S` in the device mask. `#S` is masked in every machine, which changes nothing for runs without an image, since nothing served it.
- **Exit codes:** boot failures are 125; `--write=none` with an image is 2.
- **Vendored tree:** unchanged. The disk device and its leaves are h9's own files.
## Security
 
- **What the guest newly reaches:** the files of the image's file system, through its server. The raw image is reachable only by the boot step's processes, and `#S` is masked for the program.
- **The host file** is opened read-only unless the image is `--writable`, and the access rules make it `eph` or `rw`, so no other route to it through devfs can write it.
- **Memory:** copied-up blocks come from the machine's page allocator, so a guest can't use more host memory through the disk than `--memory` allows.
- **The boot tree** is read-only, and only the boot step's processes see it.
- **A hostile image** is parsed by 9front's own tools and file servers inside the guest, not by h9, so a malformed file system can crash a guest process but can't reach the host. h9 itself reads only sectors.
- **Isolation between machines:** each machine's disks are its own units.
## Done when
 
Integration cases tagged `[image-roots]`, using the pinned release's image converted to raw (`qemu-img convert -O raw`), which `scripts/fetch.sh` gains a step for:
 
- `test "an image root runs /bin/ls from the image's file system [image-roots]"`
- `test "diskparts finds the image's partitions in #S [image-roots]"`
- `test "a write to an image root succeeds and leaves the image unchanged [image-roots]"`
- `test "with --writable, a write to an image root is in the image afterwards [image-roots]"`: copies the image first, then runs twice.
- `test "the program can't attach #S [image-roots]"`
- `test "a file server that can't start exits 125 [image-roots]"`: an image with no 9front partitions.
- `test "--write=none with an image root is a usage error [image-roots]"`
- `test "--print shows the boot step [image-roots]"`
- `test "filling the copy-on-write disk fails the write, not the machine [image-roots]"`, under `--memory 64m`.
Backend case in `tests/backends.zig`: `test "two machines in one process with the same image get separate disks [image-roots]"`.
 
Demo: `h9 --root .local/9front/9front.img --rc 'ls /usr/glenda && cat /dev/sysname'` runs from the image.
 
## Implementation
 
1. `src/kern/devhsd.c` with `data`, `ctl` and partitions, read-only, the leaves in `src/kern.zig`, and `S` in `src/kern/devtab.c` and the device mask. A case that reads `data` passes.
2. Copy-on-write blocks on the page allocator, and `--writable` images.
3. `Root.image`, `--root-fs` and `--boot-root`, and the boot step in `src/machine.zig`: the boot namespace, `diskparts`, the server, waiting for `/srv/root`, and the program's fresh namespace.
4. The end-of-run order, with `halt` for writable images.
5. The plan's `boot:` section, access kinds, conflict and caveats; `--check` with an image root.
6. `scripts/fetch.sh`'s raw image, the cases, README's `--root` notes, and DESIGN.md: the root filesystem paragraph, the Decisions table's root row, the kernel's "Added by us" table, the boot sequence, and the CLI flag table. Set `status: implemented`.
## Open issues
 
- Which file server the pinned image uses on its `fs` partition, and the magic that tells gefs from hjfs, from the pinned source.
- The exact command lines and memory flags for each server, from 9front's `bootrc` at the pinned revision, and whether each one's console takes `halt` as written here.
- Whether each run should boot the file server again, or a machine should keep it across runs, for embedders that run many programs.
- Whether the boot step's output (the server's console messages) goes to stderr, or only on failure.
 