#!/usr/bin/env zsh
# Setup check for the code review scoring workflow: configs/plugins.ini and configs/settings.ini (with [rules] root, the
# rules project of the scoring standards) in the project root.
# "check" tells the agent what is missing; the missing files are created either by the user with the
# interactive "wizard", or by the agent with "plugins --none", "plugin" and "review-state config".
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: setup.zsh <command> [options]

Commands:
  check    [--platform NAME]
           report whether configs/plugins.ini exists, whether configs/settings.ini sets subagent=true|false
           and, when it is true and --platform is given, whether it has a [NAME] section (give --platform only
           when the platform has a subagent tool), and whether [rules] root of configs/settings.ini names a rules
           project with an enabled rule (the legacy configs/standards.ini and [points], [deductions] and [grades] of
           the settings are reported too).
           Prints the execution style. Exit 7 when something is missing,
           or when the old configs.ini / plugins.ini is still in the project root (all commands stop then)
  wizard   [--platform NAME]
           create what is missing by asking the user step by step; needs an interactive terminal,
           so the user runs it, not the agent
  plugins  --none
           create configs/plugins.ini without plugins (the user confirmed that no code review plugin is used)
  plugin   --name NAME --path DIR [--applies PATTERNS] [--mode mapped|advisory]
           add a plugin to configs/plugins.ini, or replace the section with the same name; creates the file
           if needed. A relative --path is relative to the folder of the plugin list (configs/)

Options: --plugins FILE (default: configs/plugins.ini in the project root)
         --config FILE  (default: configs/settings.ini in the project root)
Settings in configs/settings.ini are saved with: review-state config --subagent true|false
                                   and review-state config --platform NAME --model TEXT --reasoning TEXT
After the plugins change, run scripts/link-skills in the project root.

Exit codes: 0 ok, 2 bad arguments or invalid plugin, 7 setup incomplete.
USAGE
}

# Absolute path; on Git Bash / MSYS use the Windows form (C:/...) so PowerShell subagents can use it too.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
script_dir="${0:A:h}"
skill_dir="$(dirname "$script_dir")"
# Project root (two levels above the physical skill folder) holds configs/plugins.ini and configs/settings.ini.
project_root="$(dirname "$(dirname "$skill_dir")")"
state_cmd=(zsh "$script_dir/review-state.zsh")

[[ $# -eq 0 ]] && { usage; exit 2; }
cmd="$1"; shift
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
plugins_file="$project_root/configs/plugins.ini" config="$project_root/configs/settings.ini"
platform="" name="" pdir="" applies="" mode="mapped" none=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) platform="${2:?--platform needs a value}"; shift 2 ;;
    --plugins) plugins_file="${2:?--plugins needs a value}"; shift 2 ;;
    --config) config="${2:?--config needs a value}"; shift 2 ;;
    --standards) echo "error: --standards was removed: the rules come from [rules] root of the settings (--config)" >&2; exit 2 ;;
    --name) name="${2:?--name needs a value}"; shift 2 ;;
    --path) pdir="${2:?--path needs a value}"; shift 2 ;;
    --applies) applies="${2:?--applies needs a value}"; shift 2 ;;
    --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
    --none) none=1; shift ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -z "$platform" || "$platform" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: --platform may only contain letters, digits, - and _" >&2; exit 2; }
link_cmd="zsh \"$project_root/scripts/link-skills.zsh\" (PowerShell: scripts\\link-skills.ps1)"

plugin_names() {  # section names of configs/plugins.ini, one per line
  LC_ALL=C awk '/^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", s); print s }' "$plugins_file"
}
subagent_setting() { "${state_cmd[@]}" config --config "$config" 2>/dev/null | sed -n 's/^subagent=//p'; }
platform_ok() { "${state_cmd[@]}" config --platform "$platform" --config "$config" >/dev/null 2>&1; }
fm_name() {  # name in the frontmatter of a SKILL.md
  awk -v q="'" 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit }
    NR > 1 && /^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); gsub(/^"|"$/, ""); if (substr($0, 1, 1) == q) $0 = substr($0, 2, length($0) - 2); print; exit }' "$1"
}

