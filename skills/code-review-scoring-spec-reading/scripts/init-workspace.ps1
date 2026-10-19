<#
.SYNOPSIS
Prepare step 1 of a review: save the PR diff and a spec-context.md skeleton under ROOT/step1.

.DESCRIPTION
Writes ROOT/step1/pr.diff and ROOT/step1/spec-context.md (ROOT defaults to tmp) and prints the step1 path on the last line.
Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 2 bad arguments or input.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File init-workspace.ps1 -Git origin/main...HEAD -Title "Order cancel #123"
#>
[CmdletBinding()]
param(
    [Alias('g')][string]$Git,
    [Alias('r')][string]$Repo = '.',
    [Alias('i', 'Input')][string]$InputPath,
    [string]$Root = 'tmp',
    [Alias('t')][string]$Title = '',
    [Alias('f')][switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

if ($Git -and $InputPath) { Exit-WithError 'use only one of -Git, -InputPath' }
if (-not $Git -and -not $InputPath) { Exit-WithError '-Git or -InputPath is required (see Get-Help)' }
$Dir = Resolve-UserPath (Join-Path $Root 'step1')
[void][IO.Directory]::CreateDirectory($Dir)
$diffPath = Join-Path $Dir 'pr.diff'; $ctxPath = Join-Path $Dir 'spec-context.md'
if (-not $Force) {
    foreach ($f in $diffPath, $ctxPath) { if ([IO.File]::Exists($f)) { Exit-WithError "$f already exists (use -Force to overwrite)" } }
}

if ($Git) {
    $diffText = Get-DiffText -Git $Git -Repo $Repo
    $range = $Git
}
else {
    $diffText = Read-Utf8Text $InputPath
    $range = 'file: ' + [IO.Path]::GetFileName($InputPath)
}
Write-Utf8File $diffPath $diffText
$diffStatus = 'provided'
if (-not $diffText.Trim()) { $diffStatus = 'unknown'; [Console]::Error.WriteLine('warning: the diff is empty; check the range') }

$tpl = Read-Utf8Text (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/spec-context-template.md')
$ctx = $tpl.Replace('{{TITLE}}', $Title).Replace('{{RANGE}}', $range).Replace('{{CREATED}}', (Get-Date -Format 'yyyy-MM-dd')).Replace('{{DIFF_STATUS}}', $diffStatus)
Write-Utf8File $ctxPath $ctx

Write-Output "pr.diff: $([regex]::Matches($diffText, "`n").Count) lines"
Write-Output $Dir
