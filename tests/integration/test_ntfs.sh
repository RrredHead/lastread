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

# --verify: hashes in a manifest, and a copy changed in place is found
OUTV="$W/outv"
mkout "$OUTV"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTV" --owner root --verify
rc_is "A: extraction with --verify" 0
check "A: ...everything was verified" out_has "verified by SHA-256: ${#REF_FILES[@]} new files"
check "A: ...the manifest passes sha256sum -c" bash -c "cd '$OUTV' && sha256sum -c --quiet '$D/vol.logs/manifest.sha256'"
epoch="$(stat -c %Y "$OUTV/media/movie1.mkv")"
printf 'Z' | dd of="$OUTV/media/movie1.mkv" bs=1 seek=12345 conv=notrunc status=none
touch -d "@$epoch" "$OUTV/media/movie1.mkv"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTV" --owner root
check "A: without --verify the changed copy is left (size and time match)" bash -c "! cmp -s '$REF/media/movie1.mkv' '$OUTV/media/movie1.mkv'"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTV" --owner root --verify --overwrite
rc_is "A: with --verify and --overwrite the run repairs it" 0
check "A: ...the changed copy was noticed" out_has "replacing existing file"
check "A: ...and extracted again, byte for byte" cmp -s "$REF/media/movie1.mkv" "$OUTV/media/movie1.mkv"

# --include / --map
OUTI="$W/outi"
mkout "$OUTI"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTI" --owner root --include media/sub --map docs/notes:renamed/notes
rc_is "A: --include and --map" 0
check "A: --include extracts the directory" cmp -s "$REF/media/sub/clip.bin" "$OUTI/media/sub/clip.bin"
check "A: --map renames the destination" cmp -s "$REF/docs/notes/план.txt" "$OUTI/renamed/notes/план.txt"
eq "A: nothing else is extracted" 2 "$(find "$OUTI" -type f | wc -l)"

# Existing files and symlinks must not put unrelated data at risk.
OUTSAFE="$W/outsafe"
mkout "$OUTSAFE" "$OUTSAFE/media/sub" "$W/outside"
printf 'existing data' >"$OUTSAFE/media/sub/clip.bin"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTSAFE" --owner root --include media/sub/clip.bin
rc_is "A: a conflicting destination is refused" 1
eq "A: the conflicting file is unchanged" 'existing data' "$(cat "$OUTSAFE/media/sub/clip.bin")"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTSAFE" --owner root --include media/sub/clip.bin --overwrite
rc_is "A: explicit overwrite replaces a regular file" 0
check "A: overwritten file equals the image" cmp -s "$REF/media/sub/clip.bin" "$OUTSAFE/media/sub/clip.bin"
rm "$OUTSAFE/media/sub/clip.bin"
printf 'outside data' >"$W/outside/victim"
ln -s "$W/outside/victim" "$OUTSAFE/media/sub/clip.bin.part"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTSAFE" --owner root --include media/sub/clip.bin
rc_is "A: an old predictable .part symlink is not used" 0
eq "A: the symlink target is unchanged" 'outside data' "$(cat "$W/outside/victim")"
check "A: the extracted file is correct despite the old symlink" cmp -s "$REF/media/sub/clip.bin" "$OUTSAFE/media/sub/clip.bin"
rm "$OUTSAFE/media/sub/clip.bin"
ln -s "$W/outside/victim" "$OUTSAFE/media/sub/clip.bin"
tool --inventory --dir "$D" --name vol --extract --extract-to "$OUTSAFE" --owner root --include media/sub/clip.bin --overwrite
rc_is "A: even --overwrite refuses a destination symlink" 1
eq "A: the destination symlink target is unchanged" 'outside data' "$(cat "$W/outside/victim")"

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
mkmap "$D/short.map" <<M
0 $((40 * M)) +
$((40 * M)) $((SIZE - 40 * M)) ?
M
head -c $((40 * M)) "$W/a/vol.img" >"$D/short.img"
tool --inventory --dir "$D" --name short
rc_is "D2: an inventory of an image that ends early works" 0
eq "D2: the image was extended (sparse) to the size of the partition" $SIZE "$(stat -c %s "$D/short.img")"
check "D2: files are listed" out_has "files in the image:"

