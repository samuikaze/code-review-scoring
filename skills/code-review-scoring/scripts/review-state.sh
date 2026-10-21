#!/usr/bin/env bash
# State control for the code review scoring workflow.
# Steps: 1 read specs, 2 code review plugins, 3 analyze code (uses the code review results), 4 score, 5 report.
# Status files ROOT/stepN-{pending,working,success,failed} gate the steps; step 2 has one status file per
# plugin (ROOT/step2-<plugin>-<state>). Outputs live in ROOT/stepN/ (step 2: ROOT/step2/<plugin>/).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: review-state.sh <command> [options]

Commands:
  init     --git RANGE [--repo DIR] [--title TEXT] [--reset]
           (refused with exit 7 while plugins.ini is missing: run setup check first)
           create ROOT and ROOT/request.md (plus ROOT/.gitignore when git does not ignore ROOT yet).
           Exit 4 if a previous review exists (--reset deletes only the workflow's own files, including
           ROOT/inputs where pasted documents are saved)
  next     [--inline] [--retry]
           the next action of the workflow: the prompt of the next step or plugin to run (runs cr-plan first
           when step 2 has no plan yet), the questions to relay, a failure to report, "finish", or the result.
           --inline renders prompts for the main agent (default: from subagent= in configs.ini);
           --retry prints the prompt again for a failed step or plugin
  finish   run step 4 (score) and step 5 (report) with their scripts, record both states and print the result
           summary; refused before step 3 succeeds. Exit 1 when one of them failed (see "next")
  show     print the state of every step (and every step 2 plugin)
  cr-plan  [--plugins FILE]
           step 2 planning: pick the plugins of plugins.ini whose "applies" patterns match files in the
           PR diff; writes ROOT/step2/plan.tsv, ROOT/step2/<plugin>/files.txt and ROOT/step2/<plugin>/diff.patch
           (only that plugin's files, to save tokens). Refused before step 1 succeeds; "next" runs it
  prompt   --step 1|2|3 [--plugin NAME] [--inline]
           print the prompt for step N (step 2 needs --plugin); refused unless the previous step succeeded
  set      --step N [--plugin NAME] --state working|pending|success|failed [--message TEXT]
           record a state; enforces the gates below
  config   [--subagent true|false] [--config FILE]
           without --subagent: print subagent=true|false from the [workflow] section (exit 6 if not set);
           with it: save it. true = each step runs in its own subagent, false = the main agent runs every step
  config   --platform NAME [--model TEXT --reasoning TEXT] [--config FILE]
           without --model/--reasoning: print the subagent settings of NAME (exit 6 if not set);
           with both: save them in the [NAME] section
           (default file of both: configs.ini in the project root)

Common option: --root DIR (default: tmp in the project root)

Gates enforced by "set":
  working  the previous step must be success; clears the status of every later step
  pending  the unit must be working; its questions.md must be newer than answers.md; needs --message
  success  the unit must be working; its outputs must exist, be valid and be current
           (step 3: findings.txt must pass the scoring checks of score --check)
  failed   the unit must be working; needs --message; appends the message to the unit's errors.log
Step 2 is success when cr-plan has run and every planned plugin is success (no plugins = success).

Exit codes: 0 ok, 1 finish: step 4 or 5 failed, 2 bad arguments, 4 previous review exists, 5 gate refused,
            6 setting not configured, 7 setup incomplete (no plugins.ini; see setup check).
USAGE
}

# Absolute path; on Git Bash / MSYS use the Windows form (C:/...) so PowerShell subagents can use it too.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
script_dir="$(abspath "$(dirname "${BASH_SOURCE[0]}")")"
skill_dir="$(dirname "$script_dir")"
# Project root (two levels above the physical skill folder) holds tmp/, reports/, plugins.ini and configs.ini.
project_root="$(dirname "$(dirname "$skill_dir")")"
skills_dir="$(dirname "$skill_dir")"
self_cmd="bash \"$script_dir/review-state.sh\""
self=(bash "$script_dir/review-state.sh")
run_tool() { local s="$skills_dir/$1/scripts/$2.sh"; shift 2; bash "$s" "$@"; }  # a script of a sibling skill

