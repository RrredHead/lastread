#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The file level on a real NTFS volume (built with mkntfs + ntfs-3g): ordinary, resident, sparse,
# compressed and heavily fragmented files ($ATTRIBUTE_LIST), extraction byte for byte, damaged files
# (unreadable areas), the inventory without the disk, targeted recovery (--file and --pick),
# silent garbage, filters and the owner of extracted files.
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

echo "building the NTFS fixture..."
build_ntfs_volume
SIZE=$((96 * M))
check "the fixture has files" test "${#REF_FILES[@]}" -ge 9
rec_frag="$(ntfs_rec "$VOL" media/frag1.bin)"
check "frag1.bin has an \$ATTRIBUTE_LIST (pieces in other MFT entries)" bash -c "istat -r '$VOL' '$rec_frag' | grep -E '^Type: 128-[0-9]+[[:space:]]+MFT Entry: [0-9]+' | grep -v 'MFT Entry: $rec_frag' >/dev/null"
loop="$(loop_attach "$VOL")"
disk="$(dm_create ntfs "$(dm_linear "$loop" 0 $SIZE)")"
chmod 755 "$W"
mkout() { # mkout DIR...: output directories writable by any owner
  mkdir -p "$@"
  chmod 777 "$@"
}

# === A. a healthy volume: image, report, extraction ============================================================
D="$W/a"
OUTA="$W/outa"
mkout "$D" "$OUTA"
tool "$disk" --dir "$D" --name vol --interval 1 --no-temp --extract --extract-to "$OUTA" --owner nobody
rc_is "A: image, report and extraction finish" 0
check "A: the volume is recognised as NTFS (no skip message)" bash -c "! grep -F 'file level supports NTFS only' '$OUT' >/dev/null"
check "A: the unreadable areas touched no file (none exist)" out_has "the unreadable areas touched no file"
check "A: the image equals the volume" cmp -s "$VOL" "$D/vol.img"
diffs="$(compare_tree "$REF" "$OUTA")"
eq "A: every file is extracted byte for byte with its modification time" "" "$diffs"
eq "A: nothing but the originals is extracted" "${#REF_FILES[@]}" "$(find "$OUTA" -type f | wc -l)"
eq "A: extracted files belong to --owner" "nobody" "$(stat -c %U "$OUTA/media/movie1.mkv")"
eq "A: file mode" "664" "$(stat -c %a "$OUTA/media/movie1.mkv")"
eq "A: directory mode" "775" "$(stat -c %a "$OUTA/media")"
check "A: no .part files are left" bash -c "[[ -z \$(find '$OUTA' -name '*.part') ]]"
# a sparse file has a long run of zeros by design: the zero-run heuristic flags it (documented)
eq "A: only the sparse file is flagged as suspicious (long zero run)" "media/sparse.bin" "$(cat "$D/vol.logs/suspicious-files.txt")"
eq "A: files.tsv lists every file as intact" "${#REF_FILES[@]}" "$(awk -F'\t' '$1 == "intact"' "$D/vol.logs/files.tsv" | wc -l)"
check "A: the fragmented file is a split file with all pieces" bash -c "awk -F'\t' '\$5 == \"media/frag1.bin\" {print \$1}' '$D/vol.logs/files.tsv' | grep -x intact >/dev/null"
check "A: no phantom ?/ entries (extension MFT entries are not files)" bash -c "! grep -F '?/' '$D/vol.logs/files.tsv' >/dev/null"

# a second extraction (inventory mode, no disk) finds everything in place
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTA" --owner nobody
rc_is "A: inventory without the disk" 0
check "A: the inventory reports everything as whole" out_has "rescued whole: ${#REF_FILES[@]}, incomplete: 0"
check "A: a second extraction finds everything in place" out_has "already in place: ${#REF_FILES[@]}"

check "A: the inventory prints counts per top-level directory" out_has "media/: whole"
tool --inventory --dir "$D" --name vol --include media/sub
rc_is "A: --inventory --include prints counts for the path" 0
check "A: ...the count for it" out_has "media/sub/: whole 1, incomplete 0"

