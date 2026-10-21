# termuxcode

OpenCode, built natively for Android and packaged for Termux.

`termuxcode` is a thin, reproducible delta on top of
[OpenCode](https://github.com/anomalyco/opencode). It does not fork the application:
the upstream tag is checked out unmodified in CI, a small patch adds the Android
target, and two native libraries are built from their pinned sources.

## Status

- Targets: `bun-linux-arm64-android` (primary, Termux) and `bun-linux-x64-android` (CI smoke test).
- Runtime: the official Bun Android build for the target ABI.
- Packages: `.deb` for Termux (`aarch64`) plus a portable tarball per architecture.
- CI: every push builds, verifies the ELF, and boots the x64 build in an Android emulator.

## Install (Termux, aarch64)

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
```

The package owns only those four paths. It never installs `$PREFIX/bin/opencode`,
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
isolated too, so log in again inside the debug directory. CI runs the smoke test
through the packaged launcher with this variable set and fails if anything
leaks into the real `HOME`.

The launcher exports the paths and Android-safe defaults:

| Variable | Value | Why |
| --- | --- | --- |
| `OPENTUI_LIB_PATH` | `$PREFIX/lib/termuxcode/libopentui.so` | OpenTUI has no Android package |
| `BUN_PTY_LIB` | `$PREFIX/lib/termuxcode/librust_pty.so` | `bun-pty` needs an Android `cdylib` |
| `OPENCODE_DISABLE_FFF` | `1` | `@ff-labs/fff-bun` has no Android binary; use system `rg` |
| `OPENCODE_DISABLE_AUTOUPDATE` | `1` | updates are managed by `pkg` |
| `OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER` | `1` | `@parcel/watcher` has no Android binding |

`termuxcode upgrade` and `termuxcode uninstall` are refused on purpose. Use
`pkg upgrade termuxcode` / `pkg uninstall termuxcode`.

## What the delta changes

1. `patches/0001-android-build.patch` - adds the two Android targets to
   `packages/opencode/script/build.ts`, selects only them with `--android`, and
   fixes the compile-time defines (`OPENCODE_LIBC=bionic`, no `OPENTUI_LIBC`,
   no dead glibc FFF binary). The same patch registers the OpenTUI patch in
   `patchedDependencies`.
2. `patches/opentui-core-0.4.5-android.patch` - lets `@opentui/core@0.4.5`
   resolve `libopentui.so` from `OPENTUI_LIB_PATH` on Android instead of
   throwing `OpenTUI is not supported on the current platform`.
3. `patches/opentui-build-zig-android.patch` - drops the glibc-only `dl` and
   `pthread` link flags for Android and sets 16 KB page alignment, which
   devices with 16 KB pages require.
4. Native libraries built from source, pinned in `upstream.json`:
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
4. boots the x64 build on an Android 28 x86_64 emulator, runs it through the
   packaged launcher with `TERMUXCODE_HOME` isolation, and checks `--version`,
   `/global/health`, and that no state leaked outside the isolated directory;
5. publishes a Termux `.deb` and tarballs, asserting the archive contains only
   the four paths above.

Local builds are not supported on purpose: the native toolchain and the Bun
cross-compile target are heavy, and CI is the source of truth.

## Limitations

- File watching is disabled. Edits made outside the TUI are not observed until
  the next refresh.
- Ripgrep search requires the Termux `ripgrep` package; the bundled FFF backend
  is unavailable on Android.
- Automatic updates are disabled. The package is the update channel.
- Only `aarch64` gets a `.deb`; `x64` is produced for emulator verification.
- The arm64 build is verified as an ELF but has not been run on a physical
  device yet; runtime smoke tests run on an API 28 x86_64 emulator.
- Android 10/11 devices may trap `statx` inside Bun and need an `LD_PRELOAD`
  shim; that path is untested here and out of scope until a device is available.

## Upstream and license

Upstream: `anomalyco/opencode` at `v1.19.3`
(`e3c4eb242585dcd77be1a867391b7c25fd47ce52`), MIT.
OpenTUI: `anomalyco/opentui` at `v0.4.5`, MIT.
`bun-pty`: `sursaone/bun-pty` at `v0.4.8`, MIT.

This repository's own files are MIT. See `LICENSE`.
`termuxcode` is not affiliated with OpenCode, Termux, or Bun.
