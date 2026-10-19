#!/usr/bin/env bash
# 依 skills/ 與 plugins.ini 同步各 AI 工具讀取 Skill 的目錄：建立缺少的連結、解除已不在清單中的連結。
# macOS / Linux 建立 symlink；Windows 的 Git Bash / MSYS2 / Cygwin 建立 Junction（不需系統管理員權限）。
# 只會變更本腳本建立過的連結（記錄在各目錄的 .managed），不會動到其他連結或實體目錄。
set -euo pipefail

usage() {
  cat <<'USAGE'
用法：link-skills.sh [選項]

  -t, --target LIST  要同步的目標，以逗號分隔（預設 agents,github）：
                       agents  → .agents/skills（Codex、Gemini CLI 等通用位置）
                       github  → .github/skills（GitHub Copilot）
                       claude  → .claude/skills（Claude Code）
                       all     → 以上全部
  -c, --config FILE  外掛清單（預設：專案根目錄的 plugins.ini）
      --check        只檢查並列出會做的變更，不實際修改
      --remove       移除本腳本建立的所有連結（不會刪除 Skill 本身）
  -h, --help         顯示說明

同步前會檢查：SKILL.md 是否存在、資料夾名稱與 name 是否一致、名稱是否重複、
是否設定了 disable-model-invocation: true，以及目標位置是否已有不是本腳本建立的同名項目。
有任何問題時不會做任何變更。

結束代碼：0 成功、1 檢查未通過、2 參數錯誤。
USAGE
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
targets="agents,github" config="" mode="sync"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) targets="${2:?--target 需要參數}"; shift 2 ;;
    -c|--config) config="${2:?--config 需要參數}"; shift 2 ;;
    --check) mode="check"; shift ;;
    --remove) mode="remove"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "錯誤：未知的參數 $1（使用 --help 查看用法）" >&2; exit 2 ;;
  esac
done
[[ "$targets" == "all" ]] && targets="agents,github,claude"
[[ -z "$config" ]] && config="$root/plugins.ini"

is_windows=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) is_windows=1 ;; esac

# Junction 在 Git Bash 中不一定會被 -L 判定為連結，因此另外用 cmd 的 dir 屬性判斷
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
make_link() {  # $1=連結位置 $2=Skill 的絕對路徑 $3=internal|plugin
  if [[ $is_windows -eq 1 ]]; then
    cmd //c "mklink /J \"$(cygpath -w "$1")\" \"$(cygpath -w "$2")\"" >/dev/null
  elif [[ "$3" == "internal" ]]; then
    ln -s "../../skills/$(basename "$2")" "$1"   # 專案內的 Skill 用相對路徑，搬動專案也不會失效
  else
    ln -s "$2" "$1"
  fi
}
same_dir() { [[ "$(cd "$1" 2>/dev/null && pwd -P)" == "$(cd "$2" 2>/dev/null && pwd -P)" ]]; }
fm_name() {  # 讀取 SKILL.md frontmatter 的 name
  awk -v q="'" 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit }
    NR > 1 && /^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); gsub(/^"|"$/, ""); if (substr($0, 1, 1) == q) $0 = substr($0, 2, length($0) - 2); print; exit }' "$1"
}
fm_disabled() {  # frontmatter 是否設定 disable-model-invocation: true
  awk 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit }
    NR > 1 && /^disable-model-invocation:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); gsub(/["\047\r \t]/, "", v); if (v == "true") found = 1; exit }
    END { exit !found }' "$1"
}

# ---- 1. 收集要連結的 Skill：skills/ 下的全部 + plugins.ini ----
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
          errors+=("[$sec] 找不到路徑 $val")
        fi ;;
      mode) [[ "$val" == "advisory" || "$val" == "mapped" ]] || errors+=("[$sec] mode 只能是 advisory 或 mapped，不能是 $val") ;;
      applies) ;;
      __nopath__) errors+=("[$sec] 缺少 path") ;;
      *) errors+=("[$sec] 未知的設定 $key") ;;
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
elif [[ "$config" != "$root/plugins.ini" ]]; then
  echo "錯誤：找不到外掛清單 $config" >&2; exit 2
fi

# ---- 2. 檢查每個 Skill ----
count=${#names[@]}
for ((i = 0; i < count; i++)); do
  n="${names[$i]}" p="${paths[$i]}"
  if [[ ! -f "$p/SKILL.md" ]]; then errors+=("${n}：找不到 $p/SKILL.md"); continue; fi
  fn="$(fm_name "$p/SKILL.md")"
  [[ "${kinds[$i]}" == "plugin" && "$fn" != "$n" ]] && errors+=("${n}：外掛區段名稱必須和 SKILL.md 的 name「${fn}」一致")
  [[ "$(basename "$p")" == "$fn" ]] || errors+=("${n}：資料夾名稱「$(basename "$p")」和 SKILL.md 的 name「${fn}」不一致")
  fm_disabled "$p/SKILL.md" && errors+=("${n}：設定了 disable-model-invocation: true，Sub-Agent 將無法透過 Skill 工具載入")
  for ((j = 0; j < i; j++)); do [[ "${names[$j]}" == "$n" ]] && errors+=("${n}：名稱重複（${paths[$j]} 與 ${p}）"); done
done

# ---- 3. 對每個目標比對現況，列出變更 ----
IFS=',' read -r -a target_list <<< "$targets"
plan=()   # 每筆：動作<TAB>目錄<TAB>名稱<TAB>路徑<TAB>種類
for t in "${target_list[@]}"; do
  case "$t" in
    agents) dir="$root/.agents/skills" ;;
    github) dir="$root/.github/skills" ;;
    claude) dir="$root/.claude/skills" ;;
    *) echo "錯誤：未知的目標 ${t}（只能是 agents、github、claude、all）" >&2; exit 2 ;;
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
      errors+=("${link#"$root"/}：已有不是本腳本建立的連結，指向其他位置，請手動確認後移除")
    elif [[ -e "$link" ]]; then
      errors+=("${link#"$root"/}：已存在實體檔案或目錄，請手動確認後移除")
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
  echo "檢查未通過，沒有做任何變更：" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  exit 1
fi

# ---- 4. 套用變更 ----
changes=0
for item in ${plan[@]+"${plan[@]}"}; do
  IFS=$'\t' read -r action dir n p kind <<< "$item"
  rel="${dir#"$root"/}/$n"
  case "$action" in
    link|relink|adopt|unlink)
      changes=$((changes + 1))
      label=""
      case "$action" in link) label="連結" ;; relink) label="重新連結" ;; adopt) label="納入管理" ;; unlink) label="解除連結" ;; esac
      if [[ "$mode" == "check" ]]; then echo "將${label} ${rel}${p:+ → $p}"; continue; fi
      [[ "$action" == "unlink" || "$action" == "relink" ]] && remove_link "$dir/$n"
      if [[ "$action" == "link" || "$action" == "relink" ]]; then mkdir -p "$dir"; make_link "$dir/$n" "$p" "$kind"; fi
      echo "已${label} ${rel}${p:+ → $p}"
      ;;
    manifest)
      [[ "$mode" == "check" ]] && continue
      if [[ "$mode" == "remove" ]]; then rm -f "$dir/.managed"; continue; fi
      mkdir -p "$dir"
      printf '%s\n' ${names[@]+"${names[@]}"} > "$dir/.managed"
      ;;
  esac
done
[[ $changes -eq 0 ]] && echo "已是最新狀態，沒有需要變更的連結"
exit 0
