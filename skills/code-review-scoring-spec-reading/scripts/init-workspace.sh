#!/usr/bin/env bash
# Prepare step 1 of a review: save the PR diff and a spec-context.md skeleton under ROOT/step1.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: init-workspace.sh (--git RANGE [--repo DIR] | --input FILE) [--root DIR] [--title TEXT] [--force]
                         [--standards FILE]

  -g, --git RANGE    save git diff RANGE (e.g. origin/main...HEAD) as pr.diff
  -r, --repo DIR     repository for --git (default: current directory)
  -i, --input FILE   copy an existing unified diff file as pr.diff
      --root DIR     review root (default: tmp in the project root); files go to ROOT/step1/
  -t, --title TEXT   PR title written into spec-context.md
  -f, --force        overwrite pr.diff and spec-context.md if they already exist
      --standards FILE the registered scoring standards (default: configs/standards.ini in the project root)
  -h, --help         show this help

Writes ROOT/step1/pr.diff and ROOT/step1/spec-context.md, and prints the step1 path on the last line.
Plans the review with "standard plan" of code-review-scoring: the standards that score the PR go to
ROOT/step1/standards/ (one report per framework standard), and their confirmations go to the Severity facts of
spec-context.md. Without standards.ini (standalone use) the plan is skipped with a warning.
Exit codes: 0 ok, 2 bad arguments or input.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Project root (two levels above the physical skill folder) holds tmp/ and reports/.
project_root="$(dirname "$(dirname "$(cd "$script_dir/.." && pwd -P)")")"
skill_dir="$(dirname "$script_dir")"
git_range="" repo="." input="" root="$project_root/tmp" title="" force=0 standards="$project_root/configs/standards.ini"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--git) git_range="${2:?--git needs a value}"; shift 2 ;;
    -r|--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    -i|--input) input="${2:?--input needs a value}"; shift 2 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -t|--title) title="${2:?--title needs a value}"; shift 2 ;;
    -f|--force) force=1; shift ;;
    --standards) standards="${2:?--standards needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$git_range" && -n "$input" ]] && { echo "error: use only one of --git, --input" >&2; exit 2; }
[[ -z "$git_range" && -z "$input" ]] && { echo "error: --git or --input is required (see --help)" >&2; exit 2; }
mkdir -p "$root/step1"
dir="$(cd "$root/step1" && { pwd -W 2>/dev/null || pwd; })"
if [[ $force -eq 0 ]]; then
  for f in pr.diff spec-context.md; do
    [[ -e "$dir/$f" ]] && { echo "error: $dir/$f already exists (use --force to overwrite)" >&2; exit 2; }
  done
fi

if [[ -n "$git_range" ]]; then
  git -C "$repo" -c core.quotePath=false diff --no-color --no-ext-diff -M "$git_range" > "$dir/pr.diff" \
    || { echo "error: git diff $git_range failed" >&2; exit 2; }
  range="$git_range"
else
  [[ -f "$input" ]] || { echo "error: diff file not found: $input" >&2; exit 2; }
  cp -- "$input" "$dir/pr.diff"
  range="file: $(basename "$input")"
fi
diff_status="provided"
[[ -s "$dir/pr.diff" ]] || { diff_status="unknown"; echo "warning: the diff is empty; check the range" >&2; }

# The standards that score the PR (code-review-scoring/scripts/standard plan) and what they need to know first.
rm -rf "$dir/standards"
confirm="" note="- (no scoring standard is planned: configs/standards.ini is missing)"
if [[ ! -f "$standards" ]]; then
  echo "warning: $standards not found; the review is not planned (the workflow needs it, see setup check)" >&2
elif [[ "$diff_status" == "provided" ]]; then
  bash "$(dirname "$skill_dir")/code-review-scoring/scripts/standard.sh" plan --diff "$dir/pr.diff" --out "$dir/standards" --standards "$standards" \
    || exit 2  # plan has printed the error
  confirm="$dir/standards/confirm.tsv" note="- (the scoring standards list nothing to confirm)"
else
  note="- (no scoring standard is planned: the diff is empty)"
fi

LC_ALL=C awk -v title="$title" -v range="$range" -v created="$(date +%Y-%m-%d)" -v ds="$diff_status" -v confirm="$confirm" -v note="$note" '
  function rep(s, a, b,    i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
  BEGIN { while (confirm != "" && (getline l < confirm) > 0) { split(l, c, "\t"); cf = cf "- " c[2] " (" c[1] ") " c[3] ":\n" } if (cf == "") cf = note "\n" }
  $0 == "{{CONFIRMATIONS}}" { printf "%s", cf; next }
  { l = rep($0, "{{TITLE}}", title); l = rep(l, "{{RANGE}}", range); l = rep(l, "{{CREATED}}", created); print rep(l, "{{DIFF_STATUS}}", ds) }
' "$skill_dir/assets/spec-context-template.md" > "$dir/spec-context.md"

echo "pr.diff: $(wc -l < "$dir/pr.diff" | tr -d ' ') lines"
echo "$dir"
