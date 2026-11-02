# Guidance for coding agents

## Start here

- Read [README.md](README.md) for setup, build commands, and repository layout.
- Read [DESIGN.md](DESIGN.md) before changing architecture or behavior that crosses components. It describes the intended design; verify in the source what is implemented today.
- Check the existing code and tests before proposing or changing behavior. Keep changes focused and preserve established decisions unless the task explicitly calls for revisiting them.

## Project conventions

- This is a Zig project targeting native 9front executables on host hypervisors. Use the Zig version and setup described in the README.
- Keep the public machine/library API independent of CLI-global state; keep the CLI a thin wrapper.
- Keep hypervisor-specific behavior behind the `src/vmm.zig` interface and its backend implementations.
- Treat `third_party/drawterm` as vendored upstream code. Prefer changes in project-owned code; modify the vendor tree only when necessary, and keep such changes minimal. It is a squashed git subtree: update it only with `scripts/vendor-drawterm.sh`, never by copying files over it.
- Update the README for user-visible changes. When a task changes an architectural decision or intended design, update the relevant section of `DESIGN.md` and add a dated entry to its `Changelog` under the milestone in progress, explaining what changed and why. Preserve prior entries; do not record routine implementation progress.
- After M10, record design changes under `Post-M10 release changes` in `DESIGN.md`: use `Unreleased` until assigned to a release, then add or use a heading for that release number.

## Validate changes

Run the narrowest relevant check, and run broader checks when the change warrants them:

```sh
zig build test
zig build
zig build m0
zig build kern
```

The README documents setup, including `scripts/env.sh` and `scripts/fetch.sh`.
