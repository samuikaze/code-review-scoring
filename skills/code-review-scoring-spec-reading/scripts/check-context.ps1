<#
.SYNOPSIS
Check that every input in spec-context.md is resolved and every open question is answered.

.DESCRIPTION
Checks ROOT/step1/spec-context.md; ROOT (-Root) defaults to tmp in the project root.
Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ready, 1 waiting for the user (or malformed file), 2 bad arguments,
3 a required input was declined (stop the review).

.EXAMPLE
powershell -ExecutionPolicy Bypass -File check-context.ps1
#>
[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

if (-not $Root) { $Root = Join-Path (Get-ProjectRoot (Split-Path -Parent $PSScriptRoot)) 'tmp' }

$ctx = Join-Path $Root 'step1/spec-context.md'
if (-not (Test-UserFile $ctx)) { Exit-WithError "$ctx not found; run init-workspace first" }

$section = ''; $seen = @{}
$bad = @(); $stop = @(); $wait = @(); $declined = @()
foreach ($line in (Read-Utf8Lines $ctx)) {
    if ($line.StartsWith('## ')) { $section = $line.Substring(3).Trim(); continue }
    if ($section -eq 'Inputs' -and $line -cmatch '^- ([a-z-]+):\s*(\S*)') {
        $key = $Matches[1]; $st = $Matches[2]; $seen[$key] = $true
        if ($st -cnotin 'unknown', 'pending', 'provided', 'declined') { $bad += "  - ${key}: invalid status `"$st`" (use unknown, pending, provided or declined)"; continue }
        if ($key -in 'diff', 'pr-description' -and $st -eq 'declined') { $stop += "  - $key (required) was declined" }
        elseif ($st -eq 'unknown') { $wait += "  - ${key}: not checked yet; ask the user whether it can be provided" }
        elseif ($st -eq 'pending') { $wait += "  - ${key}: asked, waiting for the user's reply" }
        elseif ($st -eq 'declined') { $declined += "  - $key" }
        continue
    }
    if ($section -eq 'Open questions' -and $line.StartsWith('- [ ] ')) { $wait += "  - open question: $($line.Substring(6))" }
}
if (-not $seen.ContainsKey('diff') -or -not $seen.ContainsKey('pr-description')) { $bad += '  - the Inputs section must list diff and pr-description' }

$out = [Console]::Out
if ($bad.Count) { $out.WriteLine('spec-context.md is malformed:'); $bad | ForEach-Object { $out.WriteLine($_) }; exit 1 }
if ($stop.Count) { $out.WriteLine('STOP: a required input is unavailable, so the PR cannot be scored. Tell the user why:'); $stop | ForEach-Object { $out.WriteLine($_) }; exit 3 }
if ($wait.Count) { $out.WriteLine("NOT READY: ask the user about all of these in one message (as a subagent: write them to $(Join-Path $Root 'step1/questions.md') and set the step to pending), record the replies, then run this check again:"); $wait | ForEach-Object { $out.WriteLine($_) }; exit 1 }
$out.WriteLine('READY: all inputs are resolved and all open questions are answered.')
if ($declined.Count) { $out.WriteLine('Declined optional inputs (record the affected checks as S lines or lower severities in findings.txt):'); $declined | ForEach-Object { $out.WriteLine($_) } }
