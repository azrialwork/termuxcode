#!/usr/bin/env bash
# Runs the packaged launcher on an already booted Android emulator, through the
# same layout the .deb installs, with TERMUXCODE_HOME isolation enabled.
set -euo pipefail

pkg_dir="${1:?usage: smoke.sh <package-root>}"
lib_dir="$pkg_dir/lib/termuxcode"
tmp=/data/local/tmp
root=$tmp/termuxcode-test
prefix=$root/usr
home_dir=$root/home
debug_home=$root/debug
# PREFIX points the launcher at the staged tree; TERMUXCODE_HOME keeps every
# XDG location private so this run cannot touch an opencode installation.
env_prefix="PREFIX=$prefix HOME=$home_dir TERMUXCODE_HOME=$debug_home"

adb shell mkdir -p "$prefix/bin" "$prefix/lib/termuxcode" "$home_dir"
adb push "$pkg_dir/bin/termuxcode" "$prefix/bin/termuxcode"
adb push "$lib_dir/termuxcode" "$prefix/lib/termuxcode/termuxcode"
adb push "$lib_dir/librust_pty.so" "$prefix/lib/termuxcode/librust_pty.so"
adb push "$lib_dir/libopentui.so" "$prefix/lib/termuxcode/libopentui.so"
adb push "$lib_dir/libtermuxcode-compat.so" "$prefix/lib/termuxcode/libtermuxcode-compat.so"
adb shell chmod 755 "$prefix/bin/termuxcode" "$prefix/lib/termuxcode/termuxcode"

# The launcher's shebang points at Termux; run it through the device shell.
version=$(adb shell "$env_prefix sh $prefix/bin/termuxcode --version")
echo "version: $version"
case "$version" in
*"$SMOKE_VERSION"*) ;;
*)
  echo "unexpected version output, want $SMOKE_VERSION" >&2
  exit 1
  ;;
esac

# nohup keeps the server alive after the adb shell session ends.
adb shell "nohup env $env_prefix sh $prefix/bin/termuxcode serve --port 4096 --print-logs >$home_dir/serve.log 2>&1 &" >/dev/null
adb forward tcp:4096 tcp:4096

# A debug emulator takes minutes to start a 170 MB binary; wait up to 10 minutes.
listening=0
code=000
for i in $(seq 1 300); do
  if [ "$listening" = "0" ] && adb shell "grep -q 'server listening' $home_dir/serve.log" 2>/dev/null; then
    listening=1
    adb shell cat "$home_dir/serve.log"
  fi
  if [ "$listening" = "1" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/global/health || true)
    [ "$code" = "200" ] && break
  fi
  if [ $((i % 30)) -eq 0 ]; then
    echo "waiting for server ($((i * 2))s)" >&2
    adb shell "tail -n 3 $home_dir/serve.log" >&2 || true
  fi
  sleep 2
done

if [ "$code" != "200" ]; then
  adb shell cat "$home_dir/serve.log" || true
  echo "health check failed: $code (listening=$listening)" >&2
  exit 1
fi

curl -fsS http://127.0.0.1:4096/global/health
echo

# Isolation proof: state landed under TERMUXCODE_HOME, not the real HOME.
adb shell "test -d $debug_home/data/opencode"
for leaked in "$home_dir/.config/opencode" "$home_dir/.local/share/opencode"; do
  if adb shell "test -e $leaked"; then
    echo "isolation failed: $leaked exists" >&2
    exit 1
  fi
done
echo "isolation: state confined to $debug_home"

# The TUI is the only path that loads libopentui through the JS resolver;
# --version and serve never reach it.
if adb shell "command -v script >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1"; then
  adb shell "timeout 30 script -qec \"$env_prefix sh $prefix/bin/termuxcode\" /dev/null >$home_dir/tui.log 2>&1" || true
  if adb shell "grep -q 'Failed to initialize OpenTUI' $home_dir/tui.log"; then
    adb shell cat "$home_dir/tui.log" || true
    echo "tui failed to load libopentui" >&2
    exit 1
  fi
  echo "tui: render library resolved"
else
  echo "tui: skipped (no script/timeout on device)" >&2
fi

adb shell pkill -f "termuxcode serve" || true
