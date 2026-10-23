#!/usr/bin/env zsh
# Preprocess a PR diff: drop non-reviewable files, number new-file lines, list heuristic candidates.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: prepare-diff.zsh [--root DIR | --input FILE | --git RANGE] [options]

      --root DIR       read ROOT/step1/pr.diff and write ROOT/step3/prepared.txt (unless --out is given);
                       without --root, --input and --git, ROOT is tmp in the project root. With the review plan
                       ROOT/step1/standards/plan.tsv: read the diff of the standard (ROOT/step1/standards/NAME.diff),
                       list only its code review comments and write ROOT/step3/NAME/prepared.txt
  -i, --input FILE     unified diff file; '-' = stdin
  -g, --git RANGE      run git diff RANGE (e.g. origin/main...HEAD)
  -r, --repo DIR       repository for --git (default: current directory)
  -m, --mode MODE      all (default) | summary | scan | view
      --max N          max locations listed per check (default 15)
  -o, --out FILE       write output to FILE (UTF-8) instead of stdout
      --config FILE    the settings whose [rules] root names the rules project (default: configs/settings.ini in the
                       project root)
      --standard NAME  the scoring standard (an enabled rule of rules.ini) whose scan rules, severity scale and merge
                       are used; default: the only enabled framework rule, or the common rule when no framework rule is
                       enabled. Files its applies does not cover are scanned with the rules of the common rule
      --scan FILE      use this scan rule file for every file instead of the rules project (no severity scale)
  -h, --help           show this help

Output: summary, code review comments of ROOT/step2 with their ids (root mode only), heuristic candidates
(clues only), compact diff with new-file line numbers.
Exit codes: 0 ok, 2 bad arguments or input, or a missing or invalid standard or scan rule file (run standard lint).
USAGE
}

script_dir="${0:A:h}"
# Project root (two levels above the physical skill folder) holds tmp/ and reports/.
project_root="${script_dir:h:h:h}"
skills_dir="${script_dir:h:h}"
config="$project_root/configs/settings.ini" standard="" scan="" crdir="" cplan="" cstd="" sub="" root="" input="" git_range="" repo="." mode="all" max=15 out=""
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
    --standards) echo "error: --standards was removed: the rules come from [rules] root of the settings (--config)" >&2; exit 2 ;;
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
  # With a review plan (step 1 of the workflow), each standard has its own diff and step folders.
  if [[ -f "$root/step1/standards/plan.tsv" ]]; then
    cplan="$root/step1/standards/plan.tsv"
    [[ -n "$standard" ]] || standard="$(awk -F'\t' '$1 == "report" { n++; s = $2 } END { if (n == 1) print s }' "$cplan")"
    [[ -n "$standard" ]] || { echo "error: several standards score this review (see $cplan); pass --standard NAME" >&2; exit 2; }
    awk -F'\t' -v s="$standard" '$1 == "report" && $2 == s { f = 1 } END { exit !f }' "$cplan" \
      || { echo "error: the standard $standard does not score this review (see $cplan)" >&2; exit 2; }
    cstd="$standard" sub="/$standard"
  fi
  [[ -n "$cstd" ]] && input="$root/step1/standards/$cstd.diff"
  [[ -z "$out" ]] && { mkdir -p "$root/step3$sub"; out="$root/step3$sub/prepared.txt"; }
fi

tmp="$(mktemp)" std="$(mktemp)"
trap 'rm -f "$tmp" "$std"' EXIT
# Scan rules, file scopes, severity scale and merge of the standard (code-review-scoring/scripts/standard resolve).
if [[ -n "$scan" ]]; then
  [[ -z "$standard" ]] || { echo "error: use only one of --standard, --scan" >&2; exit 2; }
  [[ -f "$scan" ]] || { echo "error: scan rule file not found: $scan" >&2; exit 2; }
  printf 'scan\t%s\n' "$scan" > "$std"
elif [[ -n "$cstd" ]]; then
  # The standard as step 1 planned it (the workflow refuses to go on when it has changed since).
  tr -d '\r' < "$root/step1/standards/$cstd.resolve" > "$std"
else
  zsh "$skills_dir/code-review-scoring/scripts/standard.zsh" resolve --settings "$config" ${standard:+"$standard"} \
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

run() { LC_ALL=C awk -v std="$std" -v mode="$mode" -v maxper="$max" -v crdir="$crdir" -v cplan="$cplan" -v cstd="$cstd" -f "$script_dir/lib/prepare.awk" "$tmp"; }
if [[ -n "$out" ]]; then
  run > "$out"
  echo "wrote ${out} ($(wc -l < "$out" | tr -d ' ') lines)"
else
  run
fi
