#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Safety checks: stop conditions (no progress), refusal to write to the failing disk, the run lock,
# traces of a dropped disk found at the start, root requirement.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=lib.sh
source "$here/lib.sh"
it_init
set +e

SIZE=$((16 * M))
src="$(make_backing disk $SIZE)"
loop="$(loop_attach "$src")"
disk="$(dm_create safe "$(dm_linear "$loop" 0 $SIZE)")"

# === a ddrescue that keeps failing, and one that ends without doing anything ==================================
mkdir -p "$W/shim"
cat >"$W/shim/ddrescue" <<'S'
#!/bin/sh
case "$1" in --version) echo "GNU ddrescue 1.27"; exit 0 ;; esac
exit "${SHIM_EXIT:-1}"
S
chmod +x "$W/shim/ddrescue"
D="$W/a"
mkdir -p "$D"
hook="$(mk_hook safety)"
SHIM_EXIT=1 PATH="$W/shim:$PATH" tool "$disk" --dir "$D" --name failing --interval 1 --no-temp --no-fs --on-event "$hook"
rc_is "ddrescue failing five times in a row without progress stops the tool" 1
check "...with that message" out_has "ddrescue failed five times in a row without progress"
sleep 1
check "the event 'failed' was sent" bash -c "grep -F 'failed|' '$W/events-safety.log' >/dev/null"
eq "the state file says failed" failed "$(sed -n 's/^state=//p' "$D/failing.logs/state")"
D="$W/b"
mkdir -p "$D"
SHIM_EXIT=0 PATH="$W/shim:$PATH" tool "$disk" --dir "$D" --name stalling --interval 1 --no-temp --no-fs
rc_is "a phase that ends three times without progress stops the tool" 1
check "...with that message" out_has "ended three times in a row without progress"

# === the systemd unit is accepted by systemd ====================================================================
if command -v systemd-analyze >/dev/null; then
  "$TOOL" /dev/disk/by-id/x --dir "$D" --name unit-test --on-event "$W/shim/ddrescue" --print-service >"$W/lastread-unit-test.service"
  chmod 644 "$W/lastread-unit-test.service"
  systemd-analyze verify "$W/lastread-unit-test.service" >"$OUT" 2>&1
  RC=$?
  rc_is "systemd-analyze verify accepts the generated unit" 0
else
  skip "systemd-analyze is not available"
fi

# === the image directory and the extraction directory must not be on the failing disk =========================
truncate -s $((64 * M)) "$W/two.img"
printf 'label: dos\n,24M,L\n,,L\n' | sfdisk -q "$W/two.img" >/dev/null 2>&1
looptwo="$(loop_attach "$W/two.img" -P)"
udevadm settle -t 10
mkfs.ext4 -q -F "${looptwo}p2" >/dev/null 2>&1
mount_registered "${looptwo}p2" "$W/samedisk"
mkdir -p "$W/samedisk/img"
tool "${looptwo}p1" --dir "$W/samedisk/img" --name x --no-temp --no-fs
rc_is "an image directory on the same disk is refused" 1
check "...with a clear message" out_has "is on the same disk as the source"
D="$W/c"
mkdir -p "$D"
tool "${looptwo}p1" --dir "$D" --name x --no-temp --extract --extract-to "$W/samedisk/img"
rc_is "an extraction directory on the same disk is refused" 1
check "...with a clear message" out_has "is on the same disk as the source"
umount "$W/samedisk"

# === the run lock: a second run for the same image is refused ===================================================
slow="$(dm_create slow "$(dm_delay "$loop" 0 $SIZE 30)")"
D="$W/d"
mkdir -p "$D"
"$TOOL" "$slow" --dir "$D" --name locked --interval 1 --no-temp --no-fs >"$W/lock1.out" 2>&1 &
pid=$!
sleep 3
tool "$slow" --dir "$D" --name locked --interval 1 --no-temp --no-fs
rc_is "a second run for the same image is refused" 1
check "...with a clear message (ddrescue already runs on the map, or the run lock)" bash -c "grep -E 'ddrescue is already running with the map|another run is in progress' '$OUT' >/dev/null"
tool --inventory --dir "$D" --name locked
rc_is "--inventory on an image that is being rescued is refused" 1
check "...with a clear message" out_has "another run is in progress"
kill -TERM "$pid"
wait "$pid"
eq "the first run ends when told to" 130 "$?"
tool "$disk" --dir "$D" --name locked --interval 1 --no-temp --no-fs
rc_is "after the first run ended, the lock is free" 0

