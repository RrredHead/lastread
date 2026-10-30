#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Map handling: ranges, sizes, traces of a dropped disk, positions, rate log, phase selection.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
map="$T/m.map" logs="$T/logs" zones="$T/logs/zones" domain="$T/logs/domain.map" LOG="$T/logs/rescue.log"
mkdir -p "$logs"
SECTOR=512 PART_SIZE=10000000000 meta_first=0 TMPD="$T"
clean_state() { rm -f "${logs:?}"/*.done "${logs:?}"/zones "${logs:?}"/zones.abandoned "${domain:?}"; }

# --- map_size, map_ranges
mkmap "$map" <<'M'
0 1000 +
1000 500 -
1500 500 ?
2000 500 *
2500 1000 +
3500 200 -
3700 9999996300 +
M
eq "map_size is the end of the last block" 10000000000 "$(map_size "$map")"
eq "map_ranges '-' lists bad areas" $'1000 1500\n3500 3700' "$(map_ranges '-')"
eq "map_ranges '?*/-' merges adjacent unread kinds" $'1000 2500\n3500 3700' "$(map_ranges '?*/-')"

# --- artifact_bytes / revert_artifacts (traces of a dropped disk)
artifact_bad=1000
mkmap "$map" <<'M'
0 1000 +
1000 3000 /
4000 500 *
4500 2000 -
6500 100 -
6600 700 ?
7300 9999992700 +
M
eq "artifact_bytes counts / and * and large bad areas" 5500 "$(artifact_bytes)"
revert_artifacts >/dev/null
eq "revert keeps the previous map next to it" "yes" "$([[ -f $map.before-revert ]] && echo yes)"
merged="$(decmap "$map" | awk '{ if (n && $3 == p && $3 == "?") { s[n] += $2 } else { n++; a[n] = $1; s[n] = $2; t[n] = $3 } p = $3 } END { for (i = 1; i <= n; i++) print a[i], s[i], t[i] }')"
eq "revert turns traces into not-tried" $'0 1000 +\n1000 5500 ?\n6500 100 -\n6600 700 ?\n7300 9999992700 +' "$merged"
eq "no traces left after the revert" 0 "$(artifact_bytes)"
mkmap "$map" <<'M'
0 1000 +
1000 5000 /
6000 9999994000 +
M
revert_artifacts >/dev/null
check "a second revert keeps the earlier copy of the map too" test -e "$map.before-revert.prev"
eq "artifact_bytes of a missing map" 0 "$(map=$T/none.map artifact_bytes)"

# --- unrescued_span
mkmap "$map" <<'M'
0 1000 +
1000 1000 ?
2000 1000 +
3000 1000 *
4000 1000 -
5000 9999995000 +
M
eq "unrescued_span: first and last unread, bad sectors ignored" "1000 4000" "$(unrescued_span 0 6000)"
eq "unrescued_span: clipped to the zone" "1500 3500" "$(unrescued_span 1500 3500)"
eq "unrescued_span: nothing unread gives E E" "3000 3000" "$(unrescued_span 2000 3000)"
eq "unrescued_span: only bad sectors gives E E" "5000 5000" "$(unrescued_span 4000 5000)"

# --- hang_position (last position with a non-zero rate)
printf '# Rates log.\n# Time Ipos Current_rate Average_rate Bad_areas Bad_size\n10 1000 5000000 5000000 0 0\n20 2000 4000000 4500000 0 0\n30 3000 0 3000000 0 0\n40 3000 0 2000000 0 0\n' >"$T/rates"
eq "hang_position: last position that still moved" 2000 "$(hang_position "$T/rates")"
printf '# Rates log.\n10 1000 0 0 0 0\n20 1000 0 0 0 0\n' >"$T/rates0"
eq "hang_position: never moved gives the first position" 1000 "$(hang_position "$T/rates0")"
eq "hang_position: missing file gives nothing" "" "$(hang_position "$T/nope")"

# --- set_map_pos / map_pos
mkmap "$map" <<'M'
0 1000 +
1000 9999999000 ?
M
set_map_pos 12345
eq "set_map_pos writes the position" "0x3039" "$(map_pos)"
eq "set_map_pos puts the status line to 'position, not-tried, pass 1'" "0x3039  ?  1" "$(awk '!/^#/ {print; exit}' "$map")"
eq "set_map_pos leaves the blocks alone" $'0 1000 +\n1000 9999999000 ?' "$(decmap "$map")"

# --- has / next_phase
clean_state
extract=0
eq "no map: copy" copy "$(map=$T/none.map next_phase)"
mkmap "$map" <<'M'
0 10000000000 ?
M
eq "not tried: copy" copy "$(next_phase)"
mkmap "$map" <<'M'
0 5000 +
5000 1000 *
6000 9999994000 +
M
eq "non-trimmed: scrape" scrape "$(next_phase)"
mkmap "$map" <<'M'
0 5000 +
5000 1000 /
6000 9999994000 +
M
eq "non-scraped: scrape" scrape "$(next_phase)"
mkmap "$map" <<'M'
0 5000 +
5000 1000 -
6000 9999994000 +
M
eq "bad sectors: retry" retry "$(next_phase)"
touch "$logs/retry.done"
eq "retry done: report" report "$(next_phase)"
touch "$logs/report.done"
eq "report done: done" "done" "$(next_phase)"
extract=1
eq "extract requested: extract" extract "$(next_phase)"
touch "$logs/extract.done"
eq "extract done: done" "done" "$(next_phase)"
extract=0
clean_state
# zones: unread blocks inside a zone do not make copy/scrape/retry necessary
mkmap "$map" <<'M'
0 2000000000 +
2000000000 1000000000 ?
3000000000 7000000000 +
M
printf '2000000000 3000000000 f 0\n' >"$zones"
eq "unread only inside a zone: zones" zones "$(next_phase)"
printf '2000000000 3000000000 r 2\n' >"$zones"
eq "zone that failed twice: zones-stuck" zones-stuck "$(next_phase)"
touch "$logs/zones.abandoned"
eq "zones given up: report" report "$(next_phase)"
rm -f "${logs:?}/zones.abandoned"
printf '0 10000000000 f 0\n' >"$zones"
eq "zones covering the device: zones" zones "$(next_phase)"
rm -f "${zones:?}"

# --- domains
printf '2000000000 3000000000 f 0\n5000000000 6000000000 f 0\n' >"$zones"
write_domain outside
eq "domain outside the zones" $'0 2000000000 +\n2000000000 1000000000 ?\n3000000000 2000000000 +\n5000000000 1000000000 ?\n6000000000 4000000000 +' "$(decmap "$domain")"
write_domain 2000000000 3000000000
eq "domain of one zone" $'0 2000000000 ?\n2000000000 1000000000 +\n3000000000 7000000000 ?' "$(decmap "$domain")"
rm -f "${zones:?}"
printf '100 200\n150 400\n1000 1100\n1100 1200\n' >"$T/r1"
eq "merge_ranges merges overlapping and adjacent" $'100 400\n1000 1200' "$(merge_ranges "$T/r1")"
write_ranges_domain "$T/r1"
eq "domain of selected files" $'0 100 ?\n100 300 +\n400 600 ?\n1000 200 +\n1200 9999998800 ?' "$(decmap "$domain")"
TARGET_RANGES="$T/r1"
mkmap "$map" <<'M'
0 120 +
120 100 ?
220 9999999780 +
M
check "has_in: unread block inside the selected files" has_in non-tried
mkmap "$map" <<'M'
0 10000000000 +
M
refuse "has_in: nothing unread inside" has_in non-tried
TARGET_RANGES=""

finish
