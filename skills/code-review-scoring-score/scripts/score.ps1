<#
.SYNOPSIS
Validate findings.txt and compute dimension scores, total and grade.

.DESCRIPTION
With -Root (default: tmp in the project root): uses ROOT/step3/findings.txt and ROOT/step1/pr.diff, refuses unanswered
questions in step1/step3, checks that every comment of a mapped code review plugin in ROOT/step2 is deducted or rejected,
and writes ROOT/step4/score.tsv and ROOT/step4/score.json.
With -Findings: standalone use without the root layout.
Scoring settings come from the [points], [deductions] (incl. merge) and [grades] sections of -Config (default: configs/settings.ini in
the project root); settings that are not given keep the defaults. Works on Windows PowerShell 5.1 and PowerShell 7+.
Saved as UTF-8 with BOM; keep that encoding.
The check items come from -Standard (a section of -Standards, default: configs/standards.ini in the project root; default
standard: the only framework standard, or the common standard when no framework standard is registered) and from the
common standard; the [points] overrides of -Standard win over the settings.
With -Check: validate findings.txt only (same checks and exit codes) and write nothing; step 3 runs it before reporting success.
Exit codes: 0 ok, 1 validation failed (errors on stderr; fix and rerun), 2 bad arguments, invalid scoring settings or standards
(run standard lint),
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
    [Alias('o')][string]$OutDir,
    [string]$Config,
    [string]$Standard,
    [string]$Standards,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$projectRoot = Get-ProjectRoot (Split-Path -Parent $PSScriptRoot)
if (-not $Root -and -not $Findings) { $Root = Join-Path $projectRoot 'tmp' }
if (-not $Config) { $Config = Join-Path $projectRoot 'configs/settings.ini' }
if (-not $Standards) { $Standards = Join-Path $projectRoot 'configs/standards.ini' }
if ($Root) {
    if (-not [IO.Directory]::Exists((Resolve-UserPath $Root))) { Exit-WithError "review root not found: $Root" }
    if (-not $Findings) { $Findings = Join-Path $Root 'step3/findings.txt' }
    if (-not $Diff -and -not $Git -and (Test-UserFile (Join-Path $Root 'step1/pr.diff'))) { $Diff = Join-Path $Root 'step1/pr.diff' }
    if (-not $OutDir -and -not $Check) {
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

# Check items of the standard and of the common standard, and the points overrides of the standard
# (code-review-scoring/scripts/standard.ps1 resolve, run with the same PowerShell; it prints its own errors).
$def = @{}; $adj = @{}; $override = @{}; $std = $null; $common = $null
$resolveArgs = @('resolve', '--standards', $Standards, '--settings', $Config)
if ($Standard) { $resolveArgs += $Standard }
$exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $resolved = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'skills/code-review-scoring/scripts/standard.ps1') @resolveArgs) }
finally { $ErrorActionPreference = $prev }
if ($LASTEXITCODE -ne 0) { exit 2 }
foreach ($l in $resolved) {
    $a = $l -split "`t"
    switch -CaseSensitive ($a[0]) {
        'check' { $def[$a[1]] = $a[2]; $adj[$a[1]] = @($a[3] -split ',' | Where-Object { $_ -ne '-' }) }
        'points' { $override[$a[1]] = [int]$a[2] }
        'standard' { $std = $a }
        'common' { $common = $a }
    }
}

# Line index of the diff: key = "path|line", value = '+' (added) or ' ' (context)
$kind = @{}; $known = @{}; $useIndex = $false
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