# configs.ini and plugins.ini moved from the project root into configs/ (as settings.ini and plugins.ini).
# The old files are no longer read, so every command stops until the user moves them.
legacy_settings() {
  local found=0 pair old new moves=() ps_moves=()
  for pair in "configs.ini:settings.ini" "plugins.ini:plugins.ini"; do
    old="$project_root/${pair%%:*}" new="$project_root/configs/${pair#*:}"
    [[ -f "$old" ]] || continue
    found=1
    if [[ -f "$new" ]]; then
      echo "legacy: $old is no longer read, and $new already exists"
      echo "        (ask the user which one to keep, and to delete the other)"
    else
      echo "legacy: $old is no longer read; move it to $new"
      moves+=("mv \"$old\" \"$new\"") ps_moves+=("Move-Item \"$old\" \"$new\"")
    fi
  done
  [[ $found -eq 1 ]] || return 0
  [[ -f "$project_root/plugins.ini" ]] && echo "note: relative plugin paths are relative to the folder of the plugin list, so add ../ in front of them after the move"
  echo "next: ask the user to move the files themselves, then run setup check again"
  if [[ ${#moves[@]} -gt 0 ]]; then
    local IFS=';'
    echo "      bash/zsh:   mkdir -p \"$project_root/configs\"; ${moves[*]}"
    echo "      PowerShell: New-Item -ItemType Directory -Force \"$project_root/configs\" | Out-Null; ${ps_moves[*]}"
  fi
  exit 7
}

new_plugins_file() {  # configs/plugins.ini starts as a copy of the commented example
  [[ -f "$plugins_file" ]] && return 0
  mkdir -p "$(dirname "$plugins_file")"
  if [[ -f "$project_root/configs/plugins.example.ini" ]]; then cp "$project_root/configs/plugins.example.ini" "$plugins_file"
  else printf '; Code review plugin skills. See docs/en/configurations.md for the format.\n' > "$plugins_file"; fi
}

# Prints the problem and returns 1 when the plugin is invalid.
check_plugin() {
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "name may only contain letters, digits, - and _"; return 1; }
  [[ -n "$pdir" ]] || { echo "path is required"; return 1; }
  [[ "$mode" == "mapped" || "$mode" == "advisory" ]] || { echo "mode must be mapped or advisory, not $mode"; return 1; }
  [[ "$pdir$applies" != *'"'* ]] || { echo "values may not contain double quotes"; return 1; }
  local base dir
  base="$(abspath "$(dirname "$plugins_file")")"
  dir="$pdir"; [[ "$dir" = /* || "$dir" =~ ^[A-Za-z]: ]] || dir="$base/$dir"
  [[ -f "$dir/SKILL.md" ]] || { echo "$dir/SKILL.md not found"; return 1; }
  local fn; fn="$(fm_name "$dir/SKILL.md")"
  [[ "$fn" == "$name" ]] || { echo "name must match the name in SKILL.md (\"$fn\")"; return 1; }
}

write_plugin() {
  new_plugins_file
  local tmpf; tmpf="$(mktemp)"
  LC_ALL=C awk -v name="$name" -v p="$pdir" -v a="$applies" -v m="$mode" '
    # Replace the [name] section in place, or append it when it does not exist yet.
    function emit() { lines[++n] = "[" name "]"; lines[++n] = "path=\"" p "\""; if (a != "") lines[++n] = "applies=\"" a "\""; lines[++n] = "mode=\"" m "\"" }
    /^[ \t]*\[/ {
      h = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", h)
      skip = 0
      if (h == name) { emit(); done = 1; skip = 1; next }
      if (n > 0 && lines[n] !~ /^[ \t]*$/) lines[++n] = ""
    }
    skip && !/^[ \t]*$/ { next }
    skip { skip = 0 }
    { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
      if (!done) { if (n > 0) lines[++n] = ""; emit() }
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$plugins_file" > "$tmpf"
  mv "$tmpf" "$plugins_file"
}

ask() {  # $1 = prompt, $2 = default; the answer is in $REPLY
  local a
  read -r "a?$1${2:+ [$2]}: " || { echo; echo "Aborted" >&2; exit 2; }
  REPLY="${a:-$2}"
}
yes_no() {  # $1 = prompt, $2 = default y|n
  local hint="y/N"; [[ "$2" == "y" ]] && hint="Y/n"
  while true; do
    ask "$1 (${hint})" ""
    case "${REPLY:-$2}" in [Yy]|[Yy][Ee][Ss]) return 0 ;; [Nn]|[Nn][Oo]) return 1 ;; esac
    echo "Please enter y or n"
  done
}

case "$cmd" in check|wizard|plugins|plugin) legacy_settings ;; esac

case "$cmd" in
  check)
    missing=0
    if [[ -f "$plugins_file" ]]; then
      list="$(plugin_names | paste -sd ',' - | sed 's/,/, /g')"
      echo "configs/plugins.ini: ok ($(plugin_names | grep -c . || true) plugin(s)${list:+: $list}) $plugins_file"
    else
      echo "configs/plugins.ini: missing $plugins_file"; missing=1
    fi
    sub="$(subagent_setting || true)"
    if [[ -n "$sub" ]]; then echo "configs/settings.ini subagent: $sub $config"
    else echo "configs/settings.ini subagent: missing $config"; missing=1; fi
    if [[ "$sub" == "true" && -n "$platform" ]]; then
      if platform_ok; then echo "configs/settings.ini [$platform]: ok $config"
      else echo "configs/settings.ini [$platform]: missing $config"; missing=1; fi
    fi
    # Scoring needs a rules project with an enabled rule; the user sets it up (the wizard does not create it).
    # configs/standards.ini and the scoring sections of the settings are no longer read.
    nostd=0
    if [[ -f "$(dirname "$config")/standards.ini" ]]; then
      echo "legacy: $(dirname "$config")/standards.ini is no longer read; its standards become rules of the rules project ([rules] root)"
      nostd=1
    fi
    old="$( [[ -f "$config" ]] && LC_ALL=C awk '/^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", s)
      if ((s == "points" || s == "deductions" || s == "grades") && !(s in seen)) { seen[s] = 1; o = o (o == "" ? "" : ", ") "[" s "]" } }
      END { print o }' "$config" || true)"
    if [[ -n "$old" ]]; then
      echo "legacy: $old of $config are no longer read; points, severities and grades are set in defaults.ini or rule.ini of the rules project"
      nostd=1
    fi
    rroot="$( [[ -f "$config" ]] && LC_ALL=C awk '{ sub(/\r$/, "") } /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); next }
      s == "rules" && /^[ \t]*root[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*$/, "", v); gsub(/^"|"$/, "", v); r = v }
      END { print r }' "$config" || true)"
    if [[ -z "$rroot" ]]; then echo "configs/settings.ini [rules] root: missing $config"; nostd=1
    else
      [[ "$rroot" = /* || "$rroot" =~ ^[A-Za-z]: ]] || rroot="$(dirname "$config")/$rroot"
      if [[ ! -f "$rroot/rules.ini" ]]; then echo "configs/settings.ini [rules] root: no rules.ini in $rroot"; nostd=1
      elif [[ ! -f "$rroot/defaults.ini" ]]; then echo "configs/settings.ini [rules] root: no defaults.ini in $rroot"; nostd=1
      else
        rroot="$(abspath "$rroot")"
        on="$(LC_ALL=C awk '{ sub(/\r$/, "") } /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); n[++k] = s; next }
          k && /^[ \t]*enable[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*$/, "", v); gsub(/^"|"$/, "", v); on[k] = (v == "true") }
          END { for (i = 1; i <= k; i++) if (on[i]) print n[i] }' "$rroot/rules.ini")"
        if [[ -n "$on" ]]; then echo "configs/settings.ini [rules] root: ok ($(grep -c . <<<"$on") enabled rule(s): $(paste -sd ',' - <<<"$on" | sed 's/,/, /g')) $rroot"
        else echo "configs/settings.ini [rules] root: no enabled rule in $rroot/rules.ini"; nostd=1; fi
      fi
    fi
    if [[ $nostd -eq 1 ]]; then
      echo "next: ask the user to set up their scoring rules: a rules project (e.g. a clone of code-review-scoring-rules) with"
      echo "      rules.ini, defaults.ini and a rule.ini and document per rule, and [rules] root in configs/settings.ini naming"
      echo "      its folder (template: templates/<language>/scoring-rule-template.md); never create them yourself"
    fi
    if [[ $missing -eq 1 ]]; then
      echo "next: ask the user whether to create the missing settings with the wizard in a terminal"
      echo "      (zsh \"$script_dir/setup.zsh\" wizard${platform:+ --platform $platform}) or by answering your questions"
      exit 7
    fi
    [[ $nostd -eq 0 ]] || exit 7
    if [[ "$sub" == "true" && -n "$platform" ]]; then echo "execution: subagent (each step runs in its own subagent with the [$platform] settings)"
    elif [[ "$sub" == "true" ]]; then echo "execution: inline (subagent=true, but no --platform was given, so the main agent runs every step)"
    else echo "execution: inline (subagent=false, so the main agent runs every step)"; fi
    echo "next: setup complete"
    ;;

  wizard)
    [[ -t 0 ]] || { echo "error: wizard needs an interactive terminal; ask the user to run it, or create the settings with plugins/plugin and review-state config" >&2; exit 2; }
    changed=0
    if [[ ! -f "$plugins_file" ]]; then
      echo "== Code review plugins (${plugins_file})"
      echo "Code review plugins are existing code review skills; step 2 of the workflow runs them on the changed files."
      if yes_no "Register code review plugins?" "y"; then
        while true; do
          ask "Plugin name (must match the name in its SKILL.md)" ""; name="${REPLY}"
          ask "Skill folder path (relative to $(dirname "${plugins_file}"))" ""; pdir="${REPLY}"
          ask "File patterns, comma-separated (e.g. *.java,*.sql; empty = all changed files)" ""; applies="${REPLY}"
          while true; do
            ask "Mode: mapped (confirmed comments can become deductions) or advisory (report only)" "mapped"; mode="${REPLY}"
            [[ "$mode" == "mapped" || "$mode" == "advisory" ]] && break
            echo "Please enter mapped or advisory"
          done
          if problem="$(check_plugin)"; then
            write_plugin; changed=1; echo "Registered [${name}]"
            yes_no "Register another plugin?" "n" || break
          else
            echo "Cannot register: ${problem}. Please try again."
          fi
        done
      else
        new_plugins_file; echo "Created ${plugins_file} without plugins"
      fi
    fi
    sub="$(subagent_setting || true)"
    if [[ -z "$sub" ]]; then
      echo "== Execution style (subagent in ${config})"
      echo "true: each step runs in its own subagent (when the platform has a subagent tool); false: the main agent runs every step itself."
      if yes_no "Run the steps in subagents?" "y"; then sub="true"; else sub="false"; fi
      "${state_cmd[@]}" config --subagent "$sub" --config "$config"
    fi
    if [[ "$sub" == "true" && -n "$platform" ]] && ! platform_ok; then
      echo "== Subagent settings ([${platform}] in ${config})"
      while true; do
        ask "Subagent model" ""; m="${REPLY}"
        ask "Subagent reasoning level" ""; r="${REPLY}"
        [[ -n "$m" && -n "$r" ]] && "${state_cmd[@]}" config --platform "$platform" --model "$m" --reasoning "$r" --config "$config" && break
        echo "Both model and reasoning are required and may not contain double quotes. Please try again."
      done
    fi
    [[ ${changed} -eq 1 ]] && echo "The plugin list changed; run ${link_cmd} to link the plugin skills."
    echo "Setup complete."
    ;;

  plugins)
    [[ $none -eq 1 ]] || { echo "error: plugins needs --none" >&2; exit 2; }
    if [[ -f "$plugins_file" ]]; then echo "configs/plugins.ini already exists: $plugins_file"; exit 0; fi
    new_plugins_file
    echo "created $plugins_file without plugins"
    ;;

  plugin)
    [[ -n "$name" ]] || { echo "error: plugin needs --name NAME" >&2; exit 2; }
    problem="$(check_plugin)" || { echo "error: plugin $name: $problem" >&2; exit 2; }
    write_plugin
    echo "saved [$name] to $plugins_file"
    echo "next: run $link_cmd"
    ;;

  *) echo "error: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac
