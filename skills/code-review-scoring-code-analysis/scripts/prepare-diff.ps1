<#
.SYNOPSIS
Preprocess a PR diff: drop non-reviewable files, number new-file lines, list heuristic candidates.

.DESCRIPTION
Prints a summary, the code review comments of ROOT/step2 with their ids (with -Root only), heuristic candidates
(clues only) and a compact diff with new-file line numbers.
The summary shows merge and the severity scale of the standard, which decide how findings.txt is written. With -Root, reads ROOT/step1/pr.diff and writes ROOT/step3/prepared.txt unless -Out is given; without -Root,
-InputPath and -Git, ROOT is tmp in the project root. -InputPath - reads the diff from stdin.
With the review plan ROOT/step1/standards/plan.tsv, -Root reads the diff of the standard -Standard (default: the only
one; ROOT/step1/standards/NAME.diff), lists only its code review comments and writes ROOT/step3/NAME/prepared.txt.
The scan rules, severity scale and merge come from -Standard (an enabled rule of the rules project that [rules] root
of -Config names; -Config defaults to configs/settings.ini in the project root; default standard: the only enabled
framework rule, or the common rule when no framework rule is enabled); files its applies does not cover are scanned
with the rules of the common rule. -Scan FILE uses one scan rule file for every file instead (no severity scale).
Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 2 bad arguments or input, or a missing or invalid standard or scan rule file (run standard lint).

.EXAMPLE
powershell -ExecutionPolicy Bypass -File prepare-diff.ps1
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
    [Alias('o')][string]$Out,
    [string]$Config,
    [string]$Standard,
    [string]$Standards,
    [string]$Scan
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$sources = @($Root, $InputPath, $Git | Where-Object { $_ }).Count
if ($sources -gt 1) { Exit-WithError 'use only one of -Root, -InputPath, -Git' }
$projectRoot = Get-ProjectRoot (Split-Path -Parent $PSScriptRoot)
if ($sources -eq 0) { $Root = Join-Path $projectRoot 'tmp' }
if (-not $Config) { $Config = Join-Path $projectRoot 'configs/settings.ini' }
if ($Standards) { Exit-WithError '-Standards was removed: the rules come from [rules] root of the settings (-Config)' }
$cplan = ''; $cstd = ''
if ($Root) {
    $InputPath = Join-Path $Root 'step1/pr.diff'; $sub = ''
    # With a review plan (step 1 of the workflow), each standard has its own diff and step folders.
    $cstd = Get-PlanStandard $Root $Standard
    if ($cstd) { $Standard = $cstd; $cplan = Join-Path $Root 'step1/standards/plan.tsv'; $InputPath = Join-Path $Root "step1/standards/$cstd.diff"; $sub = "/$cstd" }
    if (-not $Out) {
        [void][IO.Directory]::CreateDirectory((Resolve-UserPath (Join-Path $Root "step3$sub")))
        $Out = Join-Path $Root "step3$sub/prepared.txt"
    }
}
$diffText = Get-DiffText -InputPath $InputPath -Git $Git -Repo $Repo