# the image name is found by itself when the directory holds exactly one map
tool --inventory --dir "$D"
rc_is "A: --inventory without --name finds the only image" 0

# an inventory by a normal user (the directory belongs to the user)
cp -a "$D" "$W/nr"
chown -R nobody "$W/nr"
chmod 755 "$W"
cp "$TOOL" "$W/tool-copy"
chmod 755 "$W/tool-copy"
runuser -u nobody -- "$W/tool-copy" --inventory --dir "$W/nr" --name vol >"$OUT" 2>&1
RC=$?
rc_is "A: an inventory needs no root" 0
check "A: ...and finds the files" out_has "rescued whole: ${#REF_FILES[@]}, incomplete: 0"

# --include / --map
OUTI="$W/outi"
mkout "$OUTI"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTI" --owner root --include media/sub --map docs/notes:renamed/notes
rc_is "A: --include and --map" 0
check "A: --include extracts the directory" cmp -s "$REF/media/sub/clip.bin" "$OUTI/media/sub/clip.bin"
check "A: --map renames the destination" cmp -s "$REF/docs/notes/план.txt" "$OUTI/renamed/notes/план.txt"
eq "A: nothing else is extracted" 2 "$(find "$OUTI" -type f | wc -l)"

# === B. damaged files: unreadable areas inside two files =========================================================
mapfile -t movie2_runs < <(ntfs_runs "$VOL" media/movie2.mkv)
mapfile -t clip_runs < <(ntfs_runs "$VOL" media/sub/clip.bin)
read -r m2s m2l <<<"${movie2_runs[0]}"
read -r cls cll <<<"${clip_runs[0]}"
# 64 KiB inside movie2, 64 KiB inside clip.bin
bad1="$((m2s + m2l / 2 / 4096 * 4096)) 65536"
bad2="$((cls + cll / 2 / 4096 * 4096)) 65536"
mapfile -t table < <(dm_table_with_errors "$loop" $SIZE "$bad1" "$bad2")
dm_load ntfs "${table[@]}"
D="$W/b"
OUTB="$W/outb"
mkout "$D" "$OUTB"
tool "$disk" --dir "$D" --name vol --interval 1 --no-temp --extract --extract-to "$OUTB"
rc_is "B: the run with unreadable areas finishes" 0
check "B: the report names movie2" grep -Fx "media/movie2.mkv" "$D/vol.logs/damaged-files.txt"
check "B: the report names clip.bin" grep -Fx "media/sub/clip.bin" "$D/vol.logs/damaged-files.txt"
eq "B: exactly two damaged files" 2 "$(wc -l <"$D/vol.logs/damaged-files.txt")"
check "B: a damaged file is not extracted" test ! -e "$OUTB/media/movie2.mkv"
diffs="$(compare_tree "$REF" "$OUTB" media/movie2.mkv media/sub/clip.bin)"
eq "B: all other files are extracted correctly" "" "$diffs"
eq "B: the unreadable area is 2 x 64 KiB" 131072 "$(decmap "$D/vol.map" | awk '$3 == "-" {s += $2} END {print s + 0}')"

# --extract-damaged (a normal run): the damaged file is extracted too, unreadable parts are zeros
D5="$W/b2"
OUTB2="$W/outb2"
mkout "$D5" "$OUTB2"
tool "$disk" --dir "$D5" --name vol --interval 1 --no-temp --extract --extract-damaged --extract-to "$OUTB2"
rc_is "B: --extract-damaged finishes" 0
off=$((m2l / 2 / 4096 * 4096))
movie2_size="$(stat -c %s "$REF/media/movie2.mkv")"
eq "B: --extract-damaged extracts the damaged file with its full size" "$movie2_size" "$(stat -c %s "$OUTB2/media/movie2.mkv")"
check "B: ...the bytes before the unreadable area are right" same_bytes "$REF/media/movie2.mkv" "$OUTB2/media/movie2.mkv" 0 "$off"
check "B: ...the bytes after it are right" same_bytes "$REF/media/movie2.mkv" "$OUTB2/media/movie2.mkv" $((off + 65536)) $((movie2_size - off - 65536))
check "B: ...the unreadable area is zeros" bash -c "dd if='$OUTB2/media/movie2.mkv' bs=4096 skip=$((off / 4096)) count=16 status=none | cmp -s - <(head -c 65536 /dev/zero)"

