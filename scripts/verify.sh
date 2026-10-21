#!/usr/bin/env bash
set -euo pipefail

bin=${1:?binary}
lib=${2:?libopentui}
arch=${3:?arch}

test -s "$bin" || { echo "missing binary: $bin"; exit 1; }
test -s "$lib" || { echo "missing libopentui: $lib"; exit 1; }

case "$arch" in
  arm64) machine="AArch64" ;;
  x64) machine="X86-64" ;;
  *) echo "unknown arch: $arch"; exit 1 ;;
esac

echo "== $bin"
readelf -h "$bin" | grep -q "Machine:.*${machine}" || {
  echo "wrong machine for $arch"
  readelf -h "$bin"
  exit 1
}

if readelf -d "$bin" 2>/dev/null | grep NEEDED |
  grep -Eq 'ld-linux|libc\.so\.6|libgcc_s|libpthread\.so\.0'; then
  echo "glibc dependency detected"
  readelf -d "$bin" | grep NEEDED
  exit 1
fi

echo "== $lib"
readelf -h "$lib" | grep -q "Machine:.*${machine}" || {
  echo "wrong machine for libopentui"
  readelf -h "$lib"
  exit 1
}

align=$(python3 - "$lib" <<'PY'
import re
import subprocess
import sys

out = subprocess.check_output(["readelf", "-lW", sys.argv[1]], text=True)
values = [int(m, 16) for m in re.findall(r"^\s*LOAD\s+.*\s(0x[0-9a-fA-F]+)\s*$", out, re.M)]
if not values:
    raise SystemExit("no LOAD segments found")
print(hex(min(values)))
PY
)
if [ $((align)) -lt $((0x4000)) ]; then
  echo "libopentui LOAD alignment ${align} is below 16 KB"
  exit 1
fi
echo "LOAD alignment: ${align}"

if readelf -d "$lib" | grep -q 'libc++_shared'; then
  test -f "$(dirname "$lib")/libc++_shared.so" || {
    echo "libopentui needs libc++_shared.so but it is not packaged"
    exit 1
  }
fi

nm -D "$lib" | grep -q 'createEventSink' || {
  echo "libopentui is missing createEventSink"
  exit 1
}

echo "ok"
