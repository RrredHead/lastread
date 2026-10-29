#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# shellcheck disable=SC2034 # REF_FILES and VOL are used by the tests that source this file
# Builds a synthetic NTFS volume for the file-level tests. Source it after tests/integration/lib.sh
# (it needs $W, $M and the helpers) and call build_ntfs_volume. It sets:
#   VOL        the image file of the volume
#   REF        a directory with the original files (what extraction must reproduce)
#   REF_FILES  the list of files in $REF (relative paths)
#
# Contents: ordinary files, a small (resident) file, files with non-ASCII names and spaces, a
# sparse file, a compressed file, and two heavily fragmented files whose pieces do not fit into
# one MFT entry ($ATTRIBUTE_LIST): small filler files are created between the appends of a file,
# and deleted afterwards.

VOL="" REF="" REF_FILES=()

build_ntfs_volume() {
  local mnt="$W/ntfs-mnt" i
  VOL="$W/volume.img"
  REF="$W/ref"
  mkdir -p "$REF"
  truncate -s $((96 * M)) "$VOL"
  mkntfs -F -Q -c 4096 -L fixture "$VOL" >/dev/null 2>&1
  mkdir -p "$mnt"
  mount -t ntfs-3g -o compression "$VOL" "$mnt"
  mkdir -p "$mnt/docs" "$mnt/docs/notes" "$mnt/media/sub" "$mnt/fill"
  echo "a tiny resident file" >"$mnt/docs/readme.txt"
  echo "заметка" >"$mnt/docs/notes/план.txt"
  head -c 200000 /dev/urandom >"$mnt/docs/my file with spaces.bin"
  head -c $((5 * M)) /dev/urandom >"$mnt/media/movie1.mkv"
  head -c $((3 * M)) /dev/urandom >"$mnt/media/movie2.mkv"
  head -c $((1 * M)) /dev/urandom >"$mnt/media/sub/clip.bin"
  # sparse: data only after a hole
  dd if=/dev/urandom of="$mnt/media/sparse.bin" bs=4096 seek=100 count=20 status=none
  # compressed directory and file
  mkdir "$mnt/docs/packed"
  setfattr -h -v 0x00000800 -n system.ntfs_attrib_be "$mnt/docs/packed"
  { yes "a line of text that compresses well" || true; } | head -c 300000 >"$mnt/docs/packed/text.txt"
  # heavily fragmented files: appends interleaved with small files
  : >"$mnt/media/frag1.bin"
  : >"$mnt/media/frag2.bin"
  for i in $(seq 1 1400); do
    head -c 4096 /dev/urandom >>"$mnt/media/frag1.bin"
    head -c 4096 /dev/urandom >"$mnt/fill/a$i"
    head -c 4096 /dev/urandom >>"$mnt/media/frag2.bin"
    head -c 4096 /dev/urandom >"$mnt/fill/b$i"
  done
  # a fragmented file whose size is not a multiple of the cluster
  head -c 1000 /dev/urandom >>"$mnt/media/frag1.bin"
  rm -rf "${mnt:?}/fill"
  sync
  cp -a "$mnt/." "$REF/"
  umount "$mnt"
  mapfile -t REF_FILES < <(cd "$REF" && find . -type f | sed 's|^\./||' | sort)
}

# ntfs_rec IMAGE PATH: the MFT entry number of a file.
ntfs_rec() {
  fls -r -p -u "$1" | awk -F'\t' -v p="$2" '$2 == p {split($1, a, " "); sub(/-.*/, "", a[2]); print a[2]; exit}'
}
# ntfs_runs IMAGE PATH: "BYTE_START BYTE_LENGTH" per non-sparse run of a file (cluster 4096).
ntfs_runs() {
  local rec
  rec="$(ntfs_rec "$1" "$2")"
  istat -r "$1" "$rec" | awk '/Starting address/ { gsub(/,/, ""); if ($6 != "Sparse" && $6 != "Filler") printf "%d %d\n", $3 * 4096, $5 * 4096 }'
}
# dm_table_with_errors LOOP SIZE_BYTES "START LEN"...: table lines for a disk that is readable
# except for the given ranges (sorted, sector-aligned).
dm_table_with_errors() {
  local loop=$1 size=$2 pos=0 s l
  shift 2
  while read -r s l; do
    [[ -n $s ]] || continue
    if ((s > pos)); then dm_linear "$loop" "$pos" $((s - pos)); echo; fi
    dm_error "$s" "$l"
    echo
    pos=$((s + l))
  done < <(printf '%s\n' "$@" | sort -n)
  if ((pos < size)); then dm_linear "$loop" "$pos" $((size - pos)); echo; fi
}
# compare_tree REFDIR OUTDIR [skip-listed-file...]: every file of REFDIR exists in OUTDIR with the
# same bytes and modification time (seconds), except the listed ones. Prints what differs.
compare_tree() {
  local ref=$1 out=$2 f rc=0 skip
  shift 2
  while IFS= read -r f; do
    for skip in "$@"; do [[ $f == "$skip" ]] && continue 2; done
    if [[ ! -f $out/$f ]]; then
      echo "missing: $f"
      rc=1
    elif ! cmp -s "$ref/$f" "$out/$f"; then
      echo "different bytes: $f"
      rc=1
    elif [[ "$(stat -c %Y "$ref/$f")" != "$(stat -c %Y "$out/$f")" ]]; then
      echo "different mtime: $f ($(stat -c %Y "$ref/$f") vs $(stat -c %Y "$out/$f"))"
      rc=1
    fi
  done < <(cd "$ref" && find . -type f | sed 's|^\./||' | sort)
  return "$rc"
}
