#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Static checks, the same as in CI: ShellCheck on every script, no eval, no `| grep -q` under
# pipefail, executable bits. Usage: tests/lint.sh
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

failed=0
bad() {
  printf 'FAIL  %s\n' "$*"
  failed=1
}
section() { printf '== %s\n' "$*"; }

mapfile -t scripts < <(
  {
    git ls-files 2>/dev/null || find . -type f -not -path './.git/*'
  } | while IFS= read -r f; do
    [[ -f $f ]] || continue
    if [[ $f == *.sh ]] || head -1 "$f" | grep -E '^#!.*\b(ba)?sh\b' >/dev/null; then printf '%s\n' "$f"; fi
  done | sort -u
)

section "ShellCheck ($(shellcheck --version | awk '/^version:/ {print $2}')) on ${#scripts[@]} scripts"
shellcheck -x "${scripts[@]}" || bad "ShellCheck found problems"

# This script talks about the forbidden constructs in comments and patterns, so it is skipped here.
checked=()
for f in "${scripts[@]}"; do [[ $f == tests/lint.sh ]] || checked+=("$f"); done

section "No eval"
if grep -nE '(^|[^a-zA-Z_])eval[[:space:]]' "${checked[@]}" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'; then bad "eval is not allowed"; fi

section "No grep -q at the end of a pipeline (pipefail + SIGPIPE gives false negatives)"
if grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "${checked[@]}"; then bad "use grep ... >/dev/null instead of grep -q in pipelines"; fi

section "Executable bits"
for f in "${scripts[@]}"; do
  [[ $f == tests/lib.sh ]] && continue
  [[ -x $f ]] || bad "$f is not executable"
done

if ((failed)); then
  printf 'Problems found.\n'
  exit 1
fi
printf 'All clean.\n'
