#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the integration tests (root only; creates loop and device-mapper devices — use a VM).
# Usage: tests/integration/run.sh [test_name...]
# A test that prints "skip" lines (for example no scsi_debug module) still passes.
set -Eeuo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || {
  echo "root is needed; run this in a VM: tests/vm.sh integration"
  exit 1
}
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
  printf '\nINTEGRATION TESTS FAILED\n'
  exit 1
fi
printf '\nIntegration tests passed.\n'
