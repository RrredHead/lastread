#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Events (--on-event), the systemd unit (--print-service), exit codes.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/../.."
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$ROOT/lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT

# --- unit_arg escaping
eq "unit_arg quotes" '"plain"' "$(unit_arg plain)"
eq "unit_arg escapes quotes and backslashes" '"a \"b\" c\\d"' "$(unit_arg 'a "b" c\d')"
# shellcheck disable=SC2016 # literal dollar signs are the point of this test
eq "unit_arg doubles % and \$" '"100%% $$HOME"' "$(unit_arg '100% $HOME')"

# --- the unit for a command line (executed, not sourced: --print-service needs no root or device)
unit="$("$ROOT/lastread" /dev/disk/by-id/x --dir /tmp --name my-disk --extract --extract-to '/tmp/a b' --print-service)"
check "the unit has an ExecStart with the executable" contains "$unit" "ExecStart=\"$(readlink -f "$ROOT/lastread")\" \"/dev/disk/by-id/x\""
check "...with the arguments quoted" contains "$unit" '"--extract-to" "/tmp/a b"'
execline="$(grep '^ExecStart=' <<<"$unit")"
check "...and without --print-service" bash -c "[[ \$1 != *--print-service* ]]" _ "$execline"
check "a power cycle (3) and stuck zones (2) do not restart the service" contains "$unit" "RestartPreventExitStatus=2 3"
check "the unit is named after the image" contains "$unit" "lastread-my-disk.service"
check "the unit starts at boot" contains "$unit" "WantedBy=multi-user.target"
printf '%s\n' "$unit" >"$T/x.service"

# --- notify runs the program with the event, the message and the environment
cat >"$T/hook" <<H
#!/bin/sh
printf '%s|%s|%s|%s|%s\n' "\$1" "\$2" "\$LASTREAD_EVENT" "\$LASTREAD_NAME" "\$LASTREAD_DIR" >"$T/hook.out"
H
chmod +x "$T/hook"
event_cmd="$T/hook" name=example dir=/data LOG="" map=""
notify hot "too hot: 49"
for _ in $(seq 1 50); do [[ -s $T/hook.out ]] && break; sleep 0.1; done
eq "notify: arguments and environment" "hot|too hot: 49|hot|example|/data" "$(cat "$T/hook.out")"
event_cmd=""
rm -f "$T/hook.out"
notify hot "x"
sleep 0.3
check "notify without a program does nothing" test ! -e "$T/hook.out"
event_cmd="$T/no-such-program"
notify hot "x"
eq "notify with a missing program does not fail" 0 "$?"
event_cmd=""

# --- exit codes
( die_code 3 "power" ) >/dev/null 2>&1
eq "die_code 3 exits with 3" 3 "$?"
( die "x" ) >/dev/null 2>&1
eq "die exits with 1" 1 "$?"

finish
