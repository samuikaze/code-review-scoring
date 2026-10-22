<#
.SYNOPSIS
State control for the code review scoring workflow.

.DESCRIPTION
Steps: 1 read specs, 2 code review plugins, 3 analyze code (uses the code review results), 4 score, 5 report.
Status files ROOT/stepN-{pending,working,success,failed} gate the steps; step 2 has one status file per
plugin (ROOT/step2-<plugin>-<state>), steps 3 to 5 one per scoring standard of the review plan that step 1 writes
to ROOT/step1/standards/ (ROOT/step3-<standard>-<state>). Outputs live in ROOT/step1/, ROOT/step2/<plugin>/ and
ROOT/stepN/<standard>/.
Uses the same GNU-style arguments as review-state.sh so subagent prompts work on every platform:

  review-state.ps1 init --git RANGE [--repo DIR] [--title TEXT] [--reset] [--root DIR]
  review-state.ps1 next [--inline] [--retry] [--root DIR]
  review-state.ps1 finish [--root DIR]
  review-state.ps1 show [--root DIR]
  review-state.ps1 cr-plan [--plugins FILE] [--root DIR]
  review-state.ps1 prompt --step 1|2|3 [--plugin NAME] [--standard NAME] [--inline] [--root DIR]
  review-state.ps1 set --step N [--plugin NAME] [--standard NAME] --state working|pending|success|failed [--message TEXT] [--root DIR]
Every command also takes --standards FILE (default: configs/standards.ini in the project root).
  review-state.ps1 config [--subagent true|false] [--config FILE]
  review-state.ps1 config --platform NAME [--model TEXT --reasoning TEXT] [--config FILE]

next prints the next action of the workflow: the prompt of the next step or plugin to run (it runs cr-plan first
when step 2 has no plan yet), the questions to relay, a failure to report, "finish", or the result. --inline renders
prompts for the main agent (default: from subagent= in configs/settings.ini); --retry prints the prompt again for a failed
step or plugin. finish runs step 4 (score) and step 5 (report) with their scripts for every standard of the review
plan, records the states and prints the results (exit 1 when one of them failed). prompt prints the prompt of step
1, 2 or 3 (step 2 needs --plugin, step 3 --standard when several standards score the PR).

config reads and writes configs/settings.ini in the project root unless --config is given. Without --subagent it prints
subagent=true|false from the [workflow] section (true = each step runs in its own subagent, false = the main
agent runs every step); with --platform it prints or saves the model and reasoning of that platform.

cr-plan picks the plugins of configs/plugins.ini whose "applies" patterns match files in the PR diff and writes
ROOT/step2/plan.tsv, ROOT/step2/<plugin>/files.txt and ROOT/step2/<plugin>/diff.patch (only that plugin's
files, to save tokens). Step 2 is success when every planned plugin is success (no plugins = success).

Gates enforced by "set":
  working  the previous step must be success; clears the status of every later step
  pending  the unit must be working; its questions.md must be newer than answers.md; needs --message
  success  the unit must be working; its outputs must exist, be valid and be current
           (step 1: the review plan ROOT/step1/standards/plan.tsv; step 3: findings.txt must pass the scoring
           checks of score -Check)
Steps 3 to 5 also refuse to go on when a scoring standard changed after step 1 planned the review (its document,
scan rules or settings in standards.ini).
  failed   the unit must be working; needs --message; appends the message to the unit's errors.log

Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok, 1 finish: step 4 or 5 failed, 2 bad arguments, 4 previous review exists, 5 gate refused, 6 setting not configured, 7 setup incomplete (no configs/plugins.ini; see setup check).
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
Initialize-Utf8

$skillDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Get-ProjectRoot $skillDir
$isWin = ($PSVersionTable.PSVersion.Major -le 5) -or $IsWindows
$selfCmd = if ($isWin) { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" } else { "pwsh -NoProfile -File `"$PSCommandPath`"" }
$states = @('pending', 'working', 'success', 'failed')
$skillsDir = Split-Path -Parent $skillDir

