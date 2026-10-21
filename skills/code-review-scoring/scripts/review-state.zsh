#!/usr/bin/env zsh
# State control for the code review scoring workflow.
# Steps: 1 read specs, 2 code review plugins, 3 analyze code (uses the code review results), 4 score, 5 report.
# Status files ROOT/stepN-{pending,working,success,failed} gate the steps; step 2 has one status file per
# plugin (ROOT/step2-<plugin>-<state>), steps 3 to 5 one per scoring standard of the review plan that step 1 writes
# to ROOT/step1/standards/ (ROOT/step3-<standard>-<state>). Outputs live in ROOT/step1/, ROOT/step2/<plugin>/ and
# ROOT/stepN/<standard>/.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: review-state.zsh <command> [options]

Commands:
  init     --git RANGE [--repo DIR] [--title TEXT] [--reset]
           (refused with exit 7 while configs/plugins.ini is missing: run setup check first)
           create ROOT and ROOT/request.md (plus ROOT/.gitignore when git does not ignore ROOT yet).
           Exit 4 if a previous review exists (--reset deletes only the workflow's own files, including
           ROOT/inputs where pasted documents are saved)
  next     [--inline] [--retry]
           the next action of the workflow: the prompt of the next step or plugin to run (runs cr-plan first
           when step 2 has no plan yet), the questions to relay, a failure to report, "finish", or the result.
           --inline renders prompts for the main agent (default: from subagent= in configs/settings.ini);
           --retry prints the prompt again for a failed step or plugin
  finish   run step 4 (score) and step 5 (report) with their scripts for every standard of the review plan, record
           the states and print the results; refused before step 3 succeeds. Exit 1 when one of them failed (see "next")
  show     print the state of every step (and every step 2 plugin)
  cr-plan  [--plugins FILE]
           step 2 planning: pick the plugins of configs/plugins.ini whose "applies" patterns match files in the
           PR diff; writes ROOT/step2/plan.tsv, ROOT/step2/<plugin>/files.txt and ROOT/step2/<plugin>/diff.patch
           (only that plugin's files, to save tokens). Refused before step 1 succeeds; "next" runs it
  prompt   --step 1|2|3 [--plugin NAME] [--standard NAME] [--inline]
           print the prompt for step N (step 2 needs --plugin, step 3 --standard when several standards score the
           PR); refused unless the previous step succeeded
  set      --step N [--plugin NAME] [--standard NAME] --state working|pending|success|failed [--message TEXT]
           record a state (steps 3 to 5 per standard); enforces the gates below
  config   [--subagent true|false] [--config FILE]
           without --subagent: print subagent=true|false from the [workflow] section (exit 6 if not set);
           with it: save it. true = each step runs in its own subagent, false = the main agent runs every step
  config   --platform NAME [--model TEXT --reasoning TEXT] [--config FILE]
           without --model/--reasoning: print the subagent settings of NAME (exit 6 if not set);
           with both: save them in the [NAME] section
           (default file of both: configs/settings.ini in the project root)

Common options: --root DIR (default: tmp in the project root)
                --standards FILE (default: configs/standards.ini in the project root)

Gates enforced by "set":
  working  the previous step must be success; clears the status of every later step
  pending  the unit must be working; its questions.md must be newer than answers.md; needs --message
  success  the unit must be working; its outputs must exist, be valid and be current
           (step 1: the review plan ROOT/step1/standards/plan.tsv; step 3: findings.txt must pass the scoring
           checks of score --check)
Steps 3 to 5 also refuse to go on when a scoring standard changed after step 1 planned the review (its document,
scan rules or settings in standards.ini).
  failed   the unit must be working; needs --message; appends the message to the unit's errors.log
Step 2 is success when cr-plan has run and every planned plugin is success (no plugins = success).

Exit codes: 0 ok, 1 finish: step 4 or 5 failed, 2 bad arguments, 4 previous review exists, 5 gate refused,
            6 setting not configured, 7 setup incomplete (no configs/plugins.ini; see setup check).
USAGE
}

