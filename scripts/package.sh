#!/usr/bin/env bash
set -euo pipefail

arch=${1:?arch}
version=${2:?version}
bundle=${3:?bundle directory}
out=${4:?output directory}
here=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$out"
tar -C "$bundle" -czf "$out/termuxcode-${version}-${arch}.tar.gz" .

if [ "$arch" != "arm64" ]; then
  exit 0
fi

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
prefix="$root/data/data/com.termux/files/usr"
mkdir -p "$prefix"
cp -a "$bundle"/. "$prefix"/

mkdir -p "$root/DEBIAN"
size=$(du -sk "$prefix" | cut -f1)
sed \
  -e "s/@VERSION@/${version}/" \
  -e "s/@ARCH@/aarch64/" \
  -e "s/@SIZE@/${size}/" \
  "$here/../packaging/control.in" > "$root/DEBIAN/control"
chmod 644 "$root/DEBIAN/control"

dpkg-deb --root-owner-group --build "$root" "$out/termuxcode_${version}_aarch64.deb"
