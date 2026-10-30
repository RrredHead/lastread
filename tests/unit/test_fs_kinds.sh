#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2016 # fls fixtures contain literal $-names
# The file level for ext2/3/4 (and the kind detection): file_map on real istat -r output, the listing
# rules, classification.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="$here/../fixtures"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
TMPD="$T/tmp"
mkdir -p "$TMPD"
img="$T/image.img"
logs="" LOG=""

# --- the family of a file system
eq "NTFS" ntfs "$(fs_kind_of NTFS)"
eq "Ext4" ext "$(fs_kind_of Ext4)"
eq "Ext2" ext "$(fs_kind_of Ext2)"
eq "FAT32" fat "$(fs_kind_of FAT32)"
eq "exFAT" fat "$(fs_kind_of exFAT)"
eq "FAT16" fat "$(fs_kind_of FAT16)"
eq "something else" "" "$(fs_kind_of ISO9660)"
eq "nothing" "" "$(fs_kind_of "")"
eq "the block size from fsstat of an ext4 volume" 4096 "$(awk -F': *' '/^Block Size:/ {print $2; exit}' "$FX/ext/fsstat.txt")"
eq "fs_type of real ext4 fsstat output" Ext4 "$(fs_type "$(cat "$FX/ext/fsstat.txt")")"


# --- FAT and exFAT are recognised from the boot sector (fsstat does not return on exFAT)
putbytes() { # putbytes FILE OFFSET BYTE...: writes bytes given as decimal numbers
  local f=$1 off=$2 b esc=""
  shift 2
  for b in "$@"; do esc+="\\x$(printf %02x "$b")"; done
  printf '%b' "$esc" | dd of="$f" bs=1 seek="$off" conv=notrunc status=none
}
newimg() { head -c 65536 /dev/zero >"$img"; }
newimg
printf 'EXFAT   ' | dd of="$img" bs=1 seek=3 conv=notrunc status=none
putbytes "$img" 108 9 3
eq "boot_probe: exFAT with 512-byte sectors" "exFAT 512" "$(boot_probe 0)"
putbytes "$img" 108 12
eq "boot_probe: exFAT with 4096-byte sectors" "exFAT 4096" "$(boot_probe 0)"
newimg
putbytes "$img" 11 0 2
printf 'FAT32   ' | dd of="$img" bs=1 seek=82 conv=notrunc status=none
eq "boot_probe: FAT32" "FAT32 512" "$(boot_probe 0)"
newimg
putbytes "$img" 11 0 2
printf 'FAT16   ' | dd of="$img" bs=1 seek=54 conv=notrunc status=none
eq "boot_probe: FAT16" "FAT16 512" "$(boot_probe 0)"
newimg
putbytes "$img" $((4096 + 11)) 0 2
printf 'FAT12   ' | dd of="$img" bs=1 seek=$((4096 + 54)) conv=notrunc status=none
eq "boot_probe at an offset" "FAT12 512" "$(boot_probe 4096)"
refuse "boot_probe: a zeroed sector" boot_probe 0
newimg
printf 'NTFS    ' | dd of="$img" bs=1 seek=3 conv=notrunc status=none
putbytes "$img" 11 0 2
refuse "boot_probe: NTFS goes through fsstat" boot_probe 0
newimg
putbytes "$img" 11 7 7
printf 'FAT32   ' | dd of="$img" bs=1 seek=82 conv=notrunc status=none
refuse "boot_probe: nonsense sector size" boot_probe 0
newimg
putbytes "$img" 11 0 2
printf 'FAT32   ' | dd of="$img" bs=1 seek=82 conv=notrunc status=none
out="$(fs_probe 0)"
eq "fs_probe synthesises an fsstat-like description" $'File System Type: FAT32\nSector Size: 512' "$out"
eq "...whose type and sector size are read like fsstat output" "fat 512" "$(fs_kind_of "$(fs_type "$out")") $(awk -F': *' '/^Sector Size:/ {print $2}' <<<"$out")"