# inventory by the image, without the disk
tool --inventory --dir "$D" --name vol
rc_is "B: inventory without the disk" 0
check "B: the inventory knows two incomplete files" out_has "incomplete: 2"
check "B: movie2 is in the incomplete list" grep -Fx "media/movie2.mkv" "$D/vol.logs/inventory-incomplete.txt"
check "B: the intact list has the rest" test "$(wc -l <"$D/vol.logs/inventory-intact.txt")" -eq $((${#REF_FILES[@]} - 2))

# === C. targeted recovery: the disk heals, only the chosen file is read ========================================
dm_load ntfs "$(dm_linear "$loop" 0 $SIZE)"
map_before="$(md5sum <"$D/vol.map")"
tool "$disk" --dir "$D" --name vol --interval 1 --no-temp --file movie2 --extract --extract-to "$OUTB"
rc_is "C: --file recovers the chosen file" 0
check "C: it announces the selection" out_has "targeted recovery, files: 1"
check "C: movie2 is whole now" cmp -s "$REF/media/movie2.mkv" "$OUTB/media/movie2.mkv"
check "C: movie2 has its modification time" test "$(stat -c %Y "$REF/media/movie2.mkv")" = "$(stat -c %Y "$OUTB/media/movie2.mkv")"
check "C: clip.bin was not touched (still unreadable in the map)" test ! -e "$OUTB/media/sub/clip.bin"
check "C: the map changed" test "$(md5sum <"$D/vol.map")" != "$map_before"
eq "C: only clip.bin's 64 KiB remain unreadable" 65536 "$(decmap "$D/vol.map" | awk '$3 == "-" {s += $2} END {print s + 0}')"

# --pick: the plain prompt through a pty (script), choosing the first candidate
printf '1\n' >"$W/answers"
LASTREAD_PLAIN=1 script -qec "$TOOL $disk --dir $D --name vol --interval 1 --no-temp --pick --extract --extract-to $OUTB" /dev/null <"$W/answers" >"$OUT" 2>&1
RC=$?
rc_is "C: --pick recovers the chosen file" 0
check "C: --pick offers the incomplete file" out_has "clip.bin"
check "C: clip.bin is whole now" cmp -s "$REF/media/sub/clip.bin" "$OUTB/media/sub/clip.bin"
diffs="$(compare_tree "$REF" "$OUTB")"
eq "C: after both rescues the extracted tree equals the original" "" "$diffs"
# the targeted runs made the earlier report out of date: a normal run does it again
check "C: the old file list is gone after targeted recovery" test ! -e "$D/vol.logs/files.tsv"
check "C: ...and the report is to be done again" test ! -e "$D/vol.logs/report.done"
OUTC="$W/outc"
mkout "$OUTC"
tool "$disk" --dir "$D" --name vol --interval 1 --no-temp --extract --extract-to "$OUTC"
rc_is "C: a normal run after targeted recovery extracts everything that is whole now" 0
diffs="$(compare_tree "$REF" "$OUTC")"
eq "C: ...all of it (no stale damaged list)" "" "$diffs"
tool "$disk" --dir "$D" --name vol --interval 1 --no-temp --file nothing-matches
check "C: --file with no match reports nothing to recover" out_has "no incomplete files — nothing to recover selectively"

# === D. silent garbage: a service sector and a long run of zeros inside files ===================================
cp "$VOL" "$W/garbage.img"
mapfile -t gr1 < <(ntfs_runs "$W/garbage.img" "docs/my file with spaces.bin")
read -r gs1 _ <<<"${gr1[0]}"
mapfile -t gr2 < <(ntfs_runs "$W/garbage.img" media/sub/clip.bin)
read -r gs2 _ <<<"${gr2[0]}"
{ printf 'sEDU'; head -c 504 /dev/zero; printf 'sEDU'; } | dd of="$W/garbage.img" bs=1 seek=$((gs1 + 8192)) conv=notrunc status=none
head -c $((128 * 1024)) /dev/zero | dd of="$W/garbage.img" bs=1 seek=$((gs2 + 4096)) conv=notrunc status=none
loopg="$(loop_attach "$W/garbage.img")"
diskg="$(dm_create garbage "$(dm_linear "$loopg" 0 $SIZE)")"
D="$W/d"
OUTD="$W/outd"
mkout "$D" "$OUTD"
tool "$diskg" --dir "$D" --name garbage --interval 1 --no-temp --extract --extract-to "$OUTD"
rc_is "D: a volume with silent garbage is imaged and extracted" 0
printf '%s\n' "docs/my file with spaces.bin" "media/sparse.bin" "media/sub/clip.bin" | sort >"$W/expect-suspicious"
check "D: the garbage files (and the sparse file) are listed as suspicious" cmp -s "$W/expect-suspicious" "$D/garbage.logs/suspicious-files.txt"
check "D: the garbage files are still extracted" test -f "$OUTD/media/sub/clip.bin"
check "D: extraction equals the (modified) image content" cmp -s "$W/garbage.img" "$D/garbage.img"
# the check can be changed or turned off
OUTD2="$W/outd2"
D2="$W/d2"
mkout "$OUTD2" "$D2"
tool --inventory --dir "$D" --name garbage --extract --extract-to "$OUTD2" --no-suspect-check
rc_is "D: --no-suspect-check" 0
check "D: ...lists nothing new (the list is only appended to)" bash -c "! grep -F 'suspicious data inside' '$OUT' >/dev/null"

# === D2. an image shorter than the partition (the rescue has not reached the end yet) ======================
D="$W/short"
mkdir -p "$D"
cp "$W/a/vol.map" "$D/short.map"
head -c $((40 * M)) "$W/a/vol.img" >"$D/short.img"
tool --inventory --dir "$D" --name short
rc_is "D2: an inventory of an image that ends early works" 0
eq "D2: the image was extended (sparse) to the size of the partition" $SIZE "$(stat -c %s "$D/short.img")"
check "D2: files are listed" out_has "files in the image:"

# === E. other file systems and partition tables ===============================================================
truncate -s $((32 * M)) "$W/ext4.img"
mkfs.ext4 -q -F "$W/ext4.img" >/dev/null 2>&1
loope="$(loop_attach "$W/ext4.img")"
diske="$(dm_create ext4 "$(dm_linear "$loope" 0 $((32 * M)))")"
D="$W/e"
OUTE="$W/oute"
mkout "$D" "$OUTE"
tool "$diske" --dir "$D" --name ext4 --interval 1 --no-temp --extract --extract-to "$OUTE"
rc_is "E: an ext4 disk is imaged" 0
check "E: the file level is skipped with a clear message" bash -c "grep -E 'file system is .*: the file level supports NTFS only' '$OUT' >/dev/null"
check "E: the image equals the disk" cmp -s "$W/ext4.img" "$D/ext4.img"
check "E: the skipped file level does not leave a report to redo" test -e "$D/ext4.logs/report.done"
tool --inventory --dir "$D" --name ext4
rc_is "E: an explicit --inventory on a file system without a file level fails" 1
check "E: ...with a message" out_has "no file level for this image"
eq "E: nothing is extracted" 0 "$(find "$OUTE" -type f | wc -l)"
truncate -s $((40 * M)) "$W/parted.img"
printf 'label: dos\n,32M,7\n' | sfdisk -q "$W/parted.img" >/dev/null 2>&1
loopp="$(loop_attach "$W/parted.img")"
diskp="$(dm_create parted "$(dm_linear "$loopp" 0 $((40 * M)))")"
D="$W/e2"
mkdir -p "$D"
tool "$diskp" --dir "$D" --name parted --interval 1 --no-temp --extract --extract-to "$OUTE"
rc_is "E: a whole disk with a partition table is imaged" 0
check "E: ...with a hint to image the partition" out_has "the image has a partition table"

finish