# Scan rules, file scopes, severity scale and merge of the standard (code-review-scoring/scripts/standard.ps1 resolve, run with the same
# PowerShell; it prints its own errors). Owner 's' = the standard, 'c' = the common standard.
if ($Scan) {
    if ($Standard) { Exit-WithError 'use only one of -Standard, -Scan' }
    if (-not (Test-UserFile $Scan)) { Exit-WithError "scan rule file not found: $Scan" }
    $resolved = @("scan`t$(Resolve-UserPath $Scan)")
}
elseif ($cstd) {
    # The standard as step 1 planned it (the workflow refuses to go on when it has changed since).
    $resolved = @(Read-Utf8Lines (Join-Path $Root "step1/standards/$cstd.resolve") | Where-Object { $_ })
}
else {
    $resolveArgs = @('resolve', '--settings', $Config)
    if ($Standard) { $resolveArgs += $Standard }
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $resolved = @(& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'skills/code-review-scoring/scripts/standard.ps1') @resolveArgs) }
    finally { $ErrorActionPreference = $prevPref }
    if ($LASTEXITCODE -ne 0) { exit 2 }
}
$rules = New-Object System.Collections.Generic.List[object]
$idOrder = New-Object System.Collections.Generic.List[string]
$scopes = @{ s = (New-Object System.Collections.Generic.List[object]); c = (New-Object System.Collections.Generic.List[object]) }
$hints = New-Object System.Collections.Generic.List[object]
$stdName = ''; $stdVer = ''; $commonName = ''; $commonVer = ''; $applies = $null; $owner = 's'; $merge = 'false'
$sevs = New-Object System.Collections.Generic.List[object]; $csevs = New-Object System.Collections.Generic.List[object]
foreach ($rl in $resolved) {
    $a = ([string]$rl).Split("`t")
    switch -CaseSensitive ($a[0]) {
        'merge' { $merge = $a[1] }
        'severity' { $sevs.Add([pscustomobject]@{ Code = $a[1]; Points = $a[2]; Cap = $a[3]; Name = $a[4]; Meaning = $a[5] }) }
        'cseverity' { $csevs.Add([pscustomobject]@{ Code = $a[1]; Name = $a[2]; Meaning = $a[3] }) }
        'standard' { $owner = 's'; $stdName = $a[1]; $stdVer = $a[2] }
        'common' { $owner = 'c'; $commonName = $a[1]; $commonVer = $a[2] }
        'applies' { $applies = [regex]::new($a[1]) }
        'scan' {
            $file = $a[1]; $ln = 0
            if (-not (Test-UserFile $file)) { Exit-WithError "cannot read scan rules $file" }
            foreach ($l in (Read-Utf8Lines $file)) {
                $ln++
                if ($l -cmatch '^#' -or $l -cmatch '^[ \t]*$') { continue }
                $f = $l.Split("`t")
                if ($f[0] -ceq '@scope' -and $f.Count -eq 4) {
                    $scopes[$owner].Add([pscustomobject]@{ Name = $f[1]; Within = $f[2]; Re = [regex]::new($f[3]) })
                }
                elseif ($f[0] -ceq '@pr' -and $f.Count -eq 4) { $hints.Add([pscustomobject]@{ Id = $f[1]; Owner = $owner; Cond = $f[2]; Hint = $f[3] }) }
                elseif (-not $f[0].StartsWith('@') -and $f.Count -eq 7) {
                    $opt = [Text.RegularExpressions.RegexOptions]::None
                    if ($f[2].Contains('i')) { $opt = [Text.RegularExpressions.RegexOptions]::IgnoreCase }
                    $rules.Add([pscustomobject]@{
                        Id = $f[0]; Owner = $owner; Scope = $f[1]; Comments = $f[2].Contains('c')
                        Re = [regex]::new($f[3], $opt)
                        Prev = $(if ($f[4] -cne '-') { [regex]::new($f[4], $opt) } else { $null })
                        Excl = $(if ($f[5] -cne '-') { [regex]::new($f[5], $opt) } else { $null })
                        Hint = $f[6]
                    })
                    if (-not $idOrder.Contains($f[0])) { $idOrder.Add($f[0]) }
                }
                else { Exit-WithError "${file}:${ln}: not a valid scan rule line; run standard lint first" }
            }
        }
    }
}

function Test-Comment([string]$s, [string]$path) {
    $t = $s.Trim()
    if ($path -cmatch '\.(md|markdown)$') { return $t.StartsWith('<!--') }
    if ($t -cmatch '^(//|/\*|\*)') { return $true }
    if ($t.StartsWith('#') -and ($path -cmatch '\.(ya?ml|properties|sh|bash|zsh|ps1|psm1|py|rb|toml|ini|conf|cfg|env|tf)$' -or $path -cmatch '(^|/)(Dockerfile[^/]*|Makefile|\.gitignore|\.dockerignore|\.gitattributes|\.editorconfig|\.env[^/]*)$')) { return $true }
    if ($path -cmatch '\.ini$' -and $t.StartsWith(';')) { return $true }
    if ($path -cmatch '\.sql$' -and $t.StartsWith('--')) { return $true }
    if ($path -cmatch '\.(xml|html?|vue)$' -and $t.StartsWith('<!--')) { return $true }
    return $false
}

# A file is in a scope of its owner when its path matches and the within condition holds.
function Test-Scope([string]$owner, [string]$scope, $f) {
    if ($scope -ceq 'any') { return $f.Owner -ceq $owner }
    return $f.Scopes.ContainsKey("$owner`t$scope")
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
        View = New-Object System.Text.StringBuilder; Excl = ''; Owner = 's'; Scopes = @{} }
    Set-FilePath $f $p
    $script:files.Add($f)
    return $f
}

