#!/usr/bin/env bash
# Runs "standard plan" on the fixtures with every installed shell (bash, zsh, PowerShell) and compares the output and
# the written files with expected.txt. standards.ini has two framework standards (springboot-3: *.java, angular: *.ts)
# and the common standard; multi.diff changes both frameworks and common files at several levels.
#   bash tests/plan/compare.sh            compare
#   bash tests/plan/compare.sh --update   rewrite expected.txt from the bash output
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
scripts="../../skills/code-review-scoring/scripts"

cases=(
  "--diff multi.diff --standards standards.ini"
  "--diff common-only.diff --standards standards.ini"
  "--diff java-only.diff --standards standards.ini"
  "--diff empty.diff --standards standards.ini"
  "--diff common-only.diff --standards standards-nocommon.ini"
)

out="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$out"' EXIT
here="$(pwd)"; here_w="$( (pwd -W 2>/dev/null) || pwd)"; out_w="$( (cd "$out" && pwd -W 2>/dev/null) || echo "$out")"
root="$(cd ../.. && pwd)"; root_w="$(cd ../.. && { pwd -W 2>/dev/null || pwd; })"
norm() {
  tr -d '\r' | tr '\134' '/' | sed -e "s#$out_w#OUT#g" -e "s#$out#OUT#g" -e "s#$here_w/##g" -e "s#$here/##g" \
    -e "s#$root_w/#ROOT/#g" -e "s#$root/#ROOT/#g"
}

run_all() {  # $sh = bash, zsh or powershell; prints every case with its exit code and the files it wrote
  local c rc f
  for c in "${cases[@]}"; do
    echo "### $c"
    rm -rf "${out:?}"/*
    # shellcheck disable=SC2086
    set -- plan $c --settings none.ini --out "$out_w/plan"
    case "$sh" in
      bash) bash "$scripts/standard.sh" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
      zsh) zsh "$scripts/standard.zsh" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
      *) "$ps" -NoProfile -ExecutionPolicy Bypass -File "$scripts/standard.ps1" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
    esac
    echo "exit=$rc"
    for f in plan.tsv confirm.tsv; do [[ -f "$out/plan/$f" ]] && { echo "--- $f"; norm < "$out/plan/$f"; }; done
    for f in "$out"/plan/*.diff; do [[ -f "$f" ]] && { echo "--- ${f##*/}"; grep '^diff --git' "$f"; }; done
    for f in "$out"/plan/*.resolve; do [[ -f "$f" ]] && { echo "--- ${f##*/}"; grep -v '^check' "$f" | norm; }; done
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

fail=0
for sh in "${shells[@]}"; do
  if diff -u expected.txt <(run_all) > "$out.$sh.diff" 2>&1; then echo "ok: $sh"
  else fail=1; echo "FAILED: $sh"; head -40 "$out.$sh.diff"; fi
  rm -f "$out.$sh.diff"
done
command -v zsh >/dev/null 2>&1 || echo "skipped: zsh (not installed)"
[[ -n "$ps" ]] || echo "skipped: powershell (not installed)"
exit $fail
