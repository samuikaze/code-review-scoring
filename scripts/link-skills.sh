#!/usr/bin/env bash
# Syncs the skill folders that AI tools read with skills/ and configs/plugins.ini: creates missing links and removes links that are no longer listed.
# macOS / Linux get symlinks; Git Bash / MSYS2 / Cygwin on Windows get junctions (no administrator rights needed).
# Only links created by this script (listed in .managed in each folder) are changed; other links and real folders are left alone.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: link-skills.sh [options]

  -t, --target LIST  targets to sync, comma-separated (default: agents,github):
                       agents  -> .agents/skills (shared location for Codex, Gemini CLI and others)
                       github  -> .github/skills (GitHub Copilot)
                       claude  -> .claude/skills (Claude Code)
                       all     -> all of the above
  -c, --config FILE  plugin list (default: configs/plugins.ini in the project root)
      --check        only check and list the changes, without applying them
      --remove       remove every link created by this script (the skills themselves are kept)
  -h, --help         show this help

Before syncing it checks that every SKILL.md exists, that folder names match their name, that names
are unique, that no skill sets disable-model-invocation: true, and that no target already holds an item
with the same name that this script did not create. Nothing is changed when a check fails.

Exit codes: 0 ok, 1 check failed, 2 bad arguments.
USAGE
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
targets="agents,github" config="" mode="sync"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) targets="${2:?--target needs a value}"; shift 2 ;;
    -c|--config) config="${2:?--config needs a value}"; shift 2 ;;
    --check) mode="check"; shift ;;
    --remove) mode="remove"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ "$targets" == "all" ]] && targets="agents,github,claude"
[[ -z "$config" ]] && config="$root/configs/plugins.ini"
# plugins.ini moved from the project root into configs/; syncing without it would unlink every plugin.
if [[ "$mode" != "remove" && "$config" == "$root/configs/plugins.ini" && -f "$root/plugins.ini" ]]; then
  echo "error: $root/plugins.ini is no longer read; move it to $config (add ../ in front of relative plugin paths), then run this again" >&2; exit 2
fi

is_windows=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) is_windows=1 ;; esac

