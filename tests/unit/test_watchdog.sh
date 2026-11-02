#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Temperature sources, return of a dropped disk (what can be decided without a device), owner setup.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/bin"
whole=/dev/null
quiet() { "$@" >/dev/null 2>&1; }

# --- --temp-cmd: a program that prints the temperature, given the device as its only argument
cat >"$T/tempcmd" <<'S'
#!/bin/sh
# prints the content of the file next to it; the device argument must be passed
[ -n "$1" ] || exit 9
cat "$(dirname "$0")/value"
S
chmod +x "$T/tempcmd"
temp_cmd="$T/tempcmd" TEMP_GUARD=1
printf '45\n' >"$T/value"
eq "temperature from --temp-cmd" 45 "$(temperature)"
printf '47.9\n' >"$T/value"
eq "a fractional temperature is truncated" 47 "$(temperature)"
printf 'hot\n' >"$T/value"
refuse "junk is not a temperature" temperature
printf '45\n' >"$T/value"
TEMP_GUARD=0
refuse "no temperature when the watchdog is off" temperature
TEMP_GUARD=1

# --- smartctl: JSON parsing, exit status mask ignored, -d sat fallback
temp_cmd=""
cat >"$T/bin/smartctl" <<'S'
#!/bin/sh
# stub: with "-d sat" prints a temperature (exit status 64 like a worn disk), without it fails
case " $* " in
  *" -d sat "*) echo '{"temperature":{"current":39}}'; exit 64 ;;
  *) echo 'Unknown USB bridge'; exit 4 ;;
esac
S
chmod +x "$T/bin/smartctl"
PATH="$T/bin:$PATH"
SMART_ARGS=(-d sat)
eq "smartctl: the temperature is read although the exit status is non-zero" 39 "$(temperature)"
SMART_ARGS=()
refuse "smartctl: no JSON, no temperature" temperature
no_temp=0 smart_type=""
quiet detect_temperature_source
eq "auto-detection falls back to -d sat" "-d sat" "${SMART_ARGS[*]}"
eq "the watchdog is on after auto-detection" 1 "$TEMP_GUARD"
smart_type="scsi"
quiet detect_temperature_source
eq "an explicit --smart-type is not replaced by auto-detection" 0 "$TEMP_GUARD"
smart_type=""
no_temp=1
quiet detect_temperature_source
eq "--no-temp turns the watchdog off" 0 "$TEMP_GUARD"
no_temp=0
printf 'junk\n' >"$T/value"
temp_cmd="$T/tempcmd"
out="$(detect_temperature_source 2>&1)"
eq "an unusable --temp-cmd turns the watchdog off" 0 "$TEMP_GUARD"
check "...and says so" contains "$out" "without the temperature watchdog"
printf '41\n' >"$T/value"
quiet detect_temperature_source
eq "a working --temp-cmd keeps the watchdog on" 1 "$TEMP_GUARD"
temp_cmd=""
rm -f "${T:?}/bin/smartctl"
# without smartctl at all: a child shell whose PATH has only `date`
mkdir -p "$T/emptybin"
ln -sf "$(command -v date)" "$T/emptybin/date"
# shellcheck disable=SC2016 # the script is expanded by the child shell, not here
out="$(env PATH="$T/emptybin" "$BASH" -c 'source "$1"; detect_temperature_source 2>&1; echo "guard=$TEMP_GUARD"' _ "$here/../../lastread")"
check "missing smartctl: warn" contains "$out" "smartctl or jq is missing"
check "missing smartctl: run without the watchdog" contains "$out" "guard=0"

# without The Sleuth Kit the file level is "missing" (fixable), not "skipped"
# shellcheck disable=SC2016 # the script is expanded by the child shell, not here
out="$(env PATH="$T/emptybin" "$BASH" -c 'source "$1"; img=/dev/null no_fs=0; image_prepare 2>&1; echo "state=$FS_STATE"' _ "$here/../../lastread")"
check "image_prepare: no Sleuth Kit gives state=missing" contains "$out" "state=missing"
printf '08\n' >"$T/value"
temp_cmd="$T/tempcmd" TEMP_GUARD=1
eq "a temperature with a leading zero is decimal" 8 "$(temperature)"
temp_cmd=""

# --- rescan: when a host rescan can bring the disk back
SCSI_HOST="" TRANSPORT=""
check "no SCSI host: rescan unavailable" test -n "$(rescan_unavailable_reason)"
SCSI_HOST=host3
for tr in "" sata ata sas; do
  TRANSPORT=$tr
  eq "rescan is possible for transport '${tr:-none}'" "" "$(rescan_unavailable_reason)"
done
for tr in usb nvme mmc; do
  TRANSPORT=$tr
  check "rescan is refused for transport $tr, with the reason" contains "$(rescan_unavailable_reason)" "$tr"
done
rescan=1 TRANSPORT=usb recoveries=0
logs="" LOG=""
out="$(recover_device 2>&1)"
check "recover_device says why it cannot rescan a USB disk" contains "$out" "transport \"usb\""
rescan=0
refuse "recover_device does nothing with --no-rescan" recover_device
rescan=1
out="$(die_device 2>&1)"
check "die_device explains the transport" contains "$out" "not available"
check "die_device asks for a power cycle" contains "$out" "Power the machine fully off"

# --- the number of returns of a dropped disk in a row (stubs replace the system)
(
  sleep() { :; }
  rescan_host() { return 0; }
  resolve_device() { :; }
  device_ok() { return 1; }
  SCSI_HOST=host3 TRANSPORT="" rescan=1 recoveries=0 rescan_attempts=3 rescan_pause=0 kernel_timeout=0 source_arg=/dev/null
  logs="" LOG=""
  recover_device >/dev/null 2>&1
  recover_device >/dev/null 2>&1
  recover_device >/dev/null 2>&1
  recover_device >"$T/recover.out" 2>&1
  [[ $recoveries -eq 4 && $(cat "$T/recover.out") == *"keeps dropping: 3 returns in a row"* ]]
)
eq "recover_device gives up after --rescan-attempts returns in a row" 0 "$?"
(
  sleep() { :; }
  rescan_host() { return 0; }
  resolve_device() { :; }
  blockdev() { echo 123; }
  source_identity() { echo identity; }
  identity_check() { :; }
  TMPD="$T"
  device_ok() { return 0; }
  SCSI_HOST=host3 TRANSPORT="" rescan=1 recoveries=0 rescan_attempts=3 rescan_pause=0 kernel_timeout=0 source_arg=/dev/null
  logs="" LOG=""
  out="$(recover_device 2>&1)"
  [[ $out == *"the disk is back"* ]]
)
eq "recover_device reports the disk back when the device answers" 0 "$?"

# --- the script pins the locale
out="$(LC_ALL=de_DE.UTF-8 bash -c 'source "$1"; printf %s "$LC_ALL"' _ "$here/../../lastread")"
eq "the script pins LC_ALL=C" C "$out"

# --- owner for extraction
extract_to="$T/out"
mkdir -p "$extract_to"
owner="" SUDO_USER=""
setup_owner
eq "no --owner and no sudo: the current user, no runuser" 0 "${#RUN_AS[@]}"
owner="$(id -un)"
setup_owner
eq "--owner as the current user needs no runuser" 0 "${#RUN_AS[@]}"
owner="no-such-user-xyz"
refuse "an unknown --owner is refused" setup_owner
owner="$(id -un):no-such-group-xyz"
refuse "an unknown group is refused" setup_owner

finish
