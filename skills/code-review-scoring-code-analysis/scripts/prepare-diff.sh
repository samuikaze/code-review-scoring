#!/usr/bin/env bash
# Preprocess a PR diff: drop non-reviewable files, number new-file lines, list heuristic candidates.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: prepare-diff.sh [--root DIR | --input FILE | --git RANGE] [options]

      --root DIR       read ROOT/step1/pr.diff and write ROOT/step3/prepared.txt (unless --out is given);
                       without --root, --input and --git, ROOT is tmp in the project root
  -i, --input FILE     unified diff file; '-' = stdin
  -g, --git RANGE      run git diff RANGE (e.g. origin/main...HEAD)
  -r, --repo DIR       repository for --git (default: current directory)
  -m, --mode MODE      all (default) | summary | scan | view
      --max N          max locations listed per check (default 15)
  -o, --out FILE       write output to FILE (UTF-8) instead of stdout
      --config FILE    configs/settings.ini whose [deductions] merge is shown in the summary
                       (default: configs/settings.ini in the project root; missing = false)
      --standard NAME  the scoring standard (a section of standards.ini) whose scan rules are used; default: the only
                       framework standard, or the common standard when no framework standard is registered. Files its
                       applies does not cover are scanned with the rules of the common standard
      --standards FILE the registered standards (default: configs/standards.ini in the project root)
      --scan FILE      use this scan rule file for every file instead of the registered standards
  -h, --help           show this help

Output: summary, code review comments of ROOT/step2 with their ids (root mode only), heuristic candidates
(clues only), compact diff with new-file line numbers.
Exit codes: 0 ok, 2 bad arguments or input, or a missing or invalid standard or scan rule file (run standard lint).
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Project root (two levels above the physical skill folder) holds tmp/ and reports/.
project_root="$(dirname "$(dirname "$(cd "$script_dir/.." && pwd -P)")")"
skills_dir="$(dirname "$(cd "$script_dir/.." && pwd -P)")"
config="$project_root/configs/settings.ini" standards="$project_root/configs/standards.ini" standard="" scan="" crdir="" root="" input="" git_range="" repo="." mode="all" max=15 out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -i|--input) input="${2:?--input needs a value}"; shift 2 ;;
    -g|--git) git_range="${2:?--git needs a value}"; shift 2 ;;
    -r|--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    -m|--mode) mode="${2:?--mode needs a value}"; shift 2 ;;
    --max) max="${2:?--max needs a value}"; shift 2 ;;
    -o|--out) out="${2:?--out needs a value}"; shift 2 ;;
    --config) config="${2:?--config needs a value}"; shift 2 ;;
    --standard) standard="${2:?--standard needs a value}"; shift 2 ;;
    --standards) standards="${2:?--standards needs a value}"; shift 2 ;;
    --scan) scan="${2:?--scan needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
case "$mode" in all|summary|scan|view) ;; *) echo "error: --mode must be all, summary, scan or view" >&2; exit 2 ;; esac
sources=0
[[ -n "$root" ]] && sources=$((sources + 1))
[[ -n "$input" ]] && sources=$((sources + 1))
[[ -n "$git_range" ]] && sources=$((sources + 1))
[[ $sources -gt 1 ]] && { echo "error: use only one of --root, --input, --git" >&2; exit 2; }
[[ $sources -eq 0 ]] && root="$project_root/tmp"
if [[ -n "$root" ]]; then
  input="$root/step1/pr.diff"
  crdir="$root/step2"
  [[ -z "$out" ]] && { mkdir -p "$root/step3"; out="$root/step3/prepared.txt"; }
fi

# [deductions] merge decides how findings.txt is written; the scoring step validates it the same way.
merge="false"
if [[ -f "$config" ]]; then
  merge="$(LC_ALL=C awk '
    /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", s); next }
    s == "deductions" && /^[ \t]*merge[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v); gsub(/^"|"$/, "", v); val = tolower(v) }
    END { print (val == "" ? "false" : val) }' "$config")"
  [[ "$merge" == "true" || "$merge" == "false" ]] || { echo "error: [deductions] merge in $config must be true or false, not $merge" >&2; exit 2; }
fi

tmp="$(mktemp)" std="$(mktemp)"
trap 'rm -f "$tmp" "$std"' EXIT
# Scan rules and file scopes of the standard (code-review-scoring/scripts/standard resolve).
if [[ -n "$scan" ]]; then
  [[ -z "$standard" ]] || { echo "error: use only one of --standard, --scan" >&2; exit 2; }
  [[ -f "$scan" ]] || { echo "error: scan rule file not found: $scan" >&2; exit 2; }
  printf 'scan\t%s\n' "$scan" > "$std"
else
  bash "$skills_dir/code-review-scoring/scripts/standard.sh" resolve --standards "$standards" --settings "$config" ${standard:+"$standard"} \
    > "$std" || exit 2  # resolve has printed the error
fi
if [[ -n "$git_range" ]]; then
  git -C "$repo" -c core.quotePath=false diff --no-color --no-ext-diff -M "$git_range" > "$tmp" \
    || { echo "error: git diff $git_range failed" >&2; exit 2; }
elif [[ "$input" == "-" ]]; then
  [[ -t 0 ]] && { echo "error: --input - needs a diff piped to stdin (see --help)" >&2; exit 2; }
  cat > "$tmp"
else
  [[ -f "$input" ]] || { echo "error: diff file not found: $input" >&2; exit 2; }
  cat -- "$input" > "$tmp"
fi

run() { LC_ALL=C awk -v std="$std" -v mode="$mode" -v maxper="$max" -v merge="$merge" -v crdir="$crdir" -f "$script_dir/lib/prepare.awk" "$tmp"; }
if [[ -n "$out" ]]; then
  run > "$out"
  echo "wrote ${out} ($(wc -l < "$out" | tr -d ' ') lines)"
else
  run
fi
