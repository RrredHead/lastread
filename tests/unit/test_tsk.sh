#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# File level without a real volume: file_map on prepared istat outputs (including the
# $ATTRIBUTE_LIST cases), classify, tsk_files with prepared fls/ils outputs, file_stream and
# extract_files on a synthetic image. istat, fls and ils are shadowed by shell functions.
# shellcheck disable=SC2016 # the istat fixtures contain literal $-names such as $DATA
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
CLUSTER=4096
img="$T/image.img"
TMPD="$T/tmp"
logs="$T/logs"
LOG="$logs/rescue.log"
mkdir -p "$TMPD" "$logs"
ISTAT_DIR="$T/istat"
mkdir -p "$ISTAT_DIR"

# istat is shadowed: the output for an MFT entry comes from $ISTAT_DIR/ENTRY.istat.
istat() { cat "$ISTAT_DIR/${*: -1}.istat"; }

MT="2024-01-02 03:04:05.123456700"
# hdr ENTRY [BASE_ENTRY]: the head of an istat -r output (a base entry has times, an extension not).
hdr() {
  printf 'MFT Entry Header Values:\nEntry: %s        Sequence: 1\n' "$1"
  [[ -z ${2:-} ]] || printf 'Base File Record: %s\n' "$2"
  printf '$LogFile Sequence Number: 0\nAllocated File\nLinks: 1\n\n'
  if [[ -z ${2:-} ]]; then
    printf '$STANDARD_INFORMATION Attribute Values:\nFlags: Archive\nOwner ID: 0\nSecurity ID: 0  ()\n'
    printf 'Created:\t%s (UTC)\nFile Modified:\t%s (UTC)\nMFT Modified:\t%s (UTC)\nAccessed:\t%s (UTC)\n\n' "$MT" "$MT" "$MT" "$MT"
    printf '$FILE_NAME Attribute Values:\nFlags: Archive\nName: f.bin\nParent MFT Entry: 5 \tSequence: 5\n\n'
  fi
}
# run START LEN [Filler|Sparse]
run() {
  if [[ ${3:-} == Filler || ${3:-} == Sparse ]]; then
    printf '  Starting address: X, length: %s  %s\n' "$2" "$3"
  else
    printf '  Starting address: %s, length: %s  \n' "$1" "$2"
  fi
}
# list ENTRY:ID:ENTRY:VCN...: the attribute-list lines of the base entry
alist() {
  local a
  printf '$ATTRIBUTE_LIST Attribute Values:\n'
  for a in "$@"; do
    IFS=: read -r id rec vcn <<<"$a"
    printf 'Type: %s \tMFT Entry: %s \tVCN: %s\n' "$id" "$rec" "$vcn"
  done
  printf '\n'
}
put() { cat >"$ISTAT_DIR/$1.istat"; } # put ENTRY < output

# --- file_map: plain cases ----------------------------------------------------------------------
{
  hdr 70
  printf 'Attributes: \nType: $STANDARD_INFORMATION (16-0)   Name: N/A   Resident   size: 48\n'
  printf 'Type: $DATA (128-2)   Name: N/A   Non-Resident   size: 61340  init_size: 61340\n'
  run 100 10
  run 110 5
} | put 70
eq "simple file: adjacent runs are merged" $'61340 61340 simple '"$MT"$'\n0 100 15' "$(file_map 70)"

{
  hdr 71
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Resident   size: 15\n'
} | put 71
eq "resident file has no pieces" "15 15 resident $MT" "$(file_map 71)"

{
  hdr 72
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident, Sparse   size: 204800  init_size: 204800\n'
  run X 40 Sparse
  run 2634 10
} | put 72
eq "sparse file: sparse piece is a dash" $'204800 204800 simple '"$MT"$'\n0 - 40\n40 2634 10' "$(file_map 72)"

