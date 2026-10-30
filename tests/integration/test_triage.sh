#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# --triage on device-mapper disks: a healthy one, one with unreadable places, a dead one, a slow
# place, a hung place (the read is abandoned, triage does not hang with it), a missing device.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
it_init
set +e

SIZE=$((32 * M))
src="$(make_backing disk $SIZE)"
loop="$(loop_attach "$src")"

# --- healthy
good="$(dm_create good "$(dm_linear "$loop" 0 $SIZE)")"
tool "$good" --triage
rc_is "a healthy disk: exit 0" 0
check "GREEN" out_has "Verdict: GREEN"
eq "nine sample reads, all ok" 9 "$(grep -c ': ok ' "$OUT")"
check "a disk without SMART is a note, not a failure" out_has "no SMART data from this device"
check "the identity is printed" out_has "device:"
check "a command to start is suggested" out_has "Suggested start:"

# --- unreadable places at two sample positions (8 MiB and 24 MiB)
mapfile -t table < <({
  dm_linear "$loop" 0 $((8 * M)); echo
  dm_error $((8 * M)) $((4 * M)); echo
  dm_linear "$loop" $((12 * M)) $((12 * M)); echo
  dm_error $((24 * M)) $((4 * M)); echo
  dm_linear "$loop" $((28 * M)) $((4 * M)); echo
})
bad="$(dm_create bad "${table[@]}")"
tool "$bad" --triage
rc_is "a disk with unreadable places: exit 0" 0
check "YELLOW" out_has "Verdict: YELLOW"
check "...two failed samples" out_has "2 of 9 sample reads failed or timed out"
check "...a way to skip them is suggested" out_has "--min-rate 1M --skip-size 1Mi"

# --- dead
dead="$(dm_create dead "$(dm_error 0 $SIZE)")"
tool "$dead" --triage
rc_is "a dead disk: exit 4" 4
check "RED" out_has "Verdict: RED"
check "...stopped reading after two failures" out_has "two failures in a row: not reading any more"
eq "...after only two sample reads" 2 "$(grep -c ': error ' "$OUT")"

# --- a slow place
slow="$(dm_create slow \
  "$(dm_linear "$loop" 0 $((8 * M)))" \
  "$(dm_delay "$loop" $((8 * M)) $((4 * M)) 1500)" \
  "$(dm_linear "$loop" $((12 * M)) $((20 * M)))")"
tool "$slow" --triage --triage-timeout 5
rc_is "a slow place: exit 0" 0
check "YELLOW" out_has "Verdict: YELLOW"
check "...a slow sample is named" out_has ": slow "

# --- a hung place: the read is abandoned after --triage-timeout
hung="$(dm_create hung \
  "$(dm_linear "$loop" 0 $((8 * M)))" \
  "$(dm_delay "$loop" $((8 * M)) $((4 * M)) 20000)" \
  "$(dm_linear "$loop" $((12 * M)) $((20 * M)))")"
start=$SECONDS
tool "$hung" --triage --triage-timeout 2
took=$((SECONDS - start))
rc_is "a hung place: exit 4" 4
check "RED" out_has "Verdict: RED"
check "...the hung read was abandoned" out_has "timeout"
check "...in seconds, not after the 20 s hang" test "$took" -le 12

# --- refusals
tool "$W/no-such-device" --triage
rc_is "a missing device is refused" 1
cp "$TOOL" "$W/tool-copy"
chmod 755 "$W/tool-copy" "$W"
runuser -u nobody -- "$W/tool-copy" "$good" --triage >"$OUT" 2>&1
RC=$?
rc_is "a normal user cannot triage" 1
check "...with a clear message" out_has "root is needed"
tool "$good" --triage --extract --extract-to "$W"
rc_is "--triage with --extract is refused" 1

finish
