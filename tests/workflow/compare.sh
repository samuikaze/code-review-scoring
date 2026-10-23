#!/usr/bin/env bash
# Runs the whole review workflow on a throwaway git repository with every installed shell (bash, zsh, PowerShell)
# and compares the output with expected.txt: init, step 1 (plan with two framework standards and the common
# standard; the rules project is rules/, where angular has its own severity scale and grades), step 2 (one fake code
# review plugin), step 3 for each standard (comments mapped to the scale with M records), finish (one report per
# standard, each showing only the comments on its files), show, and the gate that refuses to go on after a standard has
# changed.
#   bash tests/workflow/compare.sh            compare
#   bash tests/workflow/compare.sh --update   rewrite expected.txt from the bash output
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
here="$(pwd)"
skills="$(cd ../../skills && pwd)"
root="$(cd ../.. && pwd)"; root_w="$(cd ../.. && { pwd -W 2>/dev/null || pwd; })"

work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT
work_w="$( (cd "$work" && pwd -W 2>/dev/null) || echo "$work")"
norm() {
  tr -d '\r' | tr '\134' '/' | sed -E -e "s#$work_w#WORK#g" -e "s#$work#WORK#g" -e "s#$root_w/#ROOT/#g" -e "s#$root/#ROOT/#g" \
    -e 's#(bash|zsh|powershell -NoProfile -ExecutionPolicy Bypass -File|pwsh -NoProfile -File) "ROOT/skills/code-review-scoring/scripts/review-state\.(sh|zsh|ps1)"#STATE_CMD#g' \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+/TIME/g' -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}/DATE/g'
}