# Absolute path; on Git Bash / MSYS use the Windows form (C:/...) so PowerShell subagents can use it too.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
script_dir="${0:A:h}"
skill_dir="$(dirname "$script_dir")"
# Project root (two levels above the physical skill folder) holds tmp/, reports/, configs/plugins.ini and configs/settings.ini.
project_root="$(dirname "$(dirname "$skill_dir")")"
skills_dir="$(dirname "$skill_dir")"
self_cmd="zsh \"$script_dir/review-state.zsh\""
self=(zsh "$script_dir/review-state.zsh")
run_tool() { local s="$skills_dir/$1/scripts/$2.zsh"; shift 2; zsh "$s" "$@"; }  # a script of a sibling skill

[[ $# -eq 0 ]] && { usage; exit 2; }
cmd="$1"; shift
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
root="$project_root/tmp" step="" plugin="" state="" message="" git_range="" repo="." title="" reset=0
config="$project_root/configs/settings.ini" subagent="" platform="" model="" reasoning="" plugins_file="$project_root/configs/plugins.ini"
inline="" retry=0 standard="" standards="$project_root/configs/standards.ini"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    --step) step="${2:?--step needs a value}"; shift 2 ;;
    --plugin) plugin="${2:?--plugin needs a value}"; shift 2 ;;
    --standard) standard="${2:?--standard needs a value}"; shift 2 ;;
    --standards) standards="${2:?--standards needs a value}"; shift 2 ;;
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
# configs/settings.ini: [workflow] subagent=true|false, and one [NAME] section per platform with model and reasoning.
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
  # A new configs/settings.ini starts as a copy of the commented example
  if [[ ! -f "$config" ]]; then
    mkdir -p "$(dirname "$config")"
    if [[ -f "$project_root/configs/settings.example.ini" ]]; then cp "$project_root/configs/settings.example.ini" "$config"; else : > "$config"; fi
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

