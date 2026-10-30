#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --recheck-garbage: scanning the image, marking finished blocks as bad, the ranges that count as unread.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
map="$T/m.map" logs="$T/logs" zones="$logs/zones" domain="$logs/domain.map" LOG="$logs/rescue.log" TMPD="$T/tmp" img="$T/disk.img"
mkdir -p "$logs" "$TMPD"
SECTOR=512 PART_SIZE=100000 meta_first=0

# --- the patterns
args() { (parse_args "$@" /dev/null && validate_args && printf '%s' "$GARBAGE_RE"); }
eq "default scan pattern: the service sector tag, a one-byte match" 'sEDU(?=\x00{504}sEDU)' "$(args --recheck-garbage)"
eq "custom patterns replace it and are wrapped in a lookahead" '(?=(?:BADBAD)|(?:x\d))[\s\S]' "$(args --recheck-garbage --suspect-pattern BADBAD --suspect-pattern 'x\d')"
refuse "--recheck-garbage needs the data check" args --recheck-garbage --no-suspect-check
refuse "an invalid pattern is refused" args --recheck-garbage --suspect-pattern 'a(b'

# --- scan_garbage on a synthetic image
tag() { { printf 'sEDU'; head -c 504 /dev/zero; printf 'sEDU'; } | dd of="$img" bs=1 seek="$1" conv=notrunc status=none; }
head -c 65536 /dev/urandom >"$img"
tag 4096
tag 10000
tag 4608 # directly after the first one: the ranges merge
GARBAGE_RE='sEDU(?=\x00{504}sEDU)'
eq "scan: sectors of the matches, merged" $'4096 5120\n9728 10240' "$(scan_garbage)"
head -c 65536 /dev/urandom >"$img"
eq "scan: a clean image gives nothing" "" "$(scan_garbage)"
printf 'xxBADBADxx' | dd of="$img" bs=1 seek=20000 conv=notrunc status=none
GARBAGE_RE='(?=(?:BADBAD))[\s\S]'
eq "scan: a custom pattern marks the sector where it starts" "19968 20480" "$(scan_garbage)"

# --- mark_map_ranges
mkmap "$map" <<'M'
0 8192 +
8192 1024 ?
9216 8192 +
17408 82592 +
M
printf '4096 4608\n8192 8704\n9728 10240\n' >"$T/r"
mark_map_ranges "$T/r"
eq "finished blocks inside the ranges become bad, other kinds stay" $'0 4096 +\n4096 512 -\n4608 3584 +\n8192 1024 ?\n9216 512 +\n9728 512 -\n10240 89760 +' "$(decmap "$map")"
check "the rewritten map is a valid mapfile" ddrescuelog -t "$map" >/dev/null
eq "bad sectors in the map are exactly the marked ones" $'4096 4608\n9728 10240' "$(map_ranges '-')"
mkmap "$map" <<'M'
0 100000 +
M
printf '0 512\n99488 100000\n' >"$T/r"
mark_map_ranges "$T/r"
eq "ranges at both ends of the device" $'0 512 -\n512 98976 +\n99488 512 -' "$(decmap "$map")"

# --- unread_ranges includes the garbage record
mkmap "$map" <<'M'
0 1000 -
1000 99000 +
M
printf '5120 5632\n' >"$logs/garbage-ranges.txt"
eq "unread ranges: the map and the garbage record, merged" $'0 1000\n5120 5632' "$(unread_ranges '-')"
rm -f "${logs:?}/garbage-ranges.txt"
eq "unread ranges: without a garbage record just the map" "0 1000" "$(unread_ranges '-')"

# --- the phase comes after retry
recheck_garbage=1
touch "$logs/retry.done"
mkmap "$map" <<'M'
0 100000 +
M
eq "after retry: the garbage check" garbage "$(next_phase)"
touch "$logs/garbage.done"
eq "after the check: report" report "$(next_phase)"
recheck_garbage=0
rm -f "${logs:?}/garbage.done"
eq "not requested: no garbage phase" report "$(next_phase)"

finish
