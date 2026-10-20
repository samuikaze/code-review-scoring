#!/usr/bin/env bash
# Setup check for the code review scoring workflow: plugins.ini and configs.ini in the project root.
# "check" tells the agent what is missing; the missing files are created either by the user with the
# interactive "wizard", or by the agent with "plugins --none", "plugin" and "review-state config".
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: setup.sh <command> [options]

Commands:
  check    [--platform NAME]
           report whether plugins.ini exists and, with --platform, whether configs.ini has a [NAME] section
           (give --platform only in subagent mode). Exit 7 when something is missing
  wizard   [--platform NAME]
           create what is missing by asking the user step by step; needs an interactive terminal,
           so the user runs it, not the agent
  plugins  --none
           create plugins.ini without plugins (the user confirmed that no code review plugin is used)
  plugin   --name NAME --path DIR [--applies PATTERNS] [--mode mapped|advisory]
           add a plugin to plugins.ini, or replace the section with the same name; creates plugins.ini if needed.
           A relative --path is relative to the folder of plugins.ini

Options: --plugins FILE (default: plugins.ini in the project root)
         --config FILE  (default: configs.ini in the project root)
Subagent settings are saved with: review-state config --platform NAME --model TEXT --reasoning TEXT
After the plugins change, run scripts/link-skills in the project root.

Exit codes: 0 ok, 2 bad arguments or invalid plugin, 7 setup incomplete.
USAGE
}

# Absolute path; on Git Bash / MSYS use the Windows form (C:/...) so PowerShell subagents can use it too.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
script_dir="$(abspath "$(dirname "${BASH_SOURCE[0]}")")"
skill_dir="$(dirname "$script_dir")"
# Project root (two levels above the physical skill folder) holds plugins.ini and configs.ini.
project_root="$(dirname "$(dirname "$skill_dir")")"
state_cmd=(bash "$script_dir/review-state.sh")

[[ $# -eq 0 ]] && { usage; exit 2; }
cmd="$1"; shift
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
plugins_file="$project_root/plugins.ini" config="$project_root/configs.ini"
platform="" name="" pdir="" applies="" mode="mapped" none=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) platform="${2:?--platform needs a value}"; shift 2 ;;
    --plugins) plugins_file="${2:?--plugins needs a value}"; shift 2 ;;
    --config) config="${2:?--config needs a value}"; shift 2 ;;
    --name) name="${2:?--name needs a value}"; shift 2 ;;
    --path) pdir="${2:?--path needs a value}"; shift 2 ;;
    --applies) applies="${2:?--applies needs a value}"; shift 2 ;;
    --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
    --none) none=1; shift ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -z "$platform" || "$platform" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: --platform may only contain letters, digits, - and _" >&2; exit 2; }
link_cmd="bash \"$project_root/scripts/link-skills.sh\" (PowerShell: scripts\\link-skills.ps1)"

plugin_names() {  # section names of plugins.ini, one per line
  LC_ALL=C awk '/^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", s); print s }' "$plugins_file"
}
platform_ok() { "${state_cmd[@]}" config --platform "$platform" --config "$config" >/dev/null 2>&1; }
fm_name() {  # name in the frontmatter of a SKILL.md
  awk -v q="'" 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit }
    NR > 1 && /^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); gsub(/^"|"$/, ""); if (substr($0, 1, 1) == q) $0 = substr($0, 2, length($0) - 2); print; exit }' "$1"
}

new_plugins_file() {  # plugins.ini starts as a copy of the commented example
  [[ -f "$plugins_file" ]] && return 0
  if [[ -f "$project_root/plugins.example.ini" ]]; then cp "$project_root/plugins.example.ini" "$plugins_file"
  else printf '; Code review plugin skills. See plugins.example.ini for the format.\n' > "$plugins_file"; fi
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
  read -r -p "$1${2:+ [$2]}: " a || { echo; echo "Aborted" >&2; exit 2; }
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

case "$cmd" in
  check)
    missing=0
    if [[ -f "$plugins_file" ]]; then
      list="$(plugin_names | paste -sd ',' - | sed 's/,/, /g')"
      echo "plugins.ini: ok ($(plugin_names | grep -c . || true) plugin(s)${list:+: $list}) $plugins_file"
    else
      echo "plugins.ini: missing $plugins_file"; missing=1
    fi
    if [[ -n "$platform" ]]; then
      if platform_ok; then echo "configs.ini [$platform]: ok $config"
      else echo "configs.ini [$platform]: missing $config"; missing=1; fi
    fi
    if [[ $missing -eq 1 ]]; then
      echo "next: ask the user whether to create the missing settings with the wizard in a terminal"
      echo "      (bash \"$script_dir/setup.sh\" wizard${platform:+ --platform $platform}) or by answering your questions"
      exit 7
    fi
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
    if [[ -n "$platform" ]] && ! platform_ok; then
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
    if [[ -f "$plugins_file" ]]; then echo "plugins.ini already exists: $plugins_file"; exit 0; fi
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
