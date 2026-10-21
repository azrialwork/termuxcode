#!/usr/bin/env bash
# Runs the packaged CLI on an already booted Android emulator: --version and health endpoint.
set -euo pipefail

lib_dir="${1:?usage: smoke.sh <lib-dir>}"
tmp=/data/local/tmp
env_prefix="HOME=$tmp BUN_PTY_LIB=$tmp/librust_pty.so OPENTUI_LIB_PATH=$tmp/libopentui.so"

adb push "$lib_dir/opencode" "$tmp/opencode"
adb push "$lib_dir/librust_pty.so" "$tmp/librust_pty.so"
adb push "$lib_dir/libopentui.so" "$tmp/libopentui.so"
adb shell chmod 755 "$tmp/opencode"

version=$(adb shell "$env_prefix $tmp/opencode --version")
echo "version: $version"
case "$version" in
*"$SMOKE_VERSION"*) ;;
*)
  echo "unexpected version output, want $SMOKE_VERSION" >&2
  exit 1
  ;;
esac

adb shell "$env_prefix $tmp/opencode serve --port 4096 >$tmp/serve.log 2>&1 &" >/dev/null
adb forward tcp:4096 tcp:4096

code=000
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/global/health || true)
  [ "$code" = "200" ] && break
  sleep 2
done

if [ "$code" != "200" ]; then
  adb shell cat "$tmp/serve.log" || true
  echo "health check failed: $code" >&2
  exit 1
fi

curl -fsS http://127.0.0.1:4096/global/health
adb shell pkill -f "opencode serve" || true
