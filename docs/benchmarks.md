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
- GC noise: run-to-run idle PSS varied by roughly 5% (525-557 MiB). Treat these
  numbers as a baseline, not a specification.
- Memory scales with terminal size and the project directory. Measured with no
  project open; a large repository with a TUI sidebar will differ.
- Emulator numbers are invalid here: the shell domain has a different seccomp
  policy and scheduler, and cannot reproduce the app's real behavior.
