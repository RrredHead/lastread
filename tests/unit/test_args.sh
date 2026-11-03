#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Option parsing, size parsing, validation, the silent-garbage pattern builder, --help coverage.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/../.."
# shellcheck source=../lib.sh
source "$here/../lib.sh"
# shellcheck source=../../lastread
source "$ROOT/lastread"
set +e

# --- parse_size
eq "parse_size: plain bytes" 1234 "$(parse_size 1234)"
eq "parse_size: SI suffix is a power of 1000" 1000000000 "$(parse_size 1G)"
eq "parse_size: lowercase k is accepted" 16000 "$(parse_size 16k)"
eq "parse_size: Mi is a power of 1024" 1048576 "$(parse_size 1Mi)"
eq "parse_size: 1700G" 1700000000000 "$(parse_size 1700G)"
refuse "parse_size: junk is refused" parse_size nonsense

# --- parse_args + validate_args, each case in a subshell
args_ok() { (parse_args "$@" && validate_args); }
args_val() { # args_val VARIABLE ARGS... : the value of a variable after parsing
  local v=$1
  shift
  (
    parse_args "$@" && validate_args && printf '%s' "${!v}"
  )
}
check "defaults validate" args_ok /dev/null
eq "default stop" 48 "$(args_val stop /dev/null)"
eq "default resume" 44 "$(args_val resume /dev/null)"
eq "default zone margin is 1 GB" 1000000000 "$(args_val zone_margin /dev/null)"
eq "default zone progress is 16 MiB" 16777216 "$(args_val zone_min_progress /dev/null)"
eq "default kernel timeout" 180 "$(args_val kernel_timeout /dev/null)"
eq "default rescan attempts" 3 "$(args_val rescan_attempts /dev/null)"
eq "default rescan pause" 60 "$(args_val rescan_pause /dev/null)"
eq "default interval" 60 "$(args_val interval /dev/null)"
eq "--zone-margin takes sizes" 2097152 "$(args_val zone_margin --zone-margin 2Mi /dev/null)"
eq "--dir" /x "$(args_val dir --dir /x /dev/null)"
eq "--add-zone repeats" "1G-2G 3G-4G" "$( (parse_args --add-zone 1G-2G --add-zone 3G-4G /dev/null && validate_args && printf '%s' "${add_zones[*]}"))"
refuse "--resume must be below --stop" args_ok --stop 40 --resume 40 /dev/null
refuse "--stop must be a number" args_ok --stop hot /dev/null
refuse "--interval 0 is refused" args_ok --interval 0 /dev/null
refuse "unknown option" args_ok --nonsense /dev/null
refuse "two sources" args_ok /dev/null /dev/zero
refuse "option without value" args_ok --dir
refuse "--skip-size junk" args_ok --skip-size foo /dev/null
check "--skip-size 1Mi,1Gi" args_ok --skip-size 1Mi,1Gi /dev/null
refuse "--extract needs --extract-to" args_ok --extract /dev/null
refuse "--extract-damaged needs --extract" args_ok --extract-damaged /dev/null
refuse "--extract-damaged is for a normal run" args_ok --extract --extract-to /tmp --extract-damaged --inventory
check "--extract-damaged with --extract" args_ok --extract --extract-to /tmp --extract-damaged /dev/null
refuse "--extract-to needs --extract" args_ok --extract-to /tmp /dev/null
check "--extract with --extract-to" args_ok --extract --extract-to /tmp /dev/null
check "--verify with --extract" args_ok --extract --extract-to /tmp --verify /dev/null
refuse "--verify needs --extract" args_ok --verify /dev/null
check "--overwrite with --extract" args_ok --extract --extract-to /tmp --overwrite /dev/null
refuse "--overwrite needs --extract" args_ok --overwrite /dev/null
refuse "--no-fs conflicts with --inventory" args_ok --no-fs --inventory
refuse "--no-fs conflicts with --extract" args_ok --no-fs --extract --extract-to /tmp /dev/null
refuse "--inventory conflicts with --pick" args_ok --inventory --pick
refuse "--add-zone needs FROM-TO" args_ok --add-zone 5G /dev/null
refuse "--add-zone FROM below TO" args_ok --add-zone 5G-3G /dev/null
check "--add-zone 511G-521G" args_ok --add-zone 511G-521G /dev/null
refuse "--start-at junk" args_ok --start-at 12x /dev/null
eq "--start-at 1700G" 1700000000000 "$(args_val start_at --start-at 1700G /dev/null)"
refuse "--file-mode must be octal" args_ok --file-mode 9zz /dev/null
refuse "--zone-margin junk" args_ok --zone-margin lots /dev/null

