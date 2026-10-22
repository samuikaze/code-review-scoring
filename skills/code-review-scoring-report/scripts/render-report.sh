#!/usr/bin/env bash
# Render the PR score report from the review root (tmp/stepN files) and the report template.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: render-report.sh [--root DIR] [options]

      --root DIR       review root (default: tmp in the project root). Reads ROOT/step1/spec-context.md, ROOT/step3/findings.txt,
                       ROOT/step4/score.tsv, ROOT/step4/score.json and the code review results in ROOT/step2/
  -t, --template FILE  report template (default: report-template.md of the report language, see below)
  -l, --labels FILE    display labels (default: labels.tsv of the report language)
      --config FILE    settings whose [language] report picks the report language (default: configs/settings.ini)
      --title TEXT     PR title (default: "- Title:" line of spec-context.md)
  -o, --out FILE       working copy (default: ROOT/step5/report.md); '-' = stdout only, nothing is published
      --reports DIR    where the final report is published (default: reports next to the review root)
      --no-publish     only write the working copy
      --standard NAME  with the review plan ROOT/step1/standards/plan.tsv: the report of the standard NAME (default: the
                       only one). Reads ROOT/step3/NAME/ and ROOT/step4/NAME/, shows only the code review comments on
                       its files and writes ROOT/step5/NAME/

The final report is published as REPORTS/<YYYY-MM-DD>_<PR title>.md, or <YYYY-MM-DD>_<PR title>_<standard>.md with
the review plan (the same name is overwritten when the same PR is rendered again on the same day); its path is
recorded in ROOT/step5/report-path.txt (ROOT/step5/NAME/ with the review plan).
Without ROOT/step2/plan.tsv the code review section says that no code review was run.
Report language: templates/ in the project root holds report-template.md and labels.tsv of one language (right in
templates/ or in a single templates/<language>/ folder), which is always used, or of several templates/<language>/
folders, of which [language] report of the settings picks one (default: zh-tw).
  -h, --help           show this help

Exit codes: 0 ok, 1 inputs missing or inconsistent (rerun the scoring skill), 2 bad arguments.
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Project root (two levels above the physical skill folder) holds tmp/ and reports/.
project_root="$(dirname "$(dirname "$(cd "$script_dir/.." && pwd -P)")")"
skill_dir="$(dirname "$script_dir")"
root="$project_root/tmp" template="" labels="" title="" out="" config="$project_root/configs/settings.ini"
reports="" publish=1 standard="" cplan="" cstd="" sub=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -t|--template) template="${2:?--template needs a value}"; shift 2 ;;
    -l|--labels) labels="${2:?--labels needs a value}"; shift 2 ;;
    --config) config="${2:?--config needs a value}"; shift 2 ;;
    --title) title="${2:?--title needs a value}"; shift 2 ;;
    -o|--out) out="${2:?--out needs a value}"; shift 2 ;;
    --reports) reports="${2:?--reports needs a value}"; shift 2 ;;
    --no-publish) publish=0; shift ;;
    --standard) standard="${2:?--standard needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
# The folder of the report language: the only one under templates/, or the one [language] report names.
template_dir() {
  local t="$project_root/templates" d want="" i dirs=() names=()
  [[ -f "$t/report-template.md" ]] && { dirs+=("$t"); names+=("templates/"); }
  for d in "$t"/*/; do [[ -f "${d}report-template.md" ]] && { dirs+=("${d%/}"); names+=("$(basename "$d")"); }; done
  [[ ${#dirs[@]} -gt 0 ]] || { echo "error: no report template (report-template.md) in $t" >&2; exit 2; }
  [[ ${#dirs[@]} -eq 1 ]] && { printf '%s\n' "${dirs[0]}"; return; }
  [[ -f "$config" ]] && want="$(LC_ALL=C awk '
    /^[ \t]*\[/ { h = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", h); insec = (h == "language"); next }
    insec && /^[ \t]*report[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v); gsub(/^"|"$/, "", v); val = v }
    END { print val }' "$config")"
  [[ -n "$want" ]] || want="zh-tw"
  for i in "${!dirs[@]}"; do [[ "${names[$i]}" == "$want" ]] && { printf '%s\n' "${dirs[$i]}"; return; }; done
  echo "error: no report template for the language \"$want\" ([language] report of $config); available: ${names[*]}" >&2
  exit 2
}
if [[ -z "$template" || -z "$labels" ]]; then
  tdir="$(template_dir)"
  [[ -n "$template" ]] || template="$tdir/report-template.md"
  [[ -n "$labels" ]] || labels="$tdir/labels.tsv"
fi
# With a review plan (step 1 of the workflow), each standard has its own diff and step folders.
if [[ -f "$root/step1/standards/plan.tsv" ]]; then
  cplan="$root/step1/standards/plan.tsv"
  [[ -n "$standard" ]] || standard="$(awk -F'\t' '$1 == "report" { n++; s = $2 } END { if (n == 1) print s }' "$cplan")"
  [[ -n "$standard" ]] || { echo "error: several standards score this review (see $cplan); pass --standard NAME" >&2; exit 2; }
  awk -F'\t' -v s="$standard" '$1 == "report" && $2 == s { f = 1 } END { exit !f }' "$cplan" \
    || { echo "error: the standard $standard does not score this review (see $cplan)" >&2; exit 2; }
  cstd="$standard" sub="/$standard"
fi
findings="$root/step3$sub/findings.txt" step4="$root/step4$sub"
for f in "$findings" "$template" "$labels"; do
  [[ -f "$f" ]] || { echo "error: file not found: $f" >&2; exit 2; }
done
for f in score.tsv score.json; do
  [[ -f "$step4/$f" ]] || { echo "error: $step4/$f not found; run the scoring skill first" >&2; exit 1; }
  [[ "$findings" -nt "$step4/$f" ]] && { echo "error: findings.txt changed after $f was written; rerun the scoring skill" >&2; exit 1; }
done
ctx=""; [[ -f "$root/step1/spec-context.md" ]] && ctx="$root/step1/spec-context.md"
crdir=""
if [[ -f "$root/step2/plan.tsv" ]]; then
  crdir="$root/step2"
  while IFS=$'\t' read -r p _; do
    [[ -n "$p" ]] || continue
    [[ -s "$crdir/$p/cr.txt" ]] || { echo "error: $crdir/$p/cr.txt not found; the code review step has not finished" >&2; exit 1; }
  done < "$crdir/plan.tsv"
fi
[[ -z "$out" ]] && { mkdir -p "$root/step5$sub"; out="$root/step5$sub/report.md"; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
LC_ALL=C awk -v labels="$labels" -v findings="$findings" \
  -v scoretsv="$step4/score.tsv" -v scorejson="$step4/score.json" -v cplan="$cplan" -v cstd="$cstd" \
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
[[ -n "$reports" ]] || reports="$(dirname "$root")/reports"
mkdir -p "$reports"
final="$reports/$(date +%Y-%m-%d)_${name}${cstd:+_$cstd}.md"
cp "$tmp" "$final"
final_abs="$(cd "$(dirname "$final")" && { pwd -W 2>/dev/null || pwd; })/$(basename "$final")"
[[ "$out" == "$root/step5$sub/report.md" ]] && printf '%s\n' "$final_abs" > "$root/step5$sub/report-path.txt"
echo "published ${final_abs}"
