<#
.SYNOPSIS
Render the PR score report from the review root (tmp/stepN files) and the report template.

.DESCRIPTION
Reads ROOT/step1/spec-context.md, ROOT/step3/findings.txt, ROOT/step4/score.tsv, ROOT/step4/score.json and the
code review results in ROOT/step2/, fills the template placeholders and writes ROOT/step5/report.md (working copy).
ROOT defaults to tmp. Without ROOT/step2/plan.tsv the code review section says that no code review was run.
The final report is published as REPORTS/<YYYY-MM-DD>_<PR title>.md (REPORTS defaults to reports; the same
name is overwritten when the same PR is rendered again on the same day) and its path is recorded in
ROOT/step5/report-path.txt. Use -NoPublish to write only the working copy; -Out - prints to stdout only.
Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 1 inputs missing or inconsistent (rerun the scoring skill), 2 bad arguments.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File render-report.ps1 -Root tmp
#>
[CmdletBinding()]
param(
    [string]$Root = 'tmp',
    [Alias('t')][string]$Template,
    [Alias('l')][string]$Labels,
    [string]$Title,
    [Alias('o')][string]$Out,
    [string]$Reports = 'reports',
    [switch]$NoPublish
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$skillDir = Split-Path -Parent $PSScriptRoot
if (-not $Template) { $Template = Join-Path $skillDir 'assets/report-template.md' }
if (-not $Labels) { $Labels = Join-Path $skillDir 'assets/labels.tsv' }
$findingsPath = Join-Path $Root 'step3/findings.txt'
foreach ($f in $findingsPath, $Template, $Labels) { if (-not (Test-UserFile $f)) { Exit-WithError "file not found: $f" } }
foreach ($name in 'score.tsv', 'score.json') {
    $p = Join-Path $Root "step4/$name"
    if (-not (Test-UserFile $p)) { Exit-WithError "$p not found; run the scoring skill first" 1 }
    if ((Get-Item -LiteralPath (Resolve-UserPath $findingsPath)).LastWriteTimeUtc -gt (Get-Item -LiteralPath (Resolve-UserPath $p)).LastWriteTimeUtc) {
        Exit-WithError "findings.txt changed after $name was written; rerun the scoring skill" 1
    }
}
if (-not $Out) {
    [void][IO.Directory]::CreateDirectory((Resolve-UserPath (Join-Path $Root 'step5')))
    $Out = Join-Path $Root 'step5/report.md'
}
$planFile = Join-Path $Root 'step2/plan.tsv'
if (Test-UserFile $planFile) {
    foreach ($l in (Read-Utf8Lines $planFile | Where-Object { $_ })) {
        $crFile = Join-Path $Root "step2/$(($l -split "`t")[0])/cr.txt"
        if (-not (Test-UserFile $crFile)) { Exit-WithError "$crFile not found; the code review step has not finished" 1 }
    }
}

$lab = @{}
foreach ($l in (Read-Utf8Lines $Labels)) {
    if ($l.StartsWith('#') -or $l -notmatch "`t") { continue }
    $i = $l.IndexOf("`t"); $lab[$l.Substring(0, $i)] = $l.Substring($i + 1)
}
function L([string]$Key) { if ($script:lab.ContainsKey($Key)) { return $script:lab[$Key] } return $Key }
function Format-Codes([string]$Locs) { return (@($Locs -split ',' | ForEach-Object { '`' + $_.Trim() + '`' }) -join (L 'sep.list')) }

# findings.txt (already validated by the scoring skill)
$fv = @{}; $fSev = @{}; $fLoc = @{}; $nits = @(); $deductIds = @{}
$ups = New-Object System.Collections.Generic.List[object]
$lists = @{ S = @(); H = @(); N = @(); I = @(); R = @() }
$cur = ''
foreach ($raw in (Read-Utf8Lines $findingsPath)) {
    $line = $raw.TrimEnd("`r")
    if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
    if ($line -cmatch '^\s*([a-z]+):\s*(.*)$' -and $line -cnotmatch '^[A-Z]\|') {
        if ($cur) { $fv["$cur|$($Matches[1])"] = $Matches[2].Trim() }
        continue
    }
    $a = @($line -split '\|' | ForEach-Object { $_.Trim() }); while ($a.Count -lt 5) { $a += '' }
    $cur = ''
    switch -CaseSensitive ($a[0]) {
        'F' {
            $cur = "F:$($a[1])"; $fSev[$a[1]] = $a[2]; $fLoc[$a[1]] = $a[3]
            if ($a[2] -eq 'Nit') { $nits += $a[1] } else { $deductIds[$a[1]] = $true }
        }
        'U' { $ups.Add([pscustomobject]@{ Type = $a[1]; Sub = $a[2]; Impact = $a[3]; Ref = $a[4] }); $cur = "U:$($ups.Count)" }
        'S' { $lists['S'] += ($a[1] + (L 'sep.colon') + $a[2]) }
        { $_ -cin 'H', 'N', 'I', 'R' } { $lists[$a[0]] += $a[1] }
    }
}

# score.tsv / score.json
$total = ''; $grade = ''; $capped = '0'
$dims = New-Object System.Collections.Generic.List[object]
$scored = New-Object System.Collections.Generic.List[object]
foreach ($l in (Read-Utf8Lines (Join-Path $Root 'step4/score.tsv'))) {
    $a = $l -split "`t"
    switch ($a[0]) {
        'total' { $total = $a[1] }
        'grade' { $grade = $a[1] }
        'capped' { $capped = $a[1] }
        'dim' { $dims.Add([pscustomobject]@{ Code = $a[1]; Score = $a[2]; Max = $a[3] }) }
        'finding' { $scored.Add([pscustomobject]@{ Id = $a[1]; Sev = $a[2]; Pts = $a[3]; Locs = $a[4] }) }
    }
}
if ($dims.Count -ne 7 -or -not $grade) { Exit-WithError 'score.tsv is missing or incomplete; run the scoring skill first' 1 }
$scoredIds = @{}; foreach ($s in $scored) { $scoredIds[$s.Id] = $true }
foreach ($id in $deductIds.Keys) { if (-not $scoredIds.ContainsKey($id)) { Exit-WithError "finding $id is in findings.txt but not in score.tsv; rerun the scoring skill" 1 } }
foreach ($id in $scoredIds.Keys) { if (-not $deductIds.ContainsKey($id)) { Exit-WithError "finding $id is in score.tsv but not in findings.txt; rerun the scoring skill" 1 } }
$json = (Read-Utf8Text (Join-Path $Root 'step4/score.json')).TrimEnd("`r", "`n")
if (-not $json) { Exit-WithError 'score.json is missing or empty; run the scoring skill first' 1 }

if (-not $Title) {
    $ctx = Join-Path $Root 'step1/spec-context.md'
    if (Test-UserFile $ctx) {
        $t = Read-Utf8Lines $ctx | Where-Object { $_ -match '^- Title:' } | Select-Object -First 1
        if ($t) { $Title = ($t -replace '^- Title:\s*', '').Trim() }
    }
}
$rawTitle = $Title
if (-not $Title) { $Title = L 'title.missing' }

# Block placeholders
$b = L 'sep.bracket'; $c = L 'sep.colon'
$blk = @{}
$sb = New-Object System.Text.StringBuilder
foreach ($d in $dims) {
    $items = @($scored | Where-Object { $_.Id.StartsWith($d.Code) } | ForEach-Object { "$($_.Id) $($_.Sev) -$($_.Pts)" }) -join (L 'sep.list')
    if (-not $items) { $items = L 'none' }
    [void]$sb.Append("| $($d.Code) $(L "dim.$($d.Code)") | $($d.Score)/$($d.Max) | $items |`n")
}
$blk['SCORE_ROWS'] = $sb.ToString()

$sb = New-Object System.Text.StringBuilder; $i = 0
foreach ($s in $scored) {
    $i++
    [void]$sb.Append("$i. **[$($s.Id)$b$($s.Sev)$b-$($s.Pts)]** $(Format-Codes $s.Locs)`n")
    [void]$sb.Append("   - $(L 'field.problem')$c$($fv["F:$($s.Id)|problem"])`n")
    [void]$sb.Append("   - $(L 'field.suggestion')$c$($fv["F:$($s.Id)|suggestion"])`n")
    if ($fv.ContainsKey("F:$($s.Id)|assumption")) { [void]$sb.Append("   - $(L 'field.assumption')$c$($fv["F:$($s.Id)|assumption"])`n") }
    if ($fv.ContainsKey("F:$($s.Id)|source")) { [void]$sb.Append("   - $(L 'field.source')$c$($fv["F:$($s.Id)|source"])`n") }
}
$blk['FINDINGS'] = $sb.ToString()

$sb = New-Object System.Text.StringBuilder
foreach ($id in $nits) {
    [void]$sb.Append("- [$id] $(Format-Codes $fLoc[$id])$c$($fv["F:$id|problem"])")
    if ($fv.ContainsKey("F:$id|suggestion")) { [void]$sb.Append((L 'paren.open') + (L 'field.suggestion') + $c + $fv["F:$id|suggestion"] + (L 'paren.close')) }
    [void]$sb.Append("`n")
}
foreach ($x in $lists['N']) { [void]$sb.Append("- $x`n") }
$blk['SUGGESTIONS'] = $sb.ToString()

$sb = New-Object System.Text.StringBuilder; $i = 0
foreach ($u in $ups) {
    $i++
    $tag = (L "upstream.$($u.Type)") + $b + (L "sub.$($u.Sub)")
    if ($u.Impact -and $u.Impact -ne '-') { $tag += $b + (L "impact.$($u.Impact)") }
    [void]$sb.Append("$i. **[$tag]** $($u.Ref)`n")
    [void]$sb.Append("   - $(L 'field.content')$c$($fv["U:$i|content"])`n")
    if ($fv.ContainsKey("U:$i|code")) { [void]$sb.Append("   - $(L 'field.code')$c$(Format-Codes $fv["U:$i|code"])`n") }
    if ($fv.ContainsKey("U:$i|ticket")) { [void]$sb.Append("   - $(L 'field.ticket')$c$($fv["U:$i|ticket"])`n") }
}
$blk['UPSTREAM'] = $sb.ToString()
foreach ($pair in @(@('HIGHLIGHTS', 'H'), @('SKIPPED', 'S'), @('IGNORED', 'I'), @('REMARKS', 'R'))) {
    $blk[$pair[0]] = (@($lists[$pair[1]] | ForEach-Object { "- $_`n" }) -join '')
}
$blk['SCORE_JSON'] = "$json`n"

# Code review results (ROOT/step2): plan, skipped plugins and every plugin's normalized cr.txt
$sevOrder = @('Critical', 'Major', 'Minor', 'Nit')
$crDir = Join-Path $Root 'step2'
$crTotals = @{ Critical = 0; Major = 0; Minor = 0; Nit = 0 }
if (-not (Test-UserFile (Join-Path $crDir 'plan.tsv'))) {
    $blk['CR_OVERVIEW'] = (L 'cr.not_run') + "`n"; $blk['CR_DETAILS'] = ''; $blk['CR_SKIPPED'] = ''; $crTotalsText = L 'cr.not_run'
}
else {
    $plugins = @(Read-Utf8Lines (Join-Path $crDir 'plan.tsv') | Where-Object { $_ } | ForEach-Object { $f = $_ -split "`t"; [pscustomobject]@{ Name = $f[0]; Files = $f[3] } })
    $results = @()
    foreach ($pl in $plugins) {
        $crFile = Join-Path $crDir "$($pl.Name)/cr.txt"
        $r = [pscustomobject]@{ Plugin = $pl; Ok = (Test-UserFile $crFile); Summary = ''; Comments = New-Object System.Collections.Generic.List[object]; Highlights = @(); Count = @{ Critical = 0; Major = 0; Minor = 0; Nit = 0 } }
        if ($r.Ok) {
            $curC = $null
            foreach ($raw in (Read-Utf8Lines $crFile)) {
                $line = $raw.TrimEnd("`r")
                if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
                if ($line -cmatch '^\s*([a-z]+):\s*(.*)$' -and $line -cnotmatch '^[A-Z]\|') { if ($curC) { $curC.Fields[$Matches[1]] = $Matches[2].Trim() }; continue }
                $a = @($line -split '\|' | ForEach-Object { $_.Trim() }); while ($a.Count -lt 4) { $a += '' }
                $curC = $null
                switch -CaseSensitive ($a[0]) {
                    'S' { $r.Summary = (@($r.Summary, $a[1]) | Where-Object { $_ }) -join ' ' }
                    'H' { $r.Highlights += $a[1] }
                    'C' {
                        $curC = [pscustomobject]@{ Sev = $a[1]; Locs = $a[2]; Rule = $a[3]; Fields = @{}; Index = $r.Comments.Count }
                        $r.Comments.Add($curC); $r.Count[$a[1]]++; $crTotals[$a[1]]++
                    }
                }
            }
        }
        $results += $r
    }
    $crTotalsText = if ($plugins.Count -eq 0) { L 'cr.no_plugins' } else { (@($sevOrder | ForEach-Object { "$_ $($crTotals[$_])" }) -join (L 'sep.list')) }
    if ($plugins.Count -eq 0) { $blk['CR_OVERVIEW'] = (L 'cr.no_plugins') + "`n"; $blk['CR_DETAILS'] = '' }
    else {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("| $(L 'cr.col.plugin') | $(L 'cr.col.files') | Critical | Major | Minor | Nit | $(L 'cr.col.summary') |`n| --- | --- | --- | --- | --- | --- | --- |`n")
        foreach ($r in $results) {
            $summary = if ($r.Ok) { $r.Summary } else { L 'cr.missing' }
            [void]$sb.Append("| $($r.Plugin.Name) | $($r.Plugin.Files) | $($r.Count.Critical) | $($r.Count.Major) | $($r.Count.Minor) | $($r.Count.Nit) | $summary |`n")
        }
        $blk['CR_OVERVIEW'] = $sb.ToString()
        $sb = New-Object System.Text.StringBuilder
        $first = $true
        foreach ($r in $results) {
            if (-not $first) { [void]$sb.Append("`n") }; $first = $false
            [void]$sb.Append("### $($r.Plugin.Name)`n`n")
            if (-not $r.Ok) { [void]$sb.Append((L 'cr.missing') + "`n"); continue }
            [void]$sb.Append("**$(L 'cr.summary')**$c$($r.Summary)`n`n")
            # comments sorted by severity, keeping the plugin's order within a severity
            $sorted = @($r.Comments | Sort-Object @{ Expression = { [array]::IndexOf($sevOrder, $_.Sev) } }, @{ Expression = { $_.Index } })
            if ($sorted.Count -eq 0) { [void]$sb.Append((L 'cr.no_comments') + "`n") }
            $j = 0
            foreach ($cm in $sorted) {
                $j++
                $tag = $cm.Sev; if ($cm.Rule -and $cm.Rule -ne '-') { $tag += $b + $cm.Rule }
                $locText = if ($cm.Locs -and $cm.Locs -ne '-') { ' ' + (Format-Codes $cm.Locs) } else { '' }
                [void]$sb.Append("$j. **[$tag]**$locText`n")
                [void]$sb.Append("   - $(L 'field.problem')$c$($cm.Fields['problem'])`n")
                if ($cm.Fields.ContainsKey('suggestion')) { [void]$sb.Append("   - $(L 'field.suggestion')$c$($cm.Fields['suggestion'])`n") }
            }
            if ($r.Highlights.Count -gt 0) {
                [void]$sb.Append("`n**$(L 'cr.highlights')**`n`n")
                foreach ($h in $r.Highlights) { [void]$sb.Append("- $h`n") }
            }
        }
        $blk['CR_DETAILS'] = $sb.ToString()
    }
    $sb = New-Object System.Text.StringBuilder
    if (Test-UserFile (Join-Path $crDir 'skipped.tsv')) {
        foreach ($l in (Read-Utf8Lines (Join-Path $crDir 'skipped.tsv') | Where-Object { $_ })) {
            $f = $l -split "`t"; $applies = if ($f.Count -gt 1 -and $f[1]) { $f[1] } else { L 'cr.all_files' }
            [void]$sb.Append("- $($f[0])$c$((L 'cr.skipped').Replace('{applies}', $applies))`n")
        }
    }
    $blk['CR_SKIPPED'] = $sb.ToString()
}

$inl = [ordered]@{ PR_TITLE = $Title; REVIEW_DATE = (Get-Date -Format 'yyyy-MM-dd'); GRADE = $grade; TOTAL = $total
    CAPPED_NOTE = $(if ($capped -eq '1') { L 'capped_note' } else { '' }); CR_TOTALS = $crTotalsText }

$outSb = New-Object System.Text.StringBuilder
$unknown = @{}
$tplLines = (Read-Utf8Text $Template) -split "`n"
if ($tplLines.Count -gt 0 -and $tplLines[-1] -eq '') { $tplLines = $tplLines[0..($tplLines.Count - 2)] }
foreach ($raw in $tplLines) {
    $line = $raw.TrimEnd("`r")
    if ($line -match '^\s*\{\{([A-Z_]+)\}\}\s*$' -and $blk.ContainsKey($Matches[1])) {
        $v = $blk[$Matches[1]]
        if (-not $v -and $Matches[1] -notin 'SCORE_ROWS', 'CR_DETAILS') { $v = (L 'none') + "`n" }
        [void]$outSb.Append($v)
        continue
    }
    foreach ($k in $inl.Keys) { $line = $line.Replace("{{$k}}", [string]$inl[$k]) }
    if ($line -match '\{\{[A-Z_]+\}\}') { $unknown[$Matches[0]] = $true }
    [void]$outSb.Append("$line`n")
}
foreach ($u in $unknown.Keys) { [Console]::Error.WriteLine("warning: unknown placeholder $u left as is (block placeholders must be alone on their line)") }

if ($Out -eq '-') { [Console]::Out.Write($outSb.ToString()); exit 0 }
Write-Utf8File $Out $outSb.ToString()
Write-Output "wrote $Out"
if ($NoPublish) { exit 0 }

# Publish the final report: REPORTS/<date>_<title>.md, with characters that are unsafe in file names replaced.
$name = ($rawTitle -replace '[\[\]\\/:*?"<>|#%{}\s\p{Cc}]+', '-').Trim('-', '.')
if (-not $name) { $name = 'pr-review' }
$reportsAbs = Resolve-UserPath $Reports
[void][IO.Directory]::CreateDirectory($reportsAbs)
$final = Join-Path $reportsAbs ("$(Get-Date -Format 'yyyy-MM-dd')_$name.md")
Write-Utf8File $final $outSb.ToString()
if ((Resolve-UserPath $Out) -eq (Resolve-UserPath (Join-Path $Root 'step5/report.md'))) {
    Write-Utf8File (Join-Path $Root 'step5/report-path.txt') "$final`n"
}
Write-Output "published $final"
