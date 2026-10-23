#!/usr/bin/env bash
# Runs score on the fixtures with every installed shell (bash, zsh, PowerShell) and compares the output, score.tsv and
# score.json with expected.txt. The rules project rules/ registers legacy (the check items of the rules.tsv used before the
# standards existed, so the scores of findings.txt must stay the same as before), points (other points), scaled (its own
# five-level severity scale, grades and merge=true) and the common rule.
#   bash tests/score/compare.sh            compare
#   bash tests/score/compare.sh --update   rewrite expected.txt from the bash output
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
scripts="../../skills/code-review-scoring-score/scripts"

cases=(
  "--findings findings.txt --config settings.ini --standard legacy"
  "--findings findings.txt --config settings.ini --standard points"
  "--findings invalid.txt --config settings.ini --standard legacy"
  "--findings common.txt --config settings.ini --standard legacy"
  "--findings common.txt --config settings.ini --standard scaled"
  "--findings common-scaled.txt --config settings.ini --standard scaled"
  "--findings scaled-bad.txt --config settings.ini --standard scaled"
  "--findings capped.txt --config settings.ini --standard scaled"
  "--findings findings.txt --config settings.ini"
  "--findings findings.txt --config settings.ini --standard off"
  "--findings findings.txt --config settings.ini --standard nope"
  "--findings findings.txt --config none.ini --standard legacy"
  "--findings diff-check.txt --diff pr.diff --config settings.ini --standard legacy"
)

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
here="$(pwd)"; here_w="$( (pwd -W 2>/dev/null) || pwd)"; out_w="$( (cd "$out" && pwd -W 2>/dev/null) || echo "$out")"
norm() { tr -d '\r' | tr '\134' '/' | sed -e "s#$out_w#OUT#g" -e "s#$out#OUT#g" -e "s#$here_w/##g" -e "s#$here/##g"; }
# PowerShell takes -Findings, -Config, ... instead of the GNU-style options.
psargs() {
  local a
  for a in "$@"; do
    case "$a" in
      --findings) echo -Findings ;; --config) echo -Config ;; --standard) echo -Standard ;;
      --diff) echo -Diff ;; --out-dir) echo -OutDir ;; *) echo "$a" ;;
    esac
  done
}

run_all() {  # $1 = bash, zsh or powershell; prints every case with its exit code, score.tsv and score.json
  local c f rc
  local -a a; local x
  for c in "${cases[@]}"; do
    echo "### $c"
    rm -f "$out"/score.*
    # shellcheck disable=SC2086
    set -- $c --out-dir "$out_w"
    case "$sh" in
      bash) bash "$scripts/score.sh" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
      zsh) zsh "$scripts/score.zsh" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
      *) a=(); while IFS= read -r x; do a+=("$x"); done < <(psargs "$@"); "$ps" -NoProfile -ExecutionPolicy Bypass -File "$scripts/score.ps1" "${a[@]}" 2>&1 | norm; rc=${PIPESTATUS[0]} ;;
    esac
    echo "exit=$rc"
    for f in score.tsv score.json; do [[ -f "$out/$f" ]] && { echo "--- $f"; norm < "$out/$f"; }; done
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
  if diff -u expected.txt <(run_all) > "$out/$sh.diff" 2>&1; then echo "ok: $sh"
  else fail=1; echo "FAILED: $sh"; head -40 "$out/$sh.diff"; fi
done
command -v zsh >/dev/null 2>&1 || echo "skipped: zsh (not installed)"
[[ -n "$ps" ]] || echo "skipped: powershell (not installed)"
exit $fail
