<#
.SYNOPSIS
依 skills/ 與 plugins.ini 同步各 AI 工具讀取 Skill 的目錄：建立缺少的連結、解除已不在清單中的連結。

.DESCRIPTION
Windows 建立 Junction（不需系統管理員權限）；macOS / Linux 的 PowerShell 7 建立 symlink。
只會變更本腳本建立過的連結（記錄在各目錄的 .managed），不會動到其他連結或實體目錄。

同步前會檢查：SKILL.md 是否存在、資料夾名稱與 name 是否一致、名稱是否重複、
是否設定了 disable-model-invocation: true，以及目標位置是否已有不是本腳本建立的同名項目。
有任何問題時不會做任何變更。

目標：
  agents → .agents/skills（Codex、Gemini CLI 等通用位置）
  github → .github/skills（GitHub Copilot）
  claude → .claude/skills（Claude Code）
  all    → 以上全部

相容 Windows PowerShell 5.1 與 PowerShell 7+。本檔以 UTF-8 with BOM 儲存，請勿改成其他編碼。
結束代碼：0 成功、1 檢查未通過、2 參數錯誤。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts/link-skills.ps1
.EXAMPLE
pwsh -File scripts/link-skills.ps1 -Target all -Check
.EXAMPLE
pwsh -File scripts/link-skills.ps1 -Remove
#>
[CmdletBinding()]
param(
    [Alias('t')][string[]]$Target = @('agents', 'github'),
    [Alias('c')][string]$Config,
    [switch]$Check,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $utf8 } catch { }

$root = Split-Path -Parent $PSScriptRoot
$isWin = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
$cmp = if ($isWin) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$dirs = [ordered]@{ agents = '.agents/skills'; github = '.github/skills'; claude = '.claude/skills' }

# 支援 -Target agents,github 與 -Target "agents,github" 兩種寫法
$Target = @($Target | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Target -contains 'all') { $Target = @($dirs.Keys) }
foreach ($t in $Target) {
    if (-not $dirs.Contains($t)) { [Console]::Error.WriteLine("錯誤：未知的目標 $t（只能是 agents、github、claude、all）"); exit 2 }
}
$defaultConfig = Join-Path $root 'plugins.ini'
if (-not $Config) { $Config = $defaultConfig }
$Config = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Config)

function Read-Lines([string]$Path) { return [IO.File]::ReadAllText($Path, $utf8) -split "`r?`n" }
function Get-FrontMatter([string]$SkillMd) {
    $fm = @{}
    $lines = Read-Lines $SkillMd
    if ($lines.Count -eq 0 -or -not $lines[0].StartsWith('---')) { return $fm }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith('---')) { break }
        if ($lines[$i] -match '^([A-Za-z-]+):\s*(.*?)\s*$') { $fm[$Matches[1]] = $Matches[2].Trim('"', "'") }
    }
    return $fm
}
function Test-Link([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item) -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Get-LinkTarget([string]$Path) {
    $t = @((Get-Item -LiteralPath $Path -Force).Target)[0]
    if (-not $t) { return '' }
    if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $Path) $t }
    return [IO.Path]::GetFullPath($t).TrimEnd('\', '/')
}
function Remove-Link([string]$Path) {
    # DirectoryInfo.Delete() 不帶 recursive 參數時只會移除連結本身，不會刪到連結目標的內容。
    # 不使用 Remove-Item，因為 Windows PowerShell 5.1 對 Junction 可能會遞迴刪除目標內容。
    (Get-Item -LiteralPath $Path -Force).Delete()
}
function New-Link([string]$Path, [string]$SkillPath, [string]$Kind) {
    if ($isWin) { [void](New-Item -ItemType Junction -Path $Path -Target $SkillPath) }
    elseif ($Kind -eq 'internal') { [void](New-Item -ItemType SymbolicLink -Path $Path -Target "../../skills/$(Split-Path -Leaf $SkillPath)") }
    else { [void](New-Item -ItemType SymbolicLink -Path $Path -Target $SkillPath) }
}

