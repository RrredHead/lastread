#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# shellcheck disable=SC2034 # variables here are used by the tests that source this file
# Helpers for the integration tests. They need root, loop devices and device-mapper, and they
# create and destroy block devices: run them in a VM (tests/vm.sh integration), never on a
# machine whose disks matter.
#
# A test sources tests/lib.sh and this file, calls it_init, builds "disks" out of loop devices and
# device-mapper tables, runs the tool with `tool ARGS...` (output in $OUT, status in $RC) and ends
# with finish. Everything is cleaned up on exit.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="${TOOL:-$ROOT/lastread}"
M=1048576
# Devices are registered in files, not arrays: dm_create and loop_attach run in $(...) subshells.
IT_MOUNTS=() IT_BG=()
W="" OUT="" RC=0

it_init() {
  [[ $EUID -eq 0 ]] || {
    echo "the integration tests need root (and a VM)"
    exit 1
  }
  W="$(mktemp -d /var/tmp/lastread-it.XXXXXX)"
  OUT="$W/last.out"
  trap it_cleanup EXIT
}
it_cleanup() {
  local pid m d l
  set +e
  for pid in "${IT_BG[@]}"; do kill "$pid" 2>/dev/null; done
  for m in "${IT_MOUNTS[@]}"; do umount "$m" 2>/dev/null; done
  if [[ -f $W/registry-mounts ]]; then
    while read -r m; do umount "$m" 2>/dev/null; done < <(tac "$W/registry-mounts")
  fi
  if [[ -f $W/registry-dm ]]; then
    while read -r d; do dmsetup remove --force --retry "$d" 2>/dev/null; done < <(tac "$W/registry-dm")
  fi
  if [[ -f $W/registry-loops ]]; then
    while read -r l; do losetup -d "$l" 2>/dev/null; done < <(tac "$W/registry-loops")
  fi
  if [[ -n $W ]]; then rm -rf "${W:?}"; fi
}
# mount_registered DEVICE MOUNTPOINT [mount args]: mounts and remembers to unmount on exit.
mount_registered() {
  local dev=$1 mp=$2
  shift 2
  mkdir -p "$mp"
  mount "$@" "$dev" "$mp"
  printf '%s\n' "$mp" >>"$W/registry-mounts"
}

# loop_attach FILE [losetup args]: attaches a file, prints the loop device.
loop_attach() {
  local f=$1 dev
  shift
  dev="$(losetup -f --show "$@" "$f")"
  printf '%s\n' "$dev" >>"$W/registry-loops"
  printf '%s' "$dev"
}
# make_backing NAME SIZE_BYTES [zero|random]: a backing file in $W, prints its path.
make_backing() {
  local f="$W/$1.bin"
  if [[ ${3:-random} == zero ]]; then truncate -s "$2" "$f"; else head -c "$2" /dev/urandom >"$f"; fi
  printf '%s' "$f"
}
# dm_create NAME TABLE...: creates /dev/mapper/drt-NAME from table lines, prints the path.
dm_create() {
  local name=$1
  shift
  printf '%s\n' "$@" | dmsetup create "drt-$name"
  printf 'drt-%s\n' "$name" >>"$W/registry-dm"
  dmsetup mknodes "drt-$name" >/dev/null 2>&1 || true
  printf '/dev/mapper/drt-%s' "$name"
}
# dm_load NAME TABLE...: replaces the table of a live device.
dm_load() {
  local name=$1
  shift
  printf '%s\n' "$@" | dmsetup load "drt-$name"
  dmsetup resume "drt-$name"
}
# sectors BYTES: 512-byte sectors.
sectors() { echo $(($1 / 512)); }
# dm_linear LOOP START_BYTES LEN_BYTES [OFFSET_BYTES]: a table line (offset defaults to START).
dm_linear() { printf '%s %s linear %s %s' "$(sectors "$2")" "$(sectors "$3")" "$1" "$(sectors "${4:-$2}")"; }
dm_error() { printf '%s %s error' "$(sectors "$1")" "$(sectors "$2")"; }
# dm_delay LOOP START LEN MS: reads and writes are delayed.
dm_delay() { printf '%s %s delay %s %s %s' "$(sectors "$2")" "$(sectors "$3")" "$1" "$(sectors "$2")" "$4"; }

# tool ARGS...: runs the tool, output to $OUT (and the screen if IT_VERBOSE is set), status in $RC.
tool() {
  RC=0
  if [[ -n ${IT_VERBOSE:-} ]]; then
    "$TOOL" "$@" 2>&1 | tee "$OUT"
    RC=${PIPESTATUS[0]}
  else
    "$TOOL" "$@" >"$OUT" 2>&1 || RC=$?
  fi
}
out_has() { grep -F -- "$1" "$OUT" >/dev/null; }
# bg CMD...: starts a background process that is killed on exit; sets BGPID.
bg() {
  "$@" &
  BGPID=$!
  IT_BG+=("$BGPID")
}
# same_bytes FILE_A FILE_B FROM LEN: compares LEN bytes at offset FROM in both.
same_bytes() { cmp -s -i "$3" -n "$4" "$1" "$2"; }
# rc_is DESC EXPECTED: checks $RC; on a mismatch shows the tail of the tool output.
rc_is() {
  if [[ $RC == "$2" ]]; then
    pass "$1"
  else
    fail "$1" "expected exit status $2, got $RC; output tail:"$'\n'"$(tail -15 "$OUT")"
  fi
}
