# Test VMs

Lima VMs for running hp9 with the emu backend (`--backend emu`) on Linux,
macOS and Windows. None has a usable hypervisor (no `/dev/kvm`, no nested
Hypervisor.framework, no WHP), which is the case emu is for. Nothing is
installed for building: cross-compile hp9 on the host and copy it in.

| OS | Build |
| --- | --- |
| `linux` | `zig build -Demu=unicorn -Dtarget=aarch64-linux-musl` |
| `linux-amd64` | `zig build -Demu=unicorn -Dtarget=x86_64-linux-musl` |
| `macos` | `zig build -Demu=unicorn` |
| `windows` | `zig build -Demu=unicorn -Dtarget=aarch64-windows` (Unicorn from source) |

Use `--prefix zig-out/<os>` to keep the builds apart.

| OS | Instance | Guest | VM type |
| --- | --- | --- | --- |
| `linux` | `linux` | Ubuntu 24.04 | vz |
| `linux-amd64` | `linux-amd64` | Ubuntu 24.04 x86\_64 | qemu (emulated, slow) |
| `macos` | `macos` | macOS 15.6.1 | vz |
| `windows` | `windows` | Windows 11 25H2 | qemu (hvf) |

Instances live in `.local/lima`, which `vm` uses as `LIMA_HOME`, so they don't
show up in the default `limactl list`. To use `limactl` directly:

```sh
export LIMA_HOME=$PWD/.local/lima
```

## Usage

```sh
zig build -Demu=unicorn -Dtarget=aarch64-linux-musl --prefix zig-out/linux
scripts/lima/vm up linux                    # create (first time), start, provision
scripts/lima/vm push linux zig-out/linux/bin/hp9 zig-out/fixtures/hello  # into ~/hp9
scripts/lima/vm shell linux ./hp9/hp9 --backend emu ./hp9/hello
scripts/lima/vm push-root linux             # 9front root tree into ~/hp9/root
scripts/lima/vm shell linux ./hp9/hp9 --root hp9/root /bin/cat /lib/namespace
scripts/lima/vm shell windows 'cd hp9 && hp9.exe --root root /bin/cat /lib/namespace'
scripts/lima/vm down linux
```

`push-root` copies `.local/9front/root` (from `scripts/mkroot.py`, about
250 MB in 10k files) as one tar stream over ssh, which takes seconds where
`push` would take minutes. It writes `hp9/root/.hp9-root` with the tree's
name and build time, and skips the copy when that matches; `-f` forces it.
The copy is unpacked beside the old one and swapped in, so an interrupted
push leaves the old tree intact. It takes about a second on Linux and about
a minute on Windows, where NTFS and Defender are slower. On Windows, three
files are left out: rc's `"` and `""` scripts (NTFS doesn't allow `"` in
names) and troff's `charlib/☺` (Windows `tar` decodes names in the ANSI code
page, not UTF-8).

`vm status` lists the VMs, `vm shell <os>` with no command opens a shell
(`cmd.exe` on Windows), and `vm rm <os>` deletes one.

## First boot

- **linux** boots in seconds from the Ubuntu cloud image.
- **linux-amd64** uses the same image for x86\_64, fully emulated by QEMU, so
  the first boot takes a few minutes and everything runs slowly. Use it for
  amd64 binaries, which arm64 hosts only run on the emulator.
- **macos** runs the macOS installer from Apple's restore image (about 16 GB
  download, then a few minutes). The GUI password is in `~/password` in the
  guest.
- **windows** needs the Windows 11 Arm64 installer ISO: the "English (United
  States)" Arm64 ISO from
  https://www.microsoft.com/en-us/software-download/windows11, saved as
  `~/Downloads/Win11_25H2_English_Arm64_v2.iso`, or set `WIN_ISO`. The install
  is unattended and takes about 15 minutes. At first logon, Lima's
  `first_logon.ps1` installs OpenSSH, adds Lima's ssh key and saves a random
  password in `C:\Users\<you>\password.txt`. `vm up` returns once ssh works and
  `provision.ps1` has run. Watch the VM display, but don't touch it unless the
  install gets stuck.

If the Windows install gets stuck:

1. **Setup shows no disk** at "Select location to install Windows 11": choose
   **Load driver** > Browse > the virtio-win CD > `viostor\w11\ARM64`, then
   select the disk.
2. **ssh never comes up** after the desktop appears: check
   `C:\Users\<you>\lima-setup.log`. If it doesn't end with
   `All works completed`, open right-click Start > **Terminal (Admin)** and
   run (drive letters may differ; `Get-Volume` shows them):

   ```powershell
   pnputil /add-driver E:\NetKVM\w11\ARM64\*.inf /install
   powershell -ExecutionPolicy Bypass -File F:\first_logon.ps1
   ```

   Then run `scripts/lima/vm up windows` again.

[provision.ps1](provision.ps1) is idempotent. It disables Windows Update,
sleep and hibernation, excludes `~\hp9` from Defender scanning, and runs
`ngen` on the .NET Framework to speed up PowerShell startup (about 20s
before; on a fresh install it dropped to about 15s, because Windows is still
busy with first-boot work).

Windows guests run in plain mode with no shared folders, so use `vm push` to
copy files in.