# === traces of a dropped disk found in the map at the start ======================================================
D="$W/e"
mkdir -p "$D"
mkmap "$D/traces.map" <<M
0 $((2 * M)) ?
$((2 * M)) $((6 * M)) /
$((8 * M)) $((3 * M)) -
$((11 * M)) 4096 -
$((11 * M + 4096)) $((5 * M - 4096)) ?
M
truncate -s $SIZE "$D/traces.img"
tool "$disk" --dir "$D" --name traces --interval 1 --no-temp --no-fs --artifact-limit 1Mi --artifact-bad 1Mi --dry-run
rc_is "dry-run with traces in the map" 0
check "dry-run announces that the traces will be reverted" out_has "traces of a dropped disk will be returned"
tool "$disk" --dir "$D" --name traces --interval 1 --no-temp --no-fs --artifact-limit 1Mi --artifact-bad 1Mi
rc_is "a map with traces of a dropped disk is rescued" 0
check "the traces are recognised" out_has "traces of a dropped disk, not bad spots"
check "the previous map is kept" test -e "$D/traces.map.before-revert"
check "the image equals the disk (the traces were read again, the bad sector retried)" same_bytes "$src" "$D/traces.img" 0 $SIZE

# === not enough space for the image ===============================================================================
mkdir -p "$W/small"
mount_registered tmpfs "$W/small" -t tmpfs -o size=4M
tool "$disk" --dir "$W/small" --name big --no-temp --no-fs
rc_is "an image directory without enough room is refused" 1
check "...with a clear message" out_has "not enough space"

# === an unstable device name needs an explicit --name =============================================================
tool "$loop" --dir "$W/a" --no-temp --no-fs
rc_is "a /dev/loopN source without --name is refused" 1
check "...with a clear message" out_has "--name is required"
tool "$disk" --dir "$W/a" --name mid --no-temp --no-fs --add-zone "100Mi-200Mi" --dry-run
rc_is "--add-zone past the end of the device is refused" 1
check "...with a clear message" out_has "starts past the end of the device"

# === root is required to read a device ===========================================================================
D="$W/f"
mkdir -p "$D"
chmod 777 "$D"
chmod 755 "$W"
cp "$TOOL" "$W/tool-copy"
chmod 755 "$W/tool-copy"
runuser -u nobody -- "$W/tool-copy" "$disk" --dir "$D" --no-temp >"$OUT" 2>&1
RC=$?
rc_is "a normal user cannot run a rescue" 1
check "...with a clear message" out_has "root is needed"
runuser -u nobody -- "$W/tool-copy" --help >/dev/null 2>&1
RC=$?
rc_is "but --help works for anyone" 0

# an inventory of an existing image needs no root (the directory belongs to the user)
chown -R nobody "$W/e"
runuser -u nobody -- "$W/tool-copy" --inventory --dir "$W/e" --name traces >"$OUT" 2>&1
RC=$?
check "an inventory of an image needs no root: it gets as far as looking at the image" out_has "inventory by the image without the disk"
check "...and stops only because random data has no file level" out_has "no file level for this image"

# two images in one directory: the name must be given
cp "$W/e/traces.map" "$W/e/second.map"
tool --inventory --dir "$W/e"
rc_is "--inventory without --name is refused when there are several images" 1
check "...with a clear message" out_has "say which image with --name"
rm -f "$W/e/second.map"

# === a missing device, a missing directory ==================================================================================
tool "$W/no-such-device" --dir "$D" --name gone --no-temp
rc_is "a missing device is refused" 1
check "...with a hint to use --inventory" out_has "--inventory"
tool "$disk" --dir "$D" --name tooold --no-temp --stop 40 --resume 50
rc_is "--resume above --stop is refused before anything is read" 1

finish
