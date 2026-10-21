#!/usr/bin/env bash
# Measure the real on-device cost of a termuxcode install.
#
# Startup is measured on a warm page cache: one warm-up run, then N runs, and
# the median is reported. Idle memory is the sum of PSS over the whole process
# tree, sampled after the UI has been idle for --idle seconds.
#
# Usage:
#   scripts/measure.sh                       # 3 runs, 10s idle, markdown + JSON
#   scripts/measure.sh --runs 5 --idle 15
#   scripts/measure.sh --json /tmp/x.json
#   scripts/measure.sh --budget profiles/slim.env
#
# The install itself is never modified. Every run gets a throwaway
# TERMUXCODE_HOME so no real state is read or migrated.
set -euo pipefail

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
LAUNCHER=${TERMUXCODE_LAUNCHER:-$PREFIX/bin/termuxcode}
BINARY=${TERMUXCODE_BINARY:-$PREFIX/lib/termuxcode/termuxcode}
MARKER=${TERMUXCODE_MARKER:-Ask anything}
RUNS=3
IDLE=10
JSON=
BUDGET=

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS=${2:?}; shift 2 ;;
    --idle) IDLE=${2:?}; shift 2 ;;
    --json) JSON=${2:?}; shift 2 ;;
    --budget) BUDGET=${2:?}; shift 2 ;;
    --launcher) LAUNCHER=${2:?}; shift 2 ;;
    --binary) BINARY=${2:?}; shift 2 ;;
    --marker) MARKER=${2:?}; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -x "$LAUNCHER" ] || { echo "launcher not executable: $LAUNCHER" >&2; exit 1; }
[ -f "$BINARY" ] || { echo "binary not found: $BINARY" >&2; exit 1; }
case "$RUNS" in ''|*[!0-9]*) echo "--runs needs a number" >&2; exit 1 ;; esac
case "$IDLE" in ''|*[!0-9]*) echo "--idle needs a number" >&2; exit 1 ;; esac

WORK=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/measure.XXXXXX")
chmod 700 "$WORK"
cleanup() {
  local pid
  for pid in $(jobs -p); do kill -TERM "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

median() {
  sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print 0; exit }
      if (NR % 2) print v[(NR + 1) / 2]
      else printf "%.1f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2
    }'
}

tree_pids() {
  local root=$1 child
  echo "$root"
  for child in $(pgrep -P "$root" 2>/dev/null || true); do
    tree_pids "$child"
  done
}

pss_kb() {
  local pid=$1 value
  value=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || true)
  if [ -z "$value" ]; then
    value=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
  fi
  echo "${value:-0}"
}

sample_tree_kb() {
  local root=$1 pid pss=0 rss=0 value
  for pid in $(tree_pids "$root"); do
    value=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || true)
    if [ -n "$value" ]; then
      pss=$((pss + value))
      rss=$((rss + $(awk '/^Rss:/ {print $2}' "/proc/$pid/smaps_rollup")))
    else
      value=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
      value=${value:-0}
      pss=$((pss + value))
      rss=$((rss + value))
    fi
  done
  echo "$pss $rss"
}

