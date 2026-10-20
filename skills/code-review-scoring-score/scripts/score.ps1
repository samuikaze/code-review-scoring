<#
.SYNOPSIS
Validate findings.txt and compute dimension scores, total and grade.

.DESCRIPTION
With -Root (default: tmp in the project root): uses ROOT/step3/findings.txt and ROOT/step1/pr.diff, refuses unanswered
questions in step1/step3, and writes ROOT/step4/score.tsv and ROOT/step4/score.json.
With -Findings: standalone use without the root layout. Works on Windows PowerShell 5.1 and PowerShell 7+.
Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 1 validation failed (errors on stderr; fix and rerun), 2 bad arguments,
3 spec-context.md still has unresolved inputs or questions.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File score.ps1
#>
[CmdletBinding()]
param(
    [string]$Root,
    [Alias('f')][string]$Findings,
    [Alias('d')][string]$Diff,
    [Alias('g')][string]$Git,
    [Alias('r')][string]$Repo = '.',
    [Alias('o')][string]$OutDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

if (-not $Root -and -not $Findings) { $Root = Join-Path (Get-ProjectRoot (Split-Path -Parent $PSScriptRoot)) 'tmp' }
if ($Root) {
    if (-not [IO.Directory]::Exists((Resolve-UserPath $Root))) { Exit-WithError "review root not found: $Root" }
    if (-not $Findings) { $Findings = Join-Path $Root 'step3/findings.txt' }
    if (-not $Diff -and -not $Git -and (Test-UserFile (Join-Path $Root 'step1/pr.diff'))) { $Diff = Join-Path $Root 'step1/pr.diff' }
    if (-not $OutDir) {
        $OutDir = Join-Path $Root 'step4'
        [void][IO.Directory]::CreateDirectory((Resolve-UserPath $OutDir))
    }
    # Scoring must wait until every input is resolved and every question is answered.
    $ctx = Join-Path $Root 'step1/spec-context.md'
    if (Test-UserFile $ctx) {
        $n = 0
        $pending = @(Read-Utf8Lines $ctx | ForEach-Object { $n++; if ($_ -cmatch '^- [a-z-]+: (unknown|pending)\s*$' -or $_.StartsWith('- [ ] ')) { "${n}:$_" } })
        if ($pending.Count -gt 0) {
            [Console]::Error.WriteLine('error: step1/spec-context.md still has unresolved inputs or open questions; ask the user first:')
            $pending | ForEach-Object { [Console]::Error.WriteLine($_) }
            exit 3
        }
    }
    foreach ($s in 'step1', 'step3') {
        if ((Test-UserFile (Join-Path $Root "$s/questions.md")) -and -not (Test-UserFile (Join-Path $Root "$s/answers.md"))) {
            [Console]::Error.WriteLine("error: $(Join-Path $Root "$s/questions.md") has no answers.md yet; ask the user first")
            exit 3
        }
    }
}
if (-not $Findings) { Exit-WithError '-Root or -Findings is required (see Get-Help)' }
if (-not (Test-UserFile $Findings)) { Exit-WithError "findings file not found: $Findings" }
if (-not $OutDir) { $OutDir = Split-Path -Parent (Resolve-UserPath $Findings) }

# Default and allowed severities per check id
$def = @{}; $adj = @{}
foreach ($l in (Read-Utf8Lines (Join-Path $PSScriptRoot 'rules.tsv'))) {
    if ($l -match '^#' -or $l -match '^\s*$') { continue }
    $a = $l -split "`t"
    $def[$a[0]] = $a[1]; $adj[$a[0]] = @($a[2] -split ',' | Where-Object { $_ -ne '-' })
}

# Line index of the diff: key = "path|line", value = '+' (added) or ' ' (context)
$kind = @{}; $known = @{}; $hasTest = $false; $useIndex = $false
if ($Diff -or $Git) {
    $useIndex = $true
    $diffText = Get-DiffText -InputPath $Diff -Git $Git -Repo $Repo
    $p = ''; $inHunk = $false; $oLeft = 0; $nLeft = 0; $nNo = 0
    foreach ($raw in ($diffText -split "`n")) {
        $line = $raw.TrimEnd("`r")
        if ($inHunk -and ($oLeft -gt 0 -or $nLeft -gt 0)) {
            $tag = if ($line.Length -eq 0) { ' ' } else { $line.Substring(0, 1) }
            if ($tag -eq '\') { continue }
            if ($tag -eq '+') { if ($p) { $kind["$p|$nNo"] = '+'; $known[$p] = $true }; $nNo++; $nLeft--; continue }
            if ($tag -eq '-') { $oLeft--; continue }
            if ($tag -eq ' ') { if ($p) { $kind["$p|$nNo"] = ' '; $known[$p] = $true }; $nNo++; $oLeft--; $nLeft--; continue }
            $inHunk = $false
        }
        if ($line.StartsWith('diff --git ')) { $p = ''; $inHunk = $false; continue }
        if ($line.StartsWith('+++ ')) {
            $p = ($line.Substring(4) -split "`t")[0].Trim('"')
            if ($p -eq '/dev/null') { $p = '' } else { $p = $p -replace '^b/', '' }
            if ($p -match '(^|/)src/test/' -or $p -cmatch '(Test|Tests|IT)\.(java|kt)$') { $hasTest = $true }
            continue
        }
        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            $oLeft = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
            $nNo = [int]$Matches[3]
            $nLeft = if ($Matches[4]) { [int]$Matches[4] } else { 1 }
            $inHunk = $true
        }
    }
}
else {
    [Console]::Error.WriteLine('note: no diff given, location checks skipped')
}

$pts = @{ Critical = 10; Major = 5; Minor = 2; Nit = 0 }
$rank = @{ Critical = 1; Major = 2; Minor = 3; Nit = 4 }
$uTypes = @{
    'spec-gap'         = @('missing', 'wrong', 'ambiguous')
    'third-party'      = @('spec-missing', 'spec-wrong', 'behavior-mismatch', 'not-delivered', 'bug')
    'ownership-change' = @('spec', 'interface', 'process')
}
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$found = [ordered]@{}
$upstream = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]

