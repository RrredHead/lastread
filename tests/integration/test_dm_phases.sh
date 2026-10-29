#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Phases on a device-mapper disk with an unreadable area (error target) and a slow area (delay
# target): copy -> scrape -> retry -> report, resume after an interruption, option smoke tests,
# refusal to resume on a different disk.
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
# 0-16M fine, 16-17M unreadable, 17-24M fine, 24-26M slow, rest fine
disk="$(dm_create phases \
  "$(dm_linear "$loop" 0 $((16 * M)))" \
  "$(dm_error $((16 * M)) $((1 * M)))" \
  "$(dm_linear "$loop" $((17 * M)) $((7 * M)))" \
  "$(dm_delay "$loop" $((24 * M)) $((2 * M)) 200)" \
  "$(dm_linear "$loop" $((26 * M)) $((38 * M)))")"
D="$W/out"
mkdir -p "$D"
common=(--dir "$D" --name phases --interval 1 --no-temp --no-fs)

# --- dry run changes nothing
tool "$disk" "${common[@]}" --dry-run
rc_is "dry-run exits 0" 0
check "dry-run says nothing is run" out_has "dry-run: nothing is run"
check "dry-run creates no image" test ! -e "$D/phases.img"

# --- the real run
tool "$disk" "${common[@]}" --min-rate 100k
rc_is "the run exits 0" 0
check "copy phase ran" out_has "phase copy:"
check "scrape phase ran" out_has "phase scrape:"
check "retry phase ran" out_has "phase retry:"
check "the copy phase uses the sector size of the device" out_has "-b 512"
eq "the unreadable area is exactly 1 MiB" "$M" "$(decmap "$D/phases.map" | awk '$3 == "-" {s += $2} END {print s + 0}')"
eq "the unreadable area starts at 16 MiB" "$((16 * M)) $((17 * M))" "$(cat "$D/phases.logs/report-ranges.txt")"
check "the image before the bad area equals the disk" same_bytes "$src" "$D/phases.img" 0 $((16 * M))
check "the image after the bad area equals the disk" same_bytes "$src" "$D/phases.img" $((17 * M)) $((47 * M))
check "retry.done is recorded" test -e "$D/phases.logs/retry.done"
check "report.done is recorded" test -e "$D/phases.logs/report.done"
check "the run log exists" test -s "$D/phases.logs/rescue.log"
check "ddrescue event and rate logs exist" bash -c "ls '$D'/phases.logs/rates-*-copy.log '$D'/phases.logs/events.log >/dev/null"
check "the lock file does not stop the next run" true

# --- a re-run is a no-op
before="$(md5sum "$D/phases.map" | cut -d' ' -f1)"
tool "$disk" "${common[@]}"
rc_is "the second run exits 0" 0
check "the second run starts no ddrescue" bash -c "! grep -F 'phase ' '$OUT' >/dev/null"
eq "the map is untouched by the second run" "$before" "$(md5sum "$D/phases.map" | cut -d' ' -f1)"

# --- a different disk with the same name is refused
src2="$(make_backing other $((32 * M)))"
loop2="$(loop_attach "$src2")"
other_disk="$(dm_create other "$(dm_linear "$loop2" 0 $((32 * M)))")"
tool "$other_disk" "${common[@]}"
rc_is "a disk of another size is refused" 1
check "...with a clear message" out_has "another disk?"

# --- interruption and resume
D2="$W/out2"
mkdir -p "$D2"
c2=(--dir "$D2" --name resume --interval 1 --no-temp --no-fs)
slow="$(dm_create slow "$(dm_delay "$loop" 0 $((16 * M)) 40)" "$(dm_linear "$loop" $((16 * M)) $((48 * M)))")"
"$TOOL" "$slow" "${c2[@]}" >"$W/resume1.out" 2>&1 &
pid=$!
sleep 3
check "while running the machine is kept awake (systemd-inhibit)" bash -c "systemd-inhibit --list --no-pager | grep -F lastread >/dev/null"
kill -TERM "$pid"
wait "$pid"
eq "an interruption (SIGTERM; SIGINT is handled the same way) ends the run with 130" 130 "$?"
check "...and says to run again" grep -F "interrupted" "$W/resume1.out"
check "the map was saved" test -s "$D2/resume.map"
part="$(ddrescuelog -t "$D2/resume.map" | sed -n 's/^ *rescued: *\([^,]*\),.*/\1/p')"
check "something, but not everything, was rescued before the interruption" test -n "$part"
tool "$slow" "${c2[@]}"
rc_is "the next run finishes" 0
check "...with the same image" same_bytes "$src" "$D2/resume.img" 0 $SIZE

# --- option smoke test: the image comes out right with unusual options
D3="$W/out3"
mkdir -p "$D3"
tool "$disk" --dir "$D3" --name opts --interval 1 --no-temp --no-fs --reverse --skip-size 1Mi --min-rate 1M --start-at 10M --retries 1 --zone-margin 2Mi
rc_is "unusual options: exit 0" 0
check "--start-at is announced" out_has "reading starts at"
check "--min-rate reaches ddrescue as -a" out_has " -a 1M "
check "--skip-size reaches ddrescue as -K" out_has " -K 1Mi "
check "--reverse reaches ddrescue as -R" out_has " -R "
check "--retries reaches ddrescue as -r" out_has " -r 1 "
check "...the image still matches outside the bad area" same_bytes "$src" "$D3/opts.img" $((17 * M)) $((47 * M))
check "...and before it" same_bytes "$src" "$D3/opts.img" 0 $((16 * M))

# --- a missing directory and a mounted source are refused
tool "$disk" --dir "$W/nope" --no-temp
rc_is "a missing --dir is refused" 1
mkfs.ext4 -q -F "$other_disk" >/dev/null 2>&1
mount_registered "$other_disk" "$W/mnt"
tool "$other_disk" --dir "$D" --name mounted --no-temp --no-fs
rc_is "a mounted source is refused" 1
check "...with a clear message" out_has "is mounted"
umount "$W/mnt"

finish