# Defaults; configs/settings.ini can change them
$dimMax = [ordered]@{ A = 25; B = 15; C = 15; D = 15; E = 10; F = 10; G = 10 }
$pts = @{ Critical = 10; Major = 5; Minor = 2; Nit = 1 }
$gradeMin = [ordered]@{ S = 95; A = 85; B = 70; C = 55 }
$merge = $false
# Reads the scoring settings of configs/settings.ini; keys that are not set keep their defaults.
$cfgErrors = New-Object System.Collections.Generic.List[string]
if (Test-UserFile $Config) {
    $sec = ''
    foreach ($l in (Read-Utf8Lines $Config)) {
        if ($l -match '^\s*[;#]' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*\[(.*)\]\s*$') { $sec = $Matches[1]; continue }
        if ($sec -cnotin 'points', 'deductions', 'grades' -or $l -notmatch '^([^=]*)=(.*)$') { continue }
        $k = $Matches[1].Trim(); $v = $Matches[2].Trim(); if ($v -match '^"(.*)"$') { $v = $Matches[1] }
        if ($sec -eq 'deductions' -and $k -ceq 'merge') {
            $v = $v.ToLowerInvariant()
            if ($v -cnotin 'true', 'false') { $cfgErrors.Add("  - [deductions] merge: `"$v`" is not true or false") }
            else { $merge = ($v -eq 'true') }
            continue
        }
        $target = switch -CaseSensitive ($sec) { 'points' { $dimMax } 'deductions' { $pts } 'grades' { $gradeMin } }
        $allowed = switch -CaseSensitive ($sec) { 'points' { 'A, B, C, D, E, F, G' } 'deductions' { 'Critical, Major, Minor, Nit, merge' } 'grades' { 'S, A, B, C' } }
        $what = switch -CaseSensitive ($sec) { 'points' { 'dimension' } 'deductions' { 'severity' } 'grades' { 'grade' } }
        if (-not (@($target.Keys) -ccontains $k)) { $cfgErrors.Add("  - [$sec] ${k}: unknown $what (allowed: $allowed)"); continue }
        if ($v -notmatch '^[0-9]+$') { $cfgErrors.Add("  - [$sec] ${k}: `"$v`" is not a whole number"); continue }
        $target[$k] = [int]$v
    }
}
# The [points] overrides of the standard in configs/standards.ini win over the settings.
foreach ($k in $override.Keys) { $dimMax[$k] = $override[$k] }
$sum = 0; foreach ($d in $dimMax.Keys) { $sum += $dimMax[$d] }
$ovNote = if ($override.Count -gt 0) { " (with the points overrides of [$($std[1])] in standards.ini)" } else { '' }
if ($sum -ne 100) { $cfgErrors.Add("  - [points] the seven dimensions must add up to 100, not $sum$ovNote") }
if ($gradeMin.S -gt 100) { $cfgErrors.Add('  - [grades] S must be at most 100') }
$g = @('S', 'A', 'B', 'C')
for ($i = 0; $i -lt 3; $i++) {
    if ($gradeMin[$g[$i]] -le $gradeMin[$g[$i + 1]]) { $cfgErrors.Add("  - [grades] $($g[$i]) ($($gradeMin[$g[$i]])) must be higher than $($g[$i + 1]) ($($gradeMin[$g[$i + 1]]))") }
}
if ($cfgErrors.Count -gt 0) {
    [Console]::Error.WriteLine("invalid scoring settings in ${Config}:")
    $cfgErrors | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 2
}

$rank = @{ Critical = 1; Major = 2; Minor = 3; Nit = 4 }
$uTypes = @{
    'spec-gap'         = @('missing', 'wrong', 'ambiguous')
    'third-party'      = @('spec-missing', 'spec-wrong', 'behavior-mismatch', 'not-delivered', 'bug')
    'ownership-change' = @('spec', 'interface', 'process')
}
$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$found = New-Object System.Collections.Generic.List[object]
$seen = @{}; $idSeen = @{}
$upstream = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]

function Add-Error([int]$Line, [string]$Message) { $script:errors.Add("  - line ${Line}: $Message") }

# Comment ids are <plugin>#<n>: the n-th C record of the plugin's cr.txt (prepare-diff lists them in prepared.txt).
$commentMode = [ordered]@{}; $hasCr = $false
if ($Root -and (Test-UserFile (Join-Path $Root 'step2/plan.tsv'))) {
    $hasCr = $true
    foreach ($l in (Read-Utf8Lines (Join-Path $Root 'step2/plan.tsv') | Where-Object { $_ })) {
        $p = $l -split "`t"; $crFile = Join-Path $Root "step2/$($p[0])/cr.txt"; $n = 0
        if (Test-UserFile $crFile) { foreach ($x in (Read-Utf8Lines $crFile)) { if ($x -match '^\s*C\s*\|') { $n++; $commentMode["$($p[0])#$n"] = $p[2] } } }
    }
}
$used = @{}; $rejected = New-Object System.Collections.Generic.List[object]; $rejectedIds = @{}
function Test-Comment([int]$Line, [string]$Id, [string]$What) {
    if ($Id -notmatch '^[^#]+#[0-9]+$') { Add-Error $Line "$What`"$Id`" is not a comment id <plugin>#<n> (listed in prepared.txt)"; return $false }
    if (-not $script:hasCr) { return $true }
    if (-not $script:commentMode.Contains($Id)) { Add-Error $Line "$What$Id is not a code review comment of step 2"; return $false }
    if ($script:commentMode[$Id] -cne 'mapped') { Add-Error $Line "$What$Id belongs to an advisory plugin; advisory comments are never deducted or rejected"; return $false }
    return $true
}

# Checks that the record just finished has the continuation fields it needs.
function Close-Record {
    if ($script:rec -eq 'F') {
        if (-not $script:fld.ContainsKey('problem')) { Add-Error $script:recLine "$($script:recId) is missing `"problem:`"" }
        if (-not $script:fld.ContainsKey('suggestion')) { Add-Error $script:recLine "$($script:recId) is missing `"suggestion:`"" }
    }
    elseif ($script:rec -eq 'U') {
        if (-not $script:fld.ContainsKey('content')) { Add-Error $script:recLine 'upstream record is missing "content:"' }
    }
    $script:rec = ''; $script:fld = @{}
}

$rec = ''; $fld = @{}; $recId = ''; $recLine = 0
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
        if ($rec -eq 'U' -and $key -cnotin 'content', 'code', 'ticket', 'source') { Add-Error $no "unknown field `"$key`" for U (allowed: content, code, ticket, source)"; continue }
        if (-not $val) { Add-Error $no "field `"$key`" is empty"; continue }
        # source: lists the code review comments a deduction confirms, separated by 、 or commas.
        if ($key -ceq 'source') { foreach ($e in ($val -split '、|,' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { if (Test-Comment $no $e 'source ') { $used[$e] = $true } } }
        $fld[$key] = $val
        continue
    }
    Close-Record
    $c = @($line -split '\|' | ForEach-Object { $_.Trim() })
    while ($c.Count -lt 6) { $c += '' }
    switch -CaseSensitive ($c[0]) {
        'F' {
            $id = $c[1]; $sev = $c[2]; $locs = $c[3]; $reason = $c[4]
            $rec = 'skip'; $recId = $id; $recLine = $no
            # Check id "-": no check of the checklist covers the problem; deducted from the total by its severity.
            $other = ($id -eq '-')
            if (-not $other -and -not $def.ContainsKey($id)) { Add-Error $no "unknown check id $id (use - when no check covers the problem)"; break }
            if ($sev -cnotin 'Critical', 'Major', 'Minor', 'Nit') { Add-Error $no "${id}: severity `"$sev`" is not Critical/Major/Minor/Nit"; break }
            if (-not $other -and $sev -ne $def[$id] -and $sev -ne 'Nit') {
                if ($adj[$id] -notcontains $sev) {
                    $adjText = if ($adj[$id].Count -gt 0) { ", the allowed adjustment $($adj[$id] -join ',')" } else { '' }
                    Add-Error $no "${id}: severity must be the default $($def[$id])$adjText or Nit, not $sev"; break
                }
                if (-not $reason) { Add-Error $no "${id}: non-default severity $sev needs the matching adjustment condition in column 5"; break }
            }
            if (-not $locs) { Add-Error $no "${id}: missing file:line location"; break }
            if ($locs -eq '-' -and -not $other) { Add-Error $no "${id}: location - (whole PR) is only allowed when the check id is -; give file:line"; break }
            # merge=true: one F record per check id with all its locations, deducted once.
            # merge=false: one F record per occurrence with one location, each deducted.
            # Records without a check id (-) are always deducted one by one.
            if ($merge -and -not $other -and $idSeen.ContainsKey($id)) { Add-Error $no "$id appears more than once. Deductions are merged (merge=true): put every location of a check id into one record"; break }
            if (-not $merge -and $locs.Contains(',')) { Add-Error $no "${id}: several locations in one record. Deductions are not merged (merge=false): write one F record per location"; break }
            $locList = New-Object System.Collections.Generic.List[string]
            foreach ($loc in @(if ($locs -ne '-') { $locs -split ',' | ForEach-Object { $_.Trim() } })) {
                if ($loc -notmatch '^(.+):(\d+)(-\d+)?$') { Add-Error $no "${id}: location `"$loc`" is not file:line"; continue }
                $fp = $Matches[1]; $ln = $Matches[2]
                if ($useIndex) {
                    if (-not $known.ContainsKey($fp)) { Add-Error $no "${id}: file `"$fp`" is not in the diff (use the full path from the diff, no ...)" }
                    elseif (-not $kind.ContainsKey("$fp|$ln")) { Add-Error $no "${id}: $loc is outside the diff hunks" }
                    elseif ($kind["$fp|$ln"] -ne '+') { $warnings.Add("  - ${id}: $loc is an unchanged context line; make sure the problem is in added or changed code") }
                }
                $locList.Add($loc)
            }
            $clean = if ($locs -eq '-') { '-' } else { $locList -join ',' }
            if (-not $merge -and -not $other -and $seen.ContainsKey("$id|$clean")) { Add-Error $no "$id at $clean is recorded twice; one problem at one location is deducted once"; break }
            $idSeen[$id] = $true; $seen["$id|$clean"] = $true
            $found.Add([pscustomobject]@{ Seq = $found.Count + 1; Id = $id; Severity = $sev; Locations = $locList; Clean = $clean })
            $rec = 'F'
        }
        'U' {
            $rec = 'skip'; $recLine = $no
            if (-not $uTypes.ContainsKey($c[1])) { Add-Error $no 'upstream type must be spec-gap, third-party or ownership-change'; break }
            if ($uTypes[$c[1]] -cnotcontains $c[2]) { Add-Error $no "upstream subtype for $($c[1]) must be one of: $($uTypes[$c[1]] -join ',')"; break }
            if ($c[1] -eq 'spec-gap' -and $c[3] -cnotin 'high', 'medium', 'low') { Add-Error $no 'spec-gap needs impact high, medium or low'; break }
            if ($c[1] -ne 'spec-gap' -and $c[3] -and $c[3] -ne '-') { Add-Error $no 'impact is only used for spec-gap; write - instead'; break }
            if ($c[4] -cnotin 'Critical', 'Major', 'Minor', 'Nit') { Add-Error $no "upstream severity `"$($c[4])`" is not Critical/Major/Minor/Nit"; break }
            if (-not $c[5]) { Add-Error $no 'upstream record needs a reference (spec section/version, change-log date or vendor ticket); without one, do not list it'; break }
            $upstream.Add([pscustomobject]@{ Type = $c[1]; Subtype = $c[2]; Impact = $c[3]; Severity = $c[4]; Reference = $c[5] })
            $rec = 'U'
        }
        # X|<plugin>#<n>|reason: a code review comment that step 3 found not to be a real problem in this PR.
        'X' {
            if (-not $c[1] -or -not $c[2]) { Add-Error $no 'format is X|<plugin>#<n>|reason'; break }
            if (-not (Test-Comment $no $c[1] 'rejected comment ')) { break }
            if ($rejectedIds.ContainsKey($c[1])) { Add-Error $no "comment $($c[1]) is rejected twice"; break }
            $rejectedIds[$c[1]] = $true; $rejected.Add([pscustomobject]@{ Comment = $c[1]; Reason = $c[2] })
        }
        'S' {
            if (-not $c[1] -or -not $c[2]) { Add-Error $no 'format is S|check-id|reason'; break }
            $skipped.Add([pscustomobject]@{ Id = $c[1]; Reason = $c[2] })
        }
        { $_ -cin 'H', 'N', 'I', 'R' } {
            if (-not $c[1]) { Add-Error $no "$($c[0]) record has no text" }
        }
        default { Add-Error $no "unknown record type `"$($c[0])`" (allowed: F, U, X, S, H, N, I, R)" }
    }
}
Close-Record
# Every comment of a mapped plugin is either deducted (source: of an F or U record) or rejected (X).
foreach ($e in $commentMode.Keys) {
    if ($commentMode[$e] -cne 'mapped') { continue }
    if ($used.ContainsKey($e) -and $rejectedIds.ContainsKey($e)) { $errors.Add("  - comment $e is both deducted (source:) and rejected (X)") }
    elseif (-not $used.ContainsKey($e) -and -not $rejectedIds.ContainsKey($e)) { $errors.Add("  - comment $e is neither deducted (an F or U record with source: $e) nor rejected (X|$e|reason)") }
}

$tsvPath = Join-Path $OutDir 'score.tsv'; $jsonPath = Join-Path $OutDir 'score.json'
if (-not $Check) { foreach ($old in $tsvPath, $jsonPath) { if (Test-UserFile $old) { [IO.File]::Delete((Resolve-UserPath $old)) } } }

if ($errors.Count -gt 0) {
    [Console]::Error.WriteLine("validation failed with $($errors.Count) error(s). Fix findings.txt and run again:")
    $errors | ForEach-Object { [Console]::Error.WriteLine($_) }
    if ($warnings.Count -gt 0) { [Console]::Error.WriteLine('warnings:'); $warnings | ForEach-Object { [Console]::Error.WriteLine($_) } }
    exit 1
}
if ($Check) {
    [Console]::Out.Write("findings.txt is valid ($($found.Count) deductions, $($upstream.Count) upstream, $($rejected.Count) rejected comments)`n")
    if ($warnings.Count -gt 0) { [Console]::Error.WriteLine('warnings:'); $warnings | ForEach-Object { [Console]::Error.WriteLine($_) } }
    exit 0
}

function ConvertTo-JsonString([string]$s) {
    return '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace "`t", '\t') + '"'
}
# Dimension of a check id: its first letter, or the letter after CM- for the common standard.
function Get-Dimension([string]$Id) {
    if ($Id.StartsWith('CM-', [StringComparison]::Ordinal)) { return $Id.Substring(3, 1) }
    return $Id.Substring(0, 1)
}
function Join-JsonArray($items) {
    if ($items.Count -eq 0) { return '[]' }
    return "[`n" + ($items -join ",`n") + "`n  ]"
}

# Sorted by severity, then check id with records without one (-) last; occurrences of one id keep their order in findings.txt
$sorted = @($found | Sort-Object @{ Expression = { $rank[$_.Severity] } }, @{ Expression = { [int]($_.Id -eq '-') } }, @{ Expression = { $_.Id } }, @{ Expression = { $_.Seq } })
$scores = [ordered]@{}; $total = 0
foreach ($d in $dimMax.Keys) {
    $ded = 0
    foreach ($x in $sorted) { if ((Get-Dimension $x.Id) -ceq $d) { $ded += $pts[$x.Severity] } }
    $scores[$d] = [Math]::Max(0, $dimMax[$d] - $ded)
    $total += $scores[$d]
}
# Records without a check id and upstream factors are deducted from the total.
$othDed = 0; foreach ($x in $sorted) { if ($x.Id -eq '-') { $othDed += $pts[$x.Severity] } }
$upDed = 0; foreach ($u in $upstream) { $upDed += $pts[$u.Severity] }
$crit = (@($found | Where-Object { $_.Severity -eq 'Critical' }).Count + @($upstream | Where-Object { $_.Severity -eq 'Critical' }).Count) -gt 0
$total = [Math]::Max(0, $total - $othDed - $upDed)
$grade = if ($total -ge $gradeMin.S) { 'S' } elseif ($total -ge $gradeMin.A) { 'A' } elseif ($total -ge $gradeMin.B) { 'B' } elseif ($total -ge $gradeMin.C) { 'C' } else { 'D' }
$capped = $false
if ($crit -and $grade -in 'S', 'A') { $grade = 'B'; $capped = $true }

$tsv = New-Object System.Text.StringBuilder
[void]$tsv.Append("total`t$total`ngrade`t$grade`ncapped`t$([int]$capped)`ncritical`t$([int]$crit)`n")
[void]$tsv.Append("standard`t$($std[1])`t$($std[2])`t$($std[3])`n")
if ($common) { [void]$tsv.Append("common`t$($common[1])`t$($common[2])`t$($common[3])`n") }
foreach ($d in $dimMax.Keys) { [void]$tsv.Append("dim`t$d`t$($scores[$d])`t$($dimMax[$d])`n") }
foreach ($x in $sorted) { [void]$tsv.Append("finding`t$($x.Id)`t$($x.Severity)`t$($pts[$x.Severity])`t$($x.Clean)`t$($x.Seq)`n") }
$i = 0; foreach ($u in $upstream) { $i++; [void]$tsv.Append("upstream`t$i`t$($u.Severity)`t$($pts[$u.Severity])`n") }
Write-Utf8File $tsvPath $tsv.ToString()

$q = '"'
$dimJson = @($dimMax.Keys | ForEach-Object { $q + $_ + $q + ': ' + $scores[$_] }) -join ', '
$fj = @($sorted | ForEach-Object {
        $locJson = @($_.Locations | ForEach-Object { ConvertTo-JsonString $_ }) -join ', '
        $idJson = if ($_.Id -eq '-') { 'null' } else { ConvertTo-JsonString $_.Id }
        '    { "id": ' + $idJson + ', "severity": ' + (ConvertTo-JsonString $_.Severity) +
        ', "deduction": ' + $pts[$_.Severity] + ', "locations": [' + $locJson + '] }'
    })
$uj = @($upstream | ForEach-Object {
        $imp = if (-not $_.Impact -or $_.Impact -eq '-') { 'null' } else { ConvertTo-JsonString $_.Impact }
        '    { "type": ' + (ConvertTo-JsonString $_.Type) + ', "subtype": ' + (ConvertTo-JsonString $_.Subtype) +
        ', "impact": ' + $imp + ', "severity": ' + (ConvertTo-JsonString $_.Severity) + ', "deduction": ' + $pts[$_.Severity] +
        ', "reference": ' + (ConvertTo-JsonString $_.Reference) + ' }'
    })
$xj = @($rejected | ForEach-Object { '    { "comment": ' + (ConvertTo-JsonString $_.Comment) + ', "reason": ' + (ConvertTo-JsonString $_.Reason) + ' }' })
$sj = @($skipped | ForEach-Object { '    { "id": ' + (ConvertTo-JsonString $_.Id) + ', "reason": ' + (ConvertTo-JsonString $_.Reason) + ' }' })
$stdJson = { param($r) '{ "name": ' + (ConvertTo-JsonString $r[1]) + ', "version": ' + (ConvertTo-JsonString $r[2]) + ', "hash": ' + (ConvertTo-JsonString $r[3]) + ' }' }
$commonJson = if ($common) { & $stdJson $common } else { 'null' }
$json = "{`n" +
'  "total": ' + $total + ",`n" +
'  "grade": "' + $grade + '"' + ",`n" +
'  "hasCritical": ' + $crit.ToString().ToLower() + ",`n" +
'  "standard": ' + (& $stdJson $std) + ",`n" +
'  "common": ' + $commonJson + ",`n" +
'  "dimensions": { ' + $dimJson + " },`n" +
'  "otherDeduction": ' + $othDed + ",`n" +
'  "upstreamDeduction": ' + $upDed + ",`n" +
'  "findings": ' + (Join-JsonArray $fj) + ",`n" +
'  "upstream": ' + (Join-JsonArray $uj) + ",`n" +
'  "rejectedComments": ' + (Join-JsonArray $xj) + ",`n" +
'  "skippedChecks": ' + (Join-JsonArray $sj) + "`n}`n"
Write-Utf8File $jsonPath $json

$capNote = if ($capped) { ' (capped at B because of a Critical finding)' } else { '' }
$summary = "grade $grade, total $total/100$capNote`n" +
(@($dimMax.Keys | ForEach-Object { "$_ $($scores[$_])/$($dimMax[$_])  " }) -join '') + "`n" +
"deductions: $($found.Count) (without a check id: $(@($found | Where-Object { $_.Id -eq '-' }).Count)), upstream: $($upstream.Count), rejected comments: $($rejected.Count), skipped checks: $($skipped.Count)`n" +
"standard: $($std[1]) $($std[2])$(if ($common) { ", common: $($common[1]) $($common[2])" })`n"
[Console]::Out.Write($summary)
if ($warnings.Count -gt 0) { [Console]::Error.WriteLine('warnings:'); $warnings | ForEach-Object { [Console]::Error.WriteLine($_) } }
Write-Output "wrote $tsvPath and $jsonPath"
