<#
.SYNOPSIS
State control for the code review scoring workflow.

.DESCRIPTION
Steps: 1 read specs, 2 code review plugins, 3 analyze code (uses the code review results), 4 score, 5 report.
Status files ROOT/stepN-{pending,working,success,failed} gate the steps; step 2 has one status file per
plugin (ROOT/step2-<plugin>-<state>). Outputs live in ROOT/stepN/ (step 2: ROOT/step2/<plugin>/).
Uses the same GNU-style arguments as review-state.sh so subagent prompts work on every platform:

  review-state.ps1 init --git RANGE [--repo DIR] [--title TEXT] [--reset] [--root DIR]
  review-state.ps1 show [--root DIR]
  review-state.ps1 cr-plan [--plugins FILE] [--root DIR]
  review-state.ps1 prompt --step N [--plugin NAME] [--root DIR]
  review-state.ps1 set --step N [--plugin NAME] --state working|pending|success|failed [--message TEXT] [--root DIR]
  review-state.ps1 config [--subagent true|false] [--config FILE]
  review-state.ps1 config --platform NAME [--model TEXT --reasoning TEXT] [--config FILE]

config reads and writes configs.ini in the project root unless --config is given. Without --subagent it prints
subagent=true|false from the [workflow] section (true = each step runs in its own subagent, false = the main
agent runs every step); with --platform it prints or saves the model and reasoning of that platform.

cr-plan picks the plugins of plugins.ini whose "applies" patterns match files in the PR diff and writes
ROOT/step2/plan.tsv, ROOT/step2/<plugin>/files.txt and ROOT/step2/<plugin>/diff.patch (only that plugin's
files, to save tokens). Step 2 is success when every planned plugin is success (no plugins = success).

Gates enforced by "set":
  working  the previous step must be success; clears the status of every later step
  pending  the unit must be working; its questions.md must be newer than answers.md; needs --message
  success  the unit must be working; its outputs must exist, be valid and be current
  failed   the unit must be working; needs --message; appends the message to the unit's errors.log

Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 2 bad arguments, 4 previous review exists, 5 gate refused, 6 setting not configured, 7 setup incomplete (no plugins.ini; see setup check).
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$skillDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Get-ProjectRoot $skillDir
$isWin = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
$selfCmd = if ($isWin) { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" } else { "pwsh -NoProfile -File `"$PSCommandPath`"" }
$states = @('pending', 'working', 'success', 'failed')

$argv = @($args)
if ($argv.Count -eq 0 -or $argv[0] -in '-h', '--help') { Get-Help $PSCommandPath -Detailed; exit 2 }
$cmd = [string]$argv[0]
$opt = @{ root = (Join-Path $projectRoot 'tmp'); step = ''; plugin = ''; state = ''; message = ''; git = ''; repo = '.'; title = ''; reset = $false
    config = (Join-Path $projectRoot 'configs.ini'); subagent = ''; platform = ''; model = ''; reasoning = ''
    plugins = (Join-Path $projectRoot 'plugins.ini') }
$i = 1
while ($i -lt $argv.Count) {
    $a = [string]$argv[$i]
    if ($a -in '--root', '--step', '--plugin', '--state', '--message', '--git', '--repo', '--title', '--config', '--plugins', '--platform', '--model', '--reasoning', '--subagent') {
        if ($i + 1 -ge $argv.Count) { Exit-WithError "$a needs a value" }
        $opt[$a.Substring(2)] = [string]$argv[$i + 1]
        $i += 2
    }
    elseif ($a -eq '--reset') { $opt.reset = $true; $i++ }
    else { Exit-WithError "unknown argument $a (see Get-Help)" }
}
$root = $opt.root
$rootAbs = Resolve-UserPath $root