{
  hdr 74
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 8192  init_size: 8192\n'
  run 300 2
  printf 'Type: $DATA (128-5)   Name: Zone.Identifier   Non-Resident   size: 4096  init_size: 4096\n'
  run 900 1
} | put 74
eq "a named stream is not the file data" $'8192 8192 simple '"$MT"$'\n0 300 2' "$(file_map 74)"

{
  hdr 75
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 20000  init_size: 8192\n'
  run 300 2
  run 400 3
} | put 75
eq "init_size is kept" $'20000 8192 simple '"$MT"$'\n0 300 2\n2 400 3' "$(file_map 75)"

{
  hdr 76
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 40000  init_size: 40000\n'
  run 300 2
} | put 76
eq "pieces that do not cover the size make the file broken" $'40000 40000 broken '"$MT"$'\n0 300 2' "$(file_map 76)"

{
  hdr 77
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 20000  init_size: 20000\n'
  run 300 2
  run X 2 Filler
  run 500 1
} | put 77
eq "a filler in a plain file is a hole: broken" "broken" "$(file_map 77 | awk 'NR == 1 {print $3}')"

cp "$FX/real-kinds/packed.istat" "$ISTAT_DIR/78.istat"
eq "compressed file is packed (read through icat only)" "packed" "$(file_map 78 | awk 'NR == 1 {print $3}')"
cp "$FX/real-kinds/plain.istat" "$ISTAT_DIR/79.istat"
eq "real plain file" $'300000 300000 simple 2024-03-05 14:28:16.115531800\n0 2560 74' "$(file_map 79)"
cp "$FX/real-kinds/small.istat" "$ISTAT_DIR/64.istat"
eq "real resident file" "resident" "$(file_map 64 | awk 'NR == 1 {print $3}')"
cp "$FX/real-kinds/sparse.istat" "$ISTAT_DIR/66.istat"
eq "real sparse file" $'0 - 40\n40 2634 10' "$(file_map 66 | sed 1d)"
refuse "an unreadable entry fails" file_map 999

# --- file_map: $ATTRIBUTE_LIST ---------------------------------------------------------------------
# Pieces in three entries; the base entry also carries the TSK stitching: the runs of the
# extension ranges again, with shifted LCNs. Those must be ignored.
{
  hdr 80
  alist 16-0:80:0 128-2:80:0 128-0:81:4 128-0:82:8
  printf 'Attributes: \nType: $ATTRIBUTE_LIST (32-4)   Name: N/A   Non-Resident   size: 192  init_size: 192\n'
  run 7000 1
  printf 'Type: $DATA (128-2)   Name: N/A   Non-Resident   size: 49142  init_size: 49142\n'
  run 1000 4
  run 6004 4 # TSK stitch: wrong, shifted by thousands of clusters
  run 6008 4
} | put 80
{
  hdr 81 80
  printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident   size: 99999  init_size: 0\n'
  run X 4 Filler
  run 2000 4
} | put 81
{
  hdr 82 80
  printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident   size: 88888  init_size: 0\n'
  run X 8 Filler
  run 3000 4
} | put 82
eq "split file: pieces from their own entries, stitching ignored, size from VCN 0" \
  $'49142 49142 split '"$MT"$'\n0 1000 4\n4 2000 4\n8 3000 4' "$(file_map 80)"

# The base entry keeps a middle chunk in a separate attribute with another id (128-3), the first
# extension holds the range before it and a second extension the tail.
{
  hdr 90
  alist 16-0:90:0 128-2:90:0 128-0:91:4 128-3:90:8 128-0:92:12
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 61430  init_size: 61430\n'
  run 1000 4
  run 8888 4 # stitched filler replacement
  printf 'Type: $DATA (128-3)   Name: N/A   Non-Resident   size: 61430  init_size: 61430\n'
  run X 8 Filler
  run 3000 4
} | put 90
{
  hdr 91 90
  printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident   size: 7  init_size: 0\n'
  run X 4 Filler
  run 2000 4
} | put 91
{
  hdr 92 90
  printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident   size: 7  init_size: 0\n'
  run X 12 Filler
  run 4000 3
} | put 92
eq "split file: a middle chunk in the base entry under another attribute id" \
  $'61430 61430 split '"$MT"$'\n0 1000 4\n4 2000 4\n8 3000 4\n12 4000 3' "$(file_map 90)"

