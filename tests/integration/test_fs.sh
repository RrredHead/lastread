#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The file level for ext4 (with inline data), FAT32 and exFAT: images built with mkfs and filled through
# a mount (a fragmented file included), a healthy run, a run with an unreadable place inside a file,
# and an ext4 partition inside a whole-disk image.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
# shellcheck source=ntfs_fixture.sh
source "$here/ntfs_fixture.sh"
it_init
set +e
chmod 755 "$W"

mkout() {
  mkdir -p "$@"
  chmod 777 "$@"
}
fs_populate() { # fs_populate DIR [sparse]
  local d=$1 i
  mkdir -p "$d/docs/notes" "$d/media" "$d/fill"
  echo "a tiny file" >"$d/docs/readme.txt"
  echo "заметка" >"$d/docs/notes/план.txt"
  head -c 200000 /dev/urandom >"$d/docs/my file.bin"
  head -c $((3 * M)) /dev/urandom >"$d/media/movie.mkv"
  if [[ ${2:-} == sparse ]]; then dd if=/dev/urandom of="$d/media/sparse.bin" bs=4096 seek=100 count=10 status=none; fi
  : >"$d/media/frag.bin"
  for i in $(seq 1 300); do
    head -c 8192 /dev/urandom >>"$d/media/frag.bin"
    head -c 8192 /dev/urandom >"$d/fill/f$i"
  done
  rm -rf "${d:?}/fill"
}
# first_run IMAGE PATH UNIT: "BYTE_START BYTE_LENGTH" of the first run of a file (UNIT bytes per block)
first_run() {
  local rec
  rec="$(fls -r -p -u "$1" | awk -F'\t' -v p="$2" '$2 == p {split($1, a, " "); sub(/:$/, "", a[2]); print a[2]; exit}')"
  istat -r "$1" "$rec" | awk -v u="$3" '/Starting address/ { gsub(/,/, ""); if ($6 != "Sparse" && $6 != "Filler") { printf "%d %d\n", $3 * u, $5 * u; exit } }'
}

# fs_case NAME SIZE_MB UNIT MKFS... : builds the image with the command (the image path is appended),
# fills it, and tests it
fs_case() {
  local name=$1 size=$2 unit=$3 mounttype=$4 mountopts=$5 sparse=$6
  shift 6
  local img="$W/$name.img" mnt="$W/mnt-$name" ref="$W/ref-$name" lp disk d out bs
  truncate -s "${size}M" "$img"
  if ! "$@" "$img" >/dev/null 2>&1; then
    skip "$name: mkfs is not available"
    return 0
  fi
  mkdir -p "$mnt" "$ref"
  if ! mount -t "$mounttype" -o "loop,$mountopts" "$img" "$mnt" 2>/dev/null; then
    skip "$name: the kernel cannot mount this file system here"
    return 0
  fi
  printf '%s\n' "$mnt" >>"$W/registry-mounts"
  fs_populate "$mnt" "$sparse"
  cp -a "$mnt/." "$ref/"
  sync
  umount "$mnt"
  lp="$(loop_attach "$img")"
  disk="$(dm_create "$name" "$(dm_linear "$lp" 0 $((size * M)))")"

  # a healthy run
  d="$W/$name-a"
  out="$W/$name-out"
  mkout "$d" "$out"
  tool "$disk" --dir "$d" --name "$name" --interval 1 --no-temp --extract --extract-to "$out"
  rc_is "$name: image, report and extraction" 0
  check "$name: the file level was used (no skip message)" bash -c "! grep -F 'no file level' '$OUT' >/dev/null"
  check "$name: the image equals the disk" cmp -s "$img" "$d/$name.img"
  mapfile -t listed < <(cd "$ref" && find . -type f | sed 's|^\./||' | sort)
  eq "$name: every file is listed as intact" "${#listed[@]}" "$(awk -F'\t' '$1 == "intact"' "$d/$name.logs/files.tsv" | wc -l)"
  eq "$name: every file is extracted byte for byte, with its time" "" "$(compare_tree "$ref" "$out")"
  eq "$name: nothing else is extracted" "${#listed[@]}" "$(find "$out" -type f | wc -l)"

  # an unreadable place inside one file
  read -r bs _ <<<"$(first_run "$img" "docs/my file.bin" "$unit")"
  local bad="$((bs / 512 * 512)) 4096"
  mapfile -t table < <(dm_table_with_errors "$lp" $((size * M)) "$bad")
  dm_load "$name" "${table[@]}"
  d="$W/$name-b"
  out="$W/$name-outb"
  mkout "$d" "$out"
  tool "$disk" --dir "$d" --name "${name}b" --interval 1 --no-temp --extract --extract-to "$out"
  rc_is "$name: a run with an unreadable place" 0
  check "$name: the damaged file is reported" grep -Fx "docs/my file.bin" "$d/${name}b.logs/damaged-files.txt"
  eq "$name: it is the only damaged file" 1 "$(wc -l <"$d/${name}b.logs/damaged-files.txt")"
  check "$name: the damaged file is not extracted" test ! -e "$out/docs/my file.bin"
  eq "$name: all the other files are extracted correctly" "" "$(compare_tree "$ref" "$out" "docs/my file.bin")"
  # the inventory without the disk says the same
  tool --inventory --dir "$d" --name "${name}b"
  rc_is "$name: inventory without the disk" 0
  check "$name: ...one incomplete file" out_has "incomplete: 1"
}