# garbage found in the image makes the files that touch it damaged
OUTD3="$W/outd3"
D3="$W/d3"
mkout "$OUTD3" "$D3"
tool "$diskg" --dir "$D3" --name garbage --interval 1 --no-temp --recheck-garbage --extract --extract-to "$OUTD3"
rc_is "D: --recheck-garbage on a volume with a service sector inside a file" 0
check "D: the file with the service sector is damaged" grep -Fx "docs/my file with spaces.bin" "$D3/garbage.logs/damaged-files.txt"
check "D: ...and is not extracted" test ! -e "$OUTD3/docs/my file with spaces.bin"
check "D: the file with only a long run of zeros is not touched by the scan" test -f "$OUTD3/media/sub/clip.bin"

# === E. other file systems and partition tables ===============================================================
# a volume with a file system the file level cannot read (minix): imaged, the file level is skipped
truncate -s $((32 * M)) "$W/minix.img"
mkfs.minix "$W/minix.img" >/dev/null 2>&1
loope="$(loop_attach "$W/minix.img")"
diske="$(dm_create minix "$(dm_linear "$loope" 0 $((32 * M)))")"
D="$W/e"
OUTE="$W/oute"
mkout "$D" "$OUTE"
tool "$diske" --dir "$D" --name minix --interval 1 --no-temp --extract --extract-to "$OUTE"
rc_is "E: a disk with an unsupported file system is imaged" 0
check "E: the file level is skipped with a clear message" out_has "holds no file system the file level can read"
check "E: the image equals the disk" cmp -s "$W/minix.img" "$D/minix.img"
check "E: the skipped file level does not leave a report to redo" test -e "$D/minix.logs/report.done"
tool --inventory --dir "$D" --name minix
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
check "E: ...and says that no partition holds a supported file system" out_has "no partition with a supported file system in the image"

# === F. whole-disk images: the NTFS volume is found through the partition table =================================
# one NTFS partition and one with no recognisable file system
truncate -s $((1 + 96 + 8 + 1))M "$W/whole1.img"
dd if="$VOL" of="$W/whole1.img" bs=1M seek=1 conv=notrunc status=none
head -c 8M /dev/urandom | dd of="$W/whole1.img" bs=1M seek=97 conv=notrunc status=none # a partition with no file system
printf 'label: dos\nstart=2048, size=196608, type=7\nstart=198656, size=16384, type=83\n' | sfdisk -q "$W/whole1.img" >/dev/null 2>&1
loopw="$(loop_attach "$W/whole1.img")"
diskw="$(dm_create whole1 "$(dm_linear "$loopw" 0 $(((1 + 96 + 8 + 1) * M)))")"
D="$W/f1"
OUTF="$W/outf1"
mkout "$D" "$OUTF"
tool "$diskw" --dir "$D" --name whole1 --interval 1 --no-temp --extract --extract-to "$OUTF"
rc_is "F: a whole-disk image with one NTFS partition: image, report, extraction" 0
check "F: the partition is found" out_has "the file level works on partition 1 of the image"
diffs="$(compare_tree "$REF" "$OUTF")"
eq "F: every file is extracted from the partition, byte for byte" "" "$diffs"
tool --inventory --dir "$D" --name whole1
rc_is "F: an inventory of the whole-disk image" 0
check "F: ...finds all files whole" out_has "rescued whole: ${#REF_FILES[@]}, incomplete: 0"

