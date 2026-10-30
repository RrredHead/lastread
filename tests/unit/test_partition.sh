#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2016 # the istat fixture contains literal $-names such as $DATA
# The file level of a whole-disk image: finding the NTFS partition (mmls, fsstat -o) and the byte
# offset in classification, ranges and streams.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
img="$T/disk.img"
logs="" LOG="" SECTOR=512
head -c 1048576 /dev/zero >"$img"

# --- fs_locate with shadowed fsstat and mmls
MODE=table
tsk_fsstat() {
  local off=0
  [[ $1 == -o ]] && off=$2
  if [[ $MODE == plain && $off == 0 ]]; then
    printf 'File System Type: NTFS\nCluster Size: 4096\n'
    return 0
  fi
  case $off in
    2048 | 198656) printf 'File System Type: NTFS\nCluster Size: 4096\n' ;;
    400000) printf 'File System Type: ISO9660\n' ;;
    *) return 1 ;;
  esac
}
mmls() {
  case $MODE in
    table) cat <<'M' ;;
DOS Partition Table
Offset Sector: 0
Units are in 512-byte sectors

      Slot      Start        End          Length       Description
000:  Meta      0000000000   0000000000   0000000001   Primary Table (#0)
001:  -------   0000000000   0000002047   0000002048   Unallocated
002:  000:000   0000002048   0000198655   0000196608   NTFS / exFAT (0x07)
003:  000:001   0000400000   0000500000   0000100001   Linux (0x83)
M
    two) cat <<'M' ;;
DOS Partition Table
Offset Sector: 0
Units are in 512-byte sectors

      Slot      Start        End          Length       Description
000:  Meta      0000000000   0000000000   0000000001   Primary Table (#0)
001:  -------   0000000000   0000002047   0000002048   Unallocated
002:  000:000   0000002048   0000198655   0000196608   NTFS / exFAT (0x07)
003:  000:001   0000198656   0000395263   0000196608   NTFS / exFAT (0x07)
004:  000:002   0000400000   0000500000   0000100001   Linux (0x83)
M
    *) return 1 ;;
  esac
}
blkid() { return 1; }

partition=""
MODE=table
fs_locate >/dev/null
eq "one NTFS partition among others: found" "1048576" "$FS_OFFSET"
eq "...with the TSK offset in 512-byte sectors" "-o 2048" "${TSK_O[*]}"
eq "...and the fsstat output of the volume" "NTFS" "$(fs_type "$FSOUT")"
MODE=plain
fs_locate >/dev/null
eq "a partition image: offset 0, no TSK offset" "0 [] " "$FS_OFFSET [${TSK_O[*]}] "
MODE=two
refuse "two NTFS partitions without --partition: no volume" fs_locate
fs_locate >"$T/o" 2>&1
check "...the message says to choose" contains "$(cat "$T/o")" "choose one with --partition N"
check "...and lists the partitions" contains "$(cat "$T/o")" "partitions 1 2"
partition=2
fs_locate >/dev/null
eq "--partition 2: the second volume" "$((198656 * 512))" "$FS_OFFSET"
partition=3
fs_locate >"$T/o" 2>&1
check "--partition on a partition without a supported file system: refused" contains "$(cat "$T/o")" "is ISO9660: the file level supports"
partition=9
fs_locate >"$T/o" 2>&1
check "--partition beyond the table: refused" contains "$(cat "$T/o")" "only 3 partitions"
partition=""
MODE=none
fs_locate >"$T/o" 2>&1
check "no table and no file system: not recognised" contains "$(cat "$T/o")" "holds no file system the file level can read"
eq "...and the offset is reset" "0" "$FS_OFFSET"

# --- byte offsets in ranges, classification and streams
img="$T/disk.img"
CLUSTER=4096
TMPD="$T/tmp"
mkdir -p "$TMPD"
ISTAT_DIR="$T/istat"
mkdir -p "$ISTAT_DIR"
istat() { cat "$ISTAT_DIR/${*: -1}.istat"; }
MT="2024-01-02 03:04:05.123456700"
{
  printf 'MFT Entry Header Values:\nEntry: 70        Sequence: 1\n$LogFile Sequence Number: 0\nAllocated File\nLinks: 1\n\n'
  printf '$STANDARD_INFORMATION Attribute Values:\nFlags: Archive\nOwner ID: 0\nSecurity ID: 0  ()\n'
  printf 'Created:\t%s (UTC)\nFile Modified:\t%s (UTC)\nMFT Modified:\t%s (UTC)\nAccessed:\t%s (UTC)\n\n' "$MT" "$MT" "$MT" "$MT"
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 61340  init_size: 61340\n'
  printf '  Starting address: 100, length: 15  \n'
} >"$ISTAT_DIR/70.istat"
tsk_set_offset 1048576
eq "byte ranges of a file include the partition offset" "$((1048576 + 409600)) $((1048576 + 471040))" "$(file_byte_ranges 70-128-2)"
printf '%s 1500000\n' "$((1048576 + 450000))" >"$T/r.txt"
out="$(printf '70\ta/b.bin\n' | classify "$T/r.txt")"
eq "classify: absolute ranges are compared with absolute positions" "damaged" "$(cut -f1 <<<"$out")"
printf '450000 1000000\n' >"$T/r.txt"
eq "classify: a range that is only inside the partition offset does not touch the file" "intact" "$(printf '70\ta/b.bin\n' | classify "$T/r.txt" | cut -f1)"
head -c $((3 * 1024 * 1024)) /dev/urandom >"$img"
file_stream "$(file_map 70)" 70 >"$T/s"
dd if="$img" bs=1 skip=$((1048576 + 409600)) count=61340 status=none >"$T/s.expect"
check "file_stream reads the data at the partition offset" cmp -s "$T/s" "$T/s.expect"
tsk_set_offset 0

finish