# A hole between the ranges
{
  hdr 110
  alist 128-2:110:0 128-0:111:6
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 40000  init_size: 40000\n'
  run 1000 4
} | put 110
{
  hdr 111 110
  printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident   size: 7  init_size: 0\n'
  run X 6 Filler
  run 2000 4
} | put 111
eq "split file with a hole between ranges is broken" "broken" "$(file_map 110 | awk 'NR == 1 {print $3}')"
# Two entries claim the same range
{
  hdr 120
  alist 128-2:120:0 128-0:121:4 128-0:122:4
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident   size: 32000  init_size: 32000\n'
  run 1000 4
} | put 120
for e in 121 122; do
  {
    hdr "$e" 120
    printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident   size: 7  init_size: 0\n'
    run X 4 Filler
    run "$((e * 10))" 4
  } | put "$e"
done
eq "overlapping ranges make the file broken" "broken" "$(file_map 120 | awk 'NR == 1 {print $3}')"
# A compressed file with an attribute list cannot be copied by pieces
{
  hdr 130
  alist 128-2:130:0 128-0:131:4
  printf 'Attributes: \nType: $DATA (128-2)   Name: N/A   Non-Resident, Compressed   size: 32000  init_size: 32000\n'
  run 1000 4
} | put 130
{
  hdr 131 130
  printf 'Attributes: \nType: $DATA (128-0)   Name: N/A   Non-Resident, Compressed   size: 7  init_size: 0\n'
  run X 4 Filler
  run 2000 4
} | put 131
eq "compressed + attribute list is broken (icat cannot be trusted either)" "broken" "$(file_map 130 | awk 'NR == 1 {print $3}')"

# Real output of The Sleuth Kit 4.12: 3 entries, 510 runs, a list with ranges 0/470/1126.
cp "$FX/real-split/65.istat" "$ISTAT_DIR/65.istat"
cp "$FX/real-split/537.istat" "$ISTAT_DIR/537.istat"
cp "$FX/real-split/1194.istat" "$ISTAT_DIR/1194.istat"
real="$(file_map 65)"
eq "real split file: kind and size" "6144000 6144000 split" "$(awk 'NR == 1 {print $1, $2, $3}' <<<"$real")"
eq "real split file: all 1500 clusters, no gaps" "1500" "$(sed 1d <<<"$real" | awk '{n += $3; if ($1 != e) bad = 1; e = $1 + $3} END {print (bad ? "gap" : n)}')"
eq "real split file: first piece" "0 6656 3" "$(sed -n 2p <<<"$real")"

