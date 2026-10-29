#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The temperature watchdog with --temp-cmd: stop at --stop, hysteresis, continue at --resume;
# a failing sensor does not stop anything.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
it_init
set +e

SIZE=$((64 * M))
src="$(make_backing disk $SIZE)"
loop="$(loop_attach "$src")"
# every read takes ~10 ms: the whole copy needs ~10 s
disk="$(dm_create wd "$(dm_delay "$loop" 0 $SIZE 10)")"

cat >"$W/sensor" <<S
#!/bin/sh
# the "sensor": prints the number in $W/temp; fails if the file is missing; needs the device argument
[ -n "\$1" ] || exit 9
cat "$W/temp"
S
chmod +x "$W/sensor"
printf '40\n' >"$W/temp"

D="$W/out"
mkdir -p "$D"
epoch() { date -d "$(sed -n "s/^\\([0-9-]* [0-9:]*\\) $1.*/\\1/p" "$D/wd.logs/rescue.log" | head -1)" +%s; }

# sequence: 40 -> 60 (after 3 s) -> 47 (after 6 s) -> 44 (after 11 s)
(
  sleep 3
  printf '60\n' >"$W/temp"
  sleep 3
  printf '47\n' >"$W/temp"
  sleep 5
  printf '44\n' >"$W/temp"
  date +%s >"$W/set44"
) &
IT_BG+=("$!")
tool "$disk" --dir "$D" --name wd --interval 1 --stop 50 --resume 45 --temp-cmd "$W/sensor" --no-fs
rc_is "the run with a hot disk finishes" 0
check "the sensor is announced" out_has "temperature from $W/sensor"
check "ddrescue was stopped at 60 °C" out_has "stopping ddrescue, the map is saved"
check "the tool waited for the disk to cool down" out_has "cooling down: "
check "the tool continued after the temperature dropped" out_has "continuing"
eq "the copy phase was started twice (before and after the pause)" 2 "$(grep -c 'phase copy:' "$D/wd.logs/rescue.log")"
check "the image equals the disk" same_bytes "$src" "$D/wd.img" 0 $SIZE
paused="$(epoch ".*stopping ddrescue")"
resumed="$(epoch ".*temperature 44")"
check "hysteresis: no resume before the temperature fell to --resume (47 °C is not enough)" test "$((resumed - paused))" -ge 7
check "the resume came after the sensor showed 44 °C" test "$resumed" -ge "$(cat "$W/set44")"

# --- a sensor that fails does not stop the rescue
rm -f "$W/temp"
D2="$W/out2"
mkdir -p "$D2"
tool "$disk" --dir "$D2" --name nosensor --interval 1 --stop 50 --resume 45 --temp-cmd "$W/sensor" --no-fs
rc_is "a failing --temp-cmd at the start: the run goes on unwatched" 0
check "...with a warning" out_has "without the temperature watchdog"
check "...and a correct image" same_bytes "$src" "$D2/nosensor.img" 0 $SIZE

# --- --no-temp
D3="$W/out3"
mkdir -p "$D3"
tool "$disk" --dir "$D3" --name notemp --interval 1 --no-temp --no-fs
rc_is "--no-temp: the run finishes" 0
check "...and says so" out_has "temperature is not watched"

# --- the sensor works at the start and fails later (a transient failure): the run is not stopped
printf '40\n' >"$W/temp"
D4="$W/out4"
mkdir -p "$D4"
(
  sleep 3
  rm -f "$W/temp"
) &
IT_BG+=("$!")
tool "$disk" --dir "$D4" --name flaky --interval 1 --stop 50 --resume 45 --temp-cmd "$W/sensor" --no-fs
rc_is "a sensor that fails mid-run does not stop the rescue" 0
check "...and the image is right" same_bytes "$src" "$D4/flaky.img" 0 $SIZE

finish
