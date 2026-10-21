<#
.SYNOPSIS
Checks and parses scoring standards: the Markdown documents and scan rule files listed in configs/standards.ini.

.DESCRIPTION
"lint" is for the people who write standards and runs only when they ask for it; the scoring workflow uses
"parse", which prints nothing about the format unless the document is broken.
Uses the same GNU-style arguments as standard.sh:

  standard.ps1 lint [--standards FILE] [--settings FILE] [NAME ...]
  standard.ps1 lint --file DOC.md [--scan RULES.tsv] [--common]
      check configs/standards.ini and the documents and scan rule files it lists (only the NAMEs given),
      or one document that is not registered yet (--file). Prints what was parsed, then the errors and
      warnings with file and line. Regexes are compiled with .NET, and with awk when it is installed
  standard.ps1 parse --file DOC.md [--common]
      print the parsed document as TAB-separated records (name, version, dim, check, confirm);
      stops at the first format error (exit 3)
  standard.ps1 diff OLD.md NEW.md
      list the dimensions, check items and confirmations that differ between two versions of a document
  standard.ps1 resolve [--standards FILE] [--settings FILE] [NAME]
      for score: the standard NAME (default: the only framework standard, or the common one when there is
      none) and the common standard, as TAB-separated records: "standard" / "common" (name, version,
      sha256, path), "applies" (the regex of the files of NAME), "scan" (path, sha256 of the scan rules),
      "points" (the overrides of NAME) and the "check" records of each document.
      Stops when standards.ini or a document has a format error (exit 3)

Options: --standards FILE  (default: configs/standards.ini in the project root)
         --settings FILE   (default: configs/settings.ini in the project root; its [points] are checked with the overrides)
         --common          the document is the common standard (its check codes start with CM-)

Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok (warnings allowed), 1 lint found errors, 2 bad arguments or unknown NAME, 3 standards.ini or the document
has a format error or is missing.
#>

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/common.ps1')
. (Join-Path $PSScriptRoot 'lib/standard.ps1')
Initialize-Utf8

$skillDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Get-ProjectRoot $skillDir
$awkLib = Join-Path $PSScriptRoot 'lib/standard.awk'

$argv = @($args)
if ($argv.Count -eq 0) { Get-Help $PSCommandPath -Detailed; exit 2 }
if ($argv[0] -in '-h', '--help') { Get-Help $PSCommandPath -Detailed; exit 0 }
$cmd = [string]$argv[0]
$opt = @{ standards = (Join-Path $projectRoot 'configs/standards.ini'); settings = (Join-Path $projectRoot 'configs/settings.ini')
    file = ''; scan = ''; role = '' }
$names = @()
$i = 1
while ($i -lt $argv.Count) {
    $a = [string]$argv[$i]
    if ($a -in '--standards', '--settings', '--file', '--scan') {
        if ($i + 1 -ge $argv.Count) { Exit-WithError "$a needs a value" }
        $opt[$a.Substring(2)] = [string]$argv[$i + 1]; $i += 2
    }
    elseif ($a -eq '--common') { $opt.role = 'common'; $i++ }
    elseif ($a -in '-h', '--help') { Get-Help $PSCommandPath -Detailed; exit 0 }
    elseif ($a.StartsWith('-', [StringComparison]::Ordinal)) { Exit-WithError "unknown option $a (see Get-Help)" }
    else { $names += $a; $i++ }
}

