# termuxcode

OpenCode, built natively for Android and packaged for Termux.

`termuxcode` is a thin, reproducible delta on top of
[OpenCode](https://github.com/anomalyco/opencode). It does not fork the application:
the upstream tag is checked out unmodified in CI, a small patch adds the Android
target, and two native libraries are built from their pinned sources.

## Status

- Targets: `bun-linux-arm64-android` (primary, Termux) and `bun-linux-x64-android` (ELF verification only).
- Runtime: the official Bun Android build for the target ABI.
- Packages: `.deb` for Termux (`aarch64`) plus a portable tarball per architecture.
- CI: every push builds and verifies both ELFs; runtime is tested on a real device.

## Install (Termux, aarch64)

```sh
curl -fsSL https://raw.githubusercontent.com/azrialwork/termuxcode/main/install.sh | bash
termuxcode
```

The installer checks the architecture and free space, downloads the latest
`aarch64` package, verifies its SHA-256 against the release's `SHA256SUMS`,
installs it with `dpkg`, then starts the launcher once to confirm it works. It
records the hash of `$PREFIX/bin/opencode` before installing and fails if that
file changed. Re-running it updates in place; `TERMUXCODE_FORCE=1` reinstalls the
current version.

Manual install, if you prefer:

```sh
pkg install ripgrep git
curl -LO https://github.com/azrialwork/termuxcode/releases/latest/download/termuxcode_1.19.3_aarch64.deb
pkg install ./termuxcode_1.19.3_aarch64.deb
termuxcode
```

The package installs:

```
$PREFIX/bin/termuxcode                     launcher
$PREFIX/lib/termuxcode/termuxcode          compiled OpenCode binary
$PREFIX/lib/termuxcode/libopentui.so       TUI renderer (Zig)
$PREFIX/lib/termuxcode/librust_pty.so      PTY backend (Rust)
$PREFIX/lib/termuxcode/libtermuxcode-compat.so  close_range shim for Termux
```

The package owns only those five paths. It never installs `$PREFIX/bin/opencode`,
so an existing OpenCode installation keeps working next to it. `scripts/package.sh`
fails the build if the archive contains any other file.

State is shared by default: `termuxcode` uses the same `~/.config/opencode` and
`~/.local/share/opencode` directories as upstream OpenCode. Running it can
migrate that data to `1.19.3`, which an older installed binary may not read.

### Debug with isolated state

Set `TERMUXCODE_HOME` to keep config, auth, sessions, cache and temp files in a
private directory:

```sh
TERMUXCODE_HOME=$PREFIX/var/termuxcode-debug termuxcode
```

The launcher creates that directory and points `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, `XDG_CACHE_HOME`, `XDG_STATE_HOME` and `TMPDIR` at it, so the
run cannot read or migrate state used by another OpenCode installation. Auth is
isolated too, so log in again inside the debug directory.

The launcher exports the paths and Android-safe defaults:

| Variable | Value | Why |
| --- | --- | --- |
| `OPENTUI_LIB_PATH` | `$PREFIX/lib/termuxcode/libopentui.so` | OpenTUI has no Android package |
| `BUN_PTY_LIB` | `$PREFIX/lib/termuxcode/librust_pty.so` | `bun-pty` needs an Android `cdylib` |
| `OPENCODE_DISABLE_FFF` | `1` | `@ff-labs/fff-bun` has no Android binary; use system `rg` |
| `OPENCODE_DISABLE_AUTOUPDATE` | `1` | updates are managed by `pkg` |
| `OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER` | `1` | `@parcel/watcher` has no Android binding |
| `LD_PRELOAD` | `$PREFIX/lib/termuxcode/libtermuxcode-compat.so` | Termux targets SDK 28, whose seccomp policy traps `close_range` |

`termuxcode upgrade` and `termuxcode uninstall` are refused on purpose. Use
`pkg upgrade termuxcode` / `pkg uninstall termuxcode`.

## What the delta changes

1. `patches/0001-android-build.patch` - adds the two Android targets to
   `packages/opencode/script/build.ts`, selects only them with `--android`, and
   fixes the compile-time defines (`OPENCODE_LIBC=bionic`, no `OPENTUI_LIBC`,
   no dead glibc FFF binary).
2. `scripts/patch-opentui.py` - rewrites every installed `@opentui/core@0.4.5`
   copy so it accepts `android` in its platform table and resolves
   `libopentui.so` from `OPENTUI_LIB_PATH`. A patch file is not enough:
   `@opentui/core` is absent from upstream `patchedDependencies`, so a file in
   `patches/` is silently ignored.
3. `packaging/close-range-shim.c` - `LD_PRELOAD` shim for Termux's seccomp
   policy, which traps `close_range` with `SIGSYS` because the app targets SDK
   28. Emulates the call with a `/proc/self/fd` scan.
4. `patches/opentui-build-zig-android.patch` - drops the glibc-only `dl` and
   `pthread` link flags for Android and sets 16 KB page alignment, which
   devices with 16 KB pages require.
5. Native libraries built from source, pinned in `upstream.json`:
   - `libopentui.so` from OpenTUI `v0.4.5` with Zig 0.15.2, linked against the
     NDK sysroot through a generated libc file.
   - `librust_pty.so` from `bun-pty` `v0.4.8` with the Android NDK, using a
     vendored `termios 0.2.2` that accepts `target_os = "android"`.

Everything else is upstream. The upstream checkout is never committed here.

## Build

CI is the build system. The `build` workflow:

1. builds `libopentui.so` (Zig + NDK libc file) and `librust_pty.so` (Cargo +
   NDK clang, plus the vendored `termios`) for `arm64` and `x64`;
2. checks out OpenCode `v1.19.3`, applies the patches, and runs
   `bun run script/build.ts --android` with Bun `1.4.3` and
   `OPENCODE_VERSION=1.19.3` (a detached checkout would otherwise produce a
   preview version string);
3. verifies each binary with `readelf` (architecture, no glibc dependencies,
   16 KB compatible library segments);
4. publishes a Termux `.deb` and tarballs, asserting the archive contains only
   the five paths above.

Local builds are not supported on purpose: the native toolchain and the Bun
cross-compile target are heavy, and CI is the source of truth.

## Benchmarks

`scripts/measure.sh` measures installed size, startup and idle memory on a real
device (needs `hyperfine` and `jq`). The baseline for `v1.19.3`, the method and
its caveats are in [`docs/benchmarks.md`](docs/benchmarks.md). Build profiles live
in `profiles/`; `profiles/slim.env` carries the size and memory budgets that a
trimmed build must respect.

Both profiles are built from the same upstream tree; every build uploads a Bun
bundle map (`metafile-<profile>-<arch>`) that lists every module and its bytes.
The slim profile is Termux-only: `patches/slim/` removes every path that serves
another OS or another install channel. That covers the `upgrade`/`uninstall`
commands, the whole self-update machinery (installation detection, update check
and `/update` dialog), macOS managed preferences, Windows/macOS/WSL code paths in
the shell tool, LSP downloads, clipboard, terminal guards and path handling, and
the `open` dependency. It also keeps a single provider: the OpenCode provider
and the models it serves. Every other provider plugin, its auth flow, its model
list and its SDK dependency is gone from both the runtime and the TUI. Non-Termux
binaries and asset names are gone, so a slim build cannot fall back to another
platform. It builds a single `aarch64` `.deb` and ships no portable tarball. The
patch series is split one context per file (`0001` self-update, `0002` managed
config, `0003` shell tool, `0004` LSP, `0005` core runtime, `0006` opencode
runtime, `0007` TUI, `0008` `open` dependency, `0009` providers), so a single
change can be reviewed or reverted on its own.

## Limitations

- File watching is disabled. Edits made outside the TUI are not observed until
  the next refresh.
- Ripgrep search requires the Termux `ripgrep` package; the bundled FFF backend
  is unavailable on Android.
- Automatic updates are disabled. The package is the update channel.
- Only `aarch64` gets a `.deb`; `x64` is produced for ELF verification only.
- There is no automated runtime test. A shell on an emulator runs in Android's
  `shell` domain, which has a looser seccomp policy than an untrusted app, so it
  cannot catch seccomp-only failures; and packaging a full Android app harness
  is out of scope. Runtime behavior is verified by hand on an arm64 Android 12
  Termux device (`aarch64`, API 31), including the TUI, the server health
  endpoint and the isolated debug state.
- The `close_range` shim depends on Termux targeting SDK 28: Android ignores
  `LD_PRELOAD` for apps targeting SDK 29 or newer. If Termux raises its target
  SDK, both the trap and the workaround change together.
- Other trapped syscalls beyond `close_range` are not covered yet. If a future
  Bun release starts using one, the launcher will die with `Bad system call`
  again; `strace` names the syscall in `si_syscall`.

## Upstream and license

Upstream: `anomalyco/opencode` at `v1.19.3`
(`e3c4eb242585dcd77be1a867391b7c25fd47ce52`), MIT.
OpenTUI: `anomalyco/opentui` at `v0.4.5`, MIT.
`bun-pty`: `sursaone/bun-pty` at `v0.4.8`, MIT.

This repository's own files are MIT. See `LICENSE`.
`termuxcode` is not affiliated with OpenCode, Termux, or Bun.