# --- classify --------------------------------------------------------------------------------------
# File 70 occupies bytes [409600, 471040); file 72: real piece [2634*4096, 2644*4096).
printf '400000 410000\n' >"$T/r.txt"
out="$(printf '70\ta/b.bin\n' | classify "$T/r.txt")"
eq "classify: a range inside the file damages it" $'damaged\t70\t61340\t'"$MT"$'\ta/b.bin\t400' "$out"
printf '471040 480000\n' >"$T/r.txt"
eq "classify: a range right after the file does not" "intact" "$(printf '70\ta/b.bin\n' | classify "$T/r.txt" | cut -f1)"
printf '0 100\n' >"$T/r.txt"
eq "classify: a range before the file does not" "intact" "$(printf '70\ta/b.bin\n' | classify "$T/r.txt" | cut -f1)"
printf '0 1000\n' >"$T/r.txt"
eq "classify: a range over the sparse part does not damage" "intact" "$(printf '72\ts.bin\n' | classify "$T/r.txt" | cut -f1)"
printf '10790000 10800000\n' >"$T/r.txt"
eq "classify: a range over the real part of a sparse file does" "damaged" "$(printf '72\ts.bin\n' | classify "$T/r.txt" | cut -f1)"
printf '0 999999999999\n' >"$T/r.txt"
eq "classify: a resident file is never damaged by the data ranges" "intact" "$(printf '71\tr.txt\n' | classify "$T/r.txt" | cut -f1)"
eq "classify: a broken file is unknown" "unknown" "$(printf '110\tx\n' | classify "$T/r.txt" | cut -f1)"
eq "classify: an unreadable entry is unknown" $'unknown\t999\t\t\tp\t' "$(printf '999\tp\n' | classify "$T/r.txt")"
eq "classify: a '?/' path is unknown even if the entry is fine" "unknown" "$(printf '70\t?/lost.bin\n' | classify "$T/r.txt" | cut -f1)"
printf '1 2\n' >"$T/r.txt"
bs='dir\sub\tx\n.bin'
eq "classify: backslashes in paths survive (awk -v would mangle them)" "$bs" "$(printf '70\t%s\n' "$bs" | classify "$T/r.txt" | cut -f5)"
printf '400000 410000\n405000 420000\n600000 610000\n' >"$T/r.txt"
eq "classify: overlapping ranges are merged before counting" "damaged 10400" "$(printf '70\ta\n' | classify "$T/r.txt" | awk -F'\t' '{print $1, $6}')"
eq "classify with several files keeps their order" $'70\n71\n72' "$(printf '70\ta\n71\tb\n72\tc\n' | classify "$T/r.txt" | cut -f2)"

# --- file_byte_ranges -----------------------------------------------------------------------------
eq "file_byte_ranges: bytes of the pieces" "409600 471040" "$(file_byte_ranges 70-128-2)"
eq "file_byte_ranges: sparse pieces are skipped" "10788864 10829824" "$(file_byte_ranges 72)"
eq "file_byte_ranges of a split file (first three pieces)" $'4096000 4112384\n8192000 8208384\n12288000 12304384' "$(file_byte_ranges 80-128-2 | head -3)"

# --- tsk_files -----------------------------------------------------------------------------------------
fls() {
  printf 'r/r 4-128-1:\t$AttrDef\nd/d 11-144-2:\t$Extend\nr/r 25-144-2:\t$Extend/$ObjId:$O\n'
  printf 'd/d 60-144-1:\tdocs\n'
  printf 'r/r 64-128-2:\tdocs/read me.txt\n'
  printf 'r/r 65-128-2:\tdocs/big.bin\nr/r 65-128-3:\tdocs/big.bin\n'
  printf 'r/r 66-128-2:\tdocs/stream.txt\nr/r 66-128-5:\tdocs/stream.txt:Zone.Identifier\n'
  printf 'r/r 67-128-2:\tdocs/ghost.txt\n'
  printf 'r/r 68-128-2:\tdocs/tab\tname.bin\n'
  printf 'r/r 71-128-2:\tdocs/\xd0\xbf\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82.txt\n'
  printf 'r/r 72-128-2:\tdocs/unreadable-entry.txt\nr/r 73-128-2:\tdocs/not-in-ils.txt\n'
  printf 'V/V 99:\t$OrphanFiles\n'
}
ils() {
  printf 'class|host|device|start_time\nils|h||1\nst_ino|st_alloc|st_uid|st_gid|st_mtime|st_atime|st_ctime|st_crtime|st_mode|st_nlink|st_size\n'
  local i
  for i in 25 60 64 65 66 68 69 71; do printf '%s|a|0|0|0|0|0|0|555|1|10\n' "$i"; done
  printf '5|a|0|0|0|0|0|0|555|1|0\n67|f|0|0|0|0|0|0|555|0|10\n'
}
printf 'MFT Entry Header Values:\nEntry: 69        Sequence: 1\n$LogFile Sequence Number: 0\nAllocated File\nLinks: 1\n\n$FILE_NAME Attribute Values:\nFlags: Archive\nName: lost.bin\nParent MFT Entry: 5 \tSequence: 5\n' | put 69
# 67: the index entry points to an MFT entry that istat says is not in use (a ghost) -> dropped
printf 'MFT Entry Header Values:\nEntry: 67        Sequence: 2\n$LogFile Sequence Number: 0\nNot Allocated File\nLinks: 0\n' | put 67
# 73: not in the ils list, but istat says it is in use -> kept; 72: the entry cannot be read -> kept (file_map says unknown)
printf 'MFT Entry Header Values:\nEntry: 73        Sequence: 1\n$LogFile Sequence Number: 0\nAllocated File\nLinks: 1\n' | put 73
expected=$'64-128-2\tdocs/read me.txt\n65-128-2\tdocs/big.bin\n66-128-2\tdocs/stream.txt\n68-128-2\t?/entry 68\n71-128-2\tdocs/привет.txt\n72-128-2\tdocs/unreadable-entry.txt\n73-128-2\tdocs/not-in-ils.txt\n69\t?/lost.bin'
eq "tsk_files: system files, streams, duplicates and ghosts are dropped; unreadable or unlisted-but-used entries are kept; unlisted entries become ?/NAME" "$expected" "$(tsk_files)"
# ils failing or empty must not drop everything
ils() { return 1; }
out_all="$(tsk_files 2>/dev/null)"
check "tsk_files: without ils nothing is dropped except verified ghosts" contains "$out_all" $'66-128-2\tdocs/stream.txt'
check "...and the verified ghost is still dropped" bash -c '[[ $1 != *"ghost.txt"* ]]' _ "$out_all"
ils() {
  printf 'class|host|device|start_time\nils|h||1\nst_ino|st_alloc|st_uid|st_gid|st_mtime|st_atime|st_ctime|st_crtime|st_mode|st_nlink|st_size\n'
  local i
  for i in 25 60 64 65 66 68 69 71; do printf '%s|a|0|0|0|0|0|0|555|1|10\n' "$i"; done
  printf '5|a|0|0|0|0|0|0|555|1|0\n67|f|0|0|0|0|0|0|555|0|10\n'
}