function Set-FilePath($f, [string]$p) {
    $f.Path = $p
    # Files of the standard: those its applies covers (every file when there is no applies); the others go to the
    # common standard.
    $f.Owner = if ($null -eq $script:applies -or $script:applies.IsMatch($p)) { 's' } else { 'c' }
    $f.Scopes = @{}
    foreach ($o in 's', 'c') {
        foreach ($sc in $script:scopes[$o]) {
            $m = ($f.Owner -ceq $o -and $sc.Re.IsMatch($p))
            if ($m -and $sc.Within -cne '-') {
                if ($sc.Within.StartsWith('!')) { $m = -not $f.Scopes.ContainsKey("$o`t$($sc.Within.Substring(1))") }
                else { $m = $f.Scopes.ContainsKey("$o`t$($sc.Within)") }
            }
            if ($m) { $f.Scopes["$o`t$($sc.Name)"] = $true }
        }
    }
    $f.Excl = ''
    if ($p -match '(^|/)(target|build|out|dist|\.gradle|node_modules)/' -or $p -match '(^|/)generated(-sources|-test-sources)?/') { $f.Excl = 'build output / generated' }
    elseif ($p -match '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$' -or $p -match '\.lock$') { $f.Excl = 'lock file' }
    elseif ($p -match '\.(class|jar|war|png|jpe?g|gif|ico|pdf|zip)$') { $f.Excl = 'binary file' }
}