function Stop-Refused([string]$Message) { [Console]::Error.WriteLine("refused: $Message"); exit 5 }
function P([string]$Rel) { return Join-Path $rootAbs $Rel }
function Test-Exists([string]$Rel) { $p = P $Rel; return [IO.File]::Exists($p) -or [IO.Directory]::Exists($p) }
function Get-Now { return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
# $A exists and is not older than $B
function Test-NotOlder([string]$A, [string]$B) {
    $pa = P $A; $pb = P $B
    if (-not [IO.File]::Exists($pa) -or -not [IO.File]::Exists($pb)) { return $false }
    return [IO.File]::GetLastWriteTimeUtc($pa) -ge [IO.File]::GetLastWriteTimeUtc($pb)
}
function Test-NonEmpty([string]$Rel) { $p = P $Rel; return [IO.File]::Exists($p) -and (New-Object IO.FileInfo($p)).Length -gt 0 }
function Get-RequestField([string]$Name) {
    $l = Read-Utf8Lines (P 'request.md') | Where-Object { $_.StartsWith("- ${Name}: ") } | Select-Object -First 1
    if ($l) { return $l.Substring($Name.Length + 4) } return ''
}
# configs.ini: [workflow] subagent=true|false, and one [NAME] section per platform with model and reasoning.
function Get-IniValue([string]$File, [string]$Section, [string]$Key) {
    if (-not [IO.File]::Exists($File)) { return '' }
    $inSec = $false; $val = ''
    foreach ($l in (Read-Utf8Lines $File)) {
        if ($l -match '^\s*\[(.*)\]\s*$') { $inSec = ($Matches[1] -ceq $Section); continue }
        if ($inSec -and $l -match '^\s*([A-Za-z_]+)\s*=\s*"?(.*?)"?\s*$' -and $Matches[1] -eq $Key) { $val = $Matches[2] }
    }
    return $val
}
# Replaces the [Section] section in place, or appends it when it does not exist yet.
function Set-IniSection([string]$File, [string]$Section, [string[]]$Pairs) {
    $block = @("[$Section]") + @($Pairs | ForEach-Object { $k, $v = $_ -split '=', 2; "$k=`"$v`"" })
    $lines = New-Object System.Collections.Generic.List[string]
    $skip = $false; $done = $false
    $old = if ([IO.File]::Exists($File)) { Read-Utf8Lines $File } else { @() }
    foreach ($l in $old) {
        if ($l -match '^\s*\[(.*)\]\s*$') {
            $skip = $false
            if ($Matches[1] -ceq $Section) { $block | ForEach-Object { $lines.Add($_) }; $done = $true; $skip = $true; continue }
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        }
        if ($skip -and $l.Trim()) { continue }
        $skip = $false
        $lines.Add($l)
    }
    while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1].Trim()) { $lines.RemoveAt($lines.Count - 1) }
    if (-not $done) { if ($lines.Count -gt 0) { $lines.Add('') }; $block | ForEach-Object { $lines.Add($_) } }
    Write-Utf8File $File (($lines -join "`n") + "`n")
}
function Assert-Review { if (-not (Test-Exists 'request.md')) { Exit-WithError "no review in $root; run init first" } }

# Step 2 runs the code review plugins; each plugin is its own unit with its own status file.
$CR = 2
# A "unit" is a step ("1", "3", "4", "5") or a step 2 plugin ("2-<plugin>").
function Get-UnitState([string]$U) {
    foreach ($s in 'working', 'pending', 'success', 'failed') { if ([IO.File]::Exists((P "step$U-$s"))) { return $s } }
    return 'not-started'
}
function Get-UnitDir([string]$U) { if ($U.StartsWith("$CR-")) { return "step$CR/$($U.Substring(2))" } return "step$U" }
function Get-UnitField([string]$U, [string]$S, [string]$Key) {
    $p = P "step$U-$S"
    if (-not [IO.File]::Exists($p)) { return '' }
    $l = Read-Utf8Lines $p | Where-Object { $_.StartsWith("${Key}: ") } | Select-Object -First 1
    if ($l) { return $l.Substring($Key.Length + 2) } return ''
}
function Clear-Unit([string]$U) { foreach ($s in $states) { $p = P "step$U-$s"; if ([IO.File]::Exists($p)) { [IO.File]::Delete($p) } } }
function Test-Unanswered([string]$U) { $d = Get-UnitDir $U; return (Test-Exists "$d/questions.md") -and -not (Test-NotOlder "$d/answers.md" "$d/questions.md") }
function Get-PlanNames {
    if (-not (Test-Exists "step$CR/plan.tsv")) { return @() }
    return @(Read-Utf8Lines (P "step$CR/plan.tsv") | Where-Object { $_ } | ForEach-Object { ($_ -split "`t")[0] })
}
function Get-PlanField([string]$Name, [int]$Index) {
    $l = Read-Utf8Lines (P "step$CR/plan.tsv") | Where-Object { ($_ -split "`t")[0] -eq $Name } | Select-Object -First 1
    if ($l) { return ($l -split "`t")[$Index] } return ''
}
# Clears the status of step N (step 2: every plugin status and the plan)
function Clear-Step([int]$N) {
    if ($N -eq $CR) {
        if ([IO.Directory]::Exists($rootAbs)) {
            Get-ChildItem -LiteralPath $rootAbs -File -Filter "step$CR-*" -Force | ForEach-Object { [IO.File]::Delete($_.FullName) }
        }
        if (Test-Exists "step$CR/plan.tsv") { [IO.File]::Delete((P "step$CR/plan.tsv")) }
    }
    else { Clear-Unit "$N" }
}
# Aggregate state of a step; step 2 combines its plugins
function Get-StepState([int]$N) {
    if ($N -ne $CR) { return Get-UnitState "$N" }
    if (-not (Test-Exists "step$CR/plan.tsv")) { return 'not-started' }
    $all = @(Get-PlanNames | ForEach-Object { Get-UnitState "$CR-$_" })
    if ($all -contains 'failed') { return 'failed' }
    if ($all -contains 'pending') { return 'pending' }
    if ($all -contains 'working') { return 'working' }
    if (@($all | Where-Object { $_ -ne 'success' }).Count -eq 0) { return 'success' }
    return 'not-started'
}
function Test-Step {
    if ($opt.step -notmatch '^[1-5]$') { Exit-WithError '--step must be 1 to 5' }
    $n = [int]$opt.step
    if ($n -eq $CR) {
        if (-not $opt.plugin) { Exit-WithError "step $CR needs --plugin NAME (see cr-plan)" }
        if ((Get-PlanNames) -notcontains $opt.plugin) { Stop-Refused "plugin $($opt.plugin) is not in step $CR's plan; run cr-plan first" }
    }
    elseif ($opt.plugin) { Exit-WithError "--plugin is only used with --step $CR" }
    return $n
}
function Assert-Previous([int]$N) {
    if ($N -gt 1 -and (Get-StepState ($N - 1)) -ne 'success') { Stop-Refused "step $($N - 1) has not succeeded; steps cannot be skipped" }
}
# Files added or changed by the PR, without build output, generated code or lock files
function Get-DiffFiles {
    $exclude = '(^|/)(target|build|out|dist|\.gradle|node_modules)/|(^|/)generated(-sources|-test-sources)?/|(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$|\.lock$'
    return @(Read-Utf8Lines (P 'step1/pr.diff') | Where-Object { $_.StartsWith('+++ ') } | ForEach-Object {
            ($_.Substring(4) -split "`t")[0].Trim('"')
        } | Where-Object { $_ -ne '/dev/null' } | ForEach-Object { $_ -replace '^b/', '' } | Where-Object { $_ -notmatch $exclude })
}
# The parts of step 1's diff that touch the given files (each plugin reads only its own files)
function Get-PluginDiff([string[]]$Files) {
    $want = @{}; foreach ($f in $Files) { $want[$f] = $true }
    $sb = New-Object System.Text.StringBuilder
    $keep = $false
    foreach ($line in ((Read-Utf8Text (P 'step1/pr.diff')) -split "`n")) {
        if ($line.StartsWith('diff --git ')) {
            $p = if ($line -match ' "?b/(.*?)"?\s*$') { $Matches[1] } else { '' }
            $keep = $want.ContainsKey($p)
        }
        if ($keep) { [void]$sb.Append("$line`n") }
    }
    return $sb.ToString()
}
# Checks the normalized code review result; returns the list of problems
function Test-CrFile([string]$Path) {
    $problems = New-Object System.Collections.Generic.List[string]
    $rec = ''; $hasProb = $false; $recLine = 0; $summary = 0; $no = 0
    $closeRec = { if ($script:rec -eq 'C' -and -not $script:hasProb) { $problems.Add("  - line $($script:recLine): C record is missing `"problem:`"") }; $script:rec = ''; $script:hasProb = $false }
    $script:rec = ''; $script:hasProb = $false; $script:recLine = 0
    foreach ($raw in (Read-Utf8Lines $Path)) {
        $no++
        $line = $raw.TrimEnd("`r")
        if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
        if ($line -cmatch '^\s*([a-z]+):' -and $line -cnotmatch '^[A-Z]\|') {
            $k = $Matches[1]
            if ($script:rec -ne 'C') { $problems.Add("  - line ${no}: field `"$k`" is not under a C record"); continue }
            if ($k -cnotin 'problem', 'suggestion') { $problems.Add("  - line ${no}: unknown field `"$k`" (allowed: problem, suggestion)"); continue }
            if ($k -eq 'problem') { $script:hasProb = $true }
            continue
        }
        & $closeRec
        $a = @($line -split '\|'); while ($a.Count -lt 4) { $a += '' }
        switch -CaseSensitive ($a[0]) {
            'C' {
                $script:rec = 'C'; $script:recLine = $no
                if ($a[1] -cnotin 'Critical', 'Major', 'Minor', 'Nit') { $problems.Add("  - line ${no}: severity must be Critical, Major, Minor or Nit") }
                if (-not $a[2]) { $problems.Add("  - line ${no}: C record needs locations (file:line, comma-separated) or -") }
            }
            'S' { if (-not $a[1]) { $problems.Add("  - line ${no}: S record has no text") } else { $summary++ } }
            'H' { if (-not $a[1]) { $problems.Add("  - line ${no}: H record has no text") } }
            default { $problems.Add("  - line ${no}: unknown record type `"$($a[0])`" (allowed: C, S, H)") }
        }
    }
    & $closeRec
    if ($summary -eq 0) { $problems.Add('  - an S line with the overall conclusion is required') }
    return $problems
}

switch ($cmd) {
    'init' {
        if (-not $opt.git) { Exit-WithError 'init needs --git RANGE' }
        if (-not [IO.File]::Exists((Resolve-UserPath $opt.plugins))) { [Console]::Error.WriteLine("setup incomplete: $(Resolve-UserPath $opt.plugins) does not exist; run setup check first"); exit 7 }
        $existing = (Test-Exists 'request.md') -or @(1..5 | Where-Object { $n = $_; (Test-Exists "step$n") -or @($states | Where-Object { Test-Exists "step$n-$_" }).Count -gt 0 }).Count -gt 0
        if (-not $existing -and [IO.Directory]::Exists($rootAbs)) { $existing = @(Get-ChildItem -LiteralPath $rootAbs -File -Filter "step$CR-*" -Force).Count -gt 0 }
        if ($existing) {
            if (-not $opt.reset) {
                [Console]::Error.WriteLine("previous review found in $root; run 'show', then ask the user whether to resume it or start over (--reset)")
                exit 4
            }
            foreach ($n in 1..5) { if ([IO.Directory]::Exists((P "step$n"))) { [IO.Directory]::Delete((P "step$n"), $true) }; Clear-Step $n }
            if (Test-Exists 'request.md') { [IO.File]::Delete((P 'request.md')) }
        }
        $repoAbs = Resolve-UserPath $opt.repo
        & git -C $repoAbs rev-parse --git-dir 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Exit-WithError "$($opt.repo) is not a git repository" }
        [void][IO.Directory]::CreateDirectory($rootAbs)
        # Keep review files out of git unless the repository already ignores the root (keep .gitkeep).
        if (-not (Test-Exists '.gitignore')) {
            & git -C $rootAbs check-ignore -q '.review-probe' 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Utf8File (P '.gitignore') "*`n!.gitkeep`n" }
        }
        $tpl = Read-Utf8Text (Join-Path $skillDir 'assets/request-template.md')
        $req = $tpl.Replace('{{TITLE}}', $opt.title).Replace('{{REPO}}', $repoAbs).Replace('{{RANGE}}', $opt.git).Replace('{{CREATED}}', (Get-Date -Format 'yyyy-MM-dd'))
        Write-Utf8File (P 'request.md') $req
        Write-Output "initialized $rootAbs"
        Write-Output "next: list the documents the user provided in $(P 'request.md'), then dispatch step 1"
    }
    'show' {
        if (-not (Test-Exists 'request.md')) { Write-Output "no review in $root; run init first"; exit 0 }
        $next = ''
        foreach ($n in 1..5) {
            $s = Get-StepState $n
            if ($n -eq $CR) {
                $names = @(Get-PlanNames)
                $info = if (Test-Exists "step$CR/plan.tsv") { "$($names.Count) plugin(s) planned" } else { 'cr-plan not run' }
                Write-Output ("step {0}  {1,-11} {2}" -f $CR, $s, $info)
                foreach ($p in $names) {
                    $ps = Get-UnitState "$CR-$p"
                    Write-Output ("  - {0,-28} {1,-11} {2}  {3}" -f $p, $ps, (Get-UnitField "$CR-$p" $ps 'time'), (Get-UnitField "$CR-$p" $ps 'message'))
                    if (-not $next -and $s -ne 'success') {
                        $next = switch ($ps) {
                            'not-started' { "dispatch step $CR plugin $p (get the prompt with: prompt --step $CR --plugin $p)" }
                            'working' { "step $CR plugin $p is working. If its subagent has already returned, it stopped abnormally: run 'set --step $CR --plugin $p --state failed --message ...' and ask the user whether to retry" }
                            'pending' { "relay $(P "step$CR/$p/questions.md") to the user in one message, save the replies to $(P "step$CR/$p/answers.md"), then dispatch step $CR plugin $p again" }
                            'failed' { "tell the user why step $CR plugin $p failed (details: $(P "step$CR/$p/errors.log")) and ask whether to retry it" }
                            default { '' }
                        }
                    }
                }
                if (-not $next -and $s -eq 'not-started' -and -not (Test-Exists "step$CR/plan.tsv")) { $next = "run cr-plan to choose the code review plugins for step $CR" }
                continue
            }
            Write-Output ("step {0}  {1,-11} {2}  {3}" -f $n, $s, (Get-UnitField "$n" $s 'time'), (Get-UnitField "$n" $s 'message'))
            if (-not $next -and $s -ne 'success') {
                $next = switch ($s) {
                    'not-started' { "dispatch step $n (get the prompt with: prompt --step $n)" }
                    'working' { "step $n is working. If its subagent has already returned, it stopped abnormally: run 'set --step $n --state failed --message ...' and ask the user whether to retry" }
                    'pending' { "relay $(P "step$n/questions.md") to the user in one message, save the replies to $(P "step$n/answers.md"), then dispatch step $n again" }
                    'failed' { "tell the user why step $n failed (details: $(P "step$n/errors.log")) and ask whether to retry it" }
                }
            }
        }
        if (-not $next) {
            $final = if (Test-NonEmpty 'step5/report-path.txt') { (Read-Utf8Lines (P 'step5/report-path.txt'))[0] } else { P 'step5/report.md' }
            $next = "done: present $final to the user"
        }
        Write-Output "next: $next"
    }
    'cr-plan' {
        Assert-Review
        if ((Get-StepState ($CR - 1)) -ne 'success') { Stop-Refused "step $($CR - 1) has not succeeded; steps cannot be skipped" }
        for ($k = $CR; $k -le 5; $k++) { Clear-Step $k }
        if (Test-Exists "step$CR") { [IO.Directory]::Delete((P "step$CR"), $true) }
        [void][IO.Directory]::CreateDirectory((P "step$CR"))
        $plan = New-Object System.Text.StringBuilder
        $skipped = New-Object System.Text.StringBuilder
        $files = Get-DiffFiles
        $pluginsFile = Resolve-UserPath $opt.plugins
        if ([IO.File]::Exists($pluginsFile)) {
            $cfgDir = Split-Path -Parent $pluginsFile
            $sections = [ordered]@{}; $sec = ''
            foreach ($l in (Read-Utf8Lines $pluginsFile)) {
                if ($l -match '^\s*[;#]' -or $l -match '^\s*$') { continue }
                if ($l -match '^\s*\[(.*)\]\s*$') { $sec = $Matches[1]; $sections[$sec] = @{ path = ''; applies = ''; mode = '' }; continue }
                if ($sec -and $l -match '^\s*([^=]+?)\s*=\s*"?(.*?)"?\s*$') { $sections[$sec][$Matches[1]] = $Matches[2] }
            }
            foreach ($name in $sections.Keys) {
                $s = $sections[$name]
                if (-not $s.path) { Exit-WithError "plugin $name has no path in $pluginsFile" }
                $dir = $s.path
                if (-not [IO.Path]::IsPathRooted($dir)) { $dir = Join-Path $cfgDir $dir }
                $dir = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
                if (-not [IO.File]::Exists((Join-Path $dir 'SKILL.md'))) { Exit-WithError "plugin ${name}: $dir/SKILL.md not found; run scripts/link-skills first" }
                $mode = if ($s.mode) { $s.mode } else { 'mapped' }
                if ($mode -notin 'mapped', 'advisory') { Exit-WithError "plugin ${name}: mode must be mapped or advisory, not $mode" }
                $pats = @($s.applies -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $matched = @($files | Where-Object { $f = $_; $pats.Count -eq 0 -or @($pats | Where-Object { $f -like $_ }).Count -gt 0 })
                if ($matched.Count -gt 0) {
                    [void][IO.Directory]::CreateDirectory((P "step$CR/$name"))
                    Write-Utf8File (P "step$CR/$name/files.txt") (($matched -join "`n") + "`n")
                    Write-Utf8File (P "step$CR/$name/diff.patch") (Get-PluginDiff $matched)
                    [void]$plan.Append("$name`t$dir`t$mode`t$($matched.Count)`n")
                }
                else { [void]$skipped.Append("$name`t$($s.applies)`n") }
            }
        }
        Write-Utf8File (P "step$CR/plan.tsv") $plan.ToString()
        Write-Utf8File (P "step$CR/skipped.tsv") $skipped.ToString()
        $names = @(Get-PlanNames)
        Write-Output "planned $($names.Count) plugin(s) in $(P "step$CR/plan.tsv")"
        foreach ($n in $names) { Write-Output "  - $n  mode: $(Get-PlanField $n 2)  files: $(Get-PlanField $n 3)" }
        if ($skipped.Length -gt 0) {
            Write-Output 'skipped:'
            foreach ($l in ($skipped.ToString() -split "`n" | Where-Object { $_ })) { Write-Output ("  - " + ($l -replace "`t", '  no changed file matches: ')) }
        }
        if ($names.Count -gt 0) { Write-Output "next: dispatch each plugin in order with prompt --step $CR --plugin NAME" }
        else { Write-Output "next: step $CR has nothing to run and counts as success; dispatch step $($CR + 1)" }
    }
    'prompt' {
        $n = Test-Step; Assert-Review
        Assert-Previous $n
        $stateCmd = "$selfCmd set --root `"$rootAbs`""
        $pPath = ''; $pMode = ''
        if ($n -eq $CR) { $pPath = Get-PlanField $opt.plugin 1; $pMode = Get-PlanField $opt.plugin 2 }
        $tpl = Read-Utf8Text (Join-Path $skillDir "assets/prompts/step$n.md")
        $text = $tpl.Replace('{{ROOT}}', $rootAbs).Replace('{{STATE_CMD}}', $stateCmd).Replace('{{REPO}}', (Get-RequestField 'Repository')).Replace('{{RANGE}}', (Get-RequestField 'Diff range')).Replace('{{TITLE}}', (Get-RequestField 'Title')).Replace('{{SKILLS_DIR}}', (Split-Path -Parent $skillDir)).Replace('{{PLUGIN}}', $opt.plugin).Replace('{{PLUGIN_PATH}}', $pPath).Replace('{{MODE}}', $pMode)
        [Console]::Out.Write($text)
    }
    'set' {
        $n = Test-Step; Assert-Review
        $state = $opt.state; $message = $opt.message
        if ($state -cnotin $states) { Exit-WithError '--state must be working, pending, success or failed' }
        $unit = if ($n -eq $CR) { "$CR-$($opt.plugin)" } else { "$n" }
        $label = if ($n -eq $CR) { "step $CR plugin $($opt.plugin)" } else { "step $n" }
        $cur = Get-UnitState $unit
        $d = Get-UnitDir $unit
        switch ($state) {
            'working' {
                Assert-Previous $n
                for ($k = $n + 1; $k -le 5; $k++) { Clear-Step $k }
                [void][IO.Directory]::CreateDirectory((P $d))
            }
            'pending' {
                if ($cur -ne 'working') { Stop-Refused "$label is $cur; set it to working first" }
                if (-not $message) { Stop-Refused 'pending needs --message' }
                if (-not (Test-Unanswered $unit)) { Stop-Refused "write new questions to $(P "$d/questions.md") first" }
            }
            'failed' {
                if ($cur -ne 'working') { Stop-Refused "$label is $cur; set it to working first" }
                if (-not $message) { Stop-Refused 'failed needs --message with the reason' }
                [void][IO.Directory]::CreateDirectory((P $d))
                [IO.File]::AppendAllText((P "$d/errors.log"), "[$(Get-Now)] $label failed: $message`n", $script:Utf8NoBom)
            }
            'success' {
                if ($cur -ne 'working') { Stop-Refused "$label is $cur; set it to working first" }
                switch ($n) {
                    1 {
                        foreach ($f in 'pr.diff', 'spec-context.md') { if (-not (Test-NonEmpty "$d/$f")) { Stop-Refused "missing $(P "$d/$f")" } }
                        $open = @(Read-Utf8Lines (P "$d/spec-context.md") | Where-Object { $_ -cmatch '^- [a-z-]+: (unknown|pending)\s*$' -or $_.StartsWith('- [ ] ') })
                        if ($open.Count -gt 0) { Stop-Refused 'spec-context.md still has unresolved inputs or open questions' }
                        if (Test-Unanswered $unit) { Stop-Refused "$(P "$d/questions.md") has not been answered" }
                    }
                    2 {
                        if (-not (Test-NonEmpty "$d/cr.txt")) { Stop-Refused "missing $(P "$d/cr.txt")" }
                        if (Test-Unanswered $unit) { Stop-Refused "$(P "$d/questions.md") has not been answered" }
                        $problems = @(Test-CrFile (P "$d/cr.txt"))
                        if ($problems.Count -gt 0) { Stop-Refused ("$d/cr.txt is invalid:`n" + ($problems -join "`n")) }
                    }
                    3 {
                        foreach ($f in 'prepared.txt', 'findings.txt') { if (-not (Test-NonEmpty "$d/$f")) { Stop-Refused "missing $(P "$d/$f")" } }
                        if (Test-Unanswered $unit) { Stop-Refused "$(P "$d/questions.md") has not been answered" }
                    }
                    4 {
                        foreach ($f in 'score.tsv', 'score.json') {
                            if (-not (Test-NonEmpty "$d/$f")) { Stop-Refused "missing $(P "$d/$f")" }
                            if (-not (Test-NotOlder "$d/$f" 'step3/findings.txt')) { Stop-Refused "$d/$f is older than step3/findings.txt; rerun scoring" }
                        }
                    }
                    5 {
                        if (-not (Test-NonEmpty "$d/report.md")) { Stop-Refused "missing $(P "$d/report.md")" }
                        if (-not (Test-NotOlder "$d/report.md" 'step4/score.tsv')) { Stop-Refused 'report.md is older than step4/score.tsv; render again' }
                        foreach ($p in (Get-PlanNames)) {
                            if (-not (Test-NotOlder "$d/report.md" "step$CR/$p/cr.txt")) { Stop-Refused "report.md is older than step$CR/$p/cr.txt; render again" }
                        }
                        if (-not (Test-NonEmpty "$d/report-path.txt")) { Stop-Refused "the final report was not published to reports/ (missing $(P "$d/report-path.txt")); render again without -NoPublish" }
                        $final = (Read-Utf8Lines (P "$d/report-path.txt"))[0].Trim()
                        if (-not [IO.File]::Exists($final)) { Stop-Refused "published report not found: $final" }
                        if ((Read-Utf8Text $final) -ne (Read-Utf8Text (P "$d/report.md"))) { Stop-Refused "published report $final differs from $(P "$d/report.md"); render again" }
                    }
                }
            }
        }
        Clear-Unit $unit
        Write-Utf8File (P "step$unit-$state") "state: $state`ntime: $(Get-Now)`nmessage: $message`n"
        Write-Output "${label}: $state"
    }
    'config' {
        $platform = $opt.platform
        $cfg = Resolve-UserPath $opt.config
        if ($opt.subagent) {
            if ($platform -or $opt.model -or $opt.reasoning) { Exit-WithError '--subagent cannot be combined with --platform, --model or --reasoning' }
            if ($opt.subagent -cnotin 'true', 'false') { Exit-WithError '--subagent must be true or false' }
            Set-IniSection $cfg 'workflow' @("subagent=$($opt.subagent)")
            Write-Output "saved subagent=$($opt.subagent) to $cfg"
        }
        elseif (-not $platform) {
            if ($opt.model -or $opt.reasoning) { Exit-WithError '--model and --reasoning need --platform NAME' }
            $v = (Get-IniValue $cfg 'workflow' 'subagent').ToLowerInvariant()
            if ($v -notin 'true', 'false') { [Console]::Error.WriteLine("not configured: subagent=true|false is missing in [workflow] of $cfg; ask the user whether to run the steps in subagents"); exit 6 }
            [Console]::Out.Write("subagent=$v`n")
        }
        else {
            if ($platform -notmatch '^[A-Za-z0-9_-]+$') { Exit-WithError '--platform may only contain letters, digits, - and _' }
            if ($platform -eq 'workflow') { Exit-WithError 'workflow is reserved and cannot be a platform name' }
            if (-not $opt.model -and -not $opt.reasoning) {
                $m = Get-IniValue $cfg $platform 'model'
                $r = Get-IniValue $cfg $platform 'reasoning'
                if (-not $m -or -not $r) { [Console]::Error.WriteLine("not configured: [$platform] with model and reasoning is missing in $cfg; ask the user for them"); exit 6 }
                [Console]::Out.Write("model=$m`nreasoning=$r`n")
            }
            else {
                if (-not $opt.model -or -not $opt.reasoning) { Exit-WithError 'config needs both --model and --reasoning to save' }
                if (($opt.model + $opt.reasoning).Contains('"')) { Exit-WithError 'values may not contain double quotes' }
                Set-IniSection $cfg $platform @("model=$($opt.model)", "reasoning=$($opt.reasoning)")
                Write-Output "saved [$platform] to $cfg"
            }
        }
    }
    default { Exit-WithError "unknown command $cmd (see Get-Help)" }
}
