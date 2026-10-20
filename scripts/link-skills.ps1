<#
.SYNOPSIS
Syncs the skill folders that AI tools read with skills/ and plugins.ini: creates missing links and removes links that are no longer listed.

.DESCRIPTION
Windows gets junctions (no administrator rights needed); PowerShell 7 on macOS / Linux gets symlinks.
Only links created by this script (listed in .managed in each folder) are changed; other links and real folders are left alone.

Before syncing it checks that every SKILL.md exists, that folder names match their name, that names
are unique, that no skill sets disable-model-invocation: true, and that no target already holds an item
with the same name that this script did not create. Nothing is changed when a check fails.

Targets:
  agents -> .agents/skills (shared location for Codex, Gemini CLI and others)
  github -> .github/skills (GitHub Copilot)
  claude -> .claude/skills (Claude Code)
  all    -> all of the above

Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 1 check failed, 2 bad arguments.

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

# Accepts both -Target agents,github and -Target "agents,github"
$Target = @($Target | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Target -contains 'all') { $Target = @($dirs.Keys) }
foreach ($t in $Target) {
    if (-not $dirs.Contains($t)) { [Console]::Error.WriteLine("error: unknown target $t (must be agents, github, claude or all)"); exit 2 }
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
    # DirectoryInfo.Delete() without the recursive argument removes only the link itself, never the content of its target.
    # Remove-Item is not used because Windows PowerShell 5.1 may delete the content of a junction target recursively.
    (Get-Item -LiteralPath $Path -Force).Delete()
}
function New-Link([string]$Path, [string]$SkillPath, [string]$Kind) {
    if ($isWin) { [void](New-Item -ItemType Junction -Path $Path -Target $SkillPath) }
    elseif ($Kind -eq 'internal') { [void](New-Item -ItemType SymbolicLink -Path $Path -Target "../../skills/$(Split-Path -Leaf $SkillPath)") }
    else { [void](New-Item -ItemType SymbolicLink -Path $Path -Target $SkillPath) }
}

# ---- 1. Skills to link: everything under skills/ plus plugins.ini ----
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
        foreach ($k in $s.Keys) { if ($k -notin 'path', 'applies', 'mode') { $errors.Add("[$name] unknown setting $k") } }
        if ($s.ContainsKey('mode') -and $s['mode'] -notin 'advisory', 'mapped') { $errors.Add("[$name] mode must be advisory or mapped, not $($s['mode'])") }
        if (-not $s.ContainsKey('path')) { $errors.Add("[$name] path is missing"); continue }
        $p = $s['path']
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $configDir $p }
        $p = [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
        if (-not [IO.Directory]::Exists($p)) { $errors.Add("[$name] path not found: $p"); continue }
        $skills.Add([pscustomobject]@{ Name = $name; Path = $p; Kind = 'plugin' })
    }
}
elseif ($Config -ne $defaultConfig) {
    [Console]::Error.WriteLine("error: plugin list not found: $Config"); exit 2
}

# ---- 2. Check every skill ----
for ($i = 0; $i -lt $skills.Count; $i++) {
    $sk = $skills[$i]
    $md = Join-Path $sk.Path 'SKILL.md'
    if (-not [IO.File]::Exists($md)) { $errors.Add("$($sk.Name): $md not found"); continue }
    $fm = Get-FrontMatter $md
    $fn = [string]$fm['name']
    if ($sk.Kind -eq 'plugin' -and $fn -ne $sk.Name) { $errors.Add("$($sk.Name): the plugin section name must match the name in SKILL.md (`"$fn`")") }
    $leaf = Split-Path -Leaf $sk.Path
    if ($leaf -ne $fn) { $errors.Add("$($sk.Name): folder name `"$leaf`" does not match the name in SKILL.md (`"$fn`")") }
    if ($fm['disable-model-invocation'] -eq 'true') { $errors.Add("$($sk.Name): disable-model-invocation: true is set, so subagents cannot load it with the skill tool") }
    for ($j = 0; $j -lt $i; $j++) { if ($skills[$j].Name -eq $sk.Name) { $errors.Add("$($sk.Name): duplicate name ($($skills[$j].Path) and $($sk.Path))") } }
}

# ---- 3. Compare every target with its current state and plan the changes ----
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
            $errors.Add("$($dirs[$t])/$($sk.Name): a link not created by this script points elsewhere; check it and remove it manually")
        }
        elseif (Test-Path -LiteralPath $link) {
            $errors.Add("$($dirs[$t])/$($sk.Name): a real file or folder is in the way; check it and remove it manually")
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
    [Console]::Error.WriteLine('check failed, nothing was changed:')
    foreach ($e in $errors) { [Console]::Error.WriteLine("  - $e") }
    exit 1
}

# ---- 4. Apply the changes ----
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
    $suffix = if ($p.Path) { " -> $($p.Path)" } else { '' }
    if ($Check) { Write-Output "would $($p.Action) $($p.Rel)/$($p.Name)$suffix"; continue }
    if ($p.Action -in 'unlink', 'relink') { Remove-Link $link }
    if ($p.Action -in 'link', 'relink') { [void][IO.Directory]::CreateDirectory($p.Dir); New-Link $link $p.Path $p.Kind }
    Write-Output "$($p.Action)ed $($p.Rel)/$($p.Name)$suffix"
}
if ($changes -eq 0) { Write-Output 'already up to date; no link needs to change' }
exit 0
