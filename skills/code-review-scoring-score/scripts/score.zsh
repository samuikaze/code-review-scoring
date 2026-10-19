#!/usr/bin/env zsh
# Validate findings.txt and compute dimension scores, total and grade.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: score.zsh [--root DIR] [options]
       score.zsh --findings FILE [--diff FILE | --git RANGE [--repo DIR]] [--out-dir DIR]

      --root DIR       review root (default: tmp). Uses ROOT/step3/findings.txt and ROOT/step1/pr.diff,
                       refuses unanswered questions in step1/step3, writes ROOT/step4/score.tsv and score.json
  -f, --findings FILE  findings file (standalone use without the root layout)
  -d, --diff FILE      diff used to verify that every location is an added line
  -g, --git RANGE      run git diff RANGE as the verification diff
  -r, --repo DIR       repository for --git
  -o, --out-dir DIR    where score.tsv / score.json are written (default: ROOT/step4 or the findings dir)
  -h, --help           show this help

Exit codes: 0 ok, 1 validation failed (errors on stderr; fix and rerun),
            2 bad arguments, 3 spec-context.md still has unresolved inputs or questions.
USAGE
}

script_dir="${0:A:h}"
root="" findings="" diff="" git_range="" repo="." out_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -f|--findings) findings="${2:?--findings needs a value}"; shift 2 ;;
    -d|--diff) diff="${2:?--diff needs a value}"; shift 2 ;;
    -g|--git) git_range="${2:?--git needs a value}"; shift 2 ;;
    -r|--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    -o|--out-dir) out_dir="${2:?--out-dir needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -z "$root" && -z "$findings" ]] && root="tmp"
if [[ -n "$root" ]]; then
  [[ -d "$root" ]] || { echo "error: review root not found: $root" >&2; exit 2; }
  [[ -z "$findings" ]] && findings="$root/step3/findings.txt"
  [[ -z "$diff" && -z "$git_range" && -f "$root/step1/pr.diff" ]] && diff="$root/step1/pr.diff"
  [[ -z "$out_dir" ]] && { mkdir -p "$root/step4"; out_dir="$root/step4"; }
  # Scoring must wait until every input is resolved and every question is answered.
  ctx="$root/step1/spec-context.md"
  if [[ -f "$ctx" ]]; then
    pending="$(grep -nE '^- [a-z-]+: (unknown|pending)[[:space:]]*$|^- \[ \] ' "$ctx" || true)"
    if [[ -n "$pending" ]]; then
      echo "error: step1/spec-context.md still has unresolved inputs or open questions; ask the user first:" >&2
      echo "$pending" >&2
      exit 3
    fi
  fi
  for s in step1 step3; do
    if [[ -f "$root/$s/questions.md" && ! -f "$root/$s/answers.md" ]]; then
      echo "error: $root/$s/questions.md has no answers.md yet; ask the user first" >&2
      exit 3
    fi
  done
fi
[[ -z "$findings" ]] && { echo "error: --root or --findings is required (see --help)" >&2; exit 2; }
[[ -f "$findings" ]] || { echo "error: findings file not found: $findings" >&2; exit 2; }
[[ -z "$out_dir" ]] && out_dir="$(dirname "$findings")"

idx=""
tmp="$(mktemp)"
trap 'rm -f "$tmp" ${idx:+"$idx"}' EXIT
if [[ -n "$diff" || -n "$git_range" ]]; then
  idx="$(mktemp)"
  if [[ -n "$git_range" ]]; then
    git -C "$repo" -c core.quotePath=false diff --no-color --no-ext-diff -M "$git_range" > "$tmp" \
      || { echo "error: git diff $git_range failed" >&2; exit 2; }
  else
    [[ -f "$diff" ]] || { echo "error: diff file not found: $diff" >&2; exit 2; }
    cat -- "$diff" > "$tmp"
  fi
  LC_ALL=C awk -f "$script_dir/lib/diff-index.awk" "$tmp" > "$idx"
else
  echo "note: no diff given, location checks skipped" >&2
fi

rm -f "$out_dir/score.tsv" "$out_dir/score.json"
LC_ALL=C awk -v rules="$script_dir/rules.tsv" -v idxfile="$idx" \
  -v tsvout="$out_dir/score.tsv" -v jsonout="$out_dir/score.json" \
  -f "$script_dir/lib/score.awk" "$findings"
echo "wrote ${out_dir}/score.tsv and ${out_dir}/score.json"