# ext4: 4096-byte blocks, small files inside the inode, files with holes
fs_case ext4 48 4096 ext4 "" sparse mkfs.ext4 -q -F -b 4096 -I 256 -O inline_data
# FAT32 with 1 KiB clusters (the runs of FAT are listed in 512-byte sectors)
fs_case fat32 70 512 vfat "iocharset=utf8" nosparse mkfs.vfat -F 32 -s 2 -S 512
# exFAT (The Sleuth Kit's fsstat does not return on exFAT: the volume is recognised from its boot sector)
fs_case exfat 64 512 exfat "" nosparse mkfs.exfat

# A FAT destination does not support hard links; atomic no-replace must still work.
if [[ -s $W/ext4-a/ext4.img ]]; then
  truncate -s 70M "$W/fat-destination.img"
  if mkfs.vfat -F 32 "$W/fat-destination.img" >/dev/null 2>&1 &&
    mount -t vfat -o loop,iocharset=utf8 "$W/fat-destination.img" "$W/mnt-fat32" 2>/dev/null; then
    printf '%s\n' "$W/mnt-fat32" >>"$W/registry-mounts"
    tool --inventory --dir "$W/ext4-a" --name ext4 --extract --extract-to "$W/mnt-fat32" --owner root --include docs/readme.txt
    rc_is "FAT destination: safe extraction succeeds without hard links" 0
    check "FAT destination: extracted data is correct" cmp -s "$W/ref-ext4/docs/readme.txt" "$W/mnt-fat32/docs/readme.txt"
    umount "$W/mnt-fat32"
  else
    skip "FAT destination cannot be mounted"
  fi
fi

# an ext4 partition inside a whole-disk image
if [[ -s $W/ext4.img ]]; then
  truncate -s 50M "$W/whole.img"
  dd if="$W/ext4.img" of="$W/whole.img" bs=1M seek=1 conv=notrunc status=none
  printf 'label: dos\nstart=2048, size=98304, type=83\n' | sfdisk -q "$W/whole.img" >/dev/null 2>&1
  lw="$(loop_attach "$W/whole.img")"
  dw="$(dm_create whole "$(dm_linear "$lw" 0 $((50 * M)))")"
  D="$W/whole-a"
  OUTW="$W/whole-out"
  mkout "$D" "$OUTW"
  tool "$dw" --dir "$D" --name whole --interval 1 --no-temp --extract --extract-to "$OUTW"
  rc_is "ext4 in a whole-disk image" 0
  check "the partition is found" out_has "the file level works on partition 1 of the image (Ext4"
  eq "every file is extracted byte for byte" "" "$(compare_tree "$W/ref-ext4" "$OUTW")"
fi

finish
