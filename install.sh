#!/usr/bin/env bash
# termuxcode installer
#   curl -fsSL https://raw.githubusercontent.com/azrialwork/termuxcode/main/install.sh | bash
#
# Downloads the latest aarch64 .deb, verifies its checksum, installs it with
# dpkg, then starts the launcher once and checks that an existing opencode
# installation was not touched. Safe to re-run; set TERMUXCODE_FORCE=1 to
# reinstall the same version.
#
# Output is plain ASCII on purpose: it must look the same in every terminal.
set -euo pipefail

REPO="${TERMUXCODE_REPO:-azrialwork/termuxcode}"
RELEASES="https://github.com/${REPO}/releases"
FORCE="${TERMUXCODE_FORCE:-0}"

# ---------------------------------------------------------------- ui --------

UI=1
if [ -c /dev/tty ] && { : >/dev/tty; } 2>/dev/null; then
  UI=/dev/tty
fi

if { [ "$UI" = /dev/tty ] || [ -t 1 ]; } && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'
  D=$'\033[2m'
  R=$'\033[0m'
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
else
  B='' D='' R='' GREEN='' RED='' YELLOW='' CYAN=''
fi

say() { printf '%s\n' "$*" >"$UI"; }

rep() {
  local unit=$1 count=$2 out=''
  while [ "$count" -gt 0 ]; do
    out+=$unit
    count=$((count - 1))
  done
  printf '%s' "$out"
}