function Add-Error([int]$Line, [string]$Message) { $script:errors.Add("  - line ${Line}: $Message") }

# Checks that the record just finished has the continuation fields it needs.
function Close-Record {
    if ($script:rec -eq 'F') {
        if (-not $script:fld.ContainsKey('problem')) { Add-Error $script:recLine "$($script:recId) is missing `"problem:`"" }
        if ($script:recSev -ne 'Nit' -and -not $script:fld.ContainsKey('suggestion')) { Add-Error $script:recLine "$($script:recId) is missing `"suggestion:`"" }
    }
    elseif ($script:rec -eq 'U') {
        if (-not $script:fld.ContainsKey('content')) { Add-Error $script:recLine 'upstream record is missing "content:"' }
    }
    $script:rec = ''; $script:fld = @{}
}

$rec = ''; $fld = @{}; $recId = ''; $recSev = ''; $recLine = 0
$no = 0
foreach ($raw in ((Read-Utf8Text $Findings) -split "`n")) {
    $no++
    $line = $raw.TrimEnd("`r")
    if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
    if ($line -cmatch '^\s*([a-z]+):\s*(.*)$' -and $line -cnotmatch '^[A-Z]\|') {
        $key = $Matches[1]; $val = $Matches[2].Trim()
        if ($rec -eq 'skip') { continue }
        if ($rec -eq '') { Add-Error $no "field `"$key`" is not under an F or U record"; continue }
        if ($rec -eq 'F' -and $key -cnotin 'problem', 'suggestion', 'assumption', 'source') { Add-Error $no "unknown field `"$key`" for F (allowed: problem, suggestion, assumption, source)"; continue }
        if ($rec -eq 'U' -and $key -cnotin 'content', 'code', 'ticket') { Add-Error $no "unknown field `"$key`" for U (allowed: content, code, ticket)"; continue }
        if (-not $val) { Add-Error $no "field `"$key`" is empty"; continue }
        $fld[$key] = $val
        continue
    }
    Close-Record
    $c = @($line -split '\|' | ForEach-Object { $_.Trim() })
    while ($c.Count -lt 5) { $c += '' }
    switch -CaseSensitive ($c[0]) {
        'F' {
            $id = $c[1]; $sev = $c[2]; $locs = $c[3]; $reason = $c[4]
            $rec = 'skip'; $recId = $id; $recSev = $sev; $recLine = $no
            if (-not $def.ContainsKey($id)) { Add-Error $no "unknown check id $id"; break }
            if ($sev -cnotin 'Critical', 'Major', 'Minor', 'Nit') { Add-Error $no "${id}: severity `"$sev`" is not Critical/Major/Minor/Nit"; break }
            if ($sev -ne $def[$id] -and $sev -ne 'Nit') {
                if ($adj[$id] -notcontains $sev) {
                    $adjText = if ($adj[$id].Count -gt 0) { ", the allowed adjustment $($adj[$id] -join ',')" } else { '' }
                    Add-Error $no "${id}: severity must be the default $($def[$id])$adjText or Nit, not $sev"; break
                }
                if (-not $reason) { Add-Error $no "${id}: non-default severity $sev needs the matching adjustment condition in column 5"; break }
            }
            if ($id -eq 'C1' -and $sev -eq 'Critical' -and $useIndex -and $hasTest) { Add-Error $no 'C1 Critical requires that the PR changes no test file, but the diff contains test files' }
            if ($found.Contains($id)) { Add-Error $no "$id appears more than once. A check id is deducted once: merge all locations into one record"; break }
            if (-not $locs) { Add-Error $no "${id}: missing file:line locations"; break }
            $locList = New-Object System.Collections.Generic.List[string]
            foreach ($loc in ($locs -split ',' | ForEach-Object { $_.Trim() })) {
                if ($loc -notmatch '^(.+):(\d+)(-\d+)?$') { Add-Error $no "${id}: location `"$loc`" is not file:line"; continue }
                $fp = $Matches[1]; $ln = $Matches[2]
                if ($sev -ne 'Nit' -and $useIndex) {
                    if (-not $known.ContainsKey($fp)) { Add-Error $no "${id}: file `"$fp`" is not in the diff (use the full path from the diff, no ...)" }
                    elseif (-not $kind.ContainsKey("$fp|$ln")) { Add-Error $no "${id}: $loc is outside the diff hunks" }
                    elseif ($kind["$fp|$ln"] -ne '+') { $warnings.Add("  - ${id}: $loc is an unchanged context line; make sure the problem is in added or changed code") }
                }
                $locList.Add($loc)
            }
            $found[$id] = [pscustomobject]@{ Id = $id; Severity = $sev; Locations = $locList }
            $rec = 'F'
        }
        'U' {
            $rec = 'skip'; $recLine = $no
            if (-not $uTypes.ContainsKey($c[1])) { Add-Error $no 'upstream type must be spec-gap, third-party or ownership-change'; break }
            if ($uTypes[$c[1]] -cnotcontains $c[2]) { Add-Error $no "upstream subtype for $($c[1]) must be one of: $($uTypes[$c[1]] -join ',')"; break }
            if ($c[1] -eq 'spec-gap' -and $c[3] -cnotin 'high', 'medium', 'low') { Add-Error $no 'spec-gap needs impact high, medium or low'; break }
            if ($c[1] -ne 'spec-gap' -and $c[3] -and $c[3] -ne '-') { Add-Error $no 'impact is only used for spec-gap; write - instead'; break }
            if (-not $c[4]) { Add-Error $no 'upstream record needs a reference (spec section/version, change-log date or vendor ticket); without one, do not list it'; break }
            $upstream.Add([pscustomobject]@{ Type = $c[1]; Subtype = $c[2]; Impact = $c[3]; Reference = $c[4] })
            $rec = 'U'
        }
        'S' {
            if (-not $c[1] -or -not $c[2]) { Add-Error $no 'format is S|check-id|reason'; break }
            $skipped.Add([pscustomobject]@{ Id = $c[1]; Reason = $c[2] })
        }
        { $_ -cin 'H', 'N', 'I', 'R' } {
            if (-not $c[1]) { Add-Error $no "$($c[0]) record has no text" }
        }
        default { Add-Error $no "unknown record type `"$($c[0])`" (allowed: F, U, S, H, N, I, R)" }
    }
}
Close-Record

$tsvPath = Join-Path $OutDir 'score.tsv'; $jsonPath = Join-Path $OutDir 'score.json'
foreach ($old in $tsvPath, $jsonPath) { if (Test-UserFile $old) { [IO.File]::Delete((Resolve-UserPath $old)) } }

if ($errors.Count -gt 0) {
    [Console]::Error.WriteLine("validation failed with $($errors.Count) error(s). Fix findings.txt and run again:")
    $errors | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($warnings.Count -gt 0) { [Console]::Error.WriteLine('warnings:'); $warnings | ForEach-Object { [Console]::Error.WriteLine($_) } }
    exit 1
}

function ConvertTo-JsonString([string]$s) {
    return '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace "`t", '\t') + '"'
}
function Join-JsonArray($items) {
    if ($items.Count -eq 0) { return '[]' }
    return "[`n" + ($items -join ",`n") + "`n  ]"
}

$dimMax = [ordered]@{ A = 25; B = 15; C = 15; D = 15; E = 10; F = 10; G = 10 }
$sorted = @($found.Values | Sort-Object @{ Expression = { $rank[$_.Severity] } }, @{ Expression = { $_.Id } })
$deducted = @($sorted | Where-Object { $_.Severity -ne 'Nit' })
$scores = [ordered]@{}; $total = 0; $crit = $false
foreach ($d in $dimMax.Keys) {
    $ded = 0
    foreach ($x in $deducted) {
        if ($x.Id.Substring(0, 1) -ne $d) { continue }
        $ded += $pts[$x.Severity]
        if ($x.Severity -eq 'Critical') { $crit = $true }
    }
    $scores[$d] = [Math]::Max(0, $dimMax[$d] - $ded)
    $total += $scores[$d]
}
$grade = if ($total -ge 95) { 'S' } elseif ($total -ge 85) { 'A' } elseif ($total -ge 70) { 'B' } elseif ($total -ge 55) { 'C' } else { 'D' }
$capped = $false
if ($crit -and $grade -in 'S', 'A') { $grade = 'B'; $capped = $true }

$tsv = New-Object System.Text.StringBuilder
[void]$tsv.Append("total`t$total`ngrade`t$grade`ncapped`t$([int]$capped)`ncritical`t$([int]$crit)`n")
foreach ($d in $dimMax.Keys) { [void]$tsv.Append("dim`t$d`t$($scores[$d])`t$($dimMax[$d])`n") }
foreach ($x in $deducted) { [void]$tsv.Append("finding`t$($x.Id)`t$($x.Severity)`t$($pts[$x.Severity])`t$($x.Locations -join ',')`n") }
Write-Utf8File $tsvPath $tsv.ToString()

$q = '"'
$dimJson = @($dimMax.Keys | ForEach-Object { $q + $_ + $q + ': ' + $scores[$_] }) -join ', '
$fj = @($deducted | ForEach-Object {
        $locJson = @($_.Locations | ForEach-Object { ConvertTo-JsonString $_ }) -join ', '
        '    { "id": ' + (ConvertTo-JsonString $_.Id) + ', "severity": ' + (ConvertTo-JsonString $_.Severity) +
        ', "deduction": ' + $pts[$_.Severity] + ', "locations": [' + $locJson + '] }'
    })
$uj = @($upstream | ForEach-Object {
        $imp = if (-not $_.Impact -or $_.Impact -eq '-') { 'null' } else { ConvertTo-JsonString $_.Impact }
        '    { "type": ' + (ConvertTo-JsonString $_.Type) + ', "subtype": ' + (ConvertTo-JsonString $_.Subtype) +
        ', "impact": ' + $imp + ', "reference": ' + (ConvertTo-JsonString $_.Reference) + ' }'
    })
$sj = @($skipped | ForEach-Object { '    { "id": ' + (ConvertTo-JsonString $_.Id) + ', "reason": ' + (ConvertTo-JsonString $_.Reason) + ' }' })
$json = "{`n" +
'  "total": ' + $total + ",`n" +
'  "grade": "' + $grade + '"' + ",`n" +
'  "hasCritical": ' + $crit.ToString().ToLower() + ",`n" +
'  "dimensions": { ' + $dimJson + " },`n" +
'  "findings": ' + (Join-JsonArray $fj) + ",`n" +
'  "upstream": ' + (Join-JsonArray $uj) + ",`n" +
'  "skippedChecks": ' + (Join-JsonArray $sj) + "`n}`n"
Write-Utf8File $jsonPath $json

$capNote = if ($capped) { ' (capped at B because of a Critical finding)' } else { '' }
$summary = "grade $grade, total $total/100$capNote`n" +
(@($dimMax.Keys | ForEach-Object { "$_ $($scores[$_])/$($dimMax[$_])  " }) -join '') + "`n" +
"deductions: $($deducted.Count), upstream: $($upstream.Count), skipped checks: $($skipped.Count)`n"
[Console]::Out.Write($summary)
if ($warnings.Count -gt 0) { [Console]::Error.WriteLine('warnings:'); $warnings | ForEach-Object { [Console]::Error.WriteLine($_) } }
Write-Output "wrote $tsvPath and $jsonPath"