# two NTFS partitions: --partition decides
truncate -s $((1 + 96 + 96 + 1))M "$W/whole2.img"
dd if="$VOL" of="$W/whole2.img" bs=1M seek=1 conv=notrunc status=none
dd if="$VOL" of="$W/whole2.img" bs=1M seek=97 conv=notrunc status=none
printf 'label: dos\nstart=2048, size=196608, type=7\nstart=198656, size=196608, type=7\n' | sfdisk -q "$W/whole2.img" >/dev/null 2>&1
loopw2="$(loop_attach "$W/whole2.img")"
diskw2="$(dm_create whole2 "$(dm_linear "$loopw2" 0 $(((1 + 96 + 96 + 1) * M)))")"
D="$W/f2"
OUTF2="$W/outf2"
mkout "$D" "$OUTF2"
tool "$diskw2" --dir "$D" --name whole2 --interval 1 --no-temp --extract --extract-to "$OUTF2"
rc_is "F: two NTFS partitions: the disk is imaged anyway" 0
check "F: ...the file level asks to choose" out_has "choose one with --partition N"
tool --inventory --dir "$D" --name whole2
rc_is "F: an explicit --inventory without --partition fails" 1
tool --inventory --dir "$D" --name whole2 --partition 2 --extract --extract-to "$OUTF2"
rc_is "F: with --partition 2" 0
diffs="$(compare_tree "$REF" "$OUTF2")"
eq "F: the second volume is extracted byte for byte" "" "$diffs"

# 4096-byte logical sectors and a GPT
truncate -s $((1 + 96 + 1))M "$W/whole3.img"
loop4="$(loop_attach "$W/whole3.img" --sector-size 4096)"
printf 'label: gpt\nstart=1MiB, size=96MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' | sfdisk -q "$loop4" >/dev/null 2>&1
dd if="$VOL" of="$W/whole3.img" bs=1M seek=1 conv=notrunc status=none
disk4="$(dm_create whole3 "$(dm_linear "$loop4" 0 $(((1 + 96 + 1) * M)))")"
if [[ "$(blockdev --getss "$disk4")" == 4096 ]]; then
  D="$W/f3"
  OUTF3="$W/outf3"
  mkout "$D" "$OUTF3"
  tool "$disk4" --dir "$D" --name whole3 --interval 1 --no-temp --extract --extract-to "$OUTF3"
  rc_is "F: a GPT disk with 4096-byte sectors: image, report, extraction" 0
  check "F: ...ddrescue got the sector size" out_has "-b 4096"
  check "F: ...the partition is found" out_has "the file level works on partition 1 of the image"
  diffs="$(compare_tree "$REF" "$OUTF3")"
  eq "F: ...every file extracted byte for byte" "" "$diffs"
  tool --inventory --dir "$D" --name whole3
  rc_is "F: an inventory of a 4096-sector image finds the partition again (sector size from the logs)" 0
else
  skip "F: the device-mapper device does not report 4096-byte sectors"
fi

# === G. metadata first ===========================================================================================
# A slow disk: the structures of the volume and the --first path are read before the bulk.
slowvol="$(dm_create metaslow "$(dm_delay "$loop" 0 $SIZE 15)")"
D="$W/g1"
mkdir -p "$D"
"$TOOL" "$slowvol" --dir "$D" --name metavol --interval 1 --no-temp --first media/sub >"$W/g1.out" 2>&1 &
pid=$!
for _ in $(seq 1 240); do
  if grep -Fx media/sub "$D/metavol.logs/first.done" >/dev/null 2>&1 &&
    grep -F 'metadata first: finished' "$D/metavol.logs/rescue.log" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
