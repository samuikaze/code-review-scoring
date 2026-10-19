#!/usr/bin/env bash
# Render the PR score report from the review root (tmp/stepN files) and the report template.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: render-report.sh [--root DIR] [options]

      --root DIR       review root (default: tmp). Reads ROOT/step1/spec-context.md, ROOT/step2/findings.txt,
                       ROOT/step3/score.tsv, ROOT/step3/score.json and the code review results in ROOT/step4/
  -t, --template FILE  report template (default: assets/report-template.md of this skill)
  -l, --labels FILE    display labels (default: assets/labels.tsv of this skill)
      --title TEXT     PR title (default: "- Title:" line of spec-context.md)
  -o, --out FILE       working copy (default: ROOT/step5/report.md); '-' = stdout only, nothing is published
      --reports DIR    where the final report is published (default: reports)
      --no-publish     only write the working copy

The final report is published as REPORTS/<YYYY-MM-DD>_<PR title>.md (the same name is overwritten when the
same PR is rendered again on the same day); its path is recorded in ROOT/step5/report-path.txt.
Without ROOT/step4/plan.tsv the code review section says that no code review was run.
  -h, --help           show this help

Exit codes: 0 ok, 1 inputs missing or inconsistent (rerun the scoring skill), 2 bad arguments.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(dirname "$script_dir")"
root="tmp" template="$skill_dir/assets/report-template.md" labels="$skill_dir/assets/labels.tsv" title="" out=""
reports="reports" publish=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -t|--template) template="${2:?--template needs a value}"; shift 2 ;;
    -l|--labels) labels="${2:?--labels needs a value}"; shift 2 ;;
    --title) title="${2:?--title needs a value}"; shift 2 ;;
    -o|--out) out="${2:?--out needs a value}"; shift 2 ;;
    --reports) reports="${2:?--reports needs a value}"; shift 2 ;;
    --no-publish) publish=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
findings="$root/step2/findings.txt"
for f in "$findings" "$template" "$labels"; do
  [[ -f "$f" ]] || { echo "error: file not found: $f" >&2; exit 2; }
done
for f in score.tsv score.json; do
  [[ -f "$root/step3/$f" ]] || { echo "error: $root/step3/$f not found; run the scoring skill first" >&2; exit 1; }
  [[ "$findings" -nt "$root/step3/$f" ]] && { echo "error: findings.txt changed after $f was written; rerun the scoring skill" >&2; exit 1; }
done
ctx=""; [[ -f "$root/step1/spec-context.md" ]] && ctx="$root/step1/spec-context.md"
crdir=""
if [[ -f "$root/step4/plan.tsv" ]]; then
  crdir="$root/step4"
  while IFS=$'\t' read -r p _; do
    [[ -n "$p" ]] || continue
    [[ -s "$crdir/$p/cr.txt" ]] || { echo "error: $crdir/$p/cr.txt not found; the code review step has not finished" >&2; exit 1; }
  done < "$crdir/plan.tsv"
fi
[[ -z "$out" ]] && { mkdir -p "$root/step5"; out="$root/step5/report.md"; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
LC_ALL=C awk -v labels="$labels" -v findings="$findings" \
  -v scoretsv="$root/step3/score.tsv" -v scorejson="$root/step3/score.json" \
  -v ctx="$ctx" -v title="$title" -v today="$(date +%Y-%m-%d)" -v crdir="$crdir" \
  -f "$script_dir/lib/render.awk" "$template" > "$tmp"
if [[ "$out" == "-" ]]; then cat "$tmp"; exit 0; fi
cp "$tmp" "$out"
echo "wrote ${out}"
[[ $publish -eq 1 ]] || exit 0

# Publish the final report: REPORTS/<date>_<title>.md, with characters that are unsafe in file names replaced.
name="$title"
[[ -z "$name" && -n "$ctx" ]] && name="$(sed -n 's/^- Title:[[:space:]]*//p' "$ctx" | head -1)"
name="$(printf '%s' "$name" | LC_ALL=C sed -E 's/[][\/:*?"<>|#%{}[:space:][:cntrl:]]+/-/g; s/^[-.]+//; s/[-.]+$//')"
[[ -n "$name" ]] || name="pr-review"
mkdir -p "$reports"
final="$reports/$(date +%Y-%m-%d)_${name}.md"
cp "$tmp" "$final"
final_abs="$(cd "$(dirname "$final")" && pwd)/$(basename "$final")"
[[ "$out" == "$root/step5/report.md" ]] && printf '%s\n' "$final_abs" > "$root/step5/report-path.txt"
echo "published ${final_abs}"
