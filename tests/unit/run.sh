#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs every unit test (no root, no devices). Needs: bash, GNU ddrescue (ddrescuelog), jq, coreutils,
# util-linux, grep with -P. Usage: tests/unit/run.sh [test_name...]
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
if (($#)); then
  tests=()
  for n in "$@"; do tests+=("$here/${n%.sh}.sh"); done
else
  tests=("$here"/test_*.sh)
fi
for t in "${tests[@]}"; do
  printf '\n### %s\n' "${t##*/}"
  bash "$t" || failed=1
done
if ((failed)); then
  printf '\nUNIT TESTS FAILED\n'
  exit 1
fi
printf '\nUnit tests passed.\n'