# Step 2 runs the code review plugins; each plugin is its own unit with its own status file. Steps 3 to 5 run once
# per scoring standard of the review plan.
CR=2
# A "unit" is step 1, a step 2 plugin ("2-<plugin>") or a step 3 to 5 standard ("3-<standard>").
unit_state() {
  local s
  for s in working pending success failed; do [[ -f "$root/step$1-$s" ]] && { echo "$s"; return; }; done
  echo "not-started"
}
unit_dir() { if [[ "$1" == *-* ]]; then echo "$root/step${1%%-*}/${1#*-}"; else echo "$root/step$1"; fi; }
unit_field() { [[ -f "$root/step$1-$2" ]] && sed -n "s/^$3: //p" "$root/step$1-$2" | head -1 || true; }
clear_unit() { local s; for s in pending working success failed; do rm -f "$root/step$1-$s"; done; }
unanswered() { local d; d="$(unit_dir "$1")"; [[ -f "$d/questions.md" ]] && ! not_older "$d/answers.md" "$d/questions.md"; }
plan_names() { [[ -f "$root/step$CR/plan.tsv" ]] && cut -f1 "$root/step$CR/plan.tsv" || true; }
# The scoring standards of the review plan (one report each), in plan order.
std_plan="$root/step1/standards/plan.tsv"
std_names() { [[ -f "$std_plan" ]] && awk -F'\t' '$1 == "report" { print $2 }' "$std_plan" || true; }
sub_names() { if [[ "$1" == "$CR" ]]; then plan_names; else std_names; fi; }  # the units of step 2 to 5
clear_step() {  # clears the status of step $1 (step 2: every plugin status and the plan; steps 3 to 5: every standard)
  if [[ "$1" -ge "$CR" ]]; then
    find "$root" -maxdepth 1 -type f -name "step$1-*" -exec rm -f {} + 2>/dev/null || true
    [[ "$1" == "$CR" ]] && rm -f "$root/step$CR/plan.tsv"
  else
    clear_unit "$1"
  fi
  return 0
}
step_state() {  # aggregate state of a step; steps 2 to 5 combine their plugins or standards
  if [[ "$1" == 1 ]]; then unit_state "$1"; return; fi
  if [[ "$1" == "$CR" ]]; then [[ -f "$root/step$CR/plan.tsv" ]] || { echo "not-started"; return; }
  else [[ -n "$(std_names)" ]] || { echo "not-started"; return; }; fi
  local n s any_ws=0 all_ok=1 res=""
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    s="$(unit_state "$1-$n")"
    case "$s" in
      failed) res="failed" ;;
      pending) [[ "$res" == "failed" ]] || res="pending" ;;
      working) [[ -z "$res" ]] && any_ws=1 ;;
    esac
    [[ "$s" == "success" ]] || all_ok=0
  done < <(sub_names "$1")
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
  if [[ "$step" -gt "$CR" ]]; then
    [[ -f "$std_plan" ]] || refuse "step 1 has not planned the review (missing $std_plan)"
    # Without --standard: the only standard of the plan.
    [[ -n "$standard" ]] || standard="$(std_names | awk '{ n++; s = $0 } END { if (n == 1) print s }')"
    [[ -n "$standard" ]] || { echo "error: step $step needs --standard NAME: $(std_names | paste -sd, - | sed 's/,/, /g')" >&2; exit 2; }
    std_names | grep -qxF -- "$standard" || refuse "the standard $standard does not score this review (see $std_plan)"
  elif [[ -n "$standard" ]]; then
    echo "error: --standard is only used with steps 3 to 5" >&2; exit 2
  fi
}
# Step 3 needs step 2; steps 4 and 5 need the previous step of the same standard ($2).
require_prev() {
  if [[ $1 -gt 3 ]]; then
    [[ "$(unit_state "$(($1 - 1))-$2")" == "success" ]] || refuse "step $(($1 - 1)) ($2) has not succeeded; steps cannot be skipped"
  elif [[ $1 -gt 1 && "$(step_state $(($1 - 1)))" != "success" ]]; then
    refuse "step $(($1 - 1)) has not succeeded; steps cannot be skipped"
  fi
  return 0
}
# The scoring standard $1 must be the one step 1 planned with: its document, scan rules and settings in standards.ini
# (the resolve output without the paths, which differ between shells) must not have changed.
res_key() { tr -d '\r' | awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "standard" || $1 == "common" { $5 = "" } $1 == "scan" { $2 = "" } { print }'; }
std_gate() {
  local saved="$root/step1/standards/$1.resolve" now
  [[ -f "$saved" ]] || refuse "missing $saved; step 1 has not planned the review"
  now="$(zsh "$script_dir/standard.zsh" resolve --standards "$standards" --settings "$config" "$1" 2>&1)" \
    || refuse "the scoring standard $1 cannot be read: $(printf '%s\n' "$now" | head -1)"
  [[ "$(res_key < "$saved")" == "$(printf '%s\n' "$now" | res_key)" ]] \
    || refuse "the scoring standard $1 changed after step 1 planned the review (its document, scan rules or settings in standards.ini); restore it, or start the review again (init --reset)"
}
# request.md records the scoring standards of the review: name, version, sha256 and path of each document.
record_standards() {
  local f tmpf
  tmpf="$(mktemp)"
  awk '/^## Scoring standards/ { skip = 1; next } skip && /^## / { skip = 0 } !skip' "$root/request.md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$tmpf"
  { echo; echo "## Scoring standards"
    for f in $(std_names); do
      awk -F'\t' -v r="$f" '$1 == "standard" { print "- " r ": " $2 " " $3 " " $4 " " $5 } $1 == "common" { print "  - common standard: " $2 " " $3 " " $4 " " $5 }' "$root/step1/standards/$f.resolve"
    done; } >> "$tmpf"
  mv "$tmpf" "$root/request.md"
}
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
  local root_abs p_path="" p_mode="" unit_args="--step $step" dir s_doc="" c_doc="none"
  root_abs="$(abs_root)"
  dir="$root_abs/step$step"
  if [[ "$step" == "$CR" ]]; then
    p_path="$(awk -F'\t' -v n="$plugin" '$1 == n { print $2 }' "$root/step$CR/plan.tsv")"
    p_mode="$(awk -F'\t' -v n="$plugin" '$1 == n { print $3 }' "$root/step$CR/plan.tsv")"
    unit_args+=" --plugin $plugin"; dir="$root_abs/step$CR/$plugin"
  elif [[ "$step" -gt "$CR" ]]; then
    s_doc="$(awk -F'\t' '$1 == "standard" { print $5 }' "$root/step1/standards/$standard.resolve")"
    c_doc="$(awk -F'\t' '$1 == "common" { print $5 }' "$root/step1/standards/$standard.resolve")"
    unit_args+=" --standard $standard"; dir="$root_abs/step$step/$standard"
  fi
  cat "$skill_dir/assets/prompts/step$step.md" "$skill_dir/assets/prompts/protocol.md" |
    LC_ALL=C awk -v inline="$1" -v root="$root_abs" -v sc="$self_cmd set --root \"$root_abs\"" -v repo="$(req_field Repository)" \
      -v range="$(req_field 'Diff range')" -v title="$(req_field Title)" -v skills="$skills_dir" -v plugin="$plugin" \
      -v ppath="$p_path" -v pmode="$p_mode" -v unit="$unit_args" -v dir="$dir" -v step="$step" \
      -v std="$standard" -v sdoc="$s_doc" -v cdoc="${c_doc:-none}" '
      function rep(s, a, b,    i, o) { o = ""; while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
      /^\[sub\] / { if (inline) next; sub(/^\[sub\] /, "") }
      /^\[inline\] / { if (!inline) next; sub(/^\[inline\] /, "") }
      { l = rep($0, "{{ROOT}}", root); l = rep(l, "{{STATE_CMD}}", sc); l = rep(l, "{{REPO}}", repo); l = rep(l, "{{RANGE}}", range)
        l = rep(l, "{{SKILLS_DIR}}", skills); l = rep(l, "{{PLUGIN_PATH}}", ppath); l = rep(l, "{{PLUGIN}}", plugin); l = rep(l, "{{MODE}}", pmode)
        l = rep(l, "{{UNIT}}", unit); l = rep(l, "{{DIR}}", dir); l = rep(l, "{{STEP}}", step)
        l = rep(l, "{{STANDARD}}", std); l = rep(l, "{{STANDARD_DOC}}", sdoc); l = rep(l, "{{COMMON_DOC}}", cdoc)
        print rep(l, "{{TITLE}}", title) }'
}
# The action "next" prints for unit $1 (label $2) in state $3; returns 1 when the unit needs nothing.
next_action() {
  local u="$1" label="$2" s="$3" d args
  [[ "$s" == "success" ]] && return 1
  if [[ "$u" == $CR-* ]]; then
    step="$CR" plugin="${u#$CR-}" standard="" d="$(abs_root)/step$CR/${u#$CR-}" args="--step $CR --plugin ${u#$CR-}"
  elif [[ "$u" == *-* ]]; then
    step="${u%%-*}" plugin="" standard="${u#*-}" d="$(abs_root)/step${u%%-*}/${u#*-}" args="--step ${u%%-*} --standard ${u#*-}"
    std_gate "$standard"
  else
    step="$u" plugin="" standard="" d="$(abs_root)/step$u" args="--step $u"
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
      elif [[ $n -gt $CR ]]; then
        printf "step %d  %-11s %s\n" "$n" "$s" "$([[ -f "$std_plan" ]] && echo "$(std_names | grep -c . || true) standard(s)" || echo "not planned")"
      fi
      if [[ $n -ge $CR ]]; then
        while IFS= read -r p; do
          [[ -n "$p" ]] || continue
          ps="$(unit_state "$n-$p")"
          printf "  - %-28s %-11s %s  %s\n" "$p" "$ps" "$(unit_field "$n-$p" "$ps" time)" "$(unit_field "$n-$p" "$ps" message)"
        done < <(sub_names "$n")
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
    [[ -n "$(std_names)" ]] || { echo "error: step 1 has not planned the review (missing $std_plan); redo step 1" >&2; exit 2; }
    for n in $(std_names); do next_action "3-$n" "step 3 ($n)" "$(unit_state "3-$n")" && exit 0; done
    for n in $(std_names); do
      if [[ "$(unit_state "4-$n")" == "failed" && "$(unit_field "4-$n" failed message)" == "findings.txt failed validation"* ]]; then
        echo "note: scoring rejected findings.txt of $n (details: $(abs_root)/step4/$n/errors.log); step 3 ($n) runs again"
        retry=1; next_action "3-$n" "step 3 ($n)" "failed"; exit 0
      fi
    done
    for n in $(std_names); do
      for k in 4 5; do
        s="$(unit_state "$k-$n")"
        if [[ "$s" == "failed" && $retry -eq 0 ]]; then
          echo "action: failed"
          echo "step $k ($n) failed: $(unit_field "$k-$n" failed message)"
          echo "details: $(abs_root)/step$k/$n/errors.log"
          echo "Tell the user the reason and ask whether to retry; to retry, run finish."
          exit 0
        fi
      done
    done
    if [[ "$(step_state 5)" != "success" ]]; then
      echo "action: finish"
      echo "Run finish: it runs step 4 (score) and step 5 (report) with their scripts for every standard."
      exit 0
    fi
    echo "action: done"
    for n in $(std_names); do
      awk -F'\t' -v n="$n" '$1 == "grade" { g = $2 } $1 == "total" { t = $2 } $1 == "capped" && $2 == 1 { c = " (capped at B because of a Critical finding)" }
        $1 == "dim" { d = d $2 " " $3 "/" $4 "  " } END { print "result (" n "): grade " g ", total " t "/100" c; print "dimensions: " d }' "$root/step4/$n/score.tsv"
      echo "report: $(head -1 "$root/step5/$n/report-path.txt")"
    done
    ;;

  finish)
    [[ -f "$root/request.md" ]] || { echo "error: no review in $root; run init first" >&2; exit 2; }
    [[ "$(step_state 3)" == "success" ]] || refuse "step 3 has not succeeded; steps cannot be skipped"
    root_abs="$(abs_root)"
    for n in $(std_names); do std_gate "$n"; done
    # $1 = step, $2 = standard, $3 = message; records the failure and stops
    finish_failed() {
      "${self[@]}" set --root "$root_abs" --standards "$standards" --step "$1" --standard "$2" --state failed --message "$3" > /dev/null
      echo "step $1 ($2) failed: $3"
      echo "details: $root_abs/step$1/$2/errors.log"
      echo "next: run next"
      exit 1
    }
    # Each standard in turn; the standards whose report is already published are kept.
    for n in $(std_names); do
      [[ "$(unit_state "5-$n")" != "success" ]] || continue
      "${self[@]}" set --root "$root_abs" --standards "$standards" --step 4 --standard "$n" --state working > /dev/null
      rc=0; out="$(run_tool code-review-scoring-score score --root "$root_abs" --standards "$standards" --standard "$n" 2>&1)" || rc=$?
      if [[ $rc -ne 0 ]]; then
        printf '[%s] score exited %d:\n%s\n' "$(now)" "$rc" "$out" >> "$root/step4/$n/errors.log"
        [[ $rc -eq 1 ]] && finish_failed 4 "$n" "findings.txt failed validation; redo step 3"
        finish_failed 4 "$n" "scoring exited $rc: $(printf '%s\n' "$out" | head -1)"
      fi
      grade="$(printf '%s\n' "$out" | grep '^grade ' | head -1)"
      "${self[@]}" set --root "$root_abs" --standards "$standards" --step 4 --standard "$n" --state success --message "$grade" > /dev/null
      "${self[@]}" set --root "$root_abs" --standards "$standards" --step 5 --standard "$n" --state working > /dev/null
      rc=0; rout="$(run_tool code-review-scoring-report render-report --root "$root_abs" --standard "$n" 2>&1)" || rc=$?
      if [[ $rc -ne 0 ]]; then
        printf '[%s] render-report exited %d:\n%s\n' "$(now)" "$rc" "$rout" >> "$root/step5/$n/errors.log"
        finish_failed 5 "$n" "render-report exited $rc: $(printf '%s\n' "$rout" | head -1)"
      fi
      if ! sout="$("${self[@]}" set --root "$root_abs" --standards "$standards" --step 5 --standard "$n" --state success --message "report published" 2>&1)"; then
        printf '[%s] %s\n' "$(now)" "$sout" >> "$root/step5/$n/errors.log"
        finish_failed 5 "$n" "$(printf '%s\n' "$sout" | head -1)"
      fi
      echo "steps 4 and 5 ($n): success"
      printf '%s\n' "$out" | grep -v '^wrote '
      echo "report: $(head -1 "$root/step5/$n/report-path.txt")"
    done
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
          pats=("${(@s:,:)applies}")
          for pat in "${pats[@]}"; do
            pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
            # shellcheck disable=SC2053
            if [[ "$f" == $~pat ]]; then matched+="$f"$'\n'; break; fi
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
    unit="$step" label="step $step"
    [[ "$step" == "$CR" ]] && { unit="$CR-$plugin" label="step $CR plugin $plugin"; }
    if [[ "$step" -gt "$CR" ]]; then
      unit="$step-$standard" label="step $step ($standard)"
      [[ "$state" == "working" || "$state" == "success" ]] && std_gate "$standard"
    fi
    cur="$(unit_state "$unit")"
    d="$(unit_dir "$unit")"
    case "$state" in
      working)
        require_prev "$step" "$standard"
        # Later steps start over: every unit of them, or only the same standard's after steps 3 and 4.
        for ((k = step + 1; k <= 5; k++)); do if [[ "$step" -gt "$CR" ]]; then clear_unit "$k-$standard"; else clear_step "$k"; fi; done
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
            [[ -s "$std_plan" ]] || refuse "missing $std_plan: the review was not planned; check configs/standards.ini (setup check), then run standard plan --diff \"$d/pr.diff\" --out \"$d/standards\" of code-review-scoring and add its confirm.tsv to the Severity facts of spec-context.md"
            record_standards
            ;;
          2)
            [[ -s "$d/cr.txt" ]] || refuse "missing $d/cr.txt"
            unanswered "$unit" && refuse "$d/questions.md has not been answered"
            if ! out="$(validate_cr "$d/cr.txt")"; then refuse "$d/cr.txt is invalid:"$'\n'"$out"; fi
            ;;
          3)
            for f in prepared.txt findings.txt; do [[ -s "$d/$f" ]] || refuse "missing $d/$f"; done
            unanswered "$unit" && refuse "$d/questions.md has not been answered"
            if ! out="$(run_tool code-review-scoring-score score --root "$root" --standards "$standards" --standard "$standard" --check 2>&1)"; then
              refuse "findings.txt does not pass the scoring checks; fix it, then set success again:"$'\n'"$out"
            fi
            ;;
          4)
            for f in score.tsv score.json; do
              [[ -s "$d/$f" ]] || refuse "missing $d/$f"
              not_older "$d/$f" "$root/step3/$standard/findings.txt" || refuse "$d/$f is older than step3/$standard/findings.txt; rerun scoring"
            done
            ;;
          5)
            [[ -s "$d/report.md" ]] || refuse "missing $d/report.md"
            not_older "$d/report.md" "$root/step4/$standard/score.tsv" || refuse "report.md is older than step4/$standard/score.tsv; render again"
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
