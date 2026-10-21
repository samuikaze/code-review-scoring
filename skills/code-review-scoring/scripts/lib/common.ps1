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
