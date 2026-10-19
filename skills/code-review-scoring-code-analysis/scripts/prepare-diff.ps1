<#
.SYNOPSIS
Preprocess a PR diff: drop non-reviewable files, number new-file lines, list heuristic candidates.

.DESCRIPTION
Prints a summary, heuristic candidates (clues only) and a compact diff with new-file line numbers.
With -Root, reads ROOT/step1/pr.diff and writes ROOT/step3/prepared.txt unless -Out is given.
Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 2 bad arguments or input.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File prepare-diff.ps1 -Root tmp
.EXAMPLE
pwsh -File prepare-diff.ps1 -Git origin/main...HEAD -Mode scan
#>
[CmdletBinding()]
param(
    [string]$Root,
    [Alias('i', 'Input')][string]$InputPath,
    [Alias('g')][string]$Git,
    [Alias('r')][string]$Repo = '.',
    [Alias('m')][ValidateSet('all', 'summary', 'scan', 'view')][string]$Mode = 'all',
    [int]$Max = 15,
    [Alias('o')][string]$Out
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

if (@($Root, $InputPath, $Git | Where-Object { $_ }).Count -gt 1) { Exit-WithError 'use only one of -Root, -InputPath, -Git' }
if ($Root) {
    $InputPath = Join-Path $Root 'step1/pr.diff'
    if (-not $Out) {
        [void][IO.Directory]::CreateDirectory((Resolve-UserPath (Join-Path $Root 'step3')))
        $Out = Join-Path $Root 'step3/prepared.txt'
    }
}
$diffText = Get-DiffText -InputPath $InputPath -Git $Git -Repo $Repo

# Load scan rules
$rules = New-Object System.Collections.Generic.List[object]
$idOrder = New-Object System.Collections.Generic.List[string]
foreach ($l in (Read-Utf8Lines (Join-Path $PSScriptRoot 'scan-rules.tsv'))) {
    if ($l -match '^#' -or $l -match '^\s*$') { continue }
    $a = $l -split "`t"
    if ($a.Count -lt 7) { continue }
    $opt = [Text.RegularExpressions.RegexOptions]::None
    if ($a[2] -like '*i*') { $opt = [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $rules.Add([pscustomobject]@{
        Id = $a[0]; Scope = $a[1]; Comments = ($a[2] -like '*c*')
        Re = [regex]::new($a[3], $opt)
        Prev = $(if ($a[4] -ne '-') { [regex]::new($a[4], $opt) } else { $null })
        Excl = $(if ($a[5] -ne '-') { [regex]::new($a[5], $opt) } else { $null })
        Hint = $a[6]
    })
    if (-not $idOrder.Contains($a[0])) { $idOrder.Add($a[0]) }
}

function Test-Comment([string]$s, [string]$path) {
    $t = $s.Trim()
    if ($t -match '^(//|/\*|\*)') { return $true }
    if ($path -match '\.(ya?ml|properties)$' -and $t.StartsWith('#')) { return $true }
    if ($path -match '\.sql$' -and $t.StartsWith('--')) { return $true }
    return $false
}

function Test-Scope([string]$scope, $f) {
    switch ($scope) {
        'any' { return $true }
        'test' { return $f.IsTest }
        'nontest' { return -not $f.IsTest }
        'java' { return $f.Path -match '\.(java|kt)$' }
        'main' { return $f.IsMain }
        'controller' { return $f.IsMain -and $f.Path -cmatch 'Controller[A-Za-z0-9_]*\.(java|kt)$' }
        'ctrltest' { return $f.IsTest -and $f.Path -cmatch '(Controller|Repository)[A-Za-z0-9_]*(Test|Tests|IT)\.(java|kt)$' }
    }
    return $false
}

function Get-Snippet([string]$s) {
    $s = $s.Trim()
    if ($s.Length -gt 140) { $s = $s.Substring(0, 140) + '...' }
    return $s
}

$files = New-Object System.Collections.Generic.List[object]
$cands = New-Object System.Collections.Generic.List[object]
$seen = @{}
$cur = $null; $inHunk = $false; $oLeft = 0; $nLeft = 0; $nNo = 0; $prev = ''

function New-FileEntry([string]$p) {
    $f = [pscustomobject]@{ Path = ''; Status = 'modified'; Adds = 0; Dels = 0; Hunks = 0
        View = New-Object System.Text.StringBuilder; Excl = ''; IsTest = $false; IsMain = $false; IsMig = $false }
    Set-FilePath $f $p
    $script:files.Add($f)
    return $f
}

function Set-FilePath($f, [string]$p) {
    $f.Path = $p
    $f.IsTest = ($p -match '(^|/)src/test/' -or $p -cmatch '(Test|Tests|IT)\.(java|kt)$')
    $f.IsMain = (-not $f.IsTest -and $p -match '(^|/)src/main/(java|kotlin)/.+\.(java|kt)$')
    $f.IsMig = ($p -match '(^|/)(db/migration|db/changelog|liquibase|flyway)/' -or $p -match '(^|/)[VUR][0-9][0-9_.]*__[A-Za-z0-9_]+\.sql$')
    $f.Excl = ''
    if ($p -match '(^|/)(target|build|out|dist|\.gradle|node_modules)/' -or $p -match '(^|/)generated(-sources|-test-sources)?/') { $f.Excl = 'build output / generated' }
    elseif ($p -match '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$' -or $p -match '\.lock$') { $f.Excl = 'lock file' }
    elseif ($p -match '\.(class|jar|war|png|jpe?g|gif|ico|pdf|zip)$') { $f.Excl = 'binary file' }
}

function Invoke-Scan($f, [int]$ln, [string]$text) {
    if ($text -match '^\s*$') { return }
    $isComment = Test-Comment $text $f.Path
    foreach ($r in $script:rules) {
        if (-not (Test-Scope $r.Scope $f)) { continue }
        if (-not $r.Comments -and $isComment) { continue }
        if (-not $r.Re.IsMatch($text)) { continue }
        if ($r.Prev -and -not $r.Prev.IsMatch($script:prev)) { continue }
        if ($r.Excl -and $r.Excl.IsMatch($script:prev + ' ' + $text)) { continue }
        $key = "$($r.Id)|$($f.Path)|$ln"
        if ($script:seen.ContainsKey($key)) { continue }
        $script:seen[$key] = $true
        $script:cands.Add([pscustomobject]@{ Id = $r.Id; File = $f; Line = $ln; Hint = $r.Hint; Text = (Get-Snippet $text) })
    }
}

foreach ($raw in ($diffText -split "`n")) {
    $line = $raw.TrimEnd("`r")
    if ($inHunk -and ($oLeft -gt 0 -or $nLeft -gt 0)) {
        if ($line.Length -eq 0) { $tag = ' '; $body = '' } else { $tag = $line.Substring(0, 1); $body = $line.Substring(1) }
        if ($tag -eq '\') { continue }
        if ($tag -eq '+') {
            $cur.Adds++; $nLeft--
            [void]$cur.View.AppendFormat("+{0,5}  {1}`n", $nNo, $body)
            if ($cur.Adds -le 15 -and $body -cmatch '@(javax|jakarta)\.annotation\.(processing\.)?Generated|DO NOT EDIT|[Aa]uto-generated') { $cur.Excl = 'marked as generated' }
            Invoke-Scan $cur $nNo $body
            if ($body -notmatch '^\s*$') { $prev = $body }
            $nNo++; continue
        }
        if ($tag -eq '-') { $cur.Dels++; $oLeft--; [void]$cur.View.Append("-       $body`n"); continue }
        if ($tag -eq ' ') {
            [void]$cur.View.AppendFormat(" {0,5}  {1}`n", $nNo, $body)
            if ($body -notmatch '^\s*$') { $prev = $body }
            $nNo++; $oLeft--; $nLeft--; continue
        }
        $inHunk = $false
    }
    if ($line.StartsWith('diff --git ')) {
        $p = ''
        if ($line -match ' "?b/(.*?)"?$') { $p = $Matches[1] }
        $cur = New-FileEntry $p; $inHunk = $false; continue
    }
    if ($line.StartsWith('--- ')) {
        if ($null -eq $cur -or $cur.Hunks -gt 0) { $cur = New-FileEntry '' }
        if ($line.StartsWith('--- /dev/null')) { $cur.Status = 'added' }
        continue
    }
    if ($null -eq $cur) { continue }
    if ($line.StartsWith('+++ ')) {
        $p = ($line.Substring(4) -split "`t")[0].Trim('"')
        if ($p -eq '/dev/null') { $cur.Status = 'deleted' } else { Set-FilePath $cur ($p -replace '^b/', '') }
        continue
    }
    if ($line.StartsWith('new file mode')) { $cur.Status = 'added'; continue }
    if ($line.StartsWith('deleted file mode')) { $cur.Status = 'deleted'; continue }
    if ($line.StartsWith('rename from ')) { $cur.Status = 'renamed'; continue }
    if ($line.StartsWith('Binary files ')) { $cur.Status = 'binary'; continue }
    if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
        $oLeft = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
        $nNo = [int]$Matches[3]
        $nLeft = if ($Matches[4]) { [int]$Matches[4] } else { 1 }
        $inHunk = $true; $cur.Hunks++; $prev = ''
        [void]$cur.View.Append("$line`n")
    }
}

if ($files.Count -eq 0) { Exit-WithError 'no parsable diff in input' }

$nk = 0; $nx = 0; $nTest = 0; $nMain = 0; $nMig = 0; $migMod = New-Object System.Text.StringBuilder
foreach ($f in $files) {
    if (-not $f.Excl -and $f.Status -eq 'deleted') { $f.Excl = 'deleted file' }
    if (-not $f.Excl -and $f.Status -eq 'binary') { $f.Excl = 'binary file' }
    if ($f.Excl) { $nx++; continue }
    $nk++
    if ($f.IsTest) { $nTest++ }
    if ($f.IsMain -and $f.Adds -gt 0) { $nMain++ }
    if ($f.IsMig) { $nMig++; if ($f.Status -ne 'added') { [void]$migMod.Append("  - $($f.Path) ($($f.Status))`n") } }
}

$sb = New-Object System.Text.StringBuilder
if ($Mode -in 'all', 'summary') {
    [void]$sb.Append("## Summary`n")
    [void]$sb.Append("- reviewable files: $nk, excluded: $nx; main code changed: $nMain, test files: $nTest, migrations: $nMig`n")
    foreach ($f in $files) {
        $tagv = if ($f.IsTest) { ' [test]' } elseif ($f.IsMig) { ' [migration]' } else { '' }
        if ($f.Excl) { [void]$sb.Append("  - (excluded: $($f.Excl)) $($f.Path)`n") }
        else { [void]$sb.Append("  - $($f.Path) [$($f.Status) +$($f.Adds) -$($f.Dels)]$tagv`n") }
    }
    [void]$sb.Append("`n")
}
if ($Mode -in 'all', 'scan') {
    [void]$sb.Append("## Heuristic candidates (clues only: confirm in code before deducting; unlisted checks still need manual review)`n")
    if ($nMain -gt 0 -and $nTest -eq 0) { [void]$sb.Append("- C1: main code changed but the PR touches no test file (meets the C1 Critical condition if the change is business logic)`n") }
    if ($migMod.Length -gt 0) { [void]$sb.Append("- G6: existing migration file modified`n").Append($migMod.ToString()) }
    foreach ($id in $idOrder) {
        $hits = @($cands | Where-Object { $_.Id -eq $id -and -not $_.File.Excl })
        if ($hits.Count -eq 0) { continue }
        [void]$sb.Append("- $id ($($hits.Count) hits) $($hits[0].Hint)`n")
        foreach ($h in ($hits | Select-Object -First $Max)) { [void]$sb.Append("  - $($h.File.Path):$($h.Line)  $($h.Text)`n") }
        if ($hits.Count -gt $Max) { [void]$sb.Append("  - ... $($hits.Count - $Max) more not listed`n") }
    }
    [void]$sb.Append("`n")
}
if ($Mode -in 'all', 'view') {
    [void]$sb.Append("## Compact diff (+ = added line; numbers are new-file line numbers, cite these in findings)`n")
    foreach ($f in $files) {
        if ($f.Excl) { continue }
        [void]$sb.Append("`n=== $($f.Path) [$($f.Status) +$($f.Adds) -$($f.Dels)]`n").Append($f.View.ToString())
    }
}

Write-Utf8Output -Text $sb.ToString() -Out $Out
