#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2016 # the istat fixture contains literal $-names such as $INDEX_ALLOCATION
# Metadata first: range arithmetic, NTFS boot sector geometry, directory index runs, when the phase
# is due.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
map="$T/m.map" logs="$T/logs" zones="$T/logs/zones" domain="$T/logs/domain.map" LOG="$logs/rescue.log" TMPD="$T/tmp" img="$T/disk.img"
mkdir -p "$logs" "$TMPD"
SECTOR=512 PART_SIZE=10000000

# --- subtract_ranges
printf '0 100\n200 300\n400 500\n' >"$T/keep"
printf '50 250\n450 460\n' >"$T/sub"
eq "subtract_ranges cuts the edges and the middle" $'0 50\n250 300\n400 450\n460 500' "$(subtract_ranges "$T/keep" "$T/sub")"
printf '0 1000\n' >"$T/sub"
eq "subtract_ranges: everything cut" "" "$(subtract_ranges "$T/keep" "$T/sub")"
printf '600 700\n' >"$T/sub"
eq "subtract_ranges: nothing to cut" $'0 100\n200 300\n400 500' "$(subtract_ranges "$T/keep" "$T/sub")"
printf '10 20\n30 40\n' >"$T/sub"
printf '0 100\n' >"$T/keep"
eq "subtract_ranges: several holes in one range" $'0 10\n20 30\n40 100' "$(subtract_ranges "$T/keep" "$T/sub")"

# --- write_ranges_domain keeps the deferred zones out in priority mode only
printf '1000 5000\n' >"$T/want"
printf '2000 3000\n' >"$zones"
PRIORITY_MODE=0
write_ranges_domain "$T/want"
eq "ordinary: the zone is inside the domain" $'0 1000 ?\n1000 4000 +\n5000 9995000 ?' "$(decmap "$domain" | sed 's/^0 0 +$//' | grep -v '^$')"
PRIORITY_MODE=1
write_ranges_domain "$T/want"
eq "priority: the zone is cut out of the domain" $'0 1000 ?\n1000 1000 +\n2000 1000 ?\n3000 2000 +\n5000 9995000 ?' "$(decmap "$domain" | grep -v '^$')"
PRIORITY_MODE=0
rm -f "${zones:?}"

# --- NTFS boot sector geometry
putbytes() { # putbytes FILE OFFSET BYTE...: writes bytes given as decimal numbers
  local f=$1 off=$2 b esc=""
  shift 2
  for b in "$@"; do esc+="\\x$(printf %02x "$b")"; done
  printf '%b' "$esc" | dd of="$f" bs=1 seek="$off" conv=notrunc status=none
}
boot() { # boot FILE OFFSET BPS SPC MFT MIRROR CPR : a synthetic NTFS boot sector at OFFSET
  local f=$1 off=$2
  head -c $((off + 4096)) /dev/zero >"$f"
  printf 'NTFS    ' | dd of="$f" bs=1 seek=$((off + 3)) conv=notrunc status=none
  putbytes "$f" $((off + 11)) $(($3 & 255)) $(($3 >> 8))
  putbytes "$f" $((off + 13)) "$4"
  putbytes "$f" $((off + 48)) "$5" 0 0 0 0 0 0 0
  putbytes "$f" $((off + 56)) "$6" 0 0 0 0 0 0 0
  putbytes "$f" $((off + 64)) "$7"
}
boot "$img" 0 512 8 4 2 246 # cpr = -10: 1024-byte records
eq "geometry: cluster, MFT, mirror, record size" "4096 16384 8192 1024" "$(ntfs_geometry 0)"
boot "$img" 1048576 4096 1 100 50 1 # 1 cluster per record = 4096
eq "geometry at an offset, 4096-byte sectors, positive records-per-cluster" "4096 409600 204800 4096" "$(ntfs_geometry 1048576)"
boot "$img" 0 512 8 4 2 246
printf 'XXXX' | dd of="$img" bs=1 seek=3 conv=notrunc status=none
refuse "geometry: not an NTFS boot sector" ntfs_geometry 0
boot "$img" 0 300 8 4 2 246
refuse "geometry: nonsense sector size" ntfs_geometry 0
eq "img_le: little endian" "513" "$(printf '\x01\x02' | { cat >"$T/le"; img="$T/le" img_le 0 2; })"

