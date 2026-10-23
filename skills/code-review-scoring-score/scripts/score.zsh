#!/usr/bin/env zsh
# Validate findings.txt and compute dimension scores, total and grade.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: score.zsh [--root DIR] [options]
       score.zsh --findings FILE [--diff FILE | --git RANGE [--repo DIR]] [--out-dir DIR]

      --root DIR       review root (default: tmp in the project root). Uses ROOT/step3/findings.txt and ROOT/step1/pr.diff,
                       refuses unanswered questions in step1/step3, checks that every comment of a mapped code review
                       plugin in ROOT/step2 is deducted or rejected, writes ROOT/step4/score.tsv and score.json.
                       With the review plan ROOT/step1/standards/plan.tsv: ROOT/step3/NAME/findings.txt, the diff
                       ROOT/step1/standards/NAME.diff, the comments on the files of NAME, ROOT/step4/NAME/
  -f, --findings FILE  findings file (standalone use without the root layout)
  -d, --diff FILE      diff used to verify that every location is an added line
  -g, --git RANGE      run git diff RANGE as the verification diff
  -r, --repo DIR       repository for --git
  -o, --out-dir DIR    where score.tsv / score.json are written (default: ROOT/step4 or the findings dir)
      --check          validate findings.txt only (same checks, exit codes 0/1/2/3), write nothing; step 3 runs it
                       before reporting success
      --config FILE    the settings whose [rules] root names the rules project (default: configs/settings.ini in the
                       project root). The points, severity scale, grades and merge come from the rule.ini of the
                       standard or defaults.ini of the rules project
      --standard NAME  the scoring standard (an enabled rule of rules.ini); default: the only enabled framework rule, or
                       the common rule when no framework rule is enabled. Its check items and those of the common
                       rule are used
  -h, --help           show this help

Exit codes: 0 ok, 1 validation failed (errors on stderr; fix and rerun),
            2 bad arguments, invalid rules project or standards (run standard lint), 3 spec-context.md still has unresolved inputs or questions.
USAGE
}

script_dir="${0:A:h}"
# Project root (two levels above the physical skill folder) holds tmp/, reports/ and configs/settings.ini.
project_root="${script_dir:h:h:h}"
skills_dir="${script_dir:h:h}"
standard=""
root="" findings="" diff="" git_range="" repo="." out_dir="" cplan="" cstd="" sub="" config="$project_root/configs/settings.ini" crdir="" check=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -f|--findings) findings="${2:?--findings needs a value}"; shift 2 ;;
    -d|--diff) diff="${2:?--diff needs a value}"; shift 2 ;;
    -g|--git) git_range="${2:?--git needs a value}"; shift 2 ;;
    -r|--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    -o|--out-dir) out_dir="${2:?--out-dir needs a value}"; shift 2 ;;
    --config) config="${2:?--config needs a value}"; shift 2 ;;
    --standard) standard="${2:?--standard needs a value}"; shift 2 ;;
    --standards) echo "error: --standards was removed: the rules come from [rules] root of the settings (--config)" >&2; exit 2 ;;
    --check) check=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -z "$root" && -z "$findings" ]] && root="$project_root/tmp"
if [[ -n "$root" ]]; then
  [[ -d "$root" ]] || { echo "error: review root not found: $root" >&2; exit 2; }
  # With a review plan (step 1 of the workflow), each standard has its own diff and step folders.
  if [[ -f "$root/step1/standards/plan.tsv" ]]; then
    cplan="$root/step1/standards/plan.tsv"
    [[ -n "$standard" ]] || standard="$(awk -F'\t' '$1 == "report" { n++; s = $2 } END { if (n == 1) print s }' "$cplan")"
    [[ -n "$standard" ]] || { echo "error: several standards score this review (see $cplan); pass --standard NAME" >&2; exit 2; }
    awk -F'\t' -v s="$standard" '$1 == "report" && $2 == s { f = 1 } END { exit !f }' "$cplan" \
      || { echo "error: the standard $standard does not score this review (see $cplan)" >&2; exit 2; }
    cstd="$standard" sub="/$standard"
  fi
  [[ -z "$findings" ]] && findings="$root/step3$sub/findings.txt"
  crdir="$root/step2"
  [[ -z "$diff" && -z "$git_range" && -n "$cstd" ]] && diff="$root/step1/standards/$cstd.diff"
  [[ -z "$diff" && -z "$git_range" && -f "$root/step1/pr.diff" ]] && diff="$root/step1/pr.diff"
  [[ -z "$out_dir" && $check -eq 0 ]] && { mkdir -p "$root/step4$sub"; out_dir="$root/step4$sub"; }
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
  for s in step1 "step3$sub"; do
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
tmp="$(mktemp)" rules="$(mktemp)"
trap 'rm -f "$tmp" "$rules" ${idx:+"$idx"}' EXIT
# The standard as "standard resolve" prints it (code-review-scoring/scripts/standard.sh): check items, points, severity
# scale and grades. With the review plan, the standard as step 1 planned it (the workflow refuses to go on when it has
# changed since).
if [[ -n "$cstd" ]]; then
  tr -d '\r' < "$root/step1/standards/$cstd.resolve" > "$rules"
else
  zsh "$skills_dir/code-review-scoring/scripts/standard.zsh" resolve --settings "$config" ${standard:+"$standard"} \
    > "$rules" || exit 2  # resolve has printed the error
fi
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

[[ $check -eq 1 ]] || rm -f "$out_dir/score.tsv" "$out_dir/score.json"
LC_ALL=C awk -v rules="$rules" -v idxfile="$idx" -v crdir="$crdir" -v cplan="$cplan" -v cstd="$cstd" \
  -v tsvout="$out_dir/score.tsv" -v jsonout="$out_dir/score.json" -v checkonly="$check" \
  -f "$script_dir/lib/score.awk" "$findings"
[[ $check -eq 1 ]] || echo "wrote ${out_dir}/score.tsv and ${out_dir}/score.json"
