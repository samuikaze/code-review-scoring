<#
.SYNOPSIS
Setup check for the code review scoring workflow: plugins.ini and configs.ini in the project root.

.DESCRIPTION
"check" tells the agent what is missing; the missing files are created either by the user with the
interactive "wizard", or by the agent with "plugins --none", "plugin" and "review-state config".
Uses the same GNU-style arguments as setup.sh:

  setup.ps1 check [--platform NAME]
      report whether plugins.ini exists, whether configs.ini sets subagent=true|false and, when it is true
      and --platform is given, whether configs.ini has a [NAME] section (give --platform only when the
      platform has a subagent tool). Prints the execution style. Exit 7 when something is missing
  setup.ps1 wizard [--platform NAME]
      create what is missing by asking the user step by step; needs an interactive console,
      so the user runs it, not the agent
  setup.ps1 plugins --none
      create plugins.ini without plugins (the user confirmed that no code review plugin is used)
  setup.ps1 plugin --name NAME --path DIR [--applies PATTERNS] [--mode mapped|advisory]
      add a plugin to plugins.ini, or replace the section with the same name; creates plugins.ini if needed.
      A relative --path is relative to the folder of plugins.ini

Options: --plugins FILE (default: plugins.ini in the project root), --config FILE (default: configs.ini in the project root).
Settings in configs.ini are saved with: review-state config --subagent true|false
                                   and review-state config --platform NAME --model TEXT --reasoning TEXT
After the plugins change, run scripts/link-skills in the project root.

Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 2 bad arguments or invalid plugin, 7 setup incomplete.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$skillDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Get-ProjectRoot $skillDir
$stateScript = Join-Path $PSScriptRoot 'review-state.ps1'
$isWin = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
$selfCmd = if ($isWin) { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" } else { "pwsh -NoProfile -File `"$PSCommandPath`"" }
$linkCmd = "$(if ($isWin) { 'powershell -ExecutionPolicy Bypass' } else { 'pwsh' }) -File `"$(Join-Path $projectRoot 'scripts/link-skills.ps1')`" (bash: scripts/link-skills.sh)"

$argv = @($args)
if ($argv.Count -eq 0 -or $argv[0] -in '-h', '--help') { Get-Help $PSCommandPath -Detailed; exit 2 }
$cmd = [string]$argv[0]
$opt = @{ plugins = (Join-Path $projectRoot 'plugins.ini'); config = (Join-Path $projectRoot 'configs.ini')
    platform = ''; name = ''; path = ''; applies = ''; mode = 'mapped'; none = $false }
$i = 1
while ($i -lt $argv.Count) {
    $a = [string]$argv[$i]
    if ($a -in '--plugins', '--config', '--platform', '--name', '--path', '--applies', '--mode') {
        if ($i + 1 -ge $argv.Count) { Exit-WithError "$a needs a value" }
        $opt[$a.Substring(2)] = [string]$argv[$i + 1]; $i += 2
    }
    elseif ($a -eq '--none') { $opt.none = $true; $i++ }
    else { Exit-WithError "unknown option $a (see Get-Help)" }
}
if ($opt.platform -and $opt.platform -notmatch '^[A-Za-z0-9_-]+$') { Exit-WithError '--platform may only contain letters, digits, - and _' }
$pluginsFile = Resolve-UserPath $opt.plugins
$configFile = Resolve-UserPath $opt.config

function Get-PluginNames {
    if (-not [IO.File]::Exists($pluginsFile)) { return @() }
    $names = @()
    foreach ($l in (Read-Utf8Lines $pluginsFile)) { if ($l -match '^\s*\[(.*)\]\s*$') { $names += $Matches[1] } }
    return $names
}

function Get-IniSection([string]$Section) {
    # key/value pairs of one configs.ini section, read the same way as "review-state config"
    $val = @{}
    if (-not [IO.File]::Exists($configFile)) { return $val }
    $inSec = $false
    foreach ($l in (Read-Utf8Lines $configFile)) {
        if ($l -match '^\s*\[(.*)\]\s*$') { $inSec = ($Matches[1] -ceq $Section); continue }
        if ($inSec -and $l -match '^\s*([A-Za-z_]+)\s*=\s*"?(.*?)"?\s*$') { $val[$Matches[1]] = $Matches[2] }
    }
    return $val
}
# true, false, or an empty string when [workflow] subagent is not set
function Get-Subagent {
    $v = [string](Get-IniSection 'workflow')['subagent']
    $v = $v.ToLowerInvariant()
    if ($v -in 'true', 'false') { return $v } return ''
}
# The [platform] section needs both model and reasoning.
function Test-Platform { $val = Get-IniSection $opt.platform; return [bool]($val['model'] -and $val['reasoning']) }

function Get-SkillName([string]$SkillMd) {
    # name in the frontmatter of a SKILL.md
    $lines = Read-Utf8Lines $SkillMd
    if ($lines.Count -eq 0 -or $lines[0] -notmatch '^---') { return '' }
    for ($k = 1; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match '^---') { break }
        if ($lines[$k] -match '^name:\s*(.*?)\s*$') { return $Matches[1].Trim('"', "'") }
    }
    return ''
}

function New-PluginsFile {
    # plugins.ini starts as a copy of the commented example
    if ([IO.File]::Exists($pluginsFile)) { return }
    $example = Join-Path $projectRoot 'plugins.example.ini'
    if ([IO.File]::Exists($example)) { Write-Utf8File $pluginsFile (Read-Utf8Text $example) }
    else { Write-Utf8File $pluginsFile "; Code review plugin skills. See plugins.example.ini for the format.`n" }
}

