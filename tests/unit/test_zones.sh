#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Deferred zones: merging, narrowing by what was rescued, stuck zones.
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
SECTOR=512 PART_SIZE=10000000000
quiet() { "$@" >/dev/null; }

# --- zone_put
quiet zone_put 4000000000 6000000000
eq "zone_put: a new zone" "4000000000 6000000000 f 0" "$(cat "$zones")"
quiet zone_put 5500000000 7000000000
eq "zone_put: overlapping zones merge" "4000000000 7000000000 f 0" "$(cat "$zones")"
quiet zone_put 8000000000 9000000000
eq "zone_put: separate zones stay separate and sorted" $'4000000000 7000000000 f 0\n8000000000 9000000000 f 0' "$(cat "$zones")"
printf '4000000000 6000000000 r 1\n' >"$zones"
quiet zone_put 5000000000 6500000000
eq "zone_put: a merged zone starts over" "4000000000 6499999744 f 0" "$(cat "$zones")"
rm -f "${zones:?}"
quiet zone_put 1000 2000000
eq "zone_put: aligned to the sector size" "512 1999872 f 0" "$(cat "$zones")"
rm -f "${zones:?}"
quiet zone_put 9500000000 12000000000
eq "zone_put: clipped to the device" "9499999744 10000000000 f 0" "$(cat "$zones")"
rm -f "${zones:?}"
SECTOR=4096
quiet zone_put 4097 20000
eq "zone_put: uses the sector size of the device (4Kn)" "4096 16384 f 0" "$(cat "$zones")"
SECTOR=512
rm -f "${zones:?}"

# --- zone_hang outside the zones phase: a new zone around the hang
quiet zone_hang 5000000000 copy
eq "zone_hang: ±1 GB around the hang" "4000000000 6000000000 f 0" "$(cat "$zones")"
rm -f "${zones:?}"
quiet zone_hang 500000000 copy
eq "zone_hang: near the start the zone begins at 0" "0 1499999744 f 0" "$(cat "$zones")"
rm -f "${zones:?}"
zone_margin=250000000
quiet zone_hang 5000000000 scrape
eq "zone_hang: the margin is a parameter" "4749999616 5249999872 f 0" "$(cat "$zones")"
zone_margin=1000000000
rm -f "${zones:?}"

# --- zone_hang inside the zones phase: narrow by what the map shows as rescued
M=1048576
PART_SIZE=$((10000 * M))
zone_phase() { # zone_phase ZONE_LINE DIRECTION   (the map is prepared by the caller)
  printf '%s\n' "$1" >"$zones"
  read -r ZS ZE _ _ <<<"$1"
  ZD=$2
}
z() { printf '%s %s %s %s\n' "$(($1))" "$(($2))" "$3" "$4"; } # z 'EXPR' 'EXPR' DIR FAILS
mkmap "$map" <<M2
0 $((4500 * M)) +
$((4500 * M)) $((1500 * M)) ?
$((6000 * M)) $((4000 * M)) +
M2
zone_phase "$(z '4000*M' '6000*M' f 0)" f
quiet zone_hang $((4400 * M)) zones
eq "narrowing from the start: the next attempt reads from the other end" "$(z '4500*M' '6000*M' r 0)" "$(cat "$zones")"
mkmap "$map" <<M2
0 $((4000 * M)) +
$((4000 * M)) $((1500 * M + 100)) ?
$((5500 * M + 100)) $((4500 * M - 100)) +
M2
zone_phase "$(z '4000*M' '6000*M' r 0)" r
quiet zone_hang $((5600 * M)) zones
eq "narrowing from the end rounds up to a sector" "$(z '4000*M' '5500*M+512' f 0)" "$(cat "$zones")"
# bad sectors on the edge do not stop the narrowing
mkmap "$map" <<M2
0 $((4300 * M)) +
$((4300 * M)) 4096 -
$((4300 * M + 4096)) $((1200 * M - 4096)) ?
$((5500 * M)) $((4500 * M)) +
M2
zone_phase "$(z '4000*M' '6000*M' f 0)" f
quiet zone_hang $((4400 * M)) zones
eq "bad sectors at the edge do not block narrowing" "$(z '4300*M+4096' '6000*M' r 0)" "$(cat "$zones")"
# almost no progress counts as a failure; two in a row make a core
mkmap "$map" <<M2
0 $((4000 * M + 1024)) +
$((4000 * M + 1024)) $((2000 * M - 1024)) ?
$((6000 * M)) $((4000 * M)) +
M2
zone_phase "$(z '4000*M' '6000*M' f 0)" f
quiet zone_hang $((4000 * M + 1024)) zones
eq "first attempt without progress: failure 1" "$(z '4000*M+1024' '6000*M' r 1)" "$(cat "$zones")"
zone_phase "$(z '4000*M+1024' '6000*M' r 1)" r
quiet zone_hang $((5999 * M)) zones
eq "second attempt without progress: failure 2 (the zone is a core)" "$(z '4000*M+1024' '6000*M' f 2)" "$(cat "$zones")"
eq "zone_next skips a core" "" "$(zone_next)"
printf '1 2 f 2\n3 4 r 1\n' >"$zones"
eq "zone_next takes the first zone with attempts left" "3 4 r 1" "$(zone_next)"
printf '1 2 f 2\n3 4 r 2\n' >"$zones"
eq "zone_next: all cores gives nothing" "" "$(zone_next)"
# a zone read completely disappears, and the message does not end up in the zone list
mkmap "$map" <<M2
0 $((10000 * M)) +
M2
zone_phase "$(z '4000*M' '6000*M' f 0)" f
quiet zone_hang $((4100 * M)) zones
check "a fully read zone is removed together with an empty zone file" test ! -e "$zones"
printf '%s\n%s\n' "$(z '1000*M' '2000*M' f 0)" "$(z '4000*M' '6000*M' f 0)" >"$zones"
ZS=$((4000 * M)) ZE=$((6000 * M)) ZD=f
quiet zone_hang $((4100 * M)) zones
eq "a fully read zone leaves the other zones intact" "$(z '1000*M' '2000*M' f 0)" "$(cat "$zones")"
# real progress resets the failure counter
mkmap "$map" <<M2
0 $((4600 * M)) +
$((4600 * M)) $((1400 * M)) ?
$((6000 * M)) $((4000 * M)) +
M2
zone_phase "$(z '4000*M' '6000*M' f 1)" f
quiet zone_hang $((4650 * M)) zones
eq "real progress resets the failure counter" "$(z '4600*M' '6000*M' r 0)" "$(cat "$zones")"
printf '1000000000 2000000000 f 0\n' >"$zones"
eq "zones_text is readable" "1.0 GB – 2.0 GB; " "$(zones_text)"
eq "gb: small sizes are shown in MB" "52.4 MB" "$(gb 52428800)"

finish