# --- directory index runs
istat() { cat "$T/istat.txt"; }
cat >"$T/istat.txt" <<'I'
MFT Entry Header Values:
Entry: 60        Sequence: 1
$LogFile Sequence Number: 0
Allocated File
Links: 1

Attributes:
Type: $STANDARD_INFORMATION (16-0)   Name: N/A   Resident   size: 48
Type: $INDEX_ROOT (144-1)   Name: $I30   Resident   size: 80
Type: $INDEX_ALLOCATION (160-2)   Name: $I30   Non-Resident   size: 8192  init_size: 8192
  Starting address: 500, length: 1
  Starting address: X, length: 1  Sparse
  Starting address: 700, length: 1
Type: $BITMAP (176-3)   Name: $I30   Resident   size: 8
I
CLUSTER=4096
tsk_set_offset 0
eq "directory index runs (sparse pieces and other attributes left out)" $'2048000 2052096\n2867200 2871296' "$(dir_index_ranges 60)"
tsk_set_offset 1048576
eq "...with the partition offset" $'3096576 3100672\n3915776 3919872' "$(dir_index_ranges 60)"
tsk_set_offset 0

# the same output when $AttrDef is unread: the types have no names, the numbers still tell
cat >"$T/istat.txt" <<'I'
Attributes:
Type: ? (16-0)   Name: N/A   Resident   size: 48
Type: ? (128-1)   Name: N/A   Non-Resident   size: 2560  init_size: 2560
  Starting address: 600, length: 1
Type: ? (128-4)   Name: $Info   Non-Resident   size: 8192  init_size: 8192
  Starting address: 900, length: 2
Type: ? (160-5)   Name: $I30   Non-Resident   size: 4096  init_size: 4096
  Starting address: 55, length: 1
I
eq "data runs of an entry whose types are unnamed (all data attributes)" $'2457600 2461696\n3686400 3694592' "$(attr_ranges 4 128)"
eq "index runs of an entry whose types are unnamed" $'225280 229376' "$(attr_ranges 4 160)"

# --- mmls_starts
mmls() {
  if [[ $MMLS == none ]]; then return 1; fi
  cat <<'M'
DOS Partition Table
Offset Sector: 0
Units are in 512-byte sectors

      Slot      Start        End          Length       Description
000:  Meta      0000000000   0000000000   0000000001   Primary Table (#0)
001:  -------   0000000000   0000002047   0000002048   Unallocated
002:  000:000   0000002048   0000198655   0000196608   NTFS / exFAT (0x07)
003:  000:001   0000400000   0000500000   0000100001   Linux (0x83)
M
}
MMLS=table
eq "partition starts in bytes" $'1048576\n204800000' "$(mmls_starts)"
MMLS=none
refuse "no table: mmls_starts fails" mmls_starts

# --- when the phase is due
tsk_available() { return 0; }
rm -f "${logs:?}"/*.done
meta_first=1 firsts=() no_fs=0
rm -f "$map"
check "no map yet: due" meta_pending
mkmap "$map" <<'M'
0 10000000 ?
M
check "something to copy and not done before: due" meta_pending
eq "next_phase says meta first" meta "$(next_phase)"
touch "$logs/meta.done"
refuse "done before: not due" meta_pending
eq "...and the ordinary copy follows" copy "$(next_phase)"
firsts=("Photos")
check "a new --first path: due again" meta_pending
printf 'Photos\n' >"$logs/first.done"
refuse "...and not once it has been read" meta_pending
mkmap "$map" <<'M'
0 10000000 +
M
rm -f "${logs:?}/meta.done" "${logs:?}/first.done"
refuse "nothing left to copy: not due" meta_pending
mkmap "$map" <<'M'
0 10000000 ?
M
meta_first=0
refuse "--no-meta-first: not due" meta_pending
meta_first=1 no_fs=1
refuse "--no-fs: not due" meta_pending
no_fs=0
tsk_available() { return 1; }
refuse "no Sleuth Kit: not due" meta_pending

# --- options
args_ok() { (parse_args "$@" && validate_args); }
check "--first" args_ok --first Photos /dev/null
refuse "--first with --no-meta-first" args_ok --first Photos --no-meta-first /dev/null
refuse "--first with --no-fs" args_ok --first Photos --no-fs /dev/null
refuse "--first with --inventory" args_ok --first Photos --inventory
firsts=()
eq "--first paths are normalised" "a/b c" "$( (parse_args --first /a/b/ --first c /dev/null && validate_args && printf '%s' "${firsts[*]}"))"

finish
