#!/usr/bin/env bash
# Runs the packaged CLI on an already booted Android emulator: --version and health endpoint.
set -euo pipefail

lib_dir="${1:?usage: smoke.sh <lib-dir>}"
# Bun maps os.tmpdir() to /data/local/tmp on Android; keeping the binary elsewhere
# avoids colliding with opencode's own tmp dir (/data/local/tmp/opencode).
tmp=/data/local/tmp
bin_dir=$tmp/termuxcode
home_dir=$tmp/home
env_prefix="HOME=$home_dir BUN_PTY_LIB=$bin_dir/librust_pty.so OPENTUI_LIB_PATH=$bin_dir/libopentui.so"
env_prefix="$env_prefix OPENCODE_DISABLE_FFF=1 OPENCODE_DISABLE_AUTOUPDATE=1"
env_prefix="$env_prefix OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER=1"

adb shell mkdir -p "$bin_dir" "$home_dir"
adb push "$lib_dir/opencode" "$bin_dir/opencode"
adb push "$lib_dir/librust_pty.so" "$bin_dir/librust_pty.so"
adb push "$lib_dir/libopentui.so" "$bin_dir/libopentui.so"
adb shell chmod 755 "$bin_dir/opencode"

version=$(adb shell "$env_prefix $bin_dir/opencode --version")
echo "version: $version"
case "$version" in
*"$SMOKE_VERSION"*) ;;
*)
  echo "unexpected version output, want $SMOKE_VERSION" >&2
  exit 1
  ;;
esac

# nohup keeps the server alive after the adb shell session ends.
adb shell "nohup env $env_prefix $bin_dir/opencode serve --port 4096 --print-logs >$home_dir/serve.log 2>&1 &" >/dev/null
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
adb shell pkill -f "opencode serve" || true