# --- file_stream and extract_files on a synthetic image -------------------------------------------------
head -c $((600 * 1024)) /dev/urandom >"$img"
fmap_simple="$(file_map 70)"
file_stream "$fmap_simple" 70 >"$T/s1"
dd if="$img" bs=1 skip=409600 count=61340 status=none >"$T/s1.expect"
check "file_stream: a simple file equals the image bytes" cmp -s "$T/s1" "$T/s1.expect"
file_stream "$(file_map 72)" 72 >"$T/s2"
{ head -c $((40 * 4096)) /dev/zero; dd if="$img" bs=4096 skip=2634 count=10 status=none; } >"$T/s2.expect"
check "file_stream: a sparse piece is zeros" cmp -s "$T/s2" "$T/s2.expect"
file_stream "$(file_map 75)" 75 >"$T/s3"
{ dd if="$img" bs=4096 skip=300 count=2 status=none; } >"$T/s3.expect"
head -c $((20000 - 8192)) /dev/zero >>"$T/s3.expect"
check "file_stream: zeros from init_size to size" cmp -s "$T/s3" "$T/s3.expect"
# A split file: the pieces of three MFT entries, read from the image in order
head -c $((14 * 1024 * 1024)) /dev/urandom >"$img"
file_stream "$(file_map 80)" 80 >"$T/s4"
{ for lcn in 1000 2000 3000; do dd if="$img" bs=4096 skip=$lcn count=4 status=none; done; } | head -c 49142 >"$T/s4.expect"
check "file_stream: a split file is the pieces of all its entries in order" cmp -s "$T/s4" "$T/s4.expect"

