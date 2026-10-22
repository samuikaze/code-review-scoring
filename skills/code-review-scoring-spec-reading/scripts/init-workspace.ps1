<#
.SYNOPSIS
Prepare step 1 of a review: save the PR diff and a spec-context.md skeleton under ROOT/step1.

.DESCRIPTION
Writes ROOT/step1/pr.diff and ROOT/step1/spec-context.md (ROOT defaults to tmp in the project root) and prints the step1 path on the last line.
Plans the review with "standard plan" of code-review-scoring: the standards that score the PR (-Standards, default:
configs/standards.ini in the project root) go to ROOT/step1/standards/ (one report per framework standard), and their
confirmations go to the Severity facts of spec-context.md. Without standards.ini (standalone use) the plan is skipped
with a warning.
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
    [string]$Root,
    [Alias('t')][string]$Title = '',
    [Alias('f')][switch]$Force,
    [string]$Standards
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$projectRoot = Get-ProjectRoot (Split-Path -Parent $PSScriptRoot)
if (-not $Root) { $Root = Join-Path $projectRoot 'tmp' }
if (-not $Standards) { $Standards = Join-Path $projectRoot 'configs/standards.ini' }

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

# The standards that score the PR (code-review-scoring/scripts/standard.ps1 plan) and what they need to know first.
$planDir = Join-Path $Dir 'standards'
if ([IO.Directory]::Exists($planDir)) { [IO.Directory]::Delete($planDir, $true) }
$confirm = '- (no scoring standard is planned: configs/standards.ini is missing)' + "`n"
if (-not (Test-UserFile $Standards)) {
    [Console]::Error.WriteLine("warning: $Standards not found; the review is not planned (the workflow needs it, see setup check)")
}
elseif ($diffStatus -eq 'provided') {
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $std = Join-Path $projectRoot 'skills/code-review-scoring/scripts/standard.ps1'
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $exe -NoProfile -ExecutionPolicy Bypass -File $std plan --diff $diffPath --out $planDir --standards (Resolve-UserPath $Standards) | ForEach-Object { Write-Output $_ } }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { exit 2 }  # plan has printed the error
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in (Read-Utf8Lines (Join-Path $planDir 'confirm.tsv') | Where-Object { $_ })) { $c = $l.Split("`t"); [void]$sb.Append("- $($c[1]) ($($c[0])) $($c[2]):`n") }
    $confirm = if ($sb.Length -gt 0) { $sb.ToString() } else { '- (the scoring standards list nothing to confirm)' + "`n" }
}
else { $confirm = '- (no scoring standard is planned: the diff is empty)' + "`n" }

$tpl = Read-Utf8Text (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/spec-context-template.md')
$tpl = $tpl -replace "(?m)^\{\{CONFIRMATIONS\}\}\r?\n", $confirm.Replace('$', '$$')
$ctx = $tpl.Replace('{{TITLE}}', $Title).Replace('{{RANGE}}', $range).Replace('{{CREATED}}', (Get-Date -Format 'yyyy-MM-dd')).Replace('{{DIFF_STATUS}}', $diffStatus)
Write-Utf8File $ctxPath $ctx

Write-Output "pr.diff: $([regex]::Matches($diffText, "`n").Count) lines"
Write-Output $Dir