$argv = @($args)
if ($argv.Count -eq 0 -or $argv[0] -in '-h', '--help') { Get-Help $PSCommandPath -Detailed; exit 2 }
$cmd = [string]$argv[0]
$opt = @{ root = (Join-Path $projectRoot 'tmp'); step = ''; plugin = ''; standard = ''; standards = (Join-Path $projectRoot 'configs/standards.ini'); state = ''; message = ''; git = ''; repo = '.'; title = ''; reset = $false
    config = (Join-Path $projectRoot 'configs/settings.ini'); subagent = ''; platform = ''; model = ''; reasoning = ''
    plugins = (Join-Path $projectRoot 'configs/plugins.ini'); inline = $null; retry = $false }
$i = 1
while ($i -lt $argv.Count) {
    $a = [string]$argv[$i]
    if ($a -in '--root', '--step', '--plugin', '--standard', '--standards', '--state', '--message', '--git', '--repo', '--title', '--config', '--plugins', '--platform', '--model', '--reasoning', '--subagent') {
        if ($i + 1 -ge $argv.Count) { Exit-WithError "$a needs a value" }
        $opt[$a.Substring(2)] = [string]$argv[$i + 1]
        $i += 2
    }
    elseif ($a -eq '--reset') { $opt.reset = $true; $i++ }
    elseif ($a -eq '--inline') { $opt.inline = $true; $i++ }
    elseif ($a -eq '--retry') { $opt.retry = $true; $i++ }
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
# configs/settings.ini: [workflow] subagent=true|false, and one [NAME] section per platform with model and reasoning.
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
    # A new configs/settings.ini starts as a copy of the commented example
    $example = Join-Path $projectRoot 'configs/settings.example.ini'
    $old = if ([IO.File]::Exists($File)) { Read-Utf8Lines $File } elseif ([IO.File]::Exists($example)) { Read-Utf8Lines $example } else { @() }
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
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent (Resolve-UserPath $File)))
    Write-Utf8File $File (($lines -join "`n") + "`n")
}
function Assert-Review { if (-not (Test-Exists 'request.md')) { Exit-WithError "no review in $root; run init first" } }

