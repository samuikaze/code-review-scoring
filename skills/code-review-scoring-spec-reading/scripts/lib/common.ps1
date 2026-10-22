# Shared helpers for the PowerShell scripts of this skill.
# Saved as UTF-8 with BOM so Windows PowerShell 5.1 reads non-ASCII text correctly. Keep the BOM when editing.

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Initialize-Utf8 {
    # Windows consoles default to the system code page (e.g. CP950). Switch to UTF-8 so that
    # console output, decoding of git output, and text piped to native programs all use UTF-8.
    try { [Console]::OutputEncoding = $script:Utf8NoBom } catch { }
    try { [Console]::InputEncoding = $script:Utf8NoBom } catch { }
    $global:OutputEncoding = $script:Utf8NoBom
}

function Exit-WithError([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("error: $Message")
    exit $Code
}

function Resolve-UserPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-ProjectRoot([string]$SkillDir) {
    # The project root, two levels above the physical skill folder, holds tmp/, reports/, configs/plugins.ini and configs/settings.ini.
    # The skill folder may be a junction or symlink (e.g. .agents/skills/...), so resolve it first.
    $item = Get-Item -LiteralPath $SkillDir -Force
    $path = $item.FullName
    if ($item.LinkType -and $item.Target) {
        $t = @($item.Target)[0]
        if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $SkillDir) $t }
        $path = [IO.Path]::GetFullPath($t)
    }
    return Split-Path -Parent (Split-Path -Parent $path)
}

function Test-UserFile([string]$Path) {
    return [IO.File]::Exists((Resolve-UserPath $Path))
}

function Read-Utf8Text([string]$Path) {
    $full = Resolve-UserPath $Path
    if (-not [IO.File]::Exists($full)) { Exit-WithError "file not found: $Path" }
    # Always read as UTF-8 (a BOM is skipped automatically); never rely on the system code page.
    return [IO.File]::ReadAllText($full, $script:Utf8NoBom)
}

function Read-Utf8Lines([string]$Path) {
    return (Read-Utf8Text $Path) -split "`r?`n"
}

function Read-StdinText {
    if (-not [Console]::IsInputRedirected) { Exit-WithError 'no input file given and nothing piped to stdin (see Get-Help)' }
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $script:Utf8NoBom)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-DiffText([string]$InputPath, [string]$Git, [string]$Repo = '.') {
    if ($Git) {
        # git output is decoded with [Console]::OutputEncoding (UTF-8 after Initialize-Utf8);
        # core.quotePath=false keeps non-ASCII paths readable instead of octal escapes.
        $lines = & git -C (Resolve-UserPath $Repo) -c core.quotePath=false diff --no-color --no-ext-diff -M $Git
        if ($LASTEXITCODE -ne 0) { Exit-WithError "git diff $Git failed" }
        return ($lines -join "`n") + "`n"
    }
    if (-not $InputPath -or $InputPath -eq '-') { return Read-StdinText }
    return Read-Utf8Text $InputPath
}

function Write-Utf8File([string]$Path, [string]$Text) {
    # Write UTF-8 without BOM. Out-File / Set-Content in Windows PowerShell 5.1 default to other encodings.
    [IO.File]::WriteAllText((Resolve-UserPath $Path), $Text, $script:Utf8NoBom)
}

