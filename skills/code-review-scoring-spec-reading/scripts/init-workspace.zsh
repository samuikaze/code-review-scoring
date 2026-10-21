#!/usr/bin/env zsh
# Prepare step 1 of a review: save the PR diff and a spec-context.md skeleton under ROOT/step1.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: init-workspace.zsh (--git RANGE [--repo DIR] | --input FILE) [--root DIR] [--title TEXT] [--force]

  -g, --git RANGE    save git diff RANGE (e.g. origin/main...HEAD) as pr.diff
  -r, --repo DIR     repository for --git (default: current directory)
  -i, --input FILE   copy an existing unified diff file as pr.diff
      --root DIR     review root (default: tmp in the project root); files go to ROOT/step1/
  -t, --title TEXT   PR title written into spec-context.md
  -f, --force        overwrite pr.diff and spec-context.md if they already exist
  -h, --help         show this help

Writes ROOT/step1/pr.diff and ROOT/step1/spec-context.md, and prints the step1 path on the last line.
Exit codes: 0 ok, 2 bad arguments or input.
USAGE
}

script_dir="${0:A:h}"
# Project root (two levels above the physical skill folder) holds tmp/ and reports/.
project_root="${script_dir:h:h:h}"
skill_dir="${script_dir:h}"
git_range="" repo="." input="" root="$project_root/tmp" title="" force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--git) git_range="${2:?--git needs a value}"; shift 2 ;;
    -r|--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    -i|--input) input="${2:?--input needs a value}"; shift 2 ;;
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -t|--title) title="${2:?--title needs a value}"; shift 2 ;;
    -f|--force) force=1; shift ;;
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

LC_ALL=C awk -v title="$title" -v range="$range" -v created="$(date +%Y-%m-%d)" -v ds="$diff_status" '
  function rep(s, a, b,    i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
  { l = rep($0, "{{TITLE}}", title); l = rep(l, "{{RANGE}}", range); l = rep(l, "{{CREATED}}", created); print rep(l, "{{DIFF_STATUS}}", ds) }
' "$skill_dir/assets/spec-context-template.md" > "$dir/spec-context.md"

echo "pr.diff: $(wc -l < "$dir/pr.diff" | tr -d ' ') lines"
echo "$dir"