[[ $# -eq 0 ]] && { usage; exit 2; }
cmd="$1"; shift
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
root="$project_root/tmp" step="" plugin="" state="" message="" git_range="" repo="." title="" reset=0
config="$project_root/configs.ini" subagent="" platform="" model="" reasoning="" plugins_file="$project_root/plugins.ini"
inline="" retry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --step) step="${2:?--step needs a value}"; shift 2 ;;
    --plugin) plugin="${2:?--plugin needs a value}"; shift 2 ;;
    --state) state="${2:?--state needs a value}"; shift 2 ;;
    --message) message="${2:?--message needs a value}"; shift 2 ;;
    --git) git_range="${2:?--git needs a value}"; shift 2 ;;
    --repo) repo="${2:?--repo needs a value}"; shift 2 ;;
    --title) title="${2:?--title needs a value}"; shift 2 ;;
    --reset) reset=1; shift ;;
    --config) config="${2:?--config needs a value}"; shift 2 ;;
    --plugins) plugins_file="${2:?--plugins needs a value}"; shift 2 ;;
    --platform) platform="${2:?--platform needs a value}"; shift 2 ;;
    --model) model="${2:?--model needs a value}"; shift 2 ;;
    --reasoning) reasoning="${2:?--reasoning needs a value}"; shift 2 ;;
    --subagent) subagent="${2:?--subagent needs a value}"; shift 2 ;;
    --inline) inline=1; shift ;;
    --retry) retry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done