# ---- 1. 收集要連結的 Skill：skills/ 下的全部 + plugins.ini ----
$skills = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
foreach ($d in (Get-ChildItem -LiteralPath (Join-Path $root 'skills') -Directory | Sort-Object Name)) {
    if (Test-Path -LiteralPath (Join-Path $d.FullName 'SKILL.md')) {
        $skills.Add([pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Kind = 'internal' })
    }
}
if ([IO.File]::Exists($Config)) {
    $configDir = Split-Path -Parent $Config
    $sections = [ordered]@{}
    $sec = ''
    foreach ($l in (Read-Lines $Config)) {
        if ($l -match '^\s*[;#]' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*\[(.*)\]\s*$') { $sec = $Matches[1]; $sections[$sec] = @{}; continue }
        if ($sec -and $l -match '^\s*([^=]+?)\s*=\s*"?(.*?)"?\s*$') { $sections[$sec][$Matches[1]] = $Matches[2] }
    }
    foreach ($name in $sections.Keys) {
        $s = $sections[$name]
        foreach ($k in $s.Keys) { if ($k -notin 'path', 'applies', 'mode') { $errors.Add("[$name] 未知的設定 $k") } }
        if ($s.ContainsKey('mode') -and $s['mode'] -notin 'advisory', 'mapped') { $errors.Add("[$name] mode 只能是 advisory 或 mapped，不能是 $($s['mode'])") }
        if (-not $s.ContainsKey('path')) { $errors.Add("[$name] 缺少 path"); continue }
        $p = $s['path']
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $configDir $p }
        $p = [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
        if (-not [IO.Directory]::Exists($p)) { $errors.Add("[$name] 找不到路徑 $p"); continue }
        $skills.Add([pscustomobject]@{ Name = $name; Path = $p; Kind = 'plugin' })
    }
}
elseif ($Config -ne $defaultConfig) {
    [Console]::Error.WriteLine("錯誤：找不到外掛清單 $Config"); exit 2
}

# ---- 2. 檢查每個 Skill ----
for ($i = 0; $i -lt $skills.Count; $i++) {
    $sk = $skills[$i]
    $md = Join-Path $sk.Path 'SKILL.md'
    if (-not [IO.File]::Exists($md)) { $errors.Add("$($sk.Name)：找不到 $md"); continue }
    $fm = Get-FrontMatter $md
    $fn = [string]$fm['name']
    if ($sk.Kind -eq 'plugin' -and $fn -ne $sk.Name) { $errors.Add("$($sk.Name)：外掛區段名稱必須和 SKILL.md 的 name「$fn」一致") }
    $leaf = Split-Path -Leaf $sk.Path
    if ($leaf -ne $fn) { $errors.Add("$($sk.Name)：資料夾名稱「$leaf」和 SKILL.md 的 name「$fn」不一致") }
    if ($fm['disable-model-invocation'] -eq 'true') { $errors.Add("$($sk.Name)：設定了 disable-model-invocation: true，Sub-Agent 將無法透過 Skill 工具載入") }
    for ($j = 0; $j -lt $i; $j++) { if ($skills[$j].Name -eq $sk.Name) { $errors.Add("$($sk.Name)：名稱重複（$($skills[$j].Path) 與 $($sk.Path)）") } }
}

# ---- 3. 對每個目標比對現況，列出變更 ----
$plan = New-Object System.Collections.Generic.List[object]
$desired = @($skills | ForEach-Object { $_.Name })
foreach ($t in $Target) {
    $dir = Join-Path $root $dirs[$t]
    $manifest = Join-Path $dir '.managed'
    $managed = if ([IO.File]::Exists($manifest)) { @(Read-Lines $manifest | Where-Object { $_ }) } else { @() }
    if ($Remove) {
        foreach ($m in $managed) { if (Test-Link (Join-Path $dir $m)) { $plan.Add([pscustomobject]@{ Action = 'unlink'; Dir = $dir; Rel = $dirs[$t]; Name = $m; Path = ''; Kind = '' }) } }
        $plan.Add([pscustomobject]@{ Action = 'manifest'; Dir = $dir; Rel = $dirs[$t]; Name = ''; Path = ''; Kind = '' })
        continue
    }
    foreach ($sk in $skills) {
        $link = Join-Path $dir $sk.Name
        $entry = [pscustomobject]@{ Action = ''; Dir = $dir; Rel = $dirs[$t]; Name = $sk.Name; Path = $sk.Path; Kind = $sk.Kind }
        if (Test-Link $link) {
            if ([string]::Equals((Get-LinkTarget $link), $sk.Path.TrimEnd('\', '/'), $cmp)) {
                if ($managed -notcontains $sk.Name) { $entry.Action = 'adopt'; $plan.Add($entry) }
                continue
            }
            if ($managed -contains $sk.Name) { $entry.Action = 'relink'; $plan.Add($entry); continue }
            $errors.Add("$($dirs[$t])/$($sk.Name)：已有不是本腳本建立的連結，指向其他位置，請手動確認後移除")
        }
        elseif (Test-Path -LiteralPath $link) {
            $errors.Add("$($dirs[$t])/$($sk.Name)：已存在實體檔案或目錄，請手動確認後移除")
        }
        else { $entry.Action = 'link'; $plan.Add($entry) }
    }
    foreach ($m in $managed) {
        if ($desired -notcontains $m -and (Test-Link (Join-Path $dir $m))) {
            $plan.Add([pscustomobject]@{ Action = 'unlink'; Dir = $dir; Rel = $dirs[$t]; Name = $m; Path = ''; Kind = '' })
        }
    }
    $plan.Add([pscustomobject]@{ Action = 'manifest'; Dir = $dir; Rel = $dirs[$t]; Name = ''; Path = ''; Kind = '' })
}

if ($errors.Count -gt 0) {
    [Console]::Error.WriteLine('檢查未通過，沒有做任何變更：')
    foreach ($e in $errors) { [Console]::Error.WriteLine("  - $e") }
    exit 1
}

# ---- 4. 套用變更 ----
$labels = @{ link = '連結'; relink = '重新連結'; adopt = '納入管理'; unlink = '解除連結' }
$changes = 0
foreach ($p in $plan) {
    if ($p.Action -eq 'manifest') {
        if ($Check) { continue }
        $manifest = Join-Path $p.Dir '.managed'
        if ($Remove) { if ([IO.File]::Exists($manifest)) { [IO.File]::Delete($manifest) }; continue }
        [void][IO.Directory]::CreateDirectory($p.Dir)
        [IO.File]::WriteAllText($manifest, (($desired -join "`n") + "`n"), $utf8)
        continue
    }
    $changes++
    $link = Join-Path $p.Dir $p.Name
    $suffix = if ($p.Path) { " → $($p.Path)" } else { '' }
    if ($Check) { Write-Output "將$($labels[$p.Action]) $($p.Rel)/$($p.Name)$suffix"; continue }
    if ($p.Action -in 'unlink', 'relink') { Remove-Link $link }
    if ($p.Action -in 'link', 'relink') { [void][IO.Directory]::CreateDirectory($p.Dir); New-Link $link $p.Path $p.Kind }
    Write-Output "已$($labels[$p.Action]) $($p.Rel)/$($p.Name)$suffix"
}
if ($changes -eq 0) { Write-Output '已是最新狀態，沒有需要變更的連結' }
exit 0
