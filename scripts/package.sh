#!/usr/bin/env bash
set -euo pipefail

arch=${1:?arch}
version=${2:?version}
bundle=${3:?bundle directory}
out=${4:?output directory}
suffix=${5:-}
here=$(cd "$(dirname "$0")" && pwd)

layout="bin/termuxcode
lib/termuxcode/libopentui.so
lib/termuxcode/libtermuxcode-compat.so
lib/termuxcode/librust_pty.so
lib/termuxcode/termuxcode"

check_layout() {
  local label=$1 actual=$2 expected
  expected=$(printf '%s\n' "$layout" | sort)
  if [ "$actual" != "$expected" ]; then
    echo "unexpected files in $label" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    exit 1
  fi
}

full_version="${version}${suffix}"

mkdir -p "$out"
archive="$out/termuxcode-${full_version}-${arch}.tar.gz"
tar -C "$bundle" -czf "$archive" .
check_layout "$archive" "$(tar -tzf "$archive" | grep -v '/$' | sed 's|^\./||' | sort)"

if [ "$arch" != "arm64" ]; then
  exit 0
fi

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
prefix="$root/data/data/com.termux/files/usr"
mkdir -p "$prefix"
cp -a "$bundle"/. "$prefix"/
find "$root" -type d -exec chmod 755 {} +
chmod 644 "$prefix/lib/termuxcode/"*.so
chmod 755 "$prefix/bin/termuxcode" "$prefix/lib/termuxcode/termuxcode"

mkdir -p "$root/DEBIAN"
chmod 755 "$root" "$root/DEBIAN"
size=$(du -sk "$prefix" | cut -f1)
sed \
  -e "s/@VERSION@/${full_version}/" \
  -e "s/@ARCH@/aarch64/" \
  -e "s/@SIZE@/${size}/" \
  "$here/../packaging/control.in" > "$root/DEBIAN/control"
chmod 644 "$root/DEBIAN/control"

deb="$out/termuxcode_${full_version}_aarch64.deb"
dpkg-deb --root-owner-group --build "$root" "$deb"
check_layout "$deb" \
  "$(dpkg-deb -c "$deb" | awk '{print $6}' | grep -v '/$' | sed 's|^\./data/data/com.termux/files/usr/||' | sort)"