size_file() { stat -c %s "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- sizes -----

lib_bytes=0
for file in "$PREFIX"/lib/termuxcode/*; do
  [ -f "$file" ] || continue
  lib_bytes=$((lib_bytes + $(size_file "$file")))
done
launcher_bytes=$(size_file "$LAUNCHER")
package_bytes=$((lib_bytes + launcher_bytes))

# ------------------------------------------------------------- startup ------

version_ms=$(hyperfine --warmup 1 --runs "$RUNS" --style none --export-json "$WORK/version.json" \
  "env TERMUXCODE_HOME=$WORK/home-version $LAUNCHER --version" >/dev/null 2>&1 &&
  jq -r '.results[0].summary.time_wall_clock.median * 1000 | floor' "$WORK/version.json") ||
  { echo "hyperfine failed" >&2; exit 1; }

tui_first_ms=()
tui_ms=()
pss_kb_values=()
rss_kb_values=()
proc_counts=()

for run in $(seq 1 "$RUNS"); do
  home="$WORK/home-$run"
  log="$WORK/tui-$run.log"
  mkdir -p "$home"

  start=$(now_ms)
  TERMUXCODE_HOME="$home" TERM=xterm-256color setsid script -qfec "$LAUNCHER" "$log" \
    </dev/null >/dev/null 2>&1 &
  root=$!

  deadline=$(( $(date +%s) + 120 ))
  first=''
  until grep -qF "$MARKER" "$log" 2>/dev/null; do
    if [ -z "$first" ] && [ -s "$log" ]; then first=$(( $(now_ms) - start )); fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "run $run: UI marker not found in 120s" >&2
      kill -TERM -- "-$root" 2>/dev/null || true
      exit 1
    fi
    sleep 0.05
  done
  tui_ms+=("$(( $(now_ms) - start ))")
  tui_first_ms+=("${first:-$(( $(now_ms) - start ))}")

  # Sample three times: one reading lands on whatever GC phase the runtime is in.
  sleep "$IDLE"
  samples=''
  for _ in 1 2 3; do
    samples="$samples$(sample_tree_kb "$root")"$'\n'
    sleep 2
  done
  pss_kb_values+=("$(printf '%s' "$samples" | awk '{print $1}' | median)")
  rss_kb_values+=("$(printf '%s' "$samples" | awk '{print $2}' | median)")
  proc_counts+=("$(tree_pids "$root" | wc -l)")

  kill -TERM -- "-$root" 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do
    kill -0 "$root" 2>/dev/null || break
    sleep 0.5
  done
  kill -KILL -- "-$root" 2>/dev/null || true
  wait "$root" 2>/dev/null || true
  rm -rf "$home"
done

tui_median=$(printf '%s\n' "${tui_ms[@]}" | median)
first_median=$(printf '%s\n' "${tui_first_ms[@]}" | median)
tui_min=$(printf '%s\n' "${tui_ms[@]}" | sort -n | head -1)
tui_max=$(printf '%s\n' "${tui_ms[@]}" | sort -n | tail -1)
pss_median=$(printf '%s\n' "${pss_kb_values[@]}" | median)
rss_median=$(printf '%s\n' "${rss_kb_values[@]}" | median)
proc_median=$(printf '%s\n' "${proc_counts[@]}" | median)
pss_mb=$(awk -v kb="$pss_median" 'BEGIN { printf "%.1f", kb / 1024 }')
rss_mb=$(awk -v kb="$rss_median" 'BEGIN { printf "%.1f", kb / 1024 }')
size_mb=$(awk -v b="$package_bytes" 'BEGIN { printf "%.1f", b / 1048576 }')

android=$(getprop ro.build.version.release 2>/dev/null || echo unknown)
device=$(getprop ro.product.model 2>/dev/null || echo unknown)

# --------------------------------------------------------------- report -----

printf '| metric | value |\n'
printf '| --- | --- |\n'
printf '| package size (installed files) | %s MiB |\n' "$size_mb"
printf '| startup, --version (median) | %s ms |\n' "$version_ms"
printf '| startup, first output (median) | %s ms |\n' "$first_median"
printf '| startup, TUI first frame (median) | %s ms |\n' "$tui_median"
printf '| startup spread (min-max) | %s-%s ms |\n' "$tui_min" "$tui_max"
printf '| idle PSS, whole tree (median) | %s MiB |\n' "$pss_mb"
printf '| idle RSS, whole tree (median) | %s MiB |\n' "$rss_mb"
printf '| idle processes | %s |\n' "$proc_median"
printf '| runs / idle window | %s / %ss |\n' "$RUNS" "$IDLE"

if [ -n "$JSON" ]; then
  jq -n \
    --arg device "$device" --arg android "$android" \
    --arg version "$(TERMUXCODE_HOME="$WORK/home-version" "$LAUNCHER" --version)" \
    --argjson package_bytes "$package_bytes" \
    --argjson version_ms "$version_ms" \
    --argjson first_ms "$first_median" \
    --argjson tui_ms "$tui_median" \
    --argjson tui_min "$tui_min" --argjson tui_max "$tui_max" \
    --argjson pss_kb "$pss_median" \
    --argjson rss_kb "$rss_median" \
    --argjson tui_runs "$(printf '%s\n' "${tui_ms[@]}" | jq -R . | jq -s .)" \
    --argjson pss_runs "$(printf '%s\n' "${pss_kb_values[@]}" | jq -R . | jq -s .)" \
    --argjson procs "$proc_median" \
    --argjson runs "$RUNS" --argjson idle "$IDLE" \
    '{device: $device, android: $android, version: $version,
      package_bytes: $package_bytes,
      startup_version_ms: $version_ms, startup_first_ms: $first_ms,
      startup_tui_ms: $tui_ms, startup_tui_min: $tui_min, startup_tui_max: $tui_max,
      idle_pss_kb: $pss_kb, idle_rss_kb: $rss_kb,
      tui_runs_ms: $tui_runs, pss_runs_kb: $pss_runs,
      idle_processes: $procs,
      runs: $runs, idle_seconds: $idle}' >"$JSON"
fi

if [ -n "$BUDGET" ]; then
  # shellcheck disable=SC1090
  . "$BUDGET"
  status=0
  if [ -n "${BUDGET_RSS_MB:-}" ] && [ "$(awk -v a="$rss_mb" -v b="$BUDGET_RSS_MB" 'BEGIN{print (a > b)}')" = 1 ]; then
    echo "budget: idle RSS ${rss_mb} MiB over ${BUDGET_RSS_MB} MiB" >&2
    status=1
  fi
  if [ -n "${BUDGET_PSS_MB:-}" ] && [ "$(awk -v a="$pss_mb" -v b="$BUDGET_PSS_MB" 'BEGIN{print (a > b)}')" = 1 ]; then
    echo "budget: idle PSS ${pss_mb} MiB over ${BUDGET_PSS_MB} MiB" >&2
    status=1
  fi
  if [ -n "${BUDGET_PACKAGE_MB:-}" ] && [ "$(awk -v a="$size_mb" -v b="$BUDGET_PACKAGE_MB" 'BEGIN{print (a > b)}')" = 1 ]; then
    echo "budget: package ${size_mb} MiB over ${BUDGET_PACKAGE_MB} MiB" >&2
    status=1
  fi
  if [ -n "${BUDGET_STARTUP_MS:-}" ] && [ "$tui_median" -gt "$BUDGET_STARTUP_MS" ]; then
    echo "budget: startup ${tui_median} ms over ${BUDGET_STARTUP_MS} ms" >&2
    status=1
  fi
  [ "$status" = 0 ] || exit 1
fi
