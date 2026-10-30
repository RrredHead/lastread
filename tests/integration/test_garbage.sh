#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --recheck-garbage on a disk that answers with service sectors instead of data: the places are found
# in the image, marked, read again; what the disk fixes disappears, what stays is counted as unreadable.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
it_init
set +e

SIZE=$((32 * M))
clean="$(make_backing clean $SIZE)"
cp "$clean" "$W/dirty.bin"
tag() { { printf 'sEDU'; head -c 504 /dev/zero; printf 'sEDU'; } | dd of="$W/dirty.bin" bs=1 seek="$1" conv=notrunc status=none; }
tag $((6 * M))
tag $((6 * M + 512))
tag $((20 * M + 4096))
cp "$W/dirty.bin" "$W/stuck.bin" # the heal below rewrites dirty.bin; this copy keeps the garbage
loop_clean="$(loop_attach "$clean")"
loop_dirty="$(loop_attach "$W/dirty.bin")"
loop_stuck="$(loop_attach "$W/stuck.bin")"
opts=(--interval 1 --no-temp --no-fs --recheck-garbage)

# --- a disk that returns real data on the second read
disk="$(dm_create garb "$(dm_linear "$loop_dirty" 0 $SIZE)")"
D="$W/heal"
mkdir -p "$D"
# The "disk heals": as soon as the tool has marked the places, the real data is written over the
# garbage in the backing file (a few milliseconds, while the tool is still on its way to the retry).
(
  until [[ -e $D/heal.logs/garbage.marked ]]; do sleep 0.002; done
  dd if="$clean" of="$W/dirty.bin" bs=1024 skip=$((6 * 1024)) seek=$((6 * 1024)) count=1 conv=notrunc status=none
  dd if="$clean" of="$W/dirty.bin" bs=512 skip=$(((20 * M + 4096) / 512)) seek=$(((20 * M + 4096) / 512)) count=1 conv=notrunc status=none
) &
IT_BG+=("$!")
tool "$disk" --dir "$D" --name heal "${opts[@]}"
rc_is "a disk that heals on the second read: the run finishes" 0
check "the places are found (the two neighbours merge into one range)" out_has "garbage check: 2 places"
check "...merged: two ranges in the first scan" bash -c "[[ \$(wc -l <'$D/heal.logs/garbage-first.txt') -eq 2 ]]"
check "...and marked for another read" out_has "marked as bad sectors, the retry phase reads them again"
check "after the new read nothing looks like garbage" out_has "after the new read 0 places"
check "the record of garbage is empty" test ! -s "$D/heal.logs/garbage-ranges.txt"
check "the image has the real data everywhere" cmp -s "$clean" "$D/heal.img"
eq "nothing is left as unreadable in the map" 0 "$(decmap "$D/heal.map" | awk '$3 == "-" {s += $2} END {print s + 0}')"

# --- a disk that keeps answering with the same garbage
disk2="$(dm_create stuck "$(dm_linear "$loop_stuck" 0 $SIZE)")"
D="$W/stays"
mkdir -p "$D"
tool "$disk2" --dir "$D" --name stays "${opts[@]}"
rc_is "a disk that keeps the garbage: the run finishes" 0
check "what still looks like garbage is reported" out_has "after the new read 2 places"
eq "...and recorded" $'6291456 6292480\n20975616 20976128' "$(cat "$D/stays.logs/garbage-ranges.txt")"
check "...and part of the unreadable ranges of the report" bash -c "grep -Fx '6291456 6292480' '$D/stays.logs/report-ranges.txt' >/dev/null"
check "the image is what the disk gave" cmp -s "$W/stuck.bin" "$D/stays.img"

# --- nothing to find
disk3="$(dm_create fine "$(dm_linear "$loop_clean" 0 $SIZE)")"
D="$W/nothing"
mkdir -p "$D"
tool "$disk3" --dir "$D" --name nothing "${opts[@]}"
rc_is "a clean disk" 0
check "...nothing found" out_has "garbage check: nothing found"

# --- not requested: no scan
D="$W/off"
mkdir -p "$D"
tool "$disk2" --dir "$D" --name off --interval 1 --no-temp --no-fs
check "without --recheck-garbage there is no scan" bash -c "! grep -F 'garbage check' '$OUT' >/dev/null"

finish