# Git Bash does not always report a junction as a link with -L, so also check its dir attributes with cmd
is_link() {
  [[ -L "$1" ]] && return 0
  if [[ $is_windows -eq 1 && -d "$1" ]]; then
    cmd //c "dir /AL /B \"$(cygpath -w "$(dirname "$1")")\"" 2>/dev/null | tr -d '\r' | grep -qx "$(basename "$1")"
    return $?
  fi
  return 1
}
remove_link() {
  if [[ $is_windows -eq 1 ]]; then cmd //c "rmdir \"$(cygpath -w "$1")\"" >/dev/null; else rm -f "$1"; fi
}
make_link() {  # $1 = link location, $2 = absolute skill path, $3 = internal|plugin
  if [[ $is_windows -eq 1 ]]; then
    cmd //c "mklink /J \"$(cygpath -w "$1")\" \"$(cygpath -w "$2")\"" >/dev/null
  elif [[ "$3" == "internal" ]]; then
    ln -s "../../skills/$(basename "$2")" "$1"   # relative for skills of this project, so moving the project keeps the links working
  else
    ln -s "$2" "$1"
  fi
}
same_dir() { [[ "$(cd "$1" 2>/dev/null && pwd -P)" == "$(cd "$2" 2>/dev/null && pwd -P)" ]]; }
fm_name() {  # name in the frontmatter of a SKILL.md
  awk -v q="'" 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit }
    NR > 1 && /^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); gsub(/^"|"$/, ""); if (substr($0, 1, 1) == q) $0 = substr($0, 2, length($0) - 2); print; exit }' "$1"
}
fm_disabled() {  # whether the frontmatter sets disable-model-invocation: true
  awk 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit }
    NR > 1 && /^disable-model-invocation:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); gsub(/["\047\r \t]/, "", v); if (v == "true") found = 1; exit }
    END { exit !found }' "$1"
}

# ---- 1. Skills to link: everything under skills/ plus configs/plugins.ini ----
names=() paths=() kinds=() errors=()
for d in "$root"/skills/*; do
  [[ -f "$d/SKILL.md" ]] || continue
  names+=("$(basename "$d")"); paths+=("$d"); kinds+=("internal")
done
if [[ -f "$config" ]]; then
  config_dir="$(cd "$(dirname "$config")" && pwd)"
  while IFS=$'\t' read -r sec key val; do
    case "$key" in
      path)
        [[ "$val" = /* || "$val" =~ ^[A-Za-z]: ]] || val="$config_dir/$val"
        if [[ -d "$val" ]]; then
          names+=("$sec"); paths+=("$(cd "$val" && pwd)"); kinds+=("plugin")
        else
          errors+=("[$sec] path not found: $val")
        fi ;;
      mode) [[ "$val" == "advisory" || "$val" == "mapped" ]] || errors+=("[$sec] mode must be advisory or mapped, not $val") ;;
      applies) ;;
      __nopath__) errors+=("[$sec] path is missing") ;;
      *) errors+=("[$sec] unknown setting $key") ;;
    esac
  done < <(LC_ALL=C awk '
    /^[ \t]*[;#]/ || /^[ \t]*$/ { next }
    /^[ \t]*\[/ { if (sec != "" && !haspath) print sec "\t__nopath__\t"; sec = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", sec); haspath = 0; next }
    sec != "" && /=/ {
      k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); gsub(/^"|"$/, "", v)
      if (k == "path") haspath = 1
      print sec "\t" k "\t" v
    }
    END { if (sec != "" && !haspath) print sec "\t__nopath__\t" }
  ' "$config")
elif [[ "$config" != "$root/configs/plugins.ini" ]]; then
  echo "error: plugin list not found: $config" >&2; exit 2
fi

# ---- 2. Check every skill ----
count=${#names[@]}
for ((i = 0; i < count; i++)); do
  n="${names[$i]}" p="${paths[$i]}"
  if [[ ! -f "$p/SKILL.md" ]]; then errors+=("${n}: $p/SKILL.md not found"); continue; fi
  fn="$(fm_name "$p/SKILL.md")"
  [[ "${kinds[$i]}" == "plugin" && "$fn" != "$n" ]] && errors+=("${n}: the plugin section name must match the name in SKILL.md (\"${fn}\")")
  [[ "$(basename "$p")" == "$fn" ]] || errors+=("${n}: folder name \"$(basename "$p")\" does not match the name in SKILL.md (\"${fn}\")")
  fm_disabled "$p/SKILL.md" && errors+=("${n}: disable-model-invocation: true is set, so subagents cannot load it with the skill tool")
  for ((j = 0; j < i; j++)); do [[ "${names[$j]}" == "$n" ]] && errors+=("${n}: duplicate name (${paths[$j]} and ${p})"); done
done

# ---- 3. Compare every target with its current state and plan the changes ----
IFS=',' read -r -a target_list <<< "$targets"
plan=()   # each item: action<TAB>folder<TAB>name<TAB>path<TAB>kind
for t in "${target_list[@]}"; do
  case "$t" in
    agents) dir="$root/.agents/skills" ;;
    github) dir="$root/.github/skills" ;;
    claude) dir="$root/.claude/skills" ;;
    *) echo "error: unknown target ${t} (must be agents, github, claude or all)" >&2; exit 2 ;;
  esac
  managed=()
  [[ -f "$dir/.managed" ]] && while IFS= read -r m; do [[ -n "$m" ]] && managed+=("$m"); done < "$dir/.managed"
  is_managed() { local m; for m in ${managed[@]+"${managed[@]}"}; do [[ "$m" == "$1" ]] && return 0; done; return 1; }

  if [[ "$mode" == "remove" ]]; then
    for m in ${managed[@]+"${managed[@]}"}; do is_link "$dir/$m" && plan+=("unlink	$dir	$m		"); done
    plan+=("manifest	$dir				")
    continue
  fi
  for ((i = 0; i < count; i++)); do
    n="${names[$i]}" link="$dir/$n"
    if is_link "$link"; then
      if same_dir "$link" "${paths[$i]}"; then
        is_managed "$n" || plan+=("adopt	$dir	$n	${paths[$i]}	${kinds[$i]}")
        continue
      fi
      if is_managed "$n"; then plan+=("relink	$dir	$n	${paths[$i]}	${kinds[$i]}"); continue; fi
      errors+=("${link#"$root"/}: a link not created by this script points elsewhere; check it and remove it manually")
    elif [[ -e "$link" ]]; then
      errors+=("${link#"$root"/}: a real file or folder is in the way; check it and remove it manually")
    else
      plan+=("link	$dir	$n	${paths[$i]}	${kinds[$i]}")
    fi
  done
  for m in ${managed[@]+"${managed[@]}"}; do
    keep=0; for n in ${names[@]+"${names[@]}"}; do [[ "$n" == "$m" ]] && keep=1; done
    [[ $keep -eq 0 ]] && is_link "$dir/$m" && plan+=("unlink	$dir	$m		")
  done
  plan+=("manifest	$dir				")
done

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "check failed, nothing was changed:" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  exit 1
fi

# ---- 4. Apply the changes ----
changes=0
for item in ${plan[@]+"${plan[@]}"}; do
  IFS=$'\t' read -r action dir n p kind <<< "$item"
  rel="${dir#"$root"/}/$n"
  case "$action" in
    link|relink|adopt|unlink)
      changes=$((changes + 1))
      label="$action" done_label="${action}ed"
      if [[ "$mode" == "check" ]]; then echo "would ${label} ${rel}${p:+ -> $p}"; continue; fi
      [[ "$action" == "unlink" || "$action" == "relink" ]] && remove_link "$dir/$n"
      if [[ "$action" == "link" || "$action" == "relink" ]]; then mkdir -p "$dir"; make_link "$dir/$n" "$p" "$kind"; fi
      echo "${done_label} ${rel}${p:+ -> $p}"
      ;;
    manifest)
      [[ "$mode" == "check" ]] && continue
      if [[ "$mode" == "remove" ]]; then rm -f "$dir/.managed"; continue; fi
      mkdir -p "$dir"
      printf '%s\n' ${names[@]+"${names[@]}"} > "$dir/.managed"
      ;;
  esac
done
[[ $changes -eq 0 ]] && echo "already up to date; no link needs to change"
exit 0
