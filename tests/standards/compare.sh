#!/usr/bin/env bash
# Runs the standard lint / parse / diff / resolve / stamp cases with every installed shell (bash, zsh, PowerShell) and compares
# their output with expected.txt. Paths are normalized, so the expected output is the same on every machine.
#   bash tests/standards/compare.sh            compare
#   bash tests/standards/compare.sh --update   rewrite expected.txt from the bash output
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
scripts="../../skills/code-review-scoring/scripts"

cases=(
  "lint --file bad.md"
  "lint --file bad-common.md --common"
  "lint --file good-v1.md --scan bad-scan.tsv"
  "lint --file good-v2.md --scan good-scan.tsv"
  "lint --standards bad-standards.ini --settings none.ini"
  "lint --standards good-standards.ini"
  "lint --standards good-standards.ini springboot-3 nope"
  "lint --standards missing.ini"
  "lint --file ../../docs/templates/scoring-rule-template.md"
  "lint --scan good-scan.tsv"
  "parse --file good-v2.md"
  "parse --file bad.md"
  "parse --file nofile.md"
  "diff good-v1.md good-v2.md"
  "diff good-v1.md good-v1.md"
  "diff good-v1.md bad.md"
  "diff good-v1.md"
  "resolve --standards good-standards.ini"
  "resolve --standards good-standards.ini common"
  "resolve --standards good-standards.ini nope"
  "resolve --standards bad-standards.ini"
  "resolve --standards missing.ini"
  "stamp --file good-v2.md --scan good-scan.tsv --out stamped.tmp.tsv"
  "lint --file good-v2.md --scan stamped.tmp.tsv"
  "stamp --file bad.md --scan good-scan.tsv --out stamped.tmp.tsv"
  "stamp --file good-v2.md --out stamped.tmp.tsv"
)

here="$(pwd)"; here_w="$( (pwd -W 2>/dev/null) || pwd)"; root="$(cd ../.. && pwd)"; root_w="$(cd ../.. && { pwd -W 2>/dev/null || pwd; })"
norm() { tr -d '\r' | tr '\134' '/' | sed -e "s#$here_w/##g" -e "s#$here/##g" -e "s#$root_w/#ROOT/#g" -e "s#$root/#ROOT/#g"; }

run_all() {  # $@ = command that runs the script; prints every case with its exit code
  local c
  for c in "${cases[@]}"; do
    echo "### $c"
    # shellcheck disable=SC2086
    "$@" $c 2>&1 | norm
    echo "exit=${PIPESTATUS[0]}"
  done
  rm -f stamped.tmp.tsv
}

declare -a shells=("bash:bash $scripts/standard.sh")
command -v zsh >/dev/null 2>&1 && shells+=("zsh:zsh $scripts/standard.zsh")
ps="$(command -v pwsh || command -v powershell.exe || command -v powershell || true)"
[[ -n "$ps" ]] && shells+=("powershell:$ps -NoProfile -ExecutionPolicy Bypass -File $scripts/standard.ps1")

if [[ "${1:-}" == "--update" ]]; then
  # shellcheck disable=SC2086
  run_all bash "$scripts/standard.sh" > expected.txt
  echo "updated expected.txt"; exit 0
fi

fail=0
for s in "${shells[@]}"; do
  name="${s%%:*}"; cmd="${s#*:}"
  # shellcheck disable=SC2086
  if diff -u expected.txt <(run_all $cmd) > "/tmp/standard-compare-$name.diff" 2>&1; then echo "ok: $name"
  else fail=1; echo "FAILED: $name"; head -40 "/tmp/standard-compare-$name.diff"; fi
done
command -v zsh >/dev/null 2>&1 || echo "skipped: zsh (not installed)"
[[ -n "$ps" ]] || echo "skipped: powershell (not installed)"
exit $fail
