#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Silent garbage: the data check (grep -P) on synthetic files.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$here/../../lastread"
set +e

T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT

# hits FILE: how many "lines" of FILE match the current SUSPECT_RE (as extract_files counts)
hits() { grep -c -aP "$SUSPECT_RE" "$1"; }
build() { (parse_args "$@" /dev/null && validate_args && printf '%s' "$SUSPECT_RE"); }

# Test data: 1 MiB of random bytes with planted spots.
base() { head -c $((1024 * 1024)) /dev/urandom >"$1"; }
plant_sector() { # plant_sector FILE OFFSET: a service sector "sEDU" + 504 zero bytes + "sEDU"
  { printf 'sEDU'; head -c 504 /dev/zero; printf 'sEDU'; } | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}
plant_zeros() { head -c "$2" /dev/zero | dd of="$1" bs=1 seek="$3" conv=notrunc status=none; }

SUSPECT_RE="$(build)"
base "$T/clean"
eq "clean random data is not suspicious" 0 "$(hits "$T/clean")"
base "$T/sector"
plant_sector "$T/sector" 4096
eq "a service sector (sEDU ... sEDU) is found" 1 "$(hits "$T/sector")"
base "$T/sector2"
plant_sector "$T/sector2" 4096
plant_sector "$T/sector2" 600000
check "two service sectors are found" test "$(hits "$T/sector2")" -ge 1
base "$T/zeros128"
plant_zeros "$T/zeros128" $((128 * 1024)) 10000
eq "128 KiB of zeros is found" 1 "$(hits "$T/zeros128")"
base "$T/zeros127"
plant_zeros "$T/zeros127" $((127 * 1024)) 10000
eq "127 KiB of zeros is normal" 0 "$(hits "$T/zeros127")"
base "$T/halftag"
{ printf 'sEDU'; head -c 504 /dev/zero; printf 'xEDU'; } | dd of="$T/halftag" bs=1 seek=4096 conv=notrunc status=none
eq "a tag without its twin at the end is not a service sector" 0 "$(hits "$T/halftag")"

SUSPECT_RE="$(build --suspect-zeros 1Ki)"
eq "--suspect-zeros 1Ki: 1 KiB of zeros is found" 1 "$(hits "$T/zeros127")"
SUSPECT_RE="$(build --suspect-zeros 0)"
eq "--suspect-zeros 0: long zeros are fine" 0 "$(hits "$T/zeros128")"
eq "--suspect-zeros 0: the tag still counts" 1 "$(hits "$T/sector")"
SUSPECT_RE="$(build --suspect-pattern 'BADBAD')"
base "$T/custom"
printf 'xxBADBADyy' | dd of="$T/custom" bs=1 seek=777 conv=notrunc status=none
eq "--suspect-pattern: a custom pattern is found" 1 "$(hits "$T/custom")"
eq "--suspect-pattern replaces the built-in tag" 0 "$(hits "$T/sector")"
SUSPECT_RE="$(build --suspect-pattern 'BADBAD' --suspect-pattern '\x00{200}')"
eq "--suspect-pattern repeats: the second pattern works" 1 "$(hits "$T/sector")"
SUSPECT_RE="$(build --suspect-zeros 1Mi)"
{ head -c $((512 * 1024)) /dev/urandom; head -c $((1024 * 1024)) /dev/zero; head -c 1024 /dev/urandom; } >"$T/bigzeros"
eq "--suspect-zeros 1Mi: a 1 MiB run is found (nested repeat count)" 1 "$(hits "$T/bigzeros")"
eq "--no-suspect-check builds no pattern" "" "$(build --no-suspect-check)"

finish