# step_done <number> <label> <state> <color> <detail>
step_done() {
  local num=$1 label=$2 state=$3 color=$4 detail=${5:-} pad dots tag
  pad=$((16 - ${#label}))
  [ "$pad" -lt 1 ] && pad=1
  dots=$(rep '.' "$pad")
  tag=$(printf '[%-4s]' "$state")
  printf "  ${D}[%s]${R} ${B}%s${R} %s ${color}%s${R} %s\n" \
    "$num" "$label" "$dots" "$tag" "$detail" >"$UI"
}

step_ok() { step_done "$1" "$2" "ok" "$GREEN" "${3:-}"; }
step_skip() { step_done "$1" "$2" "skip" "$YELLOW" "${3:-}"; }

BOX_W=58
box_rule() { printf '  +%s+\n' "$(rep '-' $((BOX_W + 4)))" >"$UI"; }

# One content row. text is always <= BOX_W wide, so the border line stays put.
box_row() {
  local text=$1 pad
  # Clamp so a stray long string can never push the right border out of line.
  [ "${#text}" -gt "$BOX_W" ] && text="${text:0:BOX_W}"
  pad=$((BOX_W - ${#text}))
  printf '  |  %s%s  |\n' "$text" "$(rep ' ' "$pad")" >"$UI"
}

# Paragraph row: wraps on spaces, hard-splits overlong words. Never overflows.
box_line() {
  local text=$1 line='' word
  local -a words=()
  read -r -a words <<<"$text" || true
  if [ "${#words[@]}" -eq 0 ]; then
    box_row ""
    return
  fi
  for word in "${words[@]}"; do
    if [ -z "$line" ]; then
      line=$word
    elif [ $((${#line} + 1 + ${#word})) -le "$BOX_W" ]; then
      line="$line $word"
    else
      box_row "$line"
      line=$word
    fi
    while [ "${#line}" -gt "$BOX_W" ]; do
      box_row "${line:0:BOX_W}"
      line="${line:BOX_W}"
    done
  done
  box_row "$line"
}

die() {
  say ""
  printf '  %s[fail]%s %s\n' "$RED" "$R" "$1" >"$UI"
  [ $# -gt 1 ] && printf '         %s%s%s\n' "$D" "$2" "$R" >"$UI"
  say ""
  exit 1
}

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
trap 'say ""; printf "  %s[abort]%s interrupted\n\n" "$RED" "$R" >"$UI"; exit 130' INT
start=$SECONDS

# -------------------------------------------------------------- banner ------

say ""
box_rule
box_row "termuxcode  ::  OpenCode for Termux"
box_row "native bionic  |  aarch64  |  built and verified in CI"
box_rule
say ""

# ----------------------------------------------------------- preflight ------

case "${PREFIX:-}" in
  *com.termux*) : ;;
  *) die "This installer only supports Termux." "Install Termux, then run it again." ;;
esac

arch=$(uname -m)
[ "$arch" = "aarch64" ] || die "Unsupported CPU: $arch" "Only aarch64 Termux is packaged."

for tool in curl sha256sum dpkg; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing tool: $tool" "Run: pkg install $tool"
done

free_kb=$(df -Pk "$PREFIX" | awk 'NR==2 {print $4}')
[ "$free_kb" -ge 358400 ] || die "Not enough free space: $((free_kb / 1024)) MB" "Around 350 MB is needed."

step_ok 01 "Environment" "Termux, ${arch}, $((free_kb / 1024 / 1024)) GB free"

# ------------------------------------------------------------- resolve ------

curl -fsSL --retry 3 "$RELEASES/latest/download/SHA256SUMS" -o "$TMP/SHA256SUMS" ||
  die "Could not fetch SHA256SUMS" "Check the network, then retry."

deb=$(awk '{print $2}' "$TMP/SHA256SUMS" | grep -E '_aarch64\.deb$' | head -1 || true)
[ -n "$deb" ] || die "No aarch64 package in the latest release."

version=$(printf '%s' "$deb" | sed -E 's/^termuxcode_(.+)_aarch64\.deb$/\1/')
step_ok 02 "Release" "v${version}"

# --------------------------------------------------------- current state ----

opencode_before=""
if [ -x "$PREFIX/bin/opencode" ]; then
  opencode_before=$(sha256sum "$PREFIX/bin/opencode" | awk '{print $1}')
  state="opencode found, left alone"
else
  state="no opencode installed"
fi

installed=""
if dpkg -s termuxcode 2>/dev/null | grep -q 'Status: install ok installed'; then
  installed=$(dpkg-query -W -f='${Version}' termuxcode 2>/dev/null || true)
fi

if [ "$installed" = "$version" ] && [ "$FORCE" != "1" ]; then
  step_skip 03 "State" "${state}; ${version} already installed"
  skip_install=1
else
  [ -n "$installed" ] && state="${state}; replacing ${installed}"
  step_ok 03 "State" "$state"
  skip_install=0
fi

# ------------------------------------------------------------ download ------

if [ "$skip_install" = 0 ]; then
  if ! command -v rg >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    say "  ${D}installing ripgrep and git${R}"
    pkg install -y ripgrep git >"$TMP/pkg.log" 2>&1 || {
      tail -n 15 "$TMP/pkg.log" >"$UI" || true
      die "Could not install ripgrep and git"
    }
  fi

  say "  ${D}downloading ${deb} (v${version})${R}"

  if [ "$UI" = /dev/tty ]; then
    curl -fL --retry 3 --progress-bar "$RELEASES/latest/download/$deb" -o "$TMP/$deb" 2>"$UI" ||
      die "Download failed"
  else
    curl -fsSL --retry 3 "$RELEASES/latest/download/$deb" -o "$TMP/$deb" ||
      die "Download failed"
  fi

  (cd "$TMP" && sha256sum -c SHA256SUMS --ignore-missing >/dev/null 2>&1) ||
    die "Checksum mismatch" "The download is corrupt; run the installer again."

  size=$(du -h "$TMP/$deb" | cut -f1)
  step_ok 04 "Download" "${size}, sha256 verified"
else
  step_skip 04 "Download" "same version, nothing to fetch"
fi

# -------------------------------------------------------------- install ----

if [ "$skip_install" = 0 ]; then
  dpkg -i "$TMP/$deb" >"$TMP/dpkg.log" 2>&1 || {
    tail -n 20 "$TMP/dpkg.log" >"$UI" || true
    die "dpkg failed" "Try: pkg install ripgrep git, then rerun."
  }

  files=$(dpkg -L termuxcode | while read -r path; do [ -f "$path" ] && echo "$path"; done | wc -l)
  [ "$files" -eq 5 ] || die "Unexpected package layout: $files files" "This build cannot be trusted."
  if dpkg -L termuxcode | grep -qx "$PREFIX/bin/opencode"; then
    die "Package would own bin/opencode" "Refusing to continue."
  fi
  step_ok 05 "Install" "5 files, no bin/opencode"
else
  step_skip 05 "Install" "already installed"
fi

# --------------------------------------------------------------- verify ----

doctor="$TMP/doctor"
out=$(TERMUXCODE_HOME="$doctor" timeout 90 "$PREFIX/bin/termuxcode" --version 2>/dev/null || true)
[ "$out" = "$version" ] || die "termuxcode did not start" "Expected $version, got '${out:-no output}'."
step_ok 06 "Verify" "launcher reports ${version}"

if [ -n "$opencode_before" ]; then
  opencode_after=$(sha256sum "$PREFIX/bin/opencode" | awk '{print $1}')
  [ "$opencode_before" = "$opencode_after" ] ||
    die "opencode binary changed" "Never expected; restore it with pkg install --reinstall opencode."
  step_ok 07 "opencode" "untouched, ${opencode_before:0:12}..."
fi

# -------------------------------------------------------------- summary ----

elapsed=$((SECONDS - start))
if [ "$skip_install" = 1 ]; then summary="already up to date"; else summary="installed"; fi
say ""
box_rule
box_row "${summary}"
box_rule
box_row "version   ${version}"
box_row "files     5 under \$PREFIX"
box_row "opencode  untouched"
box_rule
box_row "run       termuxcode"
box_row "debug     TERMUXCODE_HOME=\$PREFIX/var/termuxcode-debug"
box_row "          termuxcode"
box_row "update    rerun this installer"
box_rule
say ""
say "  ${D}done in ${elapsed}s${R}"
say ""