function Write-Utf8Output([string]$Text, [string]$Out) {
    if ($Out) {
        Write-Utf8File $Out $Text
        Write-Output "wrote $Out ($([regex]::Matches($Text, "`n").Count) lines)"
    }
    else {
        [Console]::Out.Write($Text)
    }
}

# The standard of a review with a plan (ROOT/step1/standards/plan.tsv, written in step 1 of the workflow): the name
# given, or the only one planned. Returns '' without a plan; exits 2 when the name is missing or not planned.
function Get-PlanStandard([string]$Root, [string]$Standard) {
    $plan = Join-Path $Root 'step1/standards/plan.tsv'
    if (-not (Test-UserFile $plan)) { return '' }
    $reports = @(Read-Utf8Lines $plan | ForEach-Object { $a = $_.Split("`t"); if ($a[0] -ceq 'report') { $a[1] } })
    if (-not $Standard) {
        if ($reports.Count -ne 1) { Exit-WithError "several standards score this review (see $plan); pass -Standard NAME" }
        $Standard = $reports[0]
    }
    if ($reports -cnotcontains $Standard) { Exit-WithError "the standard $Standard does not score this review (see $plan)" }
    return $Standard
}

# Whether a code review comment with these locations belongs to the standard of the review plan: one of its files is a
# file of the standard, or none of its files is in the plan (a comment on the whole PR, location -) and the standard is
# the first report. Without a standard every comment belongs to it.
function Test-CommentOwner([string]$Plan, [string]$Standard, [string]$Locations) {
    if (-not $Standard) { return $true }
    if ($script:planKey -cne "$Plan|$Standard") {
        $script:planFirst = ''; $script:planAny = [hashtable]::new([StringComparer]::Ordinal); $script:planMine = [hashtable]::new([StringComparer]::Ordinal)
        foreach ($l in (Read-Utf8Lines $Plan)) {
            $a = $l.Split("`t")
            if ($a[0] -ceq 'report' -and -not $script:planFirst) { $script:planFirst = $a[1] }
            elseif ($a[0] -ceq 'file') { $script:planAny[$a[1]] = 1; if ($a[2] -ceq $Standard) { $script:planMine[$a[1]] = 1 } }
        }
        $script:planKey = "$Plan|$Standard"
    }
    $any = $false
    foreach ($p in $Locations.Split(',')) {
        $f = $p.Trim(' ', "`t") -creplace ':[0-9][-0-9]*$', ''
        if ($script:planMine.ContainsKey($f)) { return $true }
        if ($script:planAny.ContainsKey($f)) { $any = $true }
    }
    return (-not $any -and $Standard -ceq $script:planFirst)
}

# The folder of the report language under templates/ in the project root: the only folder that holds a
# report-template.md (templates/ itself or one templates/<language>/), or, with several, the one [language] report of
# the settings names (default zh-tw). Exits 2 when there is none or the language has no folder.
function Get-ReportTemplateDir([string]$ProjectRoot, [string]$Config) {
    $t = Join-Path $ProjectRoot 'templates'
    $dirs = New-Object System.Collections.Generic.List[string]; $names = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath (Join-Path $t 'report-template.md') -PathType Leaf) { $dirs.Add($t); $names.Add('templates/') }
    if (Test-Path -LiteralPath $t -PathType Container) {
        foreach ($d in (Get-ChildItem -LiteralPath $t -Directory | Sort-Object Name)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'report-template.md') -PathType Leaf) { $dirs.Add($d.FullName); $names.Add($d.Name) }
        }
    }
    if ($dirs.Count -eq 0) { Exit-WithError "no report template (report-template.md) in $t" }
    if ($dirs.Count -eq 1) { return $dirs[0] }
    $want = ''
    if ($Config -and (Test-UserFile $Config)) {
        $sec = ''
        foreach ($l in (Read-Utf8Lines $Config)) {
            if ($l -cmatch '^[ \t]*\[(.*)\][ \t\r]*$') { $sec = $Matches[1]; continue }
            if ($sec -ceq 'language' -and $l -cmatch '^[ \t]*report[ \t]*=[ \t]*(.*?)[ \t\r]*$') { $want = $Matches[1] -replace '^"|"$', '' }
        }
    }
    if (-not $want) { $want = 'zh-tw' }
    $i = $names.IndexOf($want)
    if ($i -lt 0) { Exit-WithError "no report template for the language `"$want`" ([language] report of $Config); available: $($names -join ' ')" }
    return $dirs[$i]
}