kill -TERM "$pid"
wait "$pid"
eq "G: the run is interrupted once the --first path has been read" 130 "$?"
check "G: the phase is recorded as done" test -e "$D/metavol.logs/meta.done"
read -r mfts mftl <<<"$(istat -r "$VOL" 0 | awk '/Starting address/ { gsub(/,/, ""); print $3 * 4096, $5 * 4096; exit }')"
check "G: the first run of the \$MFT is in the image" same_bytes "$VOL" "$D/metavol.img" "$mfts" "$mftl"
mapfile -t sub_runs < <(ntfs_runs "$VOL" media/sub/clip.bin)
read -r subs subl <<<"${sub_runs[0]}"
check "G: the data of the --first path is in the image" same_bytes "$VOL" "$D/metavol.img" "$subs" "$subl"
check "G: the tail of the disk has not been read yet" bash -c "! cmp -s -i $((SIZE - 8 * M)) -n $((4 * M)) '$VOL' '$D/metavol.img'"
# the ordinary copy has no domain (-m); the reads of the metadata phase do
first_copy="$(grep -n 'phase copy:' "$D/metavol.logs/rescue.log" | grep -v -- ' -m ' | head -1 | cut -d: -f1)"
meta_end="$(grep -n 'metadata first: finished' "$D/metavol.logs/rescue.log" | head -1 | cut -d: -f1)"
check "G: the log has the metadata phase before the first ordinary copy" test -n "$meta_end" -a "$meta_end" -lt "${first_copy:-999999}"
check "G: ...and names the steps" bash -c "grep -F 'metadata first: the \$MFT' '$D/metavol.logs/rescue.log' >/dev/null"
fast="$(dm_create metafast "$(dm_linear "$loop" 0 $SIZE)")"
tool "$fast" --dir "$D" --name metavol --interval 1 --no-temp
rc_is "G: the next run finishes the disk" 0
check "G: ...without doing the metadata phase again" bash -c "! grep -F 'metadata first: the start of the disk' '$OUT' >/dev/null"
check "G: ...and the image equals the volume" cmp -s "$VOL" "$D/metavol.img"

# --no-meta-first
D="$W/g2"
mkdir -p "$D"
tool "$fast" --dir "$D" --name nometa --interval 1 --no-temp --no-meta-first
rc_is "G: --no-meta-first" 0
check "G: ...skips the phase" bash -c "! grep -F 'metadata first' '$OUT' >/dev/null"
check "G: ...and still images the volume" cmp -s "$VOL" "$D/nometa.img"

# a whole-disk image: the offset of the partition is applied in the metadata phase too
D="$W/g3"
mkdir -p "$D"
tool "$diskw" --dir "$D" --name wholemeta --interval 1 --no-temp --first media/sub
rc_is "G: metadata first on a whole-disk image" 0
check "G: ...the \$MFT is read" out_has "metadata first: the \$MFT"
check "G: ...the --first path is read" out_has "metadata first: the data of --first media/sub"
check "G: ...the image equals the disk" cmp -s "$W/whole1.img" "$D/wholemeta.img"

# a path that does not exist, and a device without NTFS
tool "$fast" --dir "$W/g2" --name nometa --interval 1 --no-temp --first nothing/here
rc_is "G: a --first path that is not there" 0
D="$W/g4"
mkdir -p "$D"
tool "$diske" --dir "$D" --name nofsmeta --interval 1 --no-temp --first something
rc_is "G: --first on a volume without a readable file system" 0
check "G: ...says there is nothing to read first" out_has "no NTFS volume"
# an ext4 volume: the file level works, the metadata-first phase is NTFS only
truncate -s $((32 * M)) "$W/ext4g.img"
mkfs.ext4 -q -F "$W/ext4g.img" >/dev/null 2>&1
loopx="$(loop_attach "$W/ext4g.img")"
diskx="$(dm_create ext4g "$(dm_linear "$loopx" 0 $((32 * M)))")"
D="$W/g5"
mkdir -p "$D"
tool "$diskx" --dir "$D" --name ext4meta --interval 1 --no-temp --first something
rc_is "G: --first on an ext4 volume" 0
check "G: ...says that only NTFS is read this way" out_has "only NTFS volumes are read this way"

finish
