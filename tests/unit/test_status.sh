#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --status: byte totals of a map, the sliding-window rate, the text and JSON reports.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
meta_first=0
dir="$T" name=disk map="$T/disk.map" img="$T/disk.img" logs="$T/disk.logs" zones="$logs/zones" LOG="$logs/rescue.log" TMPD="$T/tmp"
mkdir -p "$logs" "$TMPD"
SECTOR=512

mkmap "$map" <<'M'
0 4000000000 +
4000000000 1000000 -
4001000000 2000000 ?
4003000000 3000000 *
4006000000 4000000 /
4010000000 5990000000 ?
M
eq "map_totals: bytes per kind" "rescued=4000000000 non_tried=5992000000 non_trimmed=3000000 non_scraped=4000000 bad=1000000" "$(map_totals "$map")"
eq "map_totals: hex and decimal sizes" "rescued=16 non_tried=0 non_trimmed=0 non_scraped=0 bad=0" "$(printf '0x0  +  1\n0x00000000  16  +\n' | { cat >"$T/dec.map"; map_totals "$T/dec.map"; })"

# --- fmt_duration
eq "fmt_duration: seconds" "45 s" "$(fmt_duration 45)"
eq "fmt_duration: minutes" "5 min" "$(fmt_duration 330)"
eq "fmt_duration: hours" "3 h 12 min" "$(fmt_duration 11520)"
eq "fmt_duration: days" "2 d 4 h" "$(fmt_duration 190000)"

# --- sample_progress: 3000 bytes in 30 seconds = 100 B/s, old samples leave the window
RATE_T=() RATE_B=() RATE=""
mkmap "$map" <<'M'
0 1000 +
1000 9999999000 ?
M
SECONDS=0
sample_progress
eq "the first sample has no rate yet" 0 "$RATE"
mkmap "$map" <<'M'
0 4000 +
4000 9999996000 ?
M
SECONDS=30
sample_progress
eq "rate over the window" 100 "$RATE"
eq "rescued bytes of the last sample" 4000 "$RESCUED"
mkmap "$map" <<'M'
0 4000 +
4000 9999996000 ?
M
SECONDS=700
sample_progress
eq "samples older than ten minutes leave the window (no progress since)" 0 "$RATE"
SECONDS=0

# --- the report, from a prepared logs directory
mkmap "$map" <<'M'
0 4000000000 +
4000000000 1000000 -
4001000000 5999000000 ?
M
printf '2000000000 3000000000 f 0\n7000000000 8000000000 r 2\n' >"$zones"
printf '2026-01-01 10:00:00 phase copy: ddrescue ...\n2026-01-01 10:05:00 temperature 44 °C, rescued 4 GB\n' >"$LOG"
printf 'updated=%s\npid=999999\nstate=running\nphase=copy\ntemperature=44\nrescued=4000000000\nrate=2000000\n' "$(date +%s)" >"$logs/state"
touch "$logs/retry.done"
out="$(status_run)"
check "the text report names the image" contains "$out" "status: disk"
check "a state that says running without a lock means the run is gone" contains "$out" "stopped (the run is gone)"
check "rescued share" contains "$out" "40.0% (4.0 GB of 10.0 GB)"
check "unreadable" contains "$out" "unreadable:     1.0 MB"
check "zones are listed" contains "$out" "deferred zones: 2"
check "temperature" contains "$out" "temperature:    44 °C"
check "last events" contains "$out" "temperature 44 °C, rescued 4 GB"
# a held lock means a running rescue
exec 7>"$T/.disk.lock"
flock -n 7
out="$(status_run)"
check "a held lock means running, with the pid" contains "$out" "state:          running (pid 999999"
check "a running rescue shows the rate" contains "$out" "rate:           2.0MB/s"
check "...and a rough time left" contains "$out" "to read what is not read yet (rough)"
if command -v jq >/dev/null; then
  json=1
  js="$(status_run)"
  json=0
  eq "JSON: running" true "$(jq .running <<<"$js")"
  eq "JSON: rescued bytes" 4000000000 "$(jq .rescued <<<"$js")"
  eq "JSON: size" 10000000000 "$(jq .size <<<"$js")"
  eq "JSON: percent" 40 "$(jq .rescued_percent <<<"$js")"
  eq "JSON: zones" 2 "$(jq '.zones | length' <<<"$js")"
  eq "JSON: a zone" '{"start":7000000000,"end":8000000000,"direction":"r","failures":2}' "$(jq -c '.zones[1]' <<<"$js")"
  eq "JSON: temperature" 44 "$(jq .temperature <<<"$js")"
  eq "JSON: last events" 2 "$(jq '.last_events | length' <<<"$js")"
else
  skip "jq is not installed: JSON report not tested"
fi
exec 7>&-
refuse "no map: an error" bash -c "source '$here/../../lastread'; map='$T/none.map' name=x dir='$T' status_run"

finish