refuse() { echo "refused: $1" >&2; exit 5; }
now() { date +%Y-%m-%dT%H:%M:%S%z; }
abs_root() { mkdir -p "$root"; abspath "$root"; }
# configs.ini: [workflow] subagent=true|false, and one [NAME] section per platform with model and reasoning.
ini_get() {  # $1 = section, $2 = key; prints the value without quotes (empty when not set)
  [[ -f "$config" ]] || return 0
  LC_ALL=C awk -v sec="$1" -v key="$2" '
    /^[ \t]*\[/ { h = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", h); insec = (h == sec); next }
    insec && /^[ \t]*[A-Za-z_]+[ \t]*=/ {
      k = $0; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
      if (k != key) next
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v); gsub(/^"|"$/, "", v); val = v
    }
    END { print val }' "$config"
}
ini_set() {  # $1 = section, then KEY=VALUE pairs; replaces the section in place, or appends it
  local tmpf body="" kv
  for kv in "${@:2}"; do body+="${kv%%=*}=\"${kv#*=}\""$'\n'; done
  # A new configs.ini starts as a copy of the commented example
  if [[ ! -f "$config" ]]; then
    if [[ -f "$project_root/configs.example.ini" ]]; then cp "$project_root/configs.example.ini" "$config"; else : > "$config"; fi
  fi
  tmpf="$(mktemp)"
  sec="$1" body="$body" LC_ALL=C awk '
    function emit(   c, k, b) { lines[++n] = "[" ENVIRON["sec"] "]"; c = split(ENVIRON["body"], b, "\n"); for (k = 1; k < c; k++) lines[++n] = b[k] }
    /^[ \t]*\[/ {
      h = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", h)
      skip = 0
      if (h == ENVIRON["sec"]) { emit(); done = 1; skip = 1; next }
      if (n > 0 && lines[n] !~ /^[ \t]*$/) lines[++n] = ""
    }
    skip && !/^[ \t]*$/ { next }
    skip { skip = 0 }
    { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
      if (!done) { if (n > 0) lines[++n] = ""; emit() }
      for (i = 1; i <= n; i++) print lines[i]
    }' "$config" > "$tmpf"
  mv "$tmpf" "$config"
}
req_field() { sed -n "s/^- $1: //p" "$root/request.md" | head -1; }
not_older() { [[ -f "$1" && -f "$2" && ! "$2" -nt "$1" ]]; }  # $1 exists and is not older than $2

# Step 2 runs the code review plugins; each plugin is its own unit with its own status file.
CR=2
# A "unit" is a step (1, 3, 4, 5) or a step 2 plugin ("2-<plugin>").
unit_state() {
  local s
  for s in working pending success failed; do [[ -f "$root/step$1-$s" ]] && { echo "$s"; return; }; done
  echo "not-started"
}
unit_dir() { if [[ "$1" == $CR-* ]]; then echo "$root/step$CR/${1#$CR-}"; else echo "$root/step$1"; fi; }
unit_field() { [[ -f "$root/step$1-$2" ]] && sed -n "s/^$3: //p" "$root/step$1-$2" | head -1 || true; }
clear_unit() { local s; for s in pending working success failed; do rm -f "$root/step$1-$s"; done; }
unanswered() { local d; d="$(unit_dir "$1")"; [[ -f "$d/questions.md" ]] && ! not_older "$d/answers.md" "$d/questions.md"; }
plan_names() { [[ -f "$root/step$CR/plan.tsv" ]] && cut -f1 "$root/step$CR/plan.tsv" || true; }
clear_step() {  # clears the status of step $1 (step 2: every plugin status and the plan)
  if [[ "$1" == "$CR" ]]; then
    find "$root" -maxdepth 1 -type f -name "step$CR-*" -exec rm -f {} + 2>/dev/null || true
    rm -f "$root/step$CR/plan.tsv"
  else
    clear_unit "$1"
  fi
}
step_state() {  # aggregate state of a step; step 2 combines its plugins
  if [[ "$1" != "$CR" ]]; then unit_state "$1"; return; fi
  [[ -f "$root/step$CR/plan.tsv" ]] || { echo "not-started"; return; }
  local n s any_ws=0 all_ok=1 res=""
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    s="$(unit_state "$CR-$n")"
    case "$s" in
      failed) res="failed" ;;
      pending) [[ "$res" == "failed" ]] || res="pending" ;;
      working) [[ -z "$res" ]] && any_ws=1 ;;
    esac
    [[ "$s" == "success" ]] || all_ok=0
  done < <(plan_names)
  if [[ -n "$res" ]]; then echo "$res"; elif [[ $any_ws -eq 1 ]]; then echo "working"
  elif [[ $all_ok -eq 1 ]]; then echo "success"; else echo "not-started"; fi
}
check_step() {
  [[ "$step" =~ ^[1-5]$ ]] || { echo "error: --step must be 1 to 5" >&2; exit 2; }
  if [[ "$step" == "$CR" ]]; then
    [[ -n "$plugin" ]] || { echo "error: step $CR needs --plugin NAME (see cr-plan)" >&2; exit 2; }
    plan_names | grep -qx "$plugin" || refuse "plugin $plugin is not in step $CR's plan; run cr-plan first"
  elif [[ -n "$plugin" ]]; then
    echo "error: --plugin is only used with --step $CR" >&2; exit 2
  fi
}
require_prev() { [[ $1 -gt 1 && "$(step_state $(($1 - 1)))" != "success" ]] && refuse "step $(($1 - 1)) has not succeeded; steps cannot be skipped" || true; }
has_previous() {
  local n s
  [[ -e "$root/request.md" ]] && return 0
  for n in 1 2 3 4 5; do
    [[ -e "$root/step$n" ]] && return 0
    for s in pending working success failed; do [[ -e "$root/step$n-$s" ]] && return 0; done
  done
  [[ -n "$(find "$root" -maxdepth 1 -type f -name "step$CR-*" 2>/dev/null | head -1)" ]]
}
diff_files() {  # files added or changed by the PR, from step 1's diff, without build output, generated code or lock files
  sed -n 's/^+++ //p' "$root/step1/pr.diff" | sed -e 's/\t.*$//' -e 's/^"//' -e 's/"$//' | grep -v '^/dev/null$' | sed 's|^b/||' |
    grep -Ev '(^|/)(target|build|out|dist|\.gradle|node_modules)/|(^|/)generated(-sources|-test-sources)?/|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$|\.lock$' || true
}
plugin_diff() {  # $1 = files.txt; prints the parts of step 1's diff that touch those files
  LC_ALL=C awk -v list="$1" '
    BEGIN { while ((getline l < list) > 0) { sub(/\r$/, "", l); if (l != "") want[l] = 1 } }
    /^diff --git / { p = $0; sub(/^diff --git .* "?b\//, "", p); sub(/"$/, "", p); keep = (p in want) }
    keep
  ' "$root/step1/pr.diff"
}
validate_cr() {  # checks the normalized code review result
  LC_ALL=C awk '
    function err(m) { n++; msg = msg "  - line " NR ": " m "\n" }
    function close_rec() { if (rec == "C" && !hasprob) err2(recline, "C record is missing \"problem:\""); rec = ""; hasprob = 0 }
    function err2(l, m) { n++; msg = msg "  - line " l ": " m "\n" }
    { sub(/\r$/, "") }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    /^[ \t]*[a-z]+:/ && !/^[A-Z]\|/ {
      k = $0; sub(/^[ \t]*/, "", k); sub(/:.*/, "", k)
      if (rec != "C") { err("field \"" k "\" is not under a C record"); next }
      if (k !~ /^(problem|suggestion|spec)$/) { err("unknown field \"" k "\" (allowed: problem, suggestion, spec)"); next }
      if (k == "problem") hasprob = 1
      next
    }
    {
      close_rec()
      split($0, a, "|"); t = a[1]
      if (t == "C") {
        rec = "C"; recline = NR
        if (a[2] !~ /^(Critical|Major|Minor|Nit)$/) err("severity must be Critical, Major, Minor or Nit")
        if (a[3] == "") err("C record needs locations (file:line, comma-separated) or -")
      } else if (t == "S") { if (a[2] == "") err("S record has no text"); else summary++ }
      else if (t == "H") { if (a[2] == "") err("H record has no text") }
      else err("unknown record type \"" t "\" (allowed: C, S, H)")
    }
    END {
      close_rec()
      if (!summary) { n++; msg = msg "  - an S line with the overall conclusion is required\n" }
      if (n) { printf "%s", msg; exit 1 }
    }
  ' "$1"
}
# Prompt of step $step (plugin $plugin): the step template plus the shared status protocol. Lines marked
# "[sub] " are only for subagents, lines marked "[inline] " only for the main agent ($1 = 1 for inline).
render_prompt() {
  local root_abs p_path="" p_mode="" unit_args="--step $step" dir
  root_abs="$(abs_root)"
  dir="$root_abs/step$step"
  if [[ "$step" == "$CR" ]]; then
    p_path="$(awk -F'\t' -v n="$plugin" '$1 == n { print $2 }' "$root/step$CR/plan.tsv")"
    p_mode="$(awk -F'\t' -v n="$plugin" '$1 == n { print $3 }' "$root/step$CR/plan.tsv")"
    unit_args+=" --plugin $plugin"; dir="$root_abs/step$CR/$plugin"
  fi
  cat "$skill_dir/assets/prompts/step$step.md" "$skill_dir/assets/prompts/protocol.md" |
    LC_ALL=C awk -v inline="$1" -v root="$root_abs" -v sc="$self_cmd set --root \"$root_abs\"" -v repo="$(req_field Repository)" \
      -v range="$(req_field 'Diff range')" -v title="$(req_field Title)" -v skills="$skills_dir" -v plugin="$plugin" \
      -v ppath="$p_path" -v pmode="$p_mode" -v unit="$unit_args" -v dir="$dir" -v step="$step" '
      function rep(s, a, b,    i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
      /^\[sub\] / { if (inline) next; sub(/^\[sub\] /, "") }
      /^\[inline\] / { if (!inline) next; sub(/^\[inline\] /, "") }
      { l = rep($0, "{{ROOT}}", root); l = rep(l, "{{STATE_CMD}}", sc); l = rep(l, "{{REPO}}", repo); l = rep(l, "{{RANGE}}", range)
        l = rep(l, "{{SKILLS_DIR}}", skills); l = rep(l, "{{PLUGIN_PATH}}", ppath); l = rep(l, "{{PLUGIN}}", plugin); l = rep(l, "{{MODE}}", pmode)
        l = rep(l, "{{UNIT}}", unit); l = rep(l, "{{DIR}}", dir); l = rep(l, "{{STEP}}", step)
        print rep(l, "{{TITLE}}", title) }'
}
# The action "next" prints for unit $1 (label $2) in state $3; returns 1 when the unit needs nothing.
next_action() {
  local u="$1" label="$2" s="$3" d args
  [[ "$s" == "success" ]] && return 1
  if [[ "$u" == $CR-* ]]; then
    step="$CR" plugin="${u#$CR-}" d="$(abs_root)/step$CR/${u#$CR-}" args="--step $CR --plugin ${u#$CR-}"
  else
    step="$u" plugin="" d="$(abs_root)/step$u" args="--step $u"
  fi
  case "$s" in
    pending)
      echo "action: ask"
      echo "$label needs answers. Ask the user every question in $d/questions.md in one message, write the replies"
      echo "to $d/answers.md (keep their wording; mark unanswerable questions \"cannot provide\"), then run next."
      return 0 ;;
    failed)
      if [[ $retry -eq 0 ]]; then
        echo "action: failed"
        echo "$label failed: $(unit_field "$u" failed message)"
        echo "details: $d/errors.log"
        echo "Tell the user the reason and ask whether to retry; to retry, run next --retry."
        return 0
      fi ;;
    working)
      if [[ $inline -eq 0 ]]; then
        echo "action: interrupted"
        echo "$label is still working although its subagent returned: run set $args --state failed"
        echo "--message \"subagent exited without a final state\", then run next."
        return 0
      fi ;;
  esac
  echo "action: run $label"
  if [[ $inline -eq 1 ]]; then
    [[ "$s" == "working" ]] && echo "note: an earlier run stopped before it finished; reuse what is already in $d"
    echo "Follow the prompt below yourself."
  else
    echo "Pass the prompt below unchanged to one new subagent with the saved model and reasoning, then run next."
  fi
  echo
  render_prompt "$inline"
  return 0
}

