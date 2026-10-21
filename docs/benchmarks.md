# Benchmarks

Numbers here are measured on the device, never inferred from code or taken from
an emulator. They are the baseline the slim profile has to beat.

## Environment

| item | value |
| --- | --- |
| device | Xiaomi Redmi 9C (`M2003J15SC`), 3.7 GB RAM, 8 cores |
| Android | 12 (API 31), Termux, `aarch64` |
| build | `v1.19.3` from the release `.deb`, installed with `dpkg` |
| terminal | pty 80x24 via `script`, `TERM=xterm-256color` |
| state | throwaway `TERMUXCODE_HOME` per run, no credentials, no project open |

## Method

- **Size**: sum of the five installed files (`$PREFIX/bin/termuxcode` plus
  `$PREFIX/lib/termuxcode/*`). Release asset sizes are recorded separately.
- **Startup `--version`**: `hyperfine --warmup 1 --runs 3`, wall clock median.
- **Startup TUI**: the launcher runs under a pty. "First output" is the first
  byte written; "first frame" is the appearance of the string `Ask anything`,
  polled every 50 ms. Median of 3 runs, spread reported.
- **Idle memory**: after 20 s without input, PSS and RSS are summed over the
  whole process tree (launcher, runtime, helper), sampled 3 times 2 s apart, and
  reduced with a median per run and across runs. Summing PSS accounts shared
  pages proportionally, so it is the honest cost on a small device.
- **Reproduce**:
  `bash scripts/measure.sh --runs 3 --idle 20 --json out.json`
  (requires `pkg install hyperfine jq`)

Raw output of the baseline run: [`2026-10-22-v1.19.3.json`](2026-10-22-v1.19.3.json).

## Baseline: v1.19.3 (full)

| metric | value |
| --- | --- |
| release `.deb` | 45.4 MiB |
| release tarball | 59.5 MiB |
| installed files | 180.3 MiB |
| compiled binary | 166.6 MiB |
| `libopentui.so` | 13.2 MiB |
| `librust_pty.so` | 509 KiB |
| `libtermuxcode-compat.so` | 7.7 KiB |
| launcher | 1.6 KiB |
| startup, `--version` | 1.9 s |
| startup, first output | 3.0 s |
| startup, TUI first frame | 13.4 s (13.37-13.55 s) |
| idle PSS, whole tree | 539.5 MiB |
| idle RSS, whole tree | 544.9 MiB |
| idle processes | 2 |

## Build profiles

`profiles/full.env` and `profiles/slim.env` are the single place where a profile
is defined. The workflow builds both from the same upstream checkout and patches,
and names artifacts after the profile (`package-full`, `package-slim`,
`metafile-slim-arm64`, ...). `slim` targets Termux only: it builds a single
`aarch64` package, ships no portable tarball, and applies `patches/slim/`, which
removes the install methods for other distros (npm, brew, scoop, choco), the
`upgrade` and `uninstall` commands, and the Windows/macOS code paths.

The first two profile runs (`39662040825`, `39662819325`) proved the pipe neutral:
slim and full binaries were byte-identical before any patch. After the first trim
the compiled binary kept the same size (174,658,760 bytes) because Bun pads the
output and the runtime dominates it; the honest signal is the bundle map, where
slim must contain fewer bytes and must not contain the deleted modules. The
pre-trim bundle is broken down in [`bundle-map.md`](bundle-map.md).

Only a tagged release publishes the slim package. The default `latest` installer
still selects the full package; `TERMUXCODE_PROFILE=slim` selects the slim one
once such a release exists.

## Slim after the first trim

Build `1.19.3+slim1` (run `39668526806`, artifact `package-slim-arm64`), measured
from an extracted `.deb` under a throwaway prefix.

| metric | full | slim |
| --- | --- | --- |
| release `.deb` | 47,617,298 B | 47,617,208 B |
| installed files | 180.3 MiB | 180.3 MiB |
| compiled binary | 174,658,760 B | 174,658,760 B |
| bundle JS | 32,783,125 B | 32,773,914 B |
| `upgrade`/`uninstall` modules | present | absent |

Startup and idle memory were measured twice against the installed full build:

| invocation | slim TUI frame | slim PSS | full TUI frame | full PSS |
| --- | --- | --- | --- | --- |
| first | 14.58 s | 461.9 MiB | 14.09 s | 502.6 MiB |
| second | 14.16 s | 530-698 MiB | 14.55 s | 594-740 MiB |

The first pair suggested a 40 MiB win; the second pair reversed and widened it.
Idle PSS on this device drifts by more than 40% between invocations, so neither
pair proves anything about memory. Only the bundle delta is attributable to the
patch, and it is 9,211 bytes: removing two commands and the non-Termux branches
does not move the runtime heap, because none of that code is loaded at boot.
No budget is filled in `profiles/slim.env` until a run can be reproduced.

## What this says

- The package is dominated by one Bun single-file bundle (166.6 of 180.3 MiB);
  the native libraries are 13.7 MiB combined.
- Idle memory is dominated by the runtime heap, not the native libraries. Cutting
  files that were never loaded at startup will not move PSS; only modules that
  are actually imported at boot will.
- First frame lands ~10.4 s after the first output byte. That gap is runtime and
  TUI initialization, and it is the honest target for startup work.

## Caveats

- Warm page cache: the package is installed and was just executed. A cold first
  launch after install is slower.
- GC noise: run-to-run idle PSS varied by roughly 5% (525-557 MiB) inside one
  session, and by up to 40% across sessions (456-740 MiB). Treat a single A/B as
  no evidence; alternate the builds over several runs before claiming a delta.
- Memory scales with terminal size and the project directory. Measured with no
  project open; a large repository with a TUI sidebar will differ.
- Emulator numbers are invalid here: the shell domain has a different seccomp
  policy and scheduler, and cannot reproduce the app's real behavior.