# A bigger synthetic image for extraction: clusters 0..399
head -c $((400 * 4096)) /dev/urandom >"$img"
printf 'sEDU' | dd of="$img" bs=1 seek=$((105 * 4096 + 512)) conv=notrunc status=none
head -c 504 /dev/zero | dd of="$img" bs=1 seek=$((105 * 4096 + 516)) conv=notrunc status=none
printf 'sEDU' | dd of="$img" bs=1 seek=$((105 * 4096 + 1020)) conv=notrunc status=none
parse_args --extract --extract-to "$T/out" /dev/null
validate_args
extract_to="$T/out"
mkdir -p "$extract_to"
owner="" RUN_AS=()
printf 'intact\t70\t61340\t%s\tmovies/a.bin\t0\ndamaged\t75\t20000\t%s\tmovies/b.bin\t5\nintact\t110\t40000\t%s\tmovies/broken.bin\t0\nintact\t74\t8192\t%s\tother/c.bin\t0\n' "$MT" "$MT" "$MT" "$MT" >"$T/files.tsv"
extract_files "$T/files.tsv" 1 >/dev/null
check "extract_files: an intact file is extracted" test -f "$extract_to/movies/a.bin"
check "extract_files: a damaged file is not extracted when only intact are wanted" test ! -e "$extract_to/movies/b.bin"
check "extract_files: a broken file is not extracted" test ! -e "$extract_to/movies/broken.bin"
dd if="$img" bs=1 skip=409600 count=61340 status=none 2>/dev/null >"$T/a.expect"
# cluster 100..114 is beyond the 400-cluster image? no: 100*4096 = 409600 < 1638400
check "extract_files: the content equals the image data" cmp -s "$extract_to/movies/a.bin" "$T/a.expect"
eq "extract_files: modification time comes from the volume" "$(date -d "$MT UTC" +%s)" "$(stat -c %Y "$extract_to/movies/a.bin")"
eq "extract_files: file mode" "664" "$(stat -c %a "$extract_to/movies/a.bin")"
eq "extract_files: directory mode" "775" "$(stat -c %a "$extract_to/movies")"
check "extract_files: no .part file is left" test ! -e "$extract_to/movies/a.bin.part"
eq "extract_files: the garbage sector is reported as suspicious" "movies/a.bin" "$(cat "$logs/suspicious-files.txt")"
out="$(extract_files "$T/files.tsv" 1)"
check "extract_files: a second run skips what is in place" contains "$out" "already in place: 2"
extract_files "$T/files.tsv" 0 >/dev/null
check "extract_files: without the filter damaged files are extracted too" test -f "$extract_to/movies/b.bin"
# --include / --map
rm -rf "${extract_to:?}"/*
includes=("movies")
extract_files "$T/files.tsv" 1 >/dev/null
check "--include keeps matching files" test -f "$extract_to/movies/a.bin"
check "--include drops the others" test ! -e "$extract_to/other/c.bin"
includes=()
maps=("other:renamed/deep")
rm -rf "${extract_to:?}"/*
extract_files "$T/files.tsv" 1 >/dev/null
check "--map renames the destination" test -f "$extract_to/renamed/deep/c.bin"
check "--map drops what it does not match" test ! -e "$extract_to/movies/a.bin"
maps=()

# --- --verify: hashes, the manifest, a file changed in place, a failing verification
verify=1 MANIFEST="$logs/manifest.sha256" STREAM_SHA="$T/stream.sha"
rm -rf "${extract_to:?}"/*
rm -f "$MANIFEST"
out="$(extract_files "$T/files.tsv" 1)"
check "verify: the summary names the verified files" contains "$out" "verified by SHA-256: 2 new files"
want="$(sha256sum "$T/a.expect" | cut -d' ' -f1)"
eq "verify: the manifest has the hash in sha256sum format" "$want  movies/a.bin" "$(grep ' movies/a.bin$' "$MANIFEST")"
check "verify: the manifest passes sha256sum -c" bash -c "cd '$extract_to' && sha256sum -c --quiet '$MANIFEST'"
out="$(extract_files "$T/files.tsv" 1)"
check "verify: files in place are checked and kept" contains "$out" "already in place: 2"
# a copy changed in place with the same size and time (a write cut short, a bad bridge)
epoch="$(stat -c %Y "$extract_to/movies/a.bin")"
printf 'Z' | dd of="$extract_to/movies/a.bin" bs=1 seek=100 conv=notrunc status=none
touch -d "@$epoch" "$extract_to/movies/a.bin"
verify=0
extract_files "$T/files.tsv" 1 >/dev/null
check "without --verify the changed copy goes unnoticed (size and time match)" bash -c "! cmp -s '$extract_to/movies/a.bin' '$T/a.expect'"
verify=1
out="$(extract_files "$T/files.tsv" 1)"
check "with --verify it is found" contains "$out" "extracting it again"
check "...and extracted again, correctly" cmp -s "$extract_to/movies/a.bin" "$T/a.expect"
# a file without a manifest entry is checked against the image
grep -v ' movies/a.bin$' "$MANIFEST" >"$MANIFEST.new"
mv "$MANIFEST.new" "$MANIFEST"
printf 'Z' | dd of="$extract_to/movies/a.bin" bs=1 seek=100 conv=notrunc status=none
touch -d "@$epoch" "$extract_to/movies/a.bin"
out="$(extract_files "$T/files.tsv" 1)"
check "...also without a manifest entry (against the image)" contains "$out" "extracting it again"
check "...and corrected" cmp -s "$extract_to/movies/a.bin" "$T/a.expect"
# a verification that fails: the copy is removed and the run fails
# shellcheck disable=SC2317 # called indirectly by extract_files
sha256sum() { if [[ ${1:-} == -- ]]; then echo "0000  $2"; else command sha256sum "$@"; fi; }
rm -rf "${extract_to:?}"/*
rm -f "$MANIFEST"
( extract_files "$T/files.tsv" 1 ) >"$T/verify-fail.out" 2>&1
eq "a failed verification fails the run" 1 "$?"
check "...says so" contains "$(cat "$T/verify-fail.out")" "VERIFICATION FAILED"
check "...and removes the copy" test ! -e "$extract_to/movies/a.bin"
unset -f sha256sum
verify=0

# --- dest_for --------------------------------------------------------------------------------------------
extract_to=/out includes=() maps=()
eq "dest_for: the tree is preserved" "/out/a/b.txt" "$(dest_for a/b.txt)"
includes=(a)
eq "dest_for: --include matches a directory" "/out/a/b.txt" "$(dest_for a/b.txt)"
eq "dest_for: --include does not match a longer name" "" "$(dest_for ab/c.txt)"
includes=(a/b.txt)
eq "dest_for: --include matches a file" "/out/a/b.txt" "$(dest_for a/b.txt)"
includes=() maps=("a/b:x")
eq "dest_for: --map" "/out/x/c.txt" "$(dest_for a/b/c.txt)"
eq "dest_for: --map filters" "" "$(dest_for z/c.txt)"
maps=("a:")
eq "dest_for: --map to the root" "/out/c.txt" "$(dest_for a/c.txt)"
maps=("a:x") includes=(z)
eq "dest_for: --map and --include are alternatives" "/out/z/q" "$(dest_for z/q)"
eq "dest_for: a path with .. is refused" "" "$(dest_for a/../etc/passwd)"
includes=() maps=()
eq "dest_for: unknown '?/' rows are never extracted" "" "$(dest_for '?/orphan.bin')"
maps=("one/file.txt:there")
eq "dest_for: --map of a single file puts it into the directory" "/out/there/file.txt" "$(dest_for one/file.txt)"
maps=()

# --- short_name -----------------------------------------------------------------------------------------
eq "short_name: short names stay" "movies/a.mkv" "$(short_name movies/a.mkv)"
long="$(printf 'x%.0s' {1..80})"
eq "short_name: long names are cut to 60 characters" 60 "$(LC_ALL=C.UTF-8 bash -c 'x=$1; echo ${#x}' _ "$(short_name "$long")")"
cyr="$(printf 'ы%.0s' {1..80})"
eq "short_name: counts characters, not bytes" 60 "$(LC_ALL=C.UTF-8 bash -c 'x=$1; echo ${#x}' _ "$(short_name "$cyr")")"

finish
