#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A disk that hangs at a place and drops off the bus: the tool stops ddrescue before it marks the
# rest as bad, reverts the traces, defers a zone around the hang, reads everything else, then the
# zone from both ends until it narrows to a core; --give-up-zones ends it.
#
# The "disk" is a device-mapper device: a delay target (20 s per read) is the hanging place, and a
# controller flips the whole device to an error table when ddrescue has been stuck on a read for
# 5 s — what a dropped disk looks like to the tool. "Power cycle" = restore the healthy table and run again.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
it_init
set +e

SIZE=$((48 * M))
CORE_START=$((24 * M))
CORE_LEN=$((M / 2))
src="$(make_backing disk $SIZE)"
loop="$(loop_attach "$src")"
healthy=(
  "$(dm_linear "$loop" 0 $CORE_START)"
  "$(dm_delay "$loop" $CORE_START $CORE_LEN 20000)"
  "$(dm_linear "$loop" $((CORE_START + CORE_LEN)) $((SIZE - CORE_START - CORE_LEN)))"
)
disk="$(dm_create hang "${healthy[@]}")"

# The controller: ddrescue stuck in an uninterruptible wait (a read hanging in the delay target)
# for 5 consecutive seconds means the "disk" drops. (The inflight counter of a device-mapper
# device does not show a read held by the delay target, so the state of ddrescue is used.)
controller() {
  local stuck=0 pid st
  while [[ ! -e $W/stop-controller ]]; do
    pid="$(pgrep -x ddrescue | head -1)"
    st=""
    [[ -z $pid ]] || st="$(ps -o stat= -p "$pid" 2>/dev/null)"
    if [[ $st == D* ]]; then stuck=$((stuck + 1)); else stuck=0; fi
    if ((stuck >= 5)) && [[ ! -e $W/dropped ]]; then
      : >"$W/dropped"
      dm_load hang "$(dm_error 0 $SIZE)"
      stuck=0
    fi
    sleep 1
  done
}
bg controller

power_cycle() {
  rm -f "$W/dropped"
  dm_load hang "${healthy[@]}"
}

D="$W/out"
mkdir -p "$D"
opts=(--dir "$D" --name hang --interval 1 --no-temp --no-fs --zone-margin 1Mi --zone-min-progress 256Ki --rescan-pause 1)

runs=0
while ((runs < 12)); do
  runs=$((runs + 1))
  tool "$disk" "${opts[@]}"
  printf 'run %d: exit %d\n' "$runs" "$RC"
  grep -E 'the disk hung|deferred zone|almost no progress|does not answer|zones-stuck|deferred zones remain' "$OUT" | sed 's/^/        /'
  if ((RC == 1)) && out_has "does not answer"; then
    power_cycle
    continue
  fi
  break
done
rc_is "the tool ends with 'only stuck zones are left'" 2
check "the tool says which zones are stuck" out_has "deferred zones remain that the disk does not read from either side"
check "it took several runs (a hang, then narrowing)" test "$runs" -ge 5
check "zones were deferred around the hang" grep -F "deferred zones —" "$D/hang.logs/rescue.log"
check "the zone was narrowed" grep -F "the zone is now" "$D/hang.logs/rescue.log"
check "attempts without progress were counted" grep -F "almost no progress (1 of 2)" "$D/hang.logs/rescue.log"
check "...up to a core" grep -F "almost no progress (2 of 2)" "$D/hang.logs/rescue.log"
check "the traces of the dropped disk were reverted" grep -F "returned to \"not tried\"" "$D/hang.logs/rescue.log"
check "a map copy from before the revert is kept" test -e "$D/hang.map.before-revert"
zone="$(cat "$D/hang.logs/zones")"
read -r zs ze _ <<<"$zone"
check "the remaining zone lies inside the hanging place" test "$zs" -ge "$CORE_START" -a "$ze" -le $((CORE_START + CORE_LEN))
check "...and is much smaller than the first zone (2 MiB)" test $((ze - zs)) -lt $((M / 2))
# everything outside the area of the hang has been read and is correct
check "the image before the hang equals the disk" same_bytes "$src" "$D/hang.img" 0 $((CORE_START - 2 * M))
check "the image after the hang equals the disk" same_bytes "$src" "$D/hang.img" $((CORE_START + CORE_LEN + 2 * M)) $((SIZE - CORE_START - CORE_LEN - 2 * M))
# rescued means correct: every block the map calls finished equals the disk
all_rescued_correct() {
  local pos size st
  while read -r pos size st; do
    [[ $st == + ]] || continue
    same_bytes "$src" "$D/hang.img" "$pos" "$size" || return 1
  done < <(decmap "$D/hang.map")
}
check "every rescued block of the map equals the disk" all_rescued_correct

# --- give up the cores
power_cycle
tool "$disk" "${opts[@]}" --give-up-zones
rc_is "after --give-up-zones the run finishes" 0
check "the zones are given up" out_has "deferred zones given up"
check "the given-up zone is in the list of unreadable ranges" grep -Fx "$zs $ze" "$D/hang.logs/report-ranges.txt"
check "no phase ran on the given-up zone" bash -c "! grep -F 'deferred zone ' '$OUT' | grep -F 'reading from' >/dev/null"

# --- a manual zone (on a healthy disk): deferred, read last, only once
D2="$W/out2"
mkdir -p "$D2"
ok="$(dm_create ok "$(dm_linear "$loop" 0 $SIZE)")"
tool "$ok" --dir "$D2" --name manual --interval 1 --no-temp --no-fs --add-zone "40Mi-44Mi"
rc_is "a manual zone: the run finishes" 0
check "...the zone is announced" out_has "deferred by hand"
check "...it is read as a zone" out_has "reading from the start"
check "...and the image equals the disk" same_bytes "$src" "$D2/manual.img" 0 $SIZE
rm -f "$D2/manual.logs/report.done"
tool "$ok" --dir "$D2" --name manual --interval 1 --no-temp --no-fs --add-zone "40Mi-44Mi"
check "the same --add-zone is not added again" out_has "was added before"

touch "$W/stop-controller"
finish