function Invoke-Scan($f, [int]$ln, [string]$text) {
    if ($text -match '^\s*$') { return }
    $isComment = Test-Comment $text $f.Path
    foreach ($r in $script:rules) {
        if (-not (Test-Scope $r.Owner $r.Scope $f)) { continue }
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

$nk = 0; $nx = 0; $nTest = 0; $nMain = 0; $nMig = 0; $nCommon = 0
foreach ($f in $files) {
    if (-not $f.Excl -and $f.Status -eq 'deleted') { $f.Excl = 'deleted file' }
    if (-not $f.Excl -and $f.Status -eq 'binary') { $f.Excl = 'binary file' }
    if ($f.Excl) { $nx++; continue }
    $nk++
    if ($f.Scopes.ContainsKey("s`ttest")) { $nTest++ }
    if ($f.Scopes.ContainsKey("s`tmain") -and $f.Adds -gt 0) { $nMain++ }
    if ($f.Scopes.ContainsKey("s`tmigration")) { $nMig++ }
    if ($f.Owner -ceq 'c') { $nCommon++ }
}

# Whether every condition of a PR hint holds; returns $null or the files of its modified: conditions.
function Get-PrHint($h) {
    $mod = New-Object System.Text.StringBuilder
    foreach ($c in $h.Cond.Split(',')) {
        $s = $c.Trim(); $x = $s.Substring($s.IndexOf(':') + 1); $hit = $false
        foreach ($f in $script:files) {
            if (-not $f.Scopes.ContainsKey("$($h.Owner)`t$x")) { continue }
            if ($s.StartsWith('has:') -and -not $f.Excl -and $f.Adds -gt 0) { $hit = $true }
            elseif ($s.StartsWith('no:') -and -not $f.Excl) { $hit = $true }
            elseif ($s.StartsWith('modified:') -and (-not $f.Excl -or $f.Excl -eq 'deleted file') -and $f.Status -ne 'added') {
                $hit = $true; [void]$mod.Append("  - $($f.Path) ($($f.Status))`n")
            }
        }
        if ($(if ($s.StartsWith('no:')) { $hit } else { -not $hit })) { return $null }
    }
    return $mod.ToString()
}
function Get-CountPart([string]$scope, [string]$label, [int]$n) {
    foreach ($sc in $script:scopes['s']) { if ($sc.Name -ceq $scope) { return ", ${label}: $n" } }
    return ''
}

$sb = New-Object System.Text.StringBuilder
if ($Mode -in 'all', 'summary') {
    [void]$sb.Append("## Summary`n")
    if ($stdName) {
        $cover = if ($null -eq $applies) { '' } elseif ($commonName) { "; the files it does not cover ([common]) use the common standard $commonName $commonVer" } else { '; the files it does not cover are marked [no standard] and are not scored' }
        [void]$sb.Append("- standard: $stdName $stdVer$cover`n")
    }
    [void]$sb.Append("- deductions: $(if ($merge -eq 'true') { 'merged (merge=true): one F line per check id with all its locations; deducted once' } else { 'not merged (merge=false): one F line per location; every occurrence is deducted' })`n")
    # The severity scale of the standard, and that of the common standard when it differs (codes not in the same order).
    if ($sevs.Count -gt 0) {
        $label = { param($x) $x.Code + $(if ($x.Name -and $x.Name -cne $x.Code) { " ($($x.Name))" } else { '' }) }
        # The meaning of a severity: "-" is none; the lines of a multi-line meaning (separated by |) go on indented lines.
        $text = { param($v) if ($v -ceq '-') { '' } else { $v.Replace('|', "`n    ") } }
        [void]$sb.Append("- severity scale (from the most severe; deducted per finding; the lowest, $($sevs[$sevs.Count - 1].Code), is always allowed and is used when a problem cannot be confirmed):`n")
        foreach ($x in $sevs) { [void]$sb.Append("  - $(& $label $x): $(if ([int]$x.Points) { "-$($x.Points)" } else { '0' })$(if ($x.Cap -cne '-') { ", caps the grade at $($x.Cap)" }). $(& $text $x.Meaning)`n") }
        if ($csevs.Count -gt 0 -and (@($csevs | ForEach-Object { $_.Code }) -join ',') -cne (@($sevs | ForEach-Object { $_.Code }) -join ',')) {
            [void]$sb.Append("- severity scale of the common standard (judge its check items on this scale, give the closest severity of the standard in column 3, and preferably write the severity on this scale in from:):`n")
            foreach ($x in $csevs) { [void]$sb.Append("  - $(& $label $x). $(& $text $x.Meaning)`n") }
        }
    }
    $parts = (Get-CountPart 'main' 'main code changed' $nMain) + (Get-CountPart 'test' 'test files' $nTest) + (Get-CountPart 'migration' 'migrations' $nMig)
    if ($nCommon -gt 0) { $parts += ", $(if ($commonName) { 'common standard files' } else { 'files without a standard' }): $nCommon" }
    [void]$sb.Append("- reviewable files: $nk, excluded: $nx$(if ($parts) { '; ' + $parts.Substring(2) })`n")
    foreach ($f in $files) {
        $tagv = if ($f.Scopes.ContainsKey("s`ttest")) { ' [test]' } elseif ($f.Scopes.ContainsKey("s`tmigration")) { ' [migration]' } else { '' }
        if ($f.Owner -ceq 'c') { $tagv += $(if ($commonName) { ' [common]' } else { ' [no standard]' }) }
        if ($f.Excl) { [void]$sb.Append("  - (excluded: $($f.Excl)) $($f.Path)`n") }
        else { [void]$sb.Append("  - $($f.Path) [$($f.Status) +$($f.Adds) -$($f.Dels)]$tagv`n") }
    }
    [void]$sb.Append("`n")
    # Lists every code review comment with its id <plugin>#<n> (the n-th C record of the plugin's cr.txt).
    if ($Root -and (Test-UserFile (Join-Path $Root 'step2/plan.tsv'))) {
        [void]$sb.Append("## Code review comments (cite the ids in source: of F/U lines or in X lines, and map each to the severity scale with an M line; see the skill)`n")
        $listed = 0
        foreach ($l in (Read-Utf8Lines (Join-Path $Root 'step2/plan.tsv') | Where-Object { $_ })) {
            $p = $l -split "`t"; $crFile = Join-Path $Root "step2/$($p[0])/cr.txt"; $n = 0
            if (-not (Test-UserFile $crFile)) { continue }
            foreach ($x in (Read-Utf8Lines $crFile)) {
                $x = $x.TrimEnd("`r")
                if ($x -match '^\s*C\s*\|') {
                    $n++; $t = @($x -split '\|' | ForEach-Object { $_.Trim() }); while ($t.Count -lt 4) { $t += '' }
                    $show = Test-CommentOwner $cplan $cstd $t[2]
                    if (-not $show) { continue }
                    $listed++; $rule = if ($t[3]) { $t[3] } else { '-' }
                    [void]$sb.Append("- $($p[0])#$n [$($p[2])] $($t[1]) $rule | $($t[2])`n")
                }
                elseif ($n -gt 0 -and $show -and $x -match '^\s*problem:') { [void]$sb.Append("  $($x.Trim())`n") }
            }
        }
        if ($listed -eq 0) { [void]$sb.Append("- none`n") }
        [void]$sb.Append("`n")
    }
}
if ($Mode -in 'all', 'scan') {
    [void]$sb.Append("## Heuristic candidates (clues only: confirm in code before deducting; unlisted checks still need manual review)`n")
    if ($rules.Count -eq 0 -and $hints.Count -eq 0) { [void]$sb.Append("- none: the standard has no scan rules (scan= in the rule.ini of the standard)`n") }
    foreach ($h in $hints) {
        $mod = Get-PrHint $h
        if ($null -ne $mod) { [void]$sb.Append("- $($h.Id): $($h.Hint)`n").Append($mod) }
    }
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