# A PR that changes a Java backend, an Angular frontend and a root README, reviewed by a plugin that comments on all.
setup() {
  rm -rf "${work:?}"/*
  mkdir -p "$work/repo" "$work/std" "$work/plugin" "$work/configs"
  cp ../standards/good-v2.md ../standards/good-common.md ../plan/angular.md "$work/std/"
  cp -r rules "$work/rules"
  printf -- '---\nname: fake-review\ndescription: test plugin\n---\n' > "$work/plugin/SKILL.md"
  printf '[fake-review]\npath="../plugin"\napplies="*.java, *.ts, *.md"\nmode="mapped"\n' > "$work/configs/plugins.ini"
  printf '[language]\nreport="zh-tw"\n\n[rules]\nroot="../rules"\n' > "$work/configs/settings.ini"
  printf '[language]\nreport="en"\n\n[rules]\nroot="../rules"\n' > "$work/configs/settings-en.ini"
  printf '[language]\nreport="xx"\n\n[rules]\nroot="../rules"\n' > "$work/configs/settings-xx.ini"
  ( cd "$work/repo" && git init -q && git config user.email t@example.com && git config user.name t && git config core.autocrlf false && git config commit.gpgsign false
    printf '# demo\n' > README.md && git add . && git commit -qm base
    mkdir -p backend/src/main/java frontend/src
    printf 'class A {}\n' > backend/src/main/java/A.java
    printf 'export const a = 1;\n' > frontend/src/app.ts
    printf '# demo\n\nusage\n' > README.md
    git add . && git commit -qm change )
}

run_all() {  # $sh = bash, zsh or powershell
  local w="$work_w" R="$work_w/review" P="$work_w/configs/plugins.ini" C="$work_w/configs/settings.ini" n f rc
  setup
  rs() { case "$sh" in
      bash) bash "$skills/code-review-scoring/scripts/review-state.sh" "$@" ;;
      zsh) zsh "$skills/code-review-scoring/scripts/review-state.zsh" "$@" ;;
      *) "$ps" -NoProfile -ExecutionPolicy Bypass -File "$skills/code-review-scoring/scripts/review-state.ps1" "$@" ;;
    esac; }
  step() { echo "### $*" | norm; rs "$@" --root "$R" --config "$C" 2>&1 | norm; echo "exit=${PIPESTATUS[0]}"; }
  report() {  # $1 = settings file; renders the angular report to stdout
    case "$sh" in
      bash) bash "$skills/code-review-scoring-report/scripts/render-report.sh" --root "$R" --standard angular --config "$1" --out - ;;
      zsh) zsh "$skills/code-review-scoring-report/scripts/render-report.zsh" --root "$R" --standard angular --config "$1" --out - ;;
      *) "$ps" -NoProfile -ExecutionPolicy Bypass -File "$skills/code-review-scoring-report/scripts/render-report.ps1" -Root "$R" -Standard angular -Config "$1" -Out:- ;;
    esac; }

  step init --git HEAD~1..HEAD --repo "$w/repo" --title "Demo PR" --plugins "$P"
  step set --step 1 --state working
  echo "### init-workspace"
  case "$sh" in
    bash) bash "$skills/code-review-scoring-spec-reading/scripts/init-workspace.sh" --git HEAD~1..HEAD --repo "$w/repo" --root "$R" --title "Demo PR" --config "$C" ;;
    zsh) zsh "$skills/code-review-scoring-spec-reading/scripts/init-workspace.zsh" --git HEAD~1..HEAD --repo "$w/repo" --root "$R" --title "Demo PR" --config "$C" ;;
    *) "$ps" -NoProfile -ExecutionPolicy Bypass -File "$skills/code-review-scoring-spec-reading/scripts/init-workspace.ps1" -Git HEAD~1..HEAD -Repo "$w/repo" -Root "$R" -Title "Demo PR" -Config "$C" ;;
  esac 2>&1 | norm
  echo "--- confirmations"; grep '^- A' "$work/review/step1/spec-context.md" | norm
  # A question round: next relays the questions until answers.md is newer, then runs step 1 again.
  printf '1. question\n' > "$work/review/step1/questions.md"
  step set --step 1 --state pending --message "1 question"
  step next --inline | grep -E '^(action|exit)'
  sleep 1; printf '1. answer\n' > "$work/review/step1/answers.md"
  step next --inline | grep -E '^(action|exit)'
  step set --step 1 --state working
  sed -i -e 's/: unknown$/: provided/' "$work/review/step1/spec-context.md"
  step set --step 1 --state success
  echo "--- request.md"; sed -n '/^## Scoring standards/,$p' "$work/review/request.md" | norm
  step prompt --step 3
  step next --inline --plugins "$P"
  step set --step 2 --plugin fake-review --state working
  printf 'C|Major|backend/src/main/java/A.java:1\nproblem: java\nC|Minor|frontend/src/app.ts:1\nproblem: ts\nC|Minor|README.md:3\nproblem: readme\nS|done\n' \
    > "$work/review/step2/fake-review/cr.txt"
  step set --step 2 --plugin fake-review --state success
  echo "### next (step 3 prompt)"; rs next --inline --root "$R" --config "$C" 2>&1 | norm | grep -E '^(action|# Step|- Scoring standard|- Report language|2\. )'
  step set --step 4 --standard angular --state working
  for n in angular springboot-3; do
    step set --step 3 --standard "$n" --state working
    echo "### prepare-diff $n"
    case "$sh" in
      bash) bash "$skills/code-review-scoring-code-analysis/scripts/prepare-diff.sh" --root "$R" --standard "$n" --config "$C" ;;
      zsh) zsh "$skills/code-review-scoring-code-analysis/scripts/prepare-diff.zsh" --root "$R" --standard "$n" --config "$C" ;;
      *) "$ps" -NoProfile -ExecutionPolicy Bypass -File "$skills/code-review-scoring-code-analysis/scripts/prepare-diff.ps1" -Root "$R" -Standard "$n" -Config "$C" ;;
    esac 2>&1 | norm
    grep -E '^(- standard|- severity|C\||fake-review#)|fake-review#' "$work/review/step3/$n/prepared.txt" | norm
    if [[ "$n" == angular ]]; then
      printf 'F|A2|Minor|frontend/src/app.ts:1\nproblem: x\nsuggestion: y\nsource: fake-review#2\nX|fake-review#3|README 用語無誤。\nM|fake-review#2|Minor\nM|fake-review#3|Info\n' \
        > "$work/review/step3/$n/findings.txt"
    else
      printf 'F|A1|Major|backend/src/main/java/A.java:1\nproblem: x\nsuggestion: y\nsource: fake-review#1\nX|fake-review#3|README 用語無誤。\nM|fake-review#1|Major\nM|fake-review#3|Nit\n' \
        > "$work/review/step3/$n/findings.txt"
    fi
    step set --step 3 --standard "$n" --state success
  done
  step next --inline | grep -E '^(### |mode|action|exit)'
  step finish
  echo "--- reports"; ( cd "$work/reports" && ls ) | norm
  for f in "$work"/reports/*.md; do
    echo "--- ${f##*/}" | norm; grep -E '評分標準|fake-review' "$f" | norm
  done
  # The report language: [language] report picks one of the folders under templates/.
  echo "### render-report (report=\"en\")"; report "$w/configs/settings-en.ini" 2>&1 | norm | grep -E '^(# |- \*\*(Scoring standard|Grade)|## |\| (Dimension|A ))'
  echo "### render-report (report=\"xx\")"; report "$w/configs/settings-xx.ini" 2>&1 | norm; echo "exit=${PIPESTATUS[0]}"
  step show
  step next --inline | grep -vE '^(Load|- |[0-9]. |Tasks|Status|## |# |Follow|$)'
  # A standard that changes after step 1 stops the review.
  printf '\n<!-- edited -->\n' >> "$work/std/angular.md"
  step set --step 3 --standard angular --state working
  step finish
}

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)
ps="$(command -v pwsh || command -v powershell.exe || command -v powershell || true)"
[[ -n "$ps" ]] && shells+=(powershell)

if [[ "${1:-}" == "--update" ]]; then
  sh=bash run_all > "$here/expected.txt"
  echo "updated expected.txt"; exit 0
fi

fail=0
for sh in "${shells[@]}"; do
  if diff -u "$here/expected.txt" <(run_all) > "$work.$sh.diff" 2>&1; then echo "ok: $sh"
  else fail=1; echo "FAILED: $sh"; head -60 "$work.$sh.diff"; fi
  rm -f "$work.$sh.diff"
done
command -v zsh >/dev/null 2>&1 || echo "skipped: zsh (not installed)"
[[ -n "$ps" ]] || echo "skipped: powershell (not installed)"
exit $fail