$script:nerr = 0; $script:nwarn = 0
function Write-Line([string]$Text) { [Console]::WriteLine($Text) }
function Get-Full([string]$Path) { return [IO.Path]::GetFullPath((Resolve-UserPath $Path)) }
function Get-Field([string[]]$Lines, [string]$Key) {
    foreach ($l in $Lines) { $a = $l.Split("`t"); if ($a[0] -ceq $Key) { return $a[1] } }
    return ''
}
function Add-Problem([string]$Kind, [string]$Text) {
    if ($Kind -eq 'error') { $script:nerr++ } else { $script:nwarn++ }
    Write-Line "${Kind}: $Text"
}
# Prints the diagnostics of a parser run ($Shown = file shown in the messages) and counts them.
function Write-Report([string]$Shown, [string[]]$Lines) {
    foreach ($l in $Lines) {
        $a = $l.Split("`t")
        if ($a[0] -cne '!error' -and $a[0] -cne '!warn') { continue }
        $at = if ($a[1] -ne '') { ":$($a[1])" } else { '' }
        if ($a[0] -ceq '!error') { $script:nerr++; Write-Line "error: $Shown${at}: $($a[2])" }
        else { $script:nwarn++; Write-Line "warning: $Shown${at}: $($a[2])" }
    }
}
# Paths in standards.ini: relative paths are relative to its folder.
function Resolve-StdPath([string]$Path, [string]$Base) {
    if ($Path -eq '-' -or $Path -eq '') { return '' }
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Base $Path }
    return Get-Full $Path
}

# Compiles every queued regex ("!re" records of $Shown) with awk when it is installed, and with .NET.
function Test-StdRegex([string]$Shown, [string[]]$Re) {
    if ($Re.Count -eq 0) { return }
    $awk = Get-Command awk -CommandType Application -ErrorAction SilentlyContinue
    if ($awk) {
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, (($Re -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; $env:LC_ALL = 'C'
            try {
                & $awk.Source -v mode=re -f $awkLib $tmp 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    for ($n = 1; $n -le $Re.Count; $n++) {
                        & $awk.Source -v mode=re -v only=$n -f $awkLib $tmp 2>&1 | Out-Null
                        if ($LASTEXITCODE -ne 0) { $a = $Re[$n - 1].Split("`t"); Add-Problem 'error' "${Shown}:$($a[1]): the regex does not compile in awk: $($a[2])" }
                    }
                }
            }
            finally { $ErrorActionPreference = $prev; Remove-Item Env:LC_ALL -ErrorAction SilentlyContinue }
        }
        finally { [IO.File]::Delete($tmp) }
    }
    foreach ($r in $Re) {
        $a = $r.Split("`t")
        try { [void][regex]::new($a[2]) } catch { Add-Problem 'error' "${Shown}:$($a[1]): the regex does not compile in .NET: $($a[2])" }
    }
}

# Lints one document and its scan rule file; $Want = the section name it must have ('' = any).
function Test-StdDoc([string]$Want, [string]$Doc, [string]$Role, [string]$Scan) {
    if (-not [IO.File]::Exists($Doc)) { Add-Problem 'error' "${Doc}: file not found"; return }
    $out = Invoke-StdDoc $Doc $Role
    $name = Get-Field $out 'name'
    $st = ''
    foreach ($l in $out) { $a = $l.Split("`t"); if ($a[0] -ceq 'stats') { $st = "$($a[1]) check items ($($a[2])), $($a[3]) adjustable, $($a[4]) confirmations" } }
    Write-Line "document: $(if ($name) { $name } else { '?' }) $(Get-Field $out 'version'), $st"
    Write-Report $Doc $out
    if ($Want -and $name -and $name -cne $Want) { Add-Problem 'error' "${Doc}: the front matter name $name does not match the section [$Want] in standards.ini" }
    if (-not $Scan) { return }
    if (-not [IO.File]::Exists($Scan)) { Add-Problem 'error' "${Scan}: file not found"; return }
    $sc = Invoke-StdScan $Scan $out
    foreach ($l in $sc) { $a = $l.Split("`t"); if ($a[0] -ceq 'stats') { Write-Line "scan rules: $($a[1]) line rules, $($a[2]) scopes, $($a[3]) PR hints" } }
    Write-Report $Scan $sc
    Test-StdRegex $Scan @($sc | Where-Object { $_.StartsWith("!re`t", [StringComparison]::Ordinal) })
    $src = $sc | Where-Object { $_.StartsWith("!source`t", [StringComparison]::Ordinal) } | Select-Object -First 1
    if ($src) {
        $a = $src.Split("`t")
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $Doc).Hash.ToLowerInvariant()
        if ($a[4] -cne $h) { Add-Problem 'warning' "${Scan}:$($a[1]): the scan rules were made from $($a[2]) $($a[3]), and the document has changed since; regenerate them or run the review mode" }
    }
}

