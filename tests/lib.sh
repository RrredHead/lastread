#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
# Tiny test helpers shared by tests/unit/*.sh and tests/integration/*.sh.
#   pass/fail DESC   check DESC CMD...   eq DESC EXPECTED ACTUAL   finish
# A test file sources this, then sources the tool (the tool only runs main when executed).

T_PASS=0 T_FAIL=0 T_SKIP=0
pass() {
  T_PASS=$((T_PASS + 1))
  printf 'ok    %s\n' "$1"
}
fail() {
  T_FAIL=$((T_FAIL + 1))
  printf 'FAIL  %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/        /'
}
skip() {
  T_SKIP=$((T_SKIP + 1))
  printf 'skip  %s\n' "$1"
}
# check DESC CMD...: passes if the command succeeds.
check() {
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}
# refuse DESC CMD...: passes if the command fails (run in a subshell: die() exits).
refuse() {
  local desc=$1
  shift
  if (
    set +e
    "$@"
  ) >/dev/null 2>&1; then fail "$desc (expected a failure)"; else pass "$desc"; fi
}
# eq DESC EXPECTED ACTUAL
eq() {
  if [[ $3 == "$2" ]]; then pass "$1"; else fail "$1" "expected: $2"$'\n'"actual:   $3"; fi
}
finish() {
  printf '== %s: %d passed, %d failed, %d skipped\n' "${0##*/}" "$T_PASS" "$T_FAIL" "$T_SKIP"
  ((T_FAIL == 0))
}
# contains HAYSTACK NEEDLE: succeeds if HAYSTACK has NEEDLE as a substring.
contains() { [[ $1 == *"$2"* ]]; }
# mkmap FILE: writes a ddrescue map from stdin lines "START SIZE STATUS" (decimal bytes).
mkmap() {
  local start size st
  {
    printf '# Mapfile. Created by GNU ddrescue version 1.27\n# Command line: ddrescue test\n'
    printf '# current_pos  current_status  current_pass\n0x00000000     ?               1\n'
    printf '#      pos        size  status\n'
    while read -r start size st; do printf '0x%X  0x%X  %s\n' "$start" "$size" "$st"; done
  } >"$1"
}
# decmap FILE: the blocks of a map as decimal "START SIZE STATUS" lines (status line skipped).
decmap() {
  local pos size st
  while read -r pos size st; do printf '%d %d %s\n' "$((pos))" "$((size))" "$st"; done < <(awk '!/^#/ && ++n > 1' "$1")
}