# Returns the problem, or an empty string when the plugin is valid.
function Get-PluginProblem {
    if ($opt.name -notmatch '^[A-Za-z0-9_-]+$') { return 'name may only contain letters, digits, - and _' }
    if (-not $opt.path) { return 'path is required' }
    if ($opt.mode -notin 'mapped', 'advisory') { return "mode must be mapped or advisory, not $($opt.mode)" }
    if (($opt.path + $opt.applies).Contains('"')) { return 'values may not contain double quotes' }
    $dir = $opt.path
    if (-not [IO.Path]::IsPathRooted($dir)) { $dir = Join-Path (Split-Path -Parent $pluginsFile) $dir }
    $md = Join-Path $dir 'SKILL.md'
    if (-not [IO.File]::Exists($md)) { return "$md not found" }
    $fn = Get-SkillName $md
    if ($fn -ne $opt.name) { return "name must match the name in SKILL.md (`"$fn`")" }
    return ''
}

function Save-Plugin {
    New-PluginsFile
    $section = @("[$($opt.name)]", "path=`"$($opt.path)`"")
    if ($opt.applies) { $section += "applies=`"$($opt.applies)`"" }
    $section += "mode=`"$($opt.mode)`""
    $lines = New-Object System.Collections.Generic.List[string]
    $skip = $false; $done = $false
    # Replace the [name] section in place, or append it when it does not exist yet.
    foreach ($l in (Read-Utf8Lines $pluginsFile)) {
        if ($l -match '^\s*\[(.*)\]\s*$') {
            $skip = $false
            if ($Matches[1] -eq $opt.name) { $section | ForEach-Object { $lines.Add($_) }; $done = $true; $skip = $true; continue }
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        }
        if ($skip -and $l.Trim()) { continue }
        $skip = $false
        $lines.Add($l)
    }
    while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1].Trim()) { $lines.RemoveAt($lines.Count - 1) }
    if (-not $done) { if ($lines.Count -gt 0) { $lines.Add('') }; $section | ForEach-Object { $lines.Add($_) } }
    Write-Utf8File $pluginsFile (($lines -join "`n") + "`n")
}

function Read-Answer([string]$Prompt, [string]$Default = '') {
    $hint = if ($Default) { " [$Default]" } else { '' }
    [Console]::Write("$Prompt${hint}: ")
    $a = [Console]::ReadLine()
    if ($null -eq $a) { [Console]::WriteLine(); [Console]::Error.WriteLine('Aborted'); exit 2 }
    if ($a) { return $a.Trim() } else { return $Default }
}

function Read-YesNo([string]$Prompt, [bool]$Default) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $a = Read-Answer "$Prompt ($hint)"
        if (-not $a) { return $Default }
        if ($a -match '^(?i)(y|yes)$') { return $true }
        if ($a -match '^(?i)(n|no)$') { return $false }
        [Console]::WriteLine('Please enter y or n')
    }
}