# Parses a document for parse and diff; stops with exit 3 at the first format error.
function Get-ParsedDoc([string]$Doc, [string]$Role) {
    if (-not (Test-UserFile $Doc)) { Exit-WithError "file not found: $Doc" }
    $out = Invoke-StdDoc (Resolve-UserPath $Doc) $Role
    foreach ($l in $out) {
        $a = $l.Split("`t")
        if ($a[0] -ceq '!error') {
            $at = if ($a[1] -ne '') { ":$($a[1])" } else { '' }
            [Console]::Error.WriteLine("error: $Doc${at}: $($a[2]); run standard lint first"); exit 3
        }
    }
    return , @($out | Where-Object { -not $_.StartsWith('!', [StringComparison]::Ordinal) -and -not $_.StartsWith("stats`t", [StringComparison]::Ordinal) })
}

switch ($cmd) {
    'lint' {
        if ($opt.file) {
            $scanFull = if ($opt.scan) { Get-Full $opt.scan } else { '' }
            Test-StdDoc '' (Get-Full $opt.file) $opt.role $scanFull
        }
        else {
            if ($opt.scan -or $opt.role) { Exit-WithError '--scan and --common go with --file' }
            $standards = Get-Full $opt.standards
            Write-Line "== $standards"
            if (-not [IO.File]::Exists($standards)) {
                Add-Problem 'error' "${standards}: file not found; copy configs/standards.example.ini to configs/standards.ini"
            }
            else {
                $base = Split-Path -Parent $standards
                $ini = Invoke-StdIni $standards (Resolve-UserPath $opt.settings)
                Write-Report $standards $ini
                $records = @($ini | Where-Object { $_.StartsWith("std`t", [StringComparison]::Ordinal) } | ForEach-Object { , $_.Split("`t") })
                foreach ($n in $names) {
                    if (-not ($records | Where-Object { $_[1] -ceq $n })) { Add-Problem 'error' "${standards}: [$n] is not registered" }
                }
                foreach ($r in $records) {
                    if ($names.Count -gt 0 -and $r[1] -cnotin $names) { continue }
                    if ($r[3] -ceq '-') { continue }
                    $dpath = Resolve-StdPath $r[3] $base; $scan = Resolve-StdPath $r[4] $base
                    Write-Line ''
                    Write-Line "== [$($r[1])] $dpath"
                    Test-StdDoc $r[1] $dpath $(if ($r[5] -ceq '-') { '' } else { $r[5] }) $scan
                }
            }
        }
        Write-Line ''
        Write-Line "result: $($script:nerr) error(s), $($script:nwarn) warning(s)"
        if ($script:nerr -gt 0) { exit 1 }
    }
    'parse' {
        if (-not $opt.file) { Exit-WithError 'parse needs --file DOC.md' }
        $out = Get-ParsedDoc $opt.file $opt.role
        [Console]::Out.Write((($out -join "`n") + "`n"))
    }
    'diff' {
        if ($names.Count -ne 2) { Exit-WithError 'diff needs OLD.md NEW.md' }
        $old = Get-ParsedDoc $names[0] $opt.role
        $new = Get-ParsedDoc $names[1] $opt.role
        foreach ($l in (Invoke-StdDiff $old $new)) { Write-Line $l }
    }
    'resolve' {
        if ($names.Count -gt 1) { Exit-WithError 'resolve takes at most one NAME' }
        $standards = Get-Full $opt.standards
        if (-not [IO.File]::Exists($standards)) {
            [Console]::Error.WriteLine("error: ${standards}: file not found; copy configs/standards.example.ini to configs/standards.ini"); exit 3
        }
        $base = Split-Path -Parent $standards
        $ini = Invoke-StdIni $standards (Resolve-UserPath $opt.settings)
        foreach ($l in $ini) {
            $a = $l.Split("`t")
            if ($a[0] -ceq '!error') {
                $at = if ($a[1] -ne '') { ":$($a[1])" } else { '' }
                [Console]::Error.WriteLine("error: $standards${at}: $($a[2]); run standard lint first"); exit 3
            }
        }
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($l in $ini) { if ($l.StartsWith("std`t", [StringComparison]::Ordinal)) { $records.Add($l.Split("`t")) } }
        $want = if ($names.Count -eq 1) { [string]$names[0] } else { '' }
        $common = $null; $frameworks = New-Object System.Collections.Generic.List[string]
        foreach ($r in $records) { if ($r[5] -ceq 'common') { $common = $r } else { $frameworks.Add($r[1]) } }
        if (-not $want) {
            # Without a NAME: the only framework standard, or the common one when there is no framework standard.
            if ($frameworks.Count -gt 1) { Exit-WithError "${standards}: several standards are registered ($($frameworks -join ', ')); pick one by name" }
            elseif ($frameworks.Count -eq 1) { $want = $frameworks[0] }
            elseif ($common) { $want = $common[1] }
            else { Exit-WithError "${standards}: no standard is registered" }
        }
        # The standard itself first, then the common standard (when it is another one); each with its check items.
        $pick = New-Object System.Collections.Generic.List[object]
        foreach ($r in $records) { if ($r[1] -ceq $want) { $pick.Add($r) } }
        if ($pick.Count -eq 0) { Exit-WithError "${standards}: [$want] is not registered" }
        if ($common -and $common[1] -cne $want) { $pick.Add($common) }
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $pick) {
            $dpath = Resolve-StdPath $r[3] $base
            if (-not [IO.File]::Exists($dpath)) { [Console]::Error.WriteLine("error: ${dpath}: file not found; run standard lint first"); exit 3 }
            $out = Invoke-StdDoc $dpath $(if ($r[5] -ceq '-') { '' } else { $r[5] })
            foreach ($l in $out) {
                $a = $l.Split("`t")
                if ($a[0] -ceq '!error') {
                    $at = if ($a[1] -ne '') { ":$($a[1])" } else { '' }
                    [Console]::Error.WriteLine("error: $dpath${at}: $($a[2]); run standard lint first"); exit 3
                }
            }
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $dpath).Hash.ToLowerInvariant()
            $kind = if ($r[1] -ceq $want) { 'standard' } else { 'common' }
            [void]$sb.Append("$kind`t$($r[1])`t$(Get-Field $out 'version')`tsha256:$h`t$dpath`n")
            if ($r[1] -ceq $want) {
                foreach ($l in $ini) { $a = $l.Split("`t"); if ($a[0] -ceq 'applies' -and $a[1] -ceq $want) { [void]$sb.Append("applies`t$($a[2])`n") } }
            }
            if ($r[4] -cne '-') {
                $spath = Resolve-StdPath $r[4] $base
                if (-not [IO.File]::Exists($spath)) { [Console]::Error.WriteLine("error: ${spath}: file not found; run standard lint first"); exit 3 }
                [void]$sb.Append("scan`t$spath`tsha256:$((Get-FileHash -Algorithm SHA256 -LiteralPath $spath).Hash.ToLowerInvariant())`n")
            }
            if ($r[1] -ceq $want) {
                foreach ($l in $ini) { $a = $l.Split("`t"); if ($a[0] -ceq 'points' -and $a[1] -ceq $want) { [void]$sb.Append("points`t$($a[2])`t$($a[3])`n") } }
            }
            foreach ($l in $out) { if ($l.StartsWith("check`t", [StringComparison]::Ordinal)) { [void]$sb.Append("$l`n") } }
        }
        [Console]::Out.Write($sb.ToString())
    }
    default { Exit-WithError "unknown command $cmd (see Get-Help)" }
}