check "--inventory with --include (counts only)" args_ok --inventory --include media
refuse "--include alone makes no sense" args_ok --include media /dev/null
refuse "an invalid --suspect-pattern is refused up front" args_ok --suspect-pattern 'a(b' /dev/null
check "a valid --suspect-pattern is accepted" args_ok --suspect-pattern 'a(b)' /dev/null
eq "numbers with a leading zero are decimal" "8 7" "$( (parse_args --stop 08 --resume 07 /dev/null && validate_args && printf '%s %s' "$stop" "$resume"))"
eq "--rescan-attempts 0 means --no-rescan" 0 "$(args_val rescan --rescan-attempts 0 /dev/null)"

# --- --include / --map normalisation
inc() { (parse_args --extract --extract-to /tmp "$@" /dev/null && validate_args && printf '%s' "${includes[*]}"); }
mp() { (parse_args --extract --extract-to /tmp "$@" /dev/null && validate_args && printf '%s' "${maps[*]}"); }
eq "--include strips slashes" "a/b c" "$(inc --include /a/b/ --include c)"
eq "--map normalises" "a/b:x/y" "$(mp --map /a/b/:/x/y/)"
eq "--map with destination . means the root" "a/b:" "$(mp --map a/b:.)"
refuse "--map without colon" args_ok --extract --extract-to /tmp --map abc /dev/null
refuse "--map with .. in destination" args_ok --extract --extract-to /tmp --map a:../x /dev/null
refuse "--include empty" args_ok --extract --extract-to /tmp --include / /dev/null

# --- silent-garbage pattern
re() { (parse_args "$@" /dev/null && validate_args && printf '%s' "$SUSPECT_RE"); }
eq "default pattern: sEDU sector or 128 KiB of zeros" 'sEDU\x00{504}sEDU|(?:\x00{32768}){4}' "$(re)"
eq "--suspect-zeros 0 keeps only the tag" 'sEDU\x00{504}sEDU' "$(re --suspect-zeros 0)"
eq "--no-suspect-check disables everything" '' "$(re --no-suspect-check)"
eq "--suspect-pattern replaces the tag" '(?:abc)|(?:x\d)|(?:\x00{32768}){4}' "$(re --suspect-pattern abc --suspect-pattern 'x\d')"
eq "--suspect-zeros 100" 'sEDU\x00{504}sEDU|\x00{100}' "$(re --suspect-zeros 100)"
eq "--suspect-zeros 40000" 'sEDU\x00{504}sEDU|(?:\x00{32768}){1}\x00{7232}' "$(re --suspect-zeros 40000)"
eq "--suspect-zeros 1Mi" 'sEDU\x00{504}sEDU|(?:\x00{32768}){32}' "$(re --suspect-zeros 1Mi)"

# --- every option parse_args knows is described by --help
help_text="$(usage)"
missing=""
while read -r opt; do
  [[ $help_text == *"$opt"* ]] || missing+=" $opt"
done < <(declare -f parse_args | grep -oE -- '--[a-z][a-z-]+' | sort -u)
eq "--help describes every option" "" "$missing"

# --- the executable itself
eq "--version" "lastread $VERSION" "$("$ROOT/lastread" --version)"
"$ROOT/lastread" --help >/dev/null
eq "--help exits 0" 0 "$?"
out="$("$ROOT/lastread" --stop 10 --resume 20 /dev/null 2>&1)"
check "bad --resume is reported by the executable" contains "$out" "must be lower"
out="$("$ROOT/lastread" 2>&1)"
check "no source is reported" contains "$out" "no source"

finish