case "$cmd" in
  init)
    [[ -z "$git_range" ]] && { echo "error: init needs --git RANGE" >&2; exit 2; }
    [[ -f "$plugins_file" ]] || { echo "setup incomplete: $plugins_file does not exist; run setup check first" >&2; exit 7; }
    if has_previous; then
      if [[ $reset -eq 0 ]]; then
        echo "previous review found in $root; run 'show', then ask the user whether to resume it or start over (--reset)" >&2
        exit 4
      fi
      for n in 1 2 3 4 5; do rm -rf "${root:?}/step$n"; clear_step "$n"; done
      rm -f "$root/request.md"; rm -rf "${root:?}/inputs"
    fi
    git -C "$repo" rev-parse --git-dir > /dev/null 2>&1 || { echo "error: $repo is not a git repository" >&2; exit 2; }
    repo_abs="$(abspath "$repo")"
    root_abs="$(abs_root)"
    # Keep review files out of git unless the repository already ignores the root (keep .gitkeep).
    if [[ ! -f "$root/.gitignore" ]] && ! git -C "$root" check-ignore -q .review-probe 2>/dev/null; then
      printf '*\n!.gitkeep\n' > "$root/.gitignore"
    fi
    LC_ALL=C awk -v title="$title" -v repo="$repo_abs" -v range="$git_range" -v created="$(date +%Y-%m-%d)" '
      function rep(s, a, b,    i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
      { l = rep($0, "{{TITLE}}", title); l = rep(l, "{{REPO}}", repo); l = rep(l, "{{RANGE}}", range); print rep(l, "{{CREATED}}", created) }
    ' "$skill_dir/assets/request-template.md" > "$root/request.md"
    echo "initialized $root_abs"
    echo "next: list the documents the user provided in $root_abs/request.md, then run next"
    ;;

  show)
    [[ -f "$root/request.md" ]] || { echo "no review in $root; run init first"; exit 0; }
    for n in 1 2 3 4 5; do
      s="$(step_state $n)"
      if [[ $n == "$CR" ]]; then
        printf "step %d  %-11s %s\n" "$CR" "$s" "$([[ -f "$root/step$CR/plan.tsv" ]] && echo "$(plan_names | grep -c . || true) plugin(s) planned" || echo "cr-plan not run")"
        while IFS= read -r p; do
          [[ -n "$p" ]] || continue
          ps="$(unit_state "$CR-$p")"
          printf "  - %-28s %-11s %s  %s\n" "$p" "$ps" "$(unit_field "$CR-$p" "$ps" time)" "$(unit_field "$CR-$p" "$ps" message)"
        done < <(plan_names)
        continue
      fi
      printf "step %d  %-11s %s  %s\n" "$n" "$s" "$(unit_field $n "$s" time)" "$(unit_field $n "$s" message)"
    done
    echo "next: run next"
    ;;

  next)
    [[ -f "$root/request.md" ]] || { echo "error: no review in $root; run init first" >&2; exit 2; }
    if [[ -z "$inline" ]]; then [[ "$(ini_get workflow subagent | tr '[:upper:]' '[:lower:]')" == "true" ]] && inline=0 || inline=1; fi
    [[ $inline -eq 0 ]] && echo "mode: subagent" || echo "mode: inline"
    next_action 1 "step 1" "$(unit_state 1)" && exit 0
    if [[ ! -f "$root/step$CR/plan.tsv" ]]; then
      "${self[@]}" cr-plan --root "$root" --plugins "$plugins_file" | grep -v '^next:' || exit $?
    fi
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      next_action "$CR-$p" "step $CR plugin $p" "$(unit_state "$CR-$p")" && exit 0
    done < <(plan_names)
    next_action 3 "step 3" "$(unit_state 3)" && exit 0
    s4="$(unit_state 4)" s5="$(unit_state 5)"
    if [[ "$s4" == "failed" && "$(unit_field 4 failed message)" == "findings.txt failed validation"* ]]; then
      echo "note: scoring rejected findings.txt (details: $(abs_root)/step4/errors.log); step 3 runs again"
      retry=1; step=3; next_action 3 "step 3" "failed"; exit 0
    fi
    for n in 4 5; do
      s="$(unit_state $n)"
      if [[ "$s" == "failed" && $retry -eq 0 ]]; then
        echo "action: failed"
        echo "step $n failed: $(unit_field $n failed message)"
        echo "details: $(abs_root)/step$n/errors.log"
        echo "Tell the user the reason and ask whether to retry; to retry, run finish."
        exit 0
      fi
    done
    if [[ "$s5" != "success" ]]; then
      echo "action: finish"
      echo "Run finish: it runs step 4 (score) and step 5 (report) with their scripts."
      exit 0
    fi
    echo "action: done"
    awk -F'\t' '$1 == "grade" { g = $2 } $1 == "total" { t = $2 } $1 == "capped" && $2 == 1 { c = " (capped at B because of a Critical finding)" }
      $1 == "dim" { d = d $2 " " $3 "/" $4 "  " } END { print "result: grade " g ", total " t "/100" c; print "dimensions: " d }' "$root/step4/score.tsv"
    echo "report: $(head -1 "$root/step5/report-path.txt")"
    ;;

  finish)
    [[ -f "$root/request.md" ]] || { echo "error: no review in $root; run init first" >&2; exit 2; }
    [[ "$(step_state 3)" == "success" ]] || refuse "step 3 has not succeeded; steps cannot be skipped"
    root_abs="$(abs_root)"
    # $1 = step, $2 = message; records the failure and stops
    finish_failed() {
      "${self[@]}" set --root "$root_abs" --step "$1" --state failed --message "$2" > /dev/null
      echo "step $1 failed: $2"
      echo "details: $root_abs/step$1/errors.log"
      echo "next: run next"
      exit 1
    }
    "${self[@]}" set --root "$root_abs" --step 4 --state working > /dev/null
    rc=0; out="$(run_tool code-review-scoring-score score --root "$root_abs" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      printf '[%s] score exited %d:\n%s\n' "$(now)" "$rc" "$out" >> "$root/step4/errors.log"
      [[ $rc -eq 1 ]] && finish_failed 4 "findings.txt failed validation; redo step 3"
      finish_failed 4 "scoring exited $rc: $(printf '%s\n' "$out" | head -1)"
    fi
    grade="$(printf '%s\n' "$out" | grep '^grade ' | head -1)"
    "${self[@]}" set --root "$root_abs" --step 4 --state success --message "$grade" > /dev/null
    "${self[@]}" set --root "$root_abs" --step 5 --state working > /dev/null
    rc=0; rout="$(run_tool code-review-scoring-report render-report --root "$root_abs" 2>&1)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      printf '[%s] render-report exited %d:\n%s\n' "$(now)" "$rc" "$rout" >> "$root/step5/errors.log"
      finish_failed 5 "render-report exited $rc: $(printf '%s\n' "$rout" | head -1)"
    fi
    if ! sout="$("${self[@]}" set --root "$root_abs" --step 5 --state success --message "report published" 2>&1)"; then
      printf '[%s] %s\n' "$(now)" "$sout" >> "$root/step5/errors.log"
      finish_failed 5 "$(printf '%s\n' "$sout" | head -1)"
    fi
    echo "steps 4 and 5: success"
    printf '%s\n' "$out" | grep -v '^wrote '
    echo "report: $(head -1 "$root/step5/report-path.txt")"
    ;;

  cr-plan)
    [[ -f "$root/request.md" ]] || { echo "error: no review in $root; run init first" >&2; exit 2; }
    [[ "$(step_state $((CR - 1)))" == "success" ]] || refuse "step $((CR - 1)) has not succeeded; steps cannot be skipped"
    for ((k = CR; k <= 5; k++)); do clear_step "$k"; done
    rm -rf "${root:?}/step$CR"; mkdir -p "$root/step$CR"
    : > "$root/step$CR/plan.tsv"; : > "$root/step$CR/skipped.tsv"
    files="$(diff_files)"
    if [[ -f "$plugins_file" ]]; then
      cfg_dir="$(cd "$(dirname "$plugins_file")" && pwd)"
      # Fields are separated by \037: a tab would let read merge empty fields.
      while IFS=$'\037' read -r pname pdir applies mode; do
        [[ -n "$pdir" ]] || { echo "error: plugin $pname has no path in $plugins_file" >&2; exit 2; }
        [[ "$pdir" = /* || "$pdir" =~ ^[A-Za-z]: ]] || pdir="$cfg_dir/$pdir"
        [[ -f "$pdir/SKILL.md" ]] || { echo "error: plugin $pname: $pdir/SKILL.md not found; run scripts/link-skills first" >&2; exit 2; }
        [[ -n "$mode" ]] || mode="mapped"
        [[ "$mode" == "mapped" || "$mode" == "advisory" ]] || { echo "error: plugin $pname: mode must be mapped or advisory, not $mode" >&2; exit 2; }
        matched=""
        while IFS= read -r f; do
          [[ -n "$f" ]] || continue
          if [[ -z "$applies" ]]; then matched+="$f"$'\n'; continue; fi
          IFS=',' read -r -a pats <<< "$applies"
          for pat in "${pats[@]}"; do
            pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
            # shellcheck disable=SC2053
            if [[ "$f" == $pat ]]; then matched+="$f"$'\n'; break; fi
          done
        done <<< "$files"
        if [[ -n "$matched" ]]; then
          mkdir -p "$root/step$CR/$pname"
          printf '%s' "$matched" > "$root/step$CR/$pname/files.txt"
          plugin_diff "$root/step$CR/$pname/files.txt" > "$root/step$CR/$pname/diff.patch"
          printf '%s\t%s\t%s\t%s\n' "$pname" "$(abspath "$pdir")" "$mode" "$(printf '%s' "$matched" | grep -c .)" >> "$root/step$CR/plan.tsv"
        else
          printf '%s\t%s\n' "$pname" "$applies" >> "$root/step$CR/skipped.tsv"
        fi
      done < <(LC_ALL=C awk '
        /^[ \t]*[;#]/ || /^[ \t]*$/ { next }
        /^[ \t]*\[/ { if (sec != "") print sec "\037" v["path"] "\037" v["applies"] "\037" v["mode"]; sec = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", sec); split("", v); next }
        sec != "" && /=/ { k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k); x = $0; sub(/^[^=]*=[ \t]*/, "", x); sub(/[ \t\r]+$/, "", x); gsub(/^"|"$/, "", x); v[k] = x }
        END { if (sec != "") print sec "\037" v["path"] "\037" v["applies"] "\037" v["mode"] }
      ' "$plugins_file")
    fi
    count="$(grep -c . "$root/step$CR/plan.tsv" || true)"
    echo "planned $count plugin(s) in $(abs_root)/step$CR/plan.tsv"
    if [[ "$count" -gt 0 ]]; then cut -f1,3,4 "$root/step$CR/plan.tsv" | sed 's/\t/  mode: /; s/\t/  files: /; s/^/  - /'; fi
    if [[ -s "$root/step$CR/skipped.tsv" ]]; then echo "skipped:"; sed 's/\t/  no changed file matches: /; s/^/  - /' "$root/step$CR/skipped.tsv"; fi
    echo "next: run next"
    ;;

  prompt)
    check_step
    [[ "$step" -le 3 ]] || { echo "error: steps 4 and 5 have no prompt; run finish" >&2; exit 2; }
    [[ -f "$root/request.md" ]] || { echo "error: no review in $root; run init first" >&2; exit 2; }
    require_prev "$step"
    render_prompt "${inline:-0}"
    ;;

  set)
    check_step
    case "$state" in working|pending|success|failed) ;; *) echo "error: --state must be working, pending, success or failed" >&2; exit 2 ;; esac
    [[ -f "$root/request.md" ]] || { echo "error: no review in $root; run init first" >&2; exit 2; }
    unit="$step"; [[ "$step" == "$CR" ]] && unit="$CR-$plugin"
    label="step $step"; [[ "$step" == "$CR" ]] && label="step $CR plugin $plugin"
    cur="$(unit_state "$unit")"
    d="$(unit_dir "$unit")"
    case "$state" in
      working)
        require_prev "$step"
        for ((k = step + 1; k <= 5; k++)); do clear_step "$k"; done
        mkdir -p "$d"
        ;;
      pending)
        [[ "$cur" == "working" ]] || refuse "$label is $cur; set it to working first"
        [[ -n "$message" ]] || refuse "pending needs --message"
        unanswered "$unit" || refuse "write new questions to $d/questions.md first"
        ;;
      failed)
        [[ "$cur" == "working" ]] || refuse "$label is $cur; set it to working first"
        [[ -n "$message" ]] || refuse "failed needs --message with the reason"
        mkdir -p "$d"
        printf '[%s] %s failed: %s\n' "$(now)" "$label" "$message" >> "$d/errors.log"
        ;;
      success)
        [[ "$cur" == "working" ]] || refuse "$label is $cur; set it to working first"
        case "$step" in
          1)
            for f in pr.diff spec-context.md; do [[ -s "$d/$f" ]] || refuse "missing $d/$f"; done
            if grep -qE '^- [a-z-]+: (unknown|pending)[[:space:]]*$|^- \[ \] ' "$d/spec-context.md"; then
              refuse "spec-context.md still has unresolved inputs or open questions"
            fi
            unanswered 1 && refuse "$d/questions.md has not been answered"
            ;;
          2)
            [[ -s "$d/cr.txt" ]] || refuse "missing $d/cr.txt"
            unanswered "$unit" && refuse "$d/questions.md has not been answered"
            if ! out="$(validate_cr "$d/cr.txt")"; then refuse "$d/cr.txt is invalid:"$'\n'"$out"; fi
            ;;
          3)
            for f in prepared.txt findings.txt; do [[ -s "$d/$f" ]] || refuse "missing $d/$f"; done
            unanswered 3 && refuse "$d/questions.md has not been answered"
            if ! out="$(run_tool code-review-scoring-score score --root "$root" --check 2>&1)"; then
              refuse "findings.txt does not pass the scoring checks; fix it, then set success again:"$'\n'"$out"
            fi
            ;;
          4)
            for f in score.tsv score.json; do
              [[ -s "$d/$f" ]] || refuse "missing $d/$f"
              not_older "$d/$f" "$root/step3/findings.txt" || refuse "$d/$f is older than step3/findings.txt; rerun scoring"
            done
            ;;
          5)
            [[ -s "$d/report.md" ]] || refuse "missing $d/report.md"
            not_older "$d/report.md" "$root/step4/score.tsv" || refuse "report.md is older than step4/score.tsv; render again"
            while IFS= read -r p; do
              [[ -n "$p" ]] || continue
              not_older "$d/report.md" "$root/step$CR/$p/cr.txt" || refuse "report.md is older than step$CR/$p/cr.txt; render again"
            done < <(plan_names)
            [[ -s "$d/report-path.txt" ]] || refuse "the final report was not published to reports/ (missing $d/report-path.txt); render again without --no-publish"
            final="$(head -1 "$d/report-path.txt")"
            [[ -s "$final" ]] || refuse "published report not found: $final"
            cmp -s "$final" "$d/report.md" || refuse "published report $final differs from $d/report.md; render again"
            ;;
        esac
        ;;
    esac
    clear_unit "$unit"
    printf 'state: %s\ntime: %s\nmessage: %s\n' "$state" "$(now)" "$message" > "$root/step$unit-$state"
    echo "$label: $state"
    ;;

  config)
    if [[ -n "$subagent" ]]; then
      [[ -z "$platform$model$reasoning" ]] || { echo "error: --subagent cannot be combined with --platform, --model or --reasoning" >&2; exit 2; }
      [[ "$subagent" == "true" || "$subagent" == "false" ]] || { echo "error: --subagent must be true or false" >&2; exit 2; }
      ini_set workflow "subagent=$subagent"
      echo "saved subagent=$subagent to $config"
    elif [[ -z "$platform" ]]; then
      [[ -z "$model$reasoning" ]] || { echo "error: --model and --reasoning need --platform NAME" >&2; exit 2; }
      v="$(ini_get workflow subagent | tr '[:upper:]' '[:lower:]')"
      [[ "$v" == "true" || "$v" == "false" ]] || { echo "not configured: subagent=true|false is missing in [workflow] of $config; ask the user whether to run the steps in subagents" >&2; exit 6; }
      echo "subagent=$v"
    else
      [[ "$platform" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: --platform may only contain letters, digits, - and _" >&2; exit 2; }
      [[ "$(printf '%s' "$platform" | tr '[:upper:]' '[:lower:]')" != "workflow" ]] || { echo "error: workflow is reserved and cannot be a platform name" >&2; exit 2; }
      if [[ -z "$model" && -z "$reasoning" ]]; then
        m="$(ini_get "$platform" model)"
        r="$(ini_get "$platform" reasoning)"
        [[ -n "$m" && -n "$r" ]] || { echo "not configured: [$platform] with model and reasoning is missing in $config; ask the user for them" >&2; exit 6; }
        printf 'model=%s\nreasoning=%s\n' "$m" "$r"
      else
        [[ -n "$model" && -n "$reasoning" ]] || { echo "error: config needs both --model and --reasoning to save" >&2; exit 2; }
        [[ "$model$reasoning" != *'"'* ]] || { echo "error: values may not contain double quotes" >&2; exit 2; }
        ini_set "$platform" "model=$model" "reasoning=$reasoning"
        echo "saved [$platform] to $config"
      fi
    fi
    ;;

  *) echo "error: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac
