#!/usr/bin/env bash
# Runs prepare-diff on the fixtures with every installed shell (bash, zsh, PowerShell) and compares the output with
# expected.txt. pr.diff is a Spring Boot PR with common files (README, CI, shell, Dockerfile); legacy.tsv has the scan
# rules used before the standards existed, common.tsv those of the common standard of tests/score.
#   bash tests/prepare/compare.sh            compare
#   bash tests/prepare/compare.sh --update   rewrite expected.txt from the bash output
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
scripts="../../skills/code-review-scoring-code-analysis/scripts"

cases=(
  "--input pr.diff --config none.ini --standards standards.ini"
  "--input no-test.diff --mode scan --config none.ini --standards standards.ini"
  "--input pr.diff --mode scan --config none.ini --standards standards.ini --standard common"
  "--input pr.diff --mode summary --config none.ini --standards standards-noscan.ini"
  "--input pr.diff --mode scan --config none.ini --standards standards-noscan.ini"
  "--input pr.diff --mode scan --config none.ini --scan legacy.tsv"
  "--input pr.diff --mode scan --config none.ini --scan bad.tsv"
  "--input pr.diff --config none.ini --standards missing.ini"
  "--input pr.diff --config none.ini --standards standards.ini --standard nope"
)

here="$(pwd)"; here_w="$( (pwd -W 2>/dev/null) || pwd)"
norm() { tr -d '\r' | tr '\134' '/' | sed -e "s#$here_w/##g" -e "s#$here/##g"; }
# PowerShell takes -InputPath, -Mode, ... instead of the GNU-style options.
psargs() {
  local a
  for a in "$@"; do
    case "$a" in
      --input) echo -InputPath ;; --mode) echo -Mode ;; --config) echo -Config ;; --standards) echo -Standards ;;
      --standard) echo -Standard ;; --scan) echo -Scan ;; *) echo "$a" ;;
    esac
  done
}

run_all() {  # $sh = bash, zsh or powershell; prints every case with its exit code
  local c rc
  local -a a
  for c in "${cases[@]}"; do
    echo "### $c"
    # shellcheck disable=SC2086
    set -- $c
    case "$sh" in
      bash) bash "$scripts/prepare-diff.sh" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
      zsh) zsh "$scripts/prepare-diff.zsh" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
      *) mapfile -t a < <(psargs "$@"); "$ps" -NoProfile -ExecutionPolicy Bypass -File "$scripts/prepare-diff.ps1" "${a[@]}" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
    esac
    echo "exit=$rc"
  done
}

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)
ps="$(command -v pwsh || command -v powershell.exe || command -v powershell || true)"
[[ -n "$ps" ]] && shells+=(powershell)

if [[ "${1:-}" == "--update" ]]; then
  sh=bash run_all > expected.txt
  echo "updated expected.txt"; exit 0
fi

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
fail=0
for sh in "${shells[@]}"; do
  if diff -u expected.txt <(run_all) > "$out/$sh.diff" 2>&1; then echo "ok: $sh"
  else fail=1; echo "FAILED: $sh"; head -40 "$out/$sh.diff"; fi
done
command -v zsh >/dev/null 2>&1 || echo "skipped: zsh (not installed)"
[[ -n "$ps" ]] || echo "skipped: powershell (not installed)"
exit $fail