switch ($cmd) {
    'check' {
        $missing = $false
        if ([IO.File]::Exists($pluginsFile)) {
            $names = Get-PluginNames
            $list = if ($names.Count -gt 0) { ": $($names -join ', ')" } else { '' }
            [Console]::WriteLine("plugins.ini: ok ($($names.Count) plugin(s)$list) $pluginsFile")
        }
        else { [Console]::WriteLine("plugins.ini: missing $pluginsFile"); $missing = $true }
        $sub = Get-Subagent
        if ($sub) { [Console]::WriteLine("configs.ini subagent: $sub $configFile") }
        else { [Console]::WriteLine("configs.ini subagent: missing $configFile"); $missing = $true }
        if ($sub -eq 'true' -and $opt.platform) {
            if (Test-Platform) { [Console]::WriteLine("configs.ini [$($opt.platform)]: ok $configFile") }
            else { [Console]::WriteLine("configs.ini [$($opt.platform)]: missing $configFile"); $missing = $true }
        }
        if ($missing) {
            $p = if ($opt.platform) { " --platform $($opt.platform)" } else { '' }
            [Console]::WriteLine('next: ask the user whether to create the missing settings with the wizard in a terminal')
            [Console]::WriteLine("      ($selfCmd wizard$p) or by answering your questions")
            exit 7
        }
        if ($sub -eq 'true' -and $opt.platform) { [Console]::WriteLine("execution: subagent (each step runs in its own subagent with the [$($opt.platform)] settings)") }
        elseif ($sub -eq 'true') { [Console]::WriteLine('execution: inline (subagent=true, but no --platform was given, so the main agent runs every step)') }
        else { [Console]::WriteLine('execution: inline (subagent=false, so the main agent runs every step)') }
        [Console]::WriteLine('next: setup complete')
    }
    'wizard' {
        if ([Console]::IsInputRedirected) { Exit-WithError 'wizard needs an interactive console; ask the user to run it, or create the settings with plugins/plugin and review-state config' }
        $changed = $false
        if (-not [IO.File]::Exists($pluginsFile)) {
            [Console]::WriteLine("== Code review plugins ($pluginsFile)")
            [Console]::WriteLine('Code review plugins are existing code review skills; step 2 of the workflow runs them on the changed files.')
            if (Read-YesNo 'Register code review plugins?' $true) {
                while ($true) {
                    $opt.name = Read-Answer 'Plugin name (must match the name in its SKILL.md)'
                    $opt.path = Read-Answer "Skill folder path (relative to $(Split-Path -Parent $pluginsFile))"
                    $opt.applies = Read-Answer 'File patterns, comma-separated (e.g. *.java,*.sql; empty = all changed files)'
                    while ($true) {
                        $opt.mode = Read-Answer 'Mode: mapped (confirmed comments can become deductions) or advisory (report only)' 'mapped'
                        if ($opt.mode -in 'mapped', 'advisory') { break }
                        [Console]::WriteLine('Please enter mapped or advisory')
                    }
                    $problem = Get-PluginProblem
                    if ($problem) { [Console]::WriteLine("Cannot register: $problem. Please try again."); continue }
                    Save-Plugin; $changed = $true; [Console]::WriteLine("Registered [$($opt.name)]")
                    if (-not (Read-YesNo 'Register another plugin?' $false)) { break }
                }
            }
            else { New-PluginsFile; [Console]::WriteLine("Created $pluginsFile without plugins") }
        }
        $sub = Get-Subagent
        if (-not $sub) {
            [Console]::WriteLine("== Execution style (subagent in $configFile)")
            [Console]::WriteLine('true: each step runs in its own subagent (when the platform has a subagent tool); false: the main agent runs every step itself.')
            $sub = if (Read-YesNo 'Run the steps in subagents?' $true) { 'true' } else { 'false' }
            & $stateScript config --subagent $sub --config $configFile
        }
        if ($sub -eq 'true' -and $opt.platform -and -not (Test-Platform)) {
            [Console]::WriteLine("== Subagent settings ([$($opt.platform)] in $configFile)")
            while ($true) {
                $m = Read-Answer 'Subagent model'
                $r = Read-Answer 'Subagent reasoning level'
                if ($m -and $r -and -not ($m + $r).Contains('"')) {
                    # A script that ends without "exit" leaves $LASTEXITCODE unchanged, so reset it first.
                    $global:LASTEXITCODE = 0
                    & $stateScript config --platform $opt.platform --model $m --reasoning $r --config $configFile
                    if ($LASTEXITCODE -eq 0) { break }
                }
                [Console]::WriteLine('Both model and reasoning are required and may not contain double quotes. Please try again.')
            }
        }
        if ($changed) { [Console]::WriteLine("The plugin list changed; run $linkCmd to link the plugin skills.") }
        [Console]::WriteLine('Setup complete.')
    }
    'plugins' {
        if (-not $opt.none) { Exit-WithError 'plugins needs --none' }
        if ([IO.File]::Exists($pluginsFile)) { [Console]::WriteLine("plugins.ini already exists: $pluginsFile"); exit 0 }
        New-PluginsFile
        [Console]::WriteLine("created $pluginsFile without plugins")
    }
    'plugin' {
        if (-not $opt.name) { Exit-WithError 'plugin needs --name NAME' }
        $problem = Get-PluginProblem
        if ($problem) { Exit-WithError "plugin $($opt.name): $problem" }
        Save-Plugin
        [Console]::WriteLine("saved [$($opt.name)] to $pluginsFile")
        [Console]::WriteLine("next: run $linkCmd")
    }
    default { Exit-WithError "unknown command $cmd (see Get-Help)" }
}