# --- file_map for ext on real istat -r output
FS_KIND=ext CLUSTER=4096
istat() {
  case "${*: -1}" in
    14) cat "$FX/ext/14.istat" ;;
    17) cat "$FX/ext/17.istat" ;;
    18) cat "$FX/ext/18.istat" ;;
    19) cat "$FX/ext/inline-14.istat" ;;
    *) return 1 ;;
  esac
}
mt="$(sed -n 's/^File Modified:\t\(.*\) (UTC)$/\1/p' "$FX/ext/14.istat")"
eq "ext: a one-block file" $'5 5 simple '"$mt"$'\n0 1297 1' "$(file_map 14)"
eq "ext: a contiguous file, the size is not a multiple of the block" $'300000 300000 simple '"$mt"$'\n0 1300 74' "$(file_map 17)"
eq "ext: a sparse file (a hole before and after the data)" $'1048576 1048576 simple '"$mt"$'\n0 - 50\n50 1374 5\n55 - 201' "$(file_map 18)"
eq "ext: inline data is resident" "5 5 resident $mt" "$(file_map 19)"
refuse "ext: an unreadable inode" file_map 99

# --- classification and ranges on ext
printf '%s %s\n' $((1300 * 4096 + 100)) $((1300 * 4096 + 200)) >"$T/r"
eq "a range inside the data: damaged" damaged "$(printf '17\ta\n' | classify "$T/r" | cut -f1)"
printf '%s %s\n' $((1374 * 4096 - 10)) $((1374 * 4096)) >"$T/r"
eq "a range just before the data of the sparse file: intact" intact "$(printf '18\ta\n' | classify "$T/r" | cut -f1)"
printf '0 %s\n' $((1300 * 4096)) >"$T/r"
eq "a range before the data: intact" intact "$(printf '17\ta\n' | classify "$T/r" | cut -f1)"
eq "byte ranges of the sparse file skip the holes" "$((1374 * 4096)) $((1379 * 4096))" "$(file_byte_ranges 18)"

# --- the listing of an ext volume
fls() {
  printf 'd/d 11:\tlost+found\nd/d 12:\tdocs\nr/r 13:\tdocs/mid.bin\nr/r 14:\tdocs/small.txt\n'
  printf 'r/r 15:\tdocs/$weird: name\nr/r 16:\tdocs/two\tnames\nV/V 4097:\t$OrphanFiles\n'
}
ils() {
  printf 'class|host|device|start_time\nils|h||1\nst_ino|st_alloc|st_uid|st_gid|st_mtime|st_atime|st_ctime|st_crtime|st_mode|st_nlink|st_size\n'
  local i
  for i in 1 2 7 8 11 12 13 14 15 16 20 21; do printf '%s|a|0|0|0|0|0|0|644|1|10\n' "$i"; done
}
istat() {
  case "${*: -1}" in
    20) printf 'inode: 20\nAllocated\nGroup: 0\nuid / gid: 0 / 0\nmode: rrw-r--r--\nsize: 10\nnum of links: 1\n' ;;
    21) printf 'inode: 21\nAllocated\nGroup: 0\nuid / gid: 0 / 0\nmode: drwxr-xr-x\nsize: 4096\nnum of links: 2\n' ;;
    *) return 1 ;;
  esac
}
expected=$'13\tdocs/mid.bin\n14\tdocs/small.txt\n15\tdocs/$weird: name\n16\t?/entry 16\n20\t?/entry 20'
eq "ext listing: names with \$ and : are real names; inodes the walk did not reach are listed, directories are not" "$expected" "$(tsk_files)"
FS_KIND=fat
fls() { printf 'r/r 3:\t$VOLUME_GUID\nr/r 4:\t$ALLOC_BITMAP\nr/r 5:\t$UPCASE_TABLE\nr/r 7:\tdocs/a.txt\nr/r 9:\tdocs/b.txt\nv/v 100:\t$FAT1\nV/V 101:\t$OrphanFiles\nr/r 11:\t$keep-me.txt\n'; }
ils() { printf 'class|host|device|start_time\nils|h||1\nst_ino|st_alloc\n'; printf '7|a\n9|a\n300|a\n'; }
eq "FAT/exFAT listing: the walk without the exFAT system entries" $'7\tdocs/a.txt\n9\tdocs/b.txt\n11\t$keep-me.txt' "$(tsk_files)"

finish