# Step 2 runs the code review plugins; each plugin is its own unit with its own status file. Steps 3 to 5 run once
# per scoring standard of the review plan.
$CR = 2
# A "unit" is step 1, a step 2 plugin ("2-<plugin>") or a step 3 to 5 standard ("3-<standard>").
function Get-UnitState([string]$U) {
    foreach ($s in 'working', 'pending', 'success', 'failed') { if ([IO.File]::Exists((P "step$U-$s"))) { return $s } }
    return 'not-started'
}
function Get-UnitDir([string]$U) { if ($U.Contains('-')) { return "step$($U.Substring(0, 1))/$($U.Substring(2))" } return "step$U" }
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
# The scoring standards of the review plan (one report each), in plan order.
$stdPlan = P 'step1/standards/plan.tsv'
function Get-StdNames {
    if (-not [IO.File]::Exists($stdPlan)) { return @() }
    return @(Read-Utf8Lines $stdPlan | ForEach-Object { $a = $_.Split("`t"); if ($a[0] -ceq 'report') { $a[1] } })
}
# The units of step 2 to 5
function Get-SubNames([int]$N) { if ($N -eq $CR) { return @(Get-PlanNames) } return @(Get-StdNames) }
# Clears the status of step N (step 2: every plugin status and the plan; steps 3 to 5: every standard)
function Clear-Step([int]$N) {
    if ($N -ge $CR) {
        if ([IO.Directory]::Exists($rootAbs)) {
            Get-ChildItem -LiteralPath $rootAbs -File -Filter "step$N-*" -Force | ForEach-Object { [IO.File]::Delete($_.FullName) }
        }
        if ($N -eq $CR -and (Test-Exists "step$CR/plan.tsv")) { [IO.File]::Delete((P "step$CR/plan.tsv")) }
    }
    else { Clear-Unit "$N" }
}
# Aggregate state of a step; steps 2 to 5 combine their plugins or standards
function Get-StepState([int]$N) {
    if ($N -eq 1) { return Get-UnitState "$N" }
    if ($N -eq $CR) { if (-not (Test-Exists "step$CR/plan.tsv")) { return 'not-started' } }
    elseif (@(Get-StdNames).Count -eq 0) { return 'not-started' }
    $all = @(Get-SubNames $N | ForEach-Object { Get-UnitState "$N-$_" })
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
    if ($n -gt $CR) {
        if (-not [IO.File]::Exists($stdPlan)) { Stop-Refused "step 1 has not planned the review (missing $stdPlan)" }
        # Without --standard: the only standard of the plan.
        $names = @(Get-StdNames)
        if (-not $opt.standard -and $names.Count -eq 1) { $opt.standard = $names[0] }
        if (-not $opt.standard) { Exit-WithError "step $n needs --standard NAME: $($names -join ', ')" }
        if ($names -cnotcontains $opt.standard) { Stop-Refused "the standard $($opt.standard) does not score this review (see $stdPlan)" }
    }
    elseif ($opt.standard) { Exit-WithError '--standard is only used with steps 3 to 5' }
    return $n
}
# Step 3 needs step 2; steps 4 and 5 need the previous step of the same standard.
function Assert-Previous([int]$N, [string]$Std) {
    if ($N -gt 3) {
        if ((Get-UnitState "$($N - 1)-$Std") -ne 'success') { Stop-Refused "step $($N - 1) ($Std) has not succeeded; steps cannot be skipped" }
    }
    elseif ($N -gt 1 -and (Get-StepState ($N - 1)) -ne 'success') { Stop-Refused "step $($N - 1) has not succeeded; steps cannot be skipped" }
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
            if ($k -cnotin 'problem', 'suggestion', 'spec') { $problems.Add("  - line ${no}: unknown field `"$k`" (allowed: problem, suggestion, spec)"); continue }
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
# Runs a script in a child process (this script, or a script of a sibling skill) and returns its exit code and output.
function Invoke-Child([string]$Path, [string[]]$ArgList) {
    $exe = if ($isWin) { @('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') } else { @('pwsh', '-NoProfile', '-File') }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $exe[0] $exe[1..($exe.Count - 1)] $Path @ArgList 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $old }
    return @{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
function Invoke-Tool([string]$Skill, [string]$Script, [string[]]$ArgList) {
    return Invoke-Child (Join-Path $skillsDir "$Skill/scripts/$Script.ps1") $ArgList
}
# The scoring standard $Name must be the one step 1 planned with: its document, scan rules and settings in
# standards.ini (the resolve output without the paths, which differ between shells) must not have changed.
function Get-ResKey([string]$Text) {
    $lines = foreach ($l in ($Text.Replace("`r", '') -split "`n")) {
        $f = $l.Split("`t")
        if (($f[0] -ceq 'standard' -or $f[0] -ceq 'common') -and $f.Count -gt 4) { $f[4] = '' }
        elseif ($f[0] -ceq 'scan' -and $f.Count -gt 1) { $f[1] = '' }
        $f -join "`t"
    }
    return ($lines -join "`n").TrimEnd("`n")
}
function Assert-StdGate([string]$Name) {
    $saved = P "step1/standards/$Name.resolve"
    if (-not [IO.File]::Exists($saved)) { Stop-Refused "missing $saved; step 1 has not planned the review" }
    $r = Invoke-Child (Join-Path $PSScriptRoot 'standard.ps1') @('resolve', '--standards', (Resolve-UserPath $opt.standards), '--settings', (Resolve-UserPath $opt.config), $Name)
    if ($r.Code -ne 0) { Stop-Refused "the scoring standard $Name cannot be read: $(($r.Text -split "`n")[0])" }
    if ((Get-ResKey (Read-Utf8Text $saved)) -cne (Get-ResKey $r.Text)) {
        Stop-Refused "the scoring standard $Name changed after step 1 planned the review (its document, scan rules or settings in standards.ini); restore it, or start the review again (init --reset)"
    }
}
# request.md records the scoring standards of the review: name, version, sha256 and path of each document.
function Write-RequestStandards {
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in (Read-Utf8Lines (P 'request.md'))) {
        if ($l.StartsWith('## Scoring standards')) { $skip = $true; continue }
        if ($skip -and $l.StartsWith('## ')) { $skip = $false }
        if (-not $skip) { $out.Add($l) }
    }
    while ($out.Count -gt 0 -and -not $out[$out.Count - 1]) { $out.RemoveAt($out.Count - 1) }
    $out.Add(''); $out.Add('## Scoring standards')
    foreach ($n in (Get-StdNames)) {
        foreach ($l in (Read-Utf8Lines (P "step1/standards/$n.resolve"))) {
            $f = $l.Split("`t")
            if ($f[0] -ceq 'standard') { $out.Add("- ${n}: $($f[1]) $($f[2]) $($f[3]) $($f[4])") }
            elseif ($f[0] -ceq 'common') { $out.Add("  - common standard: $($f[1]) $($f[2]) $($f[3]) $($f[4])") }
        }
    }
    Write-Utf8File (P 'request.md') (($out -join "`n") + "`n")
}
# The document path of the standard record ("standard") or the common record ("common") of a planned standard.
function Get-StdDoc([string]$Name, [string]$Kind) {
    foreach ($l in (Read-Utf8Lines (P "step1/standards/$Name.resolve"))) { $f = $l.Split("`t"); if ($f[0] -ceq $Kind) { return $f[4] } }
    return ''
}
# Options that the prompts pass on to the scripts: --standards and --config when they are not the defaults.
function Get-FileOpt([string]$Name, [string]$File, [string]$Default) {
    $f = Resolve-UserPath $File
    if ($f -ceq (Resolve-UserPath $Default)) { return '' }
    return " $Name `"$f`""
}
# The language the agents write report text in: the language label of the report template folder (templates/ in the
# project root; with several languages, the one [language] report of the settings names, default zh-tw).
function Get-ReportLanguage {
    $dir = Get-ReportTemplateDir $projectRoot $opt.config
    $v = ''
    $lf = Join-Path $dir 'labels.tsv'
    if (Test-Path -LiteralPath $lf -PathType Leaf) {
        foreach ($l in (Read-Utf8Lines $lf)) { $a = $l.Split("`t"); if ($a.Count -ge 2 -and $a[0] -ceq 'language') { $v = $a[1].TrimEnd("`r"); break } }
    }
    if ($v) { return $v }
    return "the language of the report template in $dir"
}
# Prompt of step $N (plugin $Plugin): the step template plus the shared status protocol. Lines marked "[sub] " are only
# for subagents, lines marked "[inline] " only for the main agent.
function Get-Prompt([int]$N, [string]$Plugin, [string]$Std, [bool]$Inline) {
    $pPath = ''; $pMode = ''; $unitArgs = "--step $N"; $dir = P "step$N"; $sDoc = ''; $cDoc = 'none'; $lang = ''
    if ($N -ge $CR) { $lang = Get-ReportLanguage }
    $sOpt = Get-FileOpt '--standards' $opt.standards (Join-Path $projectRoot 'configs/standards.ini')
    $cOpt = Get-FileOpt '--config' $opt.config (Join-Path $projectRoot 'configs/settings.ini')
    if ($N -eq $CR) { $pPath = Get-PlanField $Plugin 1; $pMode = Get-PlanField $Plugin 2; $unitArgs += " --plugin $Plugin"; $dir = P "step$CR/$Plugin" }
    elseif ($N -gt $CR) {
        $sDoc = Get-StdDoc $Std 'standard'; $cDoc = Get-StdDoc $Std 'common'; if (-not $cDoc) { $cDoc = 'none' }
        $unitArgs += " --standard $Std"; $dir = P "step$N/$Std"
    }
    $tpl = (Read-Utf8Text (Join-Path $skillDir "assets/prompts/step$N.md")) + (Read-Utf8Text (Join-Path $skillDir 'assets/prompts/protocol.md'))
    $lines = foreach ($l in ($tpl -split "`r?`n")) {
        if ($l.StartsWith('[sub] ')) { if ($Inline) { continue }; $l = $l.Substring(6) }
        elseif ($l.StartsWith('[inline] ')) { if (-not $Inline) { continue }; $l = $l.Substring(9) }
        $l
    }
    $text = ($lines -join "`n")
    return $text.Replace('{{ROOT}}', $rootAbs).Replace('{{STATE_CMD}}', "$selfCmd set --root `"$rootAbs`"$sOpt$cOpt").Replace('{{REPO}}', (Get-RequestField 'Repository')).Replace('{{RANGE}}', (Get-RequestField 'Diff range')).Replace('{{TITLE}}', (Get-RequestField 'Title')).Replace('{{SKILLS_DIR}}', $skillsDir).Replace('{{PLUGIN_PATH}}', $pPath).Replace('{{PLUGIN}}', $Plugin).Replace('{{MODE}}', $pMode).Replace('{{UNIT}}', $unitArgs).Replace('{{DIR}}', $dir).Replace('{{STEP}}', "$N").Replace('{{STANDARD_DOC}}', $sDoc).Replace('{{STANDARD}}', $Std).Replace('{{COMMON_DOC}}', $cDoc).Replace('{{REPORT_LANGUAGE}}', $lang).Replace('{{STANDARDS_OPT}}', $sOpt).Replace('{{CONFIG_OPT}}', $cOpt)
}
# Writes the action "next" prints for a unit ("1", "2-<plugin>" or "3-<standard>") in state $S; returns $false when it
# needs nothing.
function Write-NextAction([string]$U, [string]$Label, [string]$S, [bool]$Inline, [bool]$Retry) {
    if ($S -eq 'success') { return $false }
    $std = ''
    if ($U.StartsWith("$CR-")) { $n = $CR; $plugin = $U.Substring(2); $unitArgs = "--step $CR --plugin $plugin" }
    elseif ($U.Contains('-')) {
        $n = [int]$U.Substring(0, 1); $plugin = ''; $std = $U.Substring(2); $unitArgs = "--step $n --standard $std"
        Assert-StdGate $std
    }
    else { $n = [int]$U; $plugin = ''; $unitArgs = "--step $U" }
    $d = P (Get-UnitDir $U)
    $o = New-Object System.Collections.Generic.List[string]
    # Once the replies are written (answers.md newer than questions.md), the step runs again and applies them.
    $ans = Join-Path $d 'answers.md'; $qs = Join-Path $d 'questions.md'
    if ($S -eq 'pending' -and (Test-Path -LiteralPath $ans) -and ((-not (Test-Path -LiteralPath $qs)) -or (Get-Item -LiteralPath $ans).LastWriteTimeUtc -gt (Get-Item -LiteralPath $qs).LastWriteTimeUtc)) { $S = 'answered' }
    if ($S -eq 'pending') {
        $o.Add('action: ask')
        $o.Add("$Label needs answers. Ask the user every question in $d/questions.md in one message, write the replies")
        $o.Add("to $d/answers.md (keep their wording; mark unanswerable questions `"cannot provide`"), then run next.")
    }
    elseif ($S -eq 'failed' -and -not $Retry) {
        $o.Add('action: failed')
        $o.Add("$Label failed: $(Get-UnitField $U 'failed' 'message')")
        $o.Add("details: $d/errors.log")
        $o.Add('Tell the user the reason and ask whether to retry; to retry, run next --retry.')
    }
    elseif ($S -eq 'working' -and -not $Inline) {
        $o.Add('action: interrupted')
        $o.Add("$Label is still working although its subagent returned: run set $unitArgs --state failed")
        $o.Add('--message "subagent exited without a final state", then run next.')
    }
    else {
        $o.Add("action: run $Label")
        if ($Inline) {
            if ($S -eq 'working') { $o.Add("note: an earlier run stopped before it finished; reuse what is already in $d") }
            $o.Add('Follow the prompt below yourself.')
        }
        else { $o.Add('Pass the prompt below unchanged to one new subagent with the saved model and reasoning, then run next.') }
        $o.Add('')
        $o.Add((Get-Prompt $n $plugin $std $Inline).TrimEnd("`n"))
    }
    [Console]::Out.Write(($o -join "`n") + "`n")
    return $true
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
            if ([IO.Directory]::Exists((P 'inputs'))) { [IO.Directory]::Delete((P 'inputs'), $true) }
        }
        $repoAbs = Resolve-UserPath $opt.repo
        # git writes to stderr when the answer is no; Windows PowerShell 5.1 turns that into an error under 'Stop'.
        $ErrorActionPreference = 'Continue'
        & git -C $repoAbs rev-parse --git-dir 2>$null | Out-Null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) { Exit-WithError "$($opt.repo) is not a git repository" }
        [void][IO.Directory]::CreateDirectory($rootAbs)
        # Keep review files out of git unless the repository already ignores the root (keep .gitkeep).
        if (-not (Test-Exists '.gitignore')) {
            $ErrorActionPreference = 'Continue'
            & git -C $rootAbs check-ignore -q '.review-probe' 2>$null
            $ErrorActionPreference = 'Stop'
            if ($LASTEXITCODE -ne 0) { Write-Utf8File (P '.gitignore') "*`n!.gitkeep`n" }
        }
        $tpl = Read-Utf8Text (Join-Path $skillDir 'assets/request-template.md')
        $req = $tpl.Replace('{{TITLE}}', $opt.title).Replace('{{REPO}}', $repoAbs).Replace('{{RANGE}}', $opt.git).Replace('{{CREATED}}', (Get-Date -Format 'yyyy-MM-dd'))
        Write-Utf8File (P 'request.md') $req
        Write-Output "initialized $rootAbs"
        Write-Output "next: list the documents the user provided in $(P 'request.md'), then run next"
    }
    'show' {
        if (-not (Test-Exists 'request.md')) { Write-Output "no review in $root; run init first"; exit 0 }
        foreach ($n in 1..5) {
            $s = Get-StepState $n
            if ($n -ge $CR) {
                $names = @(Get-SubNames $n)
                if ($n -eq $CR) { $info = if (Test-Exists "step$CR/plan.tsv") { "$($names.Count) plugin(s) planned" } else { 'cr-plan not run' } }
                else { $info = if ([IO.File]::Exists($stdPlan)) { "$($names.Count) standard(s)" } else { 'not planned' } }
                Write-Output ("step {0}  {1,-11} {2}" -f $n, $s, $info)
                foreach ($p in $names) {
                    $ps = Get-UnitState "$n-$p"
                    Write-Output ("  - {0,-28} {1,-11} {2}  {3}" -f $p, $ps, (Get-UnitField "$n-$p" $ps 'time'), (Get-UnitField "$n-$p" $ps 'message'))
                }
                continue
            }
            Write-Output ("step {0}  {1,-11} {2}  {3}" -f $n, $s, (Get-UnitField "$n" $s 'time'), (Get-UnitField "$n" $s 'message'))
        }
        Write-Output 'next: run next'
    }
    'next' {
        Assert-Review
        $inline = if ($null -ne $opt.inline) { $true } else { (Get-IniValue (Resolve-UserPath $opt.config) 'workflow' 'subagent').ToLowerInvariant() -ne 'true' }
        if ($inline) { Write-Output 'mode: inline' } else { Write-Output 'mode: subagent' }
        if (Write-NextAction '1' 'step 1' (Get-UnitState '1') $inline $opt.retry) { exit 0 }
        if (-not (Test-Exists "step$CR/plan.tsv")) {
            $r = Invoke-Child $PSCommandPath @('cr-plan', '--root', $rootAbs, '--plugins', (Resolve-UserPath $opt.plugins))
            $lines = @($r.Text -split "`n" | Where-Object { -not $_.StartsWith('next:') })
            [Console]::Out.Write(($lines -join "`n") + "`n")
            if ($r.Code -ne 0) { exit $r.Code }
        }
        foreach ($p in (Get-PlanNames)) {
            if (Write-NextAction "$CR-$p" "step $CR plugin $p" (Get-UnitState "$CR-$p") $inline $opt.retry) { exit 0 }
        }
        $stds = @(Get-StdNames)
        if ($stds.Count -eq 0) { Exit-WithError "step 1 has not planned the review (missing $stdPlan); redo step 1" }
        foreach ($n in $stds) { if (Write-NextAction "3-$n" "step 3 ($n)" (Get-UnitState "3-$n") $inline $opt.retry) { exit 0 } }
        foreach ($n in $stds) {
            if ((Get-UnitState "4-$n") -eq 'failed' -and (Get-UnitField "4-$n" 'failed' 'message').StartsWith('findings.txt failed validation')) {
                Write-Output "note: scoring rejected findings.txt of $n (details: $(P "step4/$n/errors.log")); step 3 ($n) runs again"
                [void](Write-NextAction "3-$n" "step 3 ($n)" 'failed' $inline $true)
                exit 0
            }
        }
        foreach ($n in $stds) {
            foreach ($k in 4, 5) {
                if ((Get-UnitState "$k-$n") -eq 'failed' -and -not $opt.retry) {
                    Write-Output 'action: failed'
                    Write-Output "step $k ($n) failed: $(Get-UnitField "$k-$n" 'failed' 'message')"
                    Write-Output "details: $(P "step$k/$n/errors.log")"
                    Write-Output 'Tell the user the reason and ask whether to retry; to retry, run finish.'
                    exit 0
                }
            }
        }
        if ((Get-StepState 5) -ne 'success') {
            Write-Output 'action: finish'
            Write-Output 'Run finish: it runs step 4 (score) and step 5 (report) with their scripts for every standard.'
            exit 0
        }
        Write-Output 'action: done'
        foreach ($n in $stds) {
            $g = ''; $t = ''; $c = ''; $dims = ''
            foreach ($l in (Read-Utf8Lines (P "step4/$n/score.tsv"))) {
                $f = $l -split "`t"
                switch ($f[0]) {
                    'grade' { $g = $f[1] }
                    'total' { $t = $f[1] }
                    'capped' { if ($f[1] -eq '1') { $c = ' (capped at B because of a Critical finding)' } }
                    'dim' { $dims += "$($f[1]) $($f[2])/$($f[3])  " }
                }
            }
            Write-Output "result ($n): grade $g, total $t/100$c"
            Write-Output "dimensions: $dims"
            Write-Output "report: $((Read-Utf8Lines (P "step5/$n/report-path.txt"))[0].Trim())"
        }
    }
    'finish' {
        Assert-Review
        if ((Get-StepState 3) -ne 'success') { Stop-Refused 'step 3 has not succeeded; steps cannot be skipped' }
        $stds = @(Get-StdNames)
        foreach ($n in $stds) { Assert-StdGate $n }
        $stdArgs = @('--root', $rootAbs, '--standards', (Resolve-UserPath $opt.standards))
        # Records the failure of step $N of standard $Std and stops
        function Stop-Finish([int]$N, [string]$Std, [string]$Message) {
            [void](Invoke-Child $PSCommandPath (@('set') + $stdArgs + @('--step', "$N", '--standard', $Std, '--state', 'failed', '--message', $Message)))
            Write-Output "step $N ($Std) failed: $Message"
            Write-Output "details: $(P "step$N/$Std/errors.log")"
            Write-Output 'next: run next'
            exit 1
        }
        # Each standard in turn; the standards whose report is already published are kept.
        foreach ($n in $stds) {
            if ((Get-UnitState "5-$n") -eq 'success') { continue }
            [void](Invoke-Child $PSCommandPath (@('set') + $stdArgs + @('--step', '4', '--standard', $n, '--state', 'working')))
            $r = Invoke-Tool 'code-review-scoring-score' 'score' @('-Root', $rootAbs, '-Standards', (Resolve-UserPath $opt.standards), '-Standard', $n, '-Config', $opt.config)
            if ($r.Code -ne 0) {
                [IO.File]::AppendAllText((P "step4/$n/errors.log"), "[$(Get-Now)] score exited $($r.Code):`n$($r.Text)`n", $script:Utf8NoBom)
                if ($r.Code -eq 1) { Stop-Finish 4 $n 'findings.txt failed validation; redo step 3' }
                Stop-Finish 4 $n "scoring exited $($r.Code): $(($r.Text -split "`n")[0])"
            }
            $grade = @($r.Text -split "`n" | Where-Object { $_.StartsWith('grade ') })[0]
            [void](Invoke-Child $PSCommandPath (@('set') + $stdArgs + @('--step', '4', '--standard', $n, '--state', 'success', '--message', $grade)))
            [void](Invoke-Child $PSCommandPath (@('set') + $stdArgs + @('--step', '5', '--standard', $n, '--state', 'working')))
            $rr = Invoke-Tool 'code-review-scoring-report' 'render-report' @('-Root', $rootAbs, '-Standard', $n, '-Config', $opt.config)
            if ($rr.Code -ne 0) {
                [IO.File]::AppendAllText((P "step5/$n/errors.log"), "[$(Get-Now)] render-report exited $($rr.Code):`n$($rr.Text)`n", $script:Utf8NoBom)
                Stop-Finish 5 $n "render-report exited $($rr.Code): $(($rr.Text -split "`n")[0])"
            }
            $sr = Invoke-Child $PSCommandPath (@('set') + $stdArgs + @('--step', '5', '--standard', $n, '--state', 'success', '--message', 'report published'))
            if ($sr.Code -ne 0) {
                [IO.File]::AppendAllText((P "step5/$n/errors.log"), "[$(Get-Now)] $($sr.Text)`n", $script:Utf8NoBom)
                Stop-Finish 5 $n (($sr.Text -split "`n")[0])
            }
            Write-Output "steps 4 and 5 ($n): success"
            $r.Text -split "`n" | Where-Object { $_ -and -not $_.StartsWith('wrote ') } | ForEach-Object { Write-Output $_ }
            Write-Output "report: $((Read-Utf8Lines (P "step5/$n/report-path.txt"))[0].Trim())"
        }
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
        Write-Output 'next: run next'
    }
    'prompt' {
        $n = Test-Step
        if ($n -gt 3) { Exit-WithError 'steps 4 and 5 have no prompt; run finish' }
        Assert-Review
        Assert-Previous $n $opt.standard
        if ($n -gt $CR) { Assert-StdGate $opt.standard }
        [Console]::Out.Write((Get-Prompt $n $opt.plugin $opt.standard ($null -ne $opt.inline)))
    }
    'set' {
        $n = Test-Step; Assert-Review
        $state = $opt.state; $message = $opt.message
        if ($state -cnotin $states) { Exit-WithError '--state must be working, pending, success or failed' }
        $std = $opt.standard
        $unit = "$n"; $label = "step $n"
        if ($n -eq $CR) { $unit = "$CR-$($opt.plugin)"; $label = "step $CR plugin $($opt.plugin)" }
        if ($n -gt $CR) {
            $unit = "$n-$std"; $label = "step $n ($std)"
            if ($state -in 'working', 'success') { Assert-StdGate $std }
        }
        $cur = Get-UnitState $unit
        $d = Get-UnitDir $unit
        switch ($state) {
            'working' {
                Assert-Previous $n $std
                # Later steps start over: every unit of them, or only the same standard's after steps 3 and 4.
                for ($k = $n + 1; $k -le 5; $k++) { if ($n -gt $CR) { Clear-Unit "$k-$std" } else { Clear-Step $k } }
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
                        if (-not (Test-NonEmpty 'step1/standards/plan.tsv')) { Stop-Refused "missing ${stdPlan}: the review was not planned; check configs/standards.ini (setup check), then run standard plan --diff `"$(P "$d/pr.diff")`" --out `"$(P "$d/standards")`" of code-review-scoring and add its confirm.tsv to the Severity facts of spec-context.md" }
                        Write-RequestStandards
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
                        $r = Invoke-Tool 'code-review-scoring-score' 'score' @('-Root', $rootAbs, '-Standards', (Resolve-UserPath $opt.standards), '-Standard', $std, '-Config', $opt.config, '-Check')
                        if ($r.Code -ne 0) { Stop-Refused "findings.txt does not pass the scoring checks; fix it, then set success again:`n$($r.Text)" }
                    }
                    4 {
                        foreach ($f in 'score.tsv', 'score.json') {
                            if (-not (Test-NonEmpty "$d/$f")) { Stop-Refused "missing $(P "$d/$f")" }
                            if (-not (Test-NotOlder "$d/$f" "step3/$std/findings.txt")) { Stop-Refused "$d/$f is older than step3/$std/findings.txt; rerun scoring" }
                        }
                    }
                    5 {
                        if (-not (Test-NonEmpty "$d/report.md")) { Stop-Refused "missing $(P "$d/report.md")" }
                        if (-not (Test-NotOlder "$d/report.md" "step4/$std/score.tsv")) { Stop-Refused "report.md is older than step4/$std/score.tsv; render again" }
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
            if (@('workflow', 'language') -contains $platform) { Exit-WithError "$platform is reserved and cannot be a platform name" }
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
