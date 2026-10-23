<#
.SYNOPSIS
Checks and parses scoring standards: the rules project that [rules] root of configs/settings.ini names (rules.ini,
defaults.ini and the rule.ini, Markdown document and scan rule file of each rule).

.DESCRIPTION
"lint" is for the people who write standards and runs only when they ask for it; the scoring workflow uses
"parse", which prints nothing about the format unless the document is broken.
Uses the same GNU-style arguments as standard.sh:

  standard.ps1 lint [--settings FILE] [NAME ...]
  standard.ps1 lint --file DOC.md [--scan RULES.tsv] [--common]
      check the rules project: rules.ini, defaults.ini and the rule.ini, document and scan rule file of every
      rule (only the NAMEs given), or one document that is not registered yet (--file; its severities are
      checked against the rule.ini in its folder, or defaults.ini). Prints what was parsed, then the errors and
      warnings with file and line. Regexes are compiled with .NET, and with awk when it is installed
  standard.ps1 parse --file DOC.md [--common]
      print the parsed document as TAB-separated records (name, version, dim, check, confirm);
      stops at the first format error (exit 3)
  standard.ps1 diff OLD.md NEW.md
      list the dimensions, check items and confirmations that differ between two versions of a document
  standard.ps1 resolve [--settings FILE] [NAME]
      for score: the enabled rule NAME (default: the only enabled framework rule, or the common one when there
      is none) and the enabled common rule, as TAB-separated records: "standard" / "common" (name, version,
      sha256, path of the document), "ruleini" (path, sha256), "applies" (the regex of the files of NAME), "scan"
      (path, sha256 of the scan rules), "points" (dimension, points), "merge", "severity" (code, points, cap,
      display name, meaning with its lines separated by |; from the most severe), "grade" (code, min, display
      name; from the highest), "cseverity" (code, display name, meaning of the common rule's scale), the "check"
      records of each document
      and "defaults" (path, sha256 of defaults.ini).
      Stops when the rules project or a document has a format error (exit 3)
  standard.ps1 plan --diff PR.diff --out DIR [--settings FILE]
      for the review workflow: the enabled rules that score the PR. Each file goes to the framework rule whose
      applies covers it; the other files are common files, scored with the common rule in the report of their
      project (the framework of the nearest folder above them; every report when that is unclear), or on their
      own when no framework file changed. Writes DIR/plan.tsv ("report" name and file count, "file" path,
      report and kind framework|common|none), DIR/<name>.diff and DIR/<name>.resolve (the resolve output) for
      each report, and DIR/confirm.tsv (standard, check codes, what to confirm before scoring)
  standard.ps1 stamp --file DOC.md --scan DRAFT.tsv --out RULES.tsv [--common]
      write a reviewed scan rule file (--scan, e.g. a draft) to --out with the source line
      "# source: <document file> <version> sha256:<hash>" of the document (--file), so lint can tell when the
      document changes later; an existing source line is replaced

The rules project: [rules] root of the settings names its folder (relative to the folder of the settings file). It
holds rules.ini (one [name] section per rule: path = the folder of its rule.ini, enable = true|false), defaults.ini
(the points, severities and grades of the rules that do not set their own) and a folder per rule with rule.ini
([rule] standard = the Markdown document, scan = the scan rule file, applies, role = common), the document and the
scan rules.

Options: --settings FILE   (default: configs/settings.ini in the project root; its [rules] root names the rules project)
         --common          the document is the common standard (its check codes start with CM-)

Works on Windows PowerShell 5.1 and PowerShell 7+. Saved as UTF-8 with BOM; keep that encoding.
Exit codes: 0 ok (warnings allowed), 1 lint found errors, 2 bad arguments, unknown or disabled NAME, 3 the rules
project or the document has a format error or is missing.
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
$opt = @{ settings = (Join-Path $projectRoot 'configs/settings.ini'); file = ''; scan = ''; role = ''; diff = ''; out = '' }
$names = @()
$i = 1
while ($i -lt $argv.Count) {
    $a = [string]$argv[$i]
    if ($a -in '--settings', '--file', '--scan', '--diff', '--out') {
        if ($i + 1 -ge $argv.Count) { Exit-WithError "$a needs a value" }
        $opt[$a.Substring(2)] = [string]$argv[$i + 1]; $i += 2
    }
    elseif ($a -eq '--standards') { Exit-WithError '--standards was removed: the rules come from [rules] root of the settings (--settings)' }
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
function Get-Sha([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Add-Problem([string]$Kind, [string]$Text) {
    if ($Kind -eq 'error') { $script:nerr++ } else { $script:nwarn++ }
    Write-Line "${Kind}: $Text"
}
# "FILE:LINE: message" of a diagnostic record ($Shown = the file when the record names none).
function Get-DiagText([string]$Shown, [string[]]$a) {
    $f = if ($a.Count -ge 4 -and $a[3] -ne '') { $a[3] } else { $Shown }
    $at = if ($a[1] -ne '') { ":$($a[1])" } else { '' }
    return "$f${at}: $($a[2])"
}
# The first error of a parser run as "FILE:LINE: message", or ''.
function Get-FirstError([string]$Shown, [string[]]$Lines) {
    foreach ($l in $Lines) { $a = $l.Split("`t"); if ($a[0] -ceq '!error') { return Get-DiagText $Shown $a } }
    return ''
}
# Prints the diagnostics of a parser run ($Shown = file shown when the record names none) and counts them.
function Write-Report([string]$Shown, [string[]]$Lines) {
    foreach ($l in $Lines) {
        $a = $l.Split("`t")
        if ($a[0] -ceq '!error') { $script:nerr++; Write-Line "error: $(Get-DiagText $Shown $a)" }
        elseif ($a[0] -ceq '!warn') { $script:nwarn++; Write-Line "warning: $(Get-DiagText $Shown $a)" }
    }
}
# A path of the rules project as the parser wrote it, made absolute ('' for -).
function Get-PathOf([string]$Path) { if ($Path -eq '-' -or $Path -eq '') { return '' } return Get-Full $Path }

# The rules project: [rules] root of the settings, relative to the folder of the settings file. Returns
# @($true, its folder) or @($false, the reason it cannot be used).
function Get-RulesRoot([string]$Settings) {
    if (-not [IO.File]::Exists($Settings)) { return @($false, "${Settings}: file not found; run setup check") }
    $insec = $false; $v = ''
    foreach ($l in (Read-StdLines $Settings)) {
        if ($l -cmatch '^[ \t]*\[') { $h = $l -creplace '^[ \t]*\[|\][ \t]*$', ''; $insec = ($h -ceq 'rules'); continue }
        if ($insec -and $l -cmatch '^[ \t]*root[ \t]*=') { $v = (($l -creplace '^[^=]*=[ \t]*', '') -creplace '[ \t]*$', '') -creplace '^"|"$', '' }
    }
    if ($v -eq '') { return @($false, "${Settings}: [rules] root is not set; set it to the folder of the code-review-scoring-rules project") }
    $v = $v.Replace('\', '/')
    if (-not (Test-StdAbs $v)) { $v = (Split-Path -Parent $Settings) + '/' + $v }
    if (-not [IO.Directory]::Exists($v)) { return @($false, "${Settings}: [rules] root $v is not a folder") }
    return @($true, ([IO.Path]::GetFullPath($v).TrimEnd('\', '/').Replace('\', '/')))
}
# Reads the rules project of the settings: @($true, its folder, the parser output) or @($false, the reason).
function Read-Rules([string]$Settings) {
    $rr = Get-RulesRoot $Settings
    if (-not $rr[0]) { return $rr }
    return @($true, $rr[1], (Invoke-StdRules "$($rr[1])/rules.ini" $rr[1] "$($rr[1])/defaults.ini"))
}
# Like Read-Rules, for the commands that need a valid rules project: prints the first error and exits 3.
function Get-NeedRules([string]$Settings) {
    $r = Read-Rules $Settings
    if (-not $r[0]) { [Console]::Error.WriteLine("error: $($r[1])"); exit 3 }
    $e = Get-FirstError "$($r[1])/rules.ini" $r[2]
    if ($e) { [Console]::Error.WriteLine("error: $e; run standard lint first"); exit 3 }
    return $r
}
# The std records of the parser output, split into fields.
function Get-StdRecords([string[]]$Ini) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($l in $Ini) { if ($l.StartsWith("std`t", [StringComparison]::Ordinal)) { $list.Add($l.Split("`t")) } }
    return , $list.ToArray()
}
# The severity codes of the rule $Name, from the most severe.
function Get-SevsOf([string[]]$Ini, [string]$Name) {
    return , @($Ini | ForEach-Object { $a = $_.Split("`t"); if ($a[0] -ceq 'severity' -and $a[1] -ceq $Name) { $a[2] } })
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

# Lints one document and its scan rule file; $Want = the rule name it must have ('' = any), $Sevs = the severity
# codes of its scale (empty = not checked).
function Test-StdDoc([string]$Want, [string]$Doc, [string]$Role, [string]$Scan, [string[]]$Sevs) {
    if (-not [IO.File]::Exists($Doc)) { Add-Problem 'error' "${Doc}: file not found"; return }
    $out = Invoke-StdDoc $Doc $Role $Sevs
    $name = Get-Field $out 'name'
    $st = ''
    foreach ($l in $out) { $a = $l.Split("`t"); if ($a[0] -ceq 'stats') { $st = "$($a[1]) check items ($($a[2])), $($a[3]) adjustable, $($a[4]) confirmations" } }
    Write-Line "document: $(if ($name) { $name } else { '?' }) $(Get-Field $out 'version'), $st"
    Write-Report $Doc $out
    if ($Want -and $name -and $name -cne $Want) { Add-Problem 'error' "${Doc}: the front matter name $name does not match the section [$Want] in rules.ini" }
    if (-not $Scan) { return }
    if (-not [IO.File]::Exists($Scan)) { Add-Problem 'error' "${Scan}: file not found"; return }
    $sc = Invoke-StdScan $Scan $out
    foreach ($l in $sc) { $a = $l.Split("`t"); if ($a[0] -ceq 'stats') { Write-Line "scan rules: $($a[1]) line rules, $($a[2]) scopes, $($a[3]) PR hints" } }
    Write-Report $Scan $sc
    Test-StdRegex $Scan @($sc | Where-Object { $_.StartsWith("!re`t", [StringComparison]::Ordinal) })
    $src = $sc | Where-Object { $_.StartsWith("!source`t", [StringComparison]::Ordinal) } | Select-Object -First 1
    if ($src) {
        $a = $src.Split("`t")
        if ($a[4] -cne (Get-Sha $Doc)) { Add-Problem 'warning' "${Scan}:$($a[1]): the scan rules were made from $($a[2]) $($a[3]), and the document has changed since; regenerate them or run the review mode" }
    }
}

# Parses a document for parse and diff; stops with exit 3 at the first format error.
function Get-ParsedDoc([string]$Doc, [string]$Role) {
    if (-not (Test-UserFile $Doc)) { Exit-WithError "file not found: $Doc" }
    $out = Invoke-StdDoc (Resolve-UserPath $Doc) $Role @()
    $e = Get-FirstError $Doc $out
    if ($e) { [Console]::Error.WriteLine("error: $e; run standard lint first"); exit 3 }
    return , @($out | Where-Object { -not $_.StartsWith('!', [StringComparison]::Ordinal) -and -not $_.StartsWith("stats`t", [StringComparison]::Ordinal) })
}

switch ($cmd) {
    'lint' {
        if ($opt.file) {
            # An unregistered document: the scale of the rule.ini in its folder, or that of defaults.ini.
            $file = Get-Full $opt.file; $sevs = @()
            $rr = Get-RulesRoot (Get-Full $opt.settings)
            if ($rr[0]) {
                $rf = Join-Path (Split-Path -Parent $file) 'rule.ini'
                if (-not [IO.File]::Exists($rf)) { $rf = '' }
                $sevs = Get-StdScale $rf "$($rr[1])/defaults.ini"
            }
            if ($sevs.Count -eq 0) { Add-Problem 'warning' 'no severity scale found (rule.ini next to the document, or defaults.ini of the rules project); severities are not checked' }
            $scanFull = if ($opt.scan) { Get-Full $opt.scan } else { '' }
            Test-StdDoc '' $file $opt.role $scanFull $sevs
        }
        else {
            if ($opt.scan -or $opt.role) { Exit-WithError '--scan and --common go with --file' }
            $settings = Get-Full $opt.settings
            $r = Read-Rules $settings
            if (-not $r[0]) {
                Write-Line "== $settings"
                Add-Problem 'error' $r[1]
            }
            else {
                $rulesIni = "$($r[1])/rules.ini"; $ini = $r[2]
                $records = Get-StdRecords $ini
                Write-Line "== $rulesIni"
                $list = ($records | ForEach-Object { $_[1] + $(if ($_[6] -ceq 'true') { '' } else { ' (disabled)' }) }) -join ', '
                Write-Line "rules: $($records.Count) registered$(if ($records.Count -gt 0) { " ($list)" })"
                Write-Report $rulesIni $ini
                foreach ($n in $names) {
                    if (-not ($records | Where-Object { $_[1] -ceq $n })) { Add-Problem 'error' "${rulesIni}: [$n] is not registered" }
                }
                foreach ($rec in $records) {
                    if ($names.Count -gt 0 -and $rec[1] -cnotin $names) { continue }
                    $name = $rec[1]
                    Write-Line ''
                    Write-Line "== [$name]$(if ($rec[7] -cne '-') { ' ' + (Get-PathOf $rec[7]) })$(if ($rec[6] -cne 'true') { ' (disabled)' })"
                    $src = New-StdMap; $m = ''; $sl = @(); $gl = @()
                    foreach ($l in $ini) {
                        $a = $l.Split("`t")
                        if ($a[1] -cne $name) { continue }
                        if ($a[0] -ceq 'from') { $src[$a[2]] = $a[3] }
                        elseif ($a[0] -ceq 'merge') { $m = $a[2] }
                        elseif ($a[0] -ceq 'severity') { $sl += $a[2] }
                        elseif ($a[0] -ceq 'grade') { $gl += $a[2] }
                    }
                    if ($src['points']) { Write-Line "settings: points ($($src['points'])), severities $($sl -join ', ') ($($src['severities'])), grades $($gl -join ', ') ($($src['grades'])), merge=$m" }
                    if ($rec[3] -ceq '-') { continue }
                    Test-StdDoc $name (Get-PathOf $rec[3]) $(if ($rec[5] -ceq '-') { '' } else { $rec[5] }) (Get-PathOf $rec[4]) (Get-SevsOf $ini $name)
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
    'stamp' {
        if (-not $opt.file -or -not $opt.scan -or -not $opt.out) { Exit-WithError 'stamp needs --file DOC.md --scan DRAFT.tsv --out RULES.tsv' }
        foreach ($f in $opt.file, $opt.scan) { if (-not (Test-UserFile $f)) { Exit-WithError "file not found: $f" } }
        $doc = Get-ParsedDoc $opt.file $opt.role
        $docPath = Get-Full $opt.file
        $src = "# source: $([IO.Path]::GetFileName($docPath)) $(Get-Field $doc 'version') sha256:$(Get-Sha $docPath)"
        # The source line replaces the first existing one (others are dropped), or goes first.
        $lines = New-Object System.Collections.Generic.List[string]
        $done = $false
        foreach ($l in (Read-Utf8Lines $opt.scan)) {
            $l = $l.TrimEnd("`r")
            if ($l.StartsWith('# source:')) { if (-not $done) { $lines.Add($src) }; $done = $true; continue }
            $lines.Add($l)
        }
        while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1]) { $lines.RemoveAt($lines.Count - 1) }
        if (-not $done) { $lines.Insert(0, $src) }
        $outPath = Get-Full $opt.out
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $outPath))
        Write-Utf8File $outPath (($lines -join "`n") + "`n")
        Write-Line "wrote $($outPath.Replace('\', '/'))"
        Write-Line $src
    }
    'diff' {
        if ($names.Count -ne 2) { Exit-WithError 'diff needs OLD.md NEW.md' }
        $old = Get-ParsedDoc $names[0] $opt.role
        $new = Get-ParsedDoc $names[1] $opt.role
        foreach ($l in (Invoke-StdDiff $old $new)) { Write-Line $l }
    }
    'resolve' {
        if ($names.Count -gt 1) { Exit-WithError 'resolve takes at most one NAME' }
        $r = Get-NeedRules (Get-Full $opt.settings)
        $rulesIni = "$($r[1])/rules.ini"; $ini = $r[2]
        $records = Get-StdRecords $ini
        $want = if ($names.Count -eq 1) { [string]$names[0] } else { '' }
        $common = $null; $frameworks = New-Object System.Collections.Generic.List[string]
        foreach ($rec in $records) {
            if ($rec[6] -cne 'true') { continue }
            if ($rec[5] -ceq 'common') { $common = $rec } else { $frameworks.Add($rec[1]) }
        }
        if (-not $want) {
            # Without a NAME: the only enabled framework rule, or the common one when there is no framework rule.
            if ($frameworks.Count -gt 1) { Exit-WithError "${rulesIni}: several rules are enabled ($($frameworks -join ', ')); pick one by name" }
            elseif ($frameworks.Count -eq 1) { $want = $frameworks[0] }
            elseif ($common) { $want = $common[1] }
            else { Exit-WithError "${rulesIni}: no rule is enabled" }
        }
        # The rule itself first, then the enabled common rule (when it is another one); each with its check items.
        $pick = New-Object System.Collections.Generic.List[object]
        foreach ($rec in $records) { if ($rec[1] -ceq $want) { $pick.Add($rec) } }
        if ($pick.Count -eq 0) { Exit-WithError "${rulesIni}: [$want] is not registered" }
        if ($pick[0][6] -cne 'true') { Exit-WithError "${rulesIni}: [$want] is disabled (enable=`"false`")" }
        if ($common -and $common[1] -cne $want) { $pick.Add($common) }
        $sb = New-Object System.Text.StringBuilder
        foreach ($rec in $pick) {
            $name = $rec[1]; $dpath = Get-PathOf $rec[3]; $ruleini = Get-PathOf $rec[7]
            if (-not [IO.File]::Exists($dpath)) { [Console]::Error.WriteLine("error: ${dpath}: file not found; run standard lint first"); exit 3 }
            $out = Invoke-StdDoc $dpath $(if ($rec[5] -ceq '-') { '' } else { $rec[5] }) (Get-SevsOf $ini $name)
            $e = Get-FirstError $dpath $out
            if ($e) { [Console]::Error.WriteLine("error: $e; run standard lint first"); exit 3 }
            $kind = if ($name -ceq $want) { 'standard' } else { 'common' }
            [void]$sb.Append("$kind`t$name`t$(Get-Field $out 'version')`tsha256:$(Get-Sha $dpath)`t$dpath`n")
            [void]$sb.Append("ruleini`t$ruleini`tsha256:$(Get-Sha $ruleini)`n")
            if ($name -ceq $want) {
                foreach ($l in $ini) { $a = $l.Split("`t"); if ($a[0] -ceq 'applies' -and $a[1] -ceq $name) { [void]$sb.Append("applies`t$($a[2])`n") } }
            }
            if ($rec[4] -cne '-') {
                $spath = Get-PathOf $rec[4]
                if (-not [IO.File]::Exists($spath)) { [Console]::Error.WriteLine("error: ${spath}: file not found; run standard lint first"); exit 3 }
                [void]$sb.Append("scan`t$spath`tsha256:$(Get-Sha $spath)`n")
            }
            foreach ($l in $ini) {
                $a = $l.Split("`t")
                if ($a[1] -cne $name) { continue }
                if ($name -ceq $want) {
                    if ($a[0] -ceq 'points') { [void]$sb.Append("points`t$($a[2])`t$($a[3])`n") }
                    elseif ($a[0] -ceq 'merge') { [void]$sb.Append("merge`t$($a[2])`n") }
                    elseif ($a[0] -ceq 'severity') { [void]$sb.Append("severity`t$($a[2])`t$($a[3])`t$($a[4])`t$($a[5])`t$($a[6])`n") }
                    elseif ($a[0] -ceq 'grade') { [void]$sb.Append("grade`t$($a[2])`t$($a[3])`t$($a[4])`n") }
                }
                elseif ($a[0] -ceq 'severity') { [void]$sb.Append("cseverity`t$($a[2])`t$($a[5])`t$($a[6])`n") }
            }
            foreach ($l in $out) { if ($l.StartsWith("check`t", [StringComparison]::Ordinal)) { [void]$sb.Append("$l`n") } }
        }
        $d = Get-Field $ini 'defaults'
        [void]$sb.Append("defaults`t$(Get-PathOf $d)`tsha256:$(Get-Sha $d)`n")
        [Console]::Out.Write($sb.ToString())
    }
    'plan' {
        if (-not $opt.diff -or -not $opt.out -or $names.Count -gt 0) { Exit-WithError 'plan needs --diff PR.diff --out DIR' }
        if (-not (Test-UserFile $opt.diff)) { Exit-WithError "diff file not found: $($opt.diff)" }
        $settings = Get-Full $opt.settings
        $ini = (Get-NeedRules $settings)[2]
        $outDir = Get-Full $opt.out
        [void][IO.Directory]::CreateDirectory($outDir)
        foreach ($f in [IO.Directory]::GetFiles($outDir)) { if ($f -match '(\\|/)(plan\.tsv|confirm\.tsv|[^\\/]*\.diff|[^\\/]*\.resolve)$') { [IO.File]::Delete($f) } }
        $plan = Invoke-StdPlan (Resolve-UserPath $opt.diff) $ini $outDir
        foreach ($l in $plan) { if ($l.StartsWith("!error`t", [StringComparison]::Ordinal)) { Exit-WithError "$($opt.diff): $($l.Split("`t")[2])" } }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $confirm = New-Object System.Text.StringBuilder; $done = New-StdMap
        $ver = New-StdMap; $reports = New-Object System.Collections.Generic.List[string]
        foreach ($l in $plan) {
            $a = $l.Split("`t")
            if ($a[0] -cne 'report') { continue }
            $name = $a[1]; $reports.Add($name)
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { $res = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath resolve --settings $settings $name) }
            finally { $ErrorActionPreference = $prev }
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            [IO.File]::WriteAllText((Join-Path $outDir "$name.resolve"), (($res -join "`n") + "`n"), $utf8)
            # The confirmations of the standard, and those of the common standard when the report has common files.
            $hasCommon = $false
            foreach ($x in $plan) { $f = $x.Split("`t"); if ($f[0] -ceq 'file' -and $f[2] -ceq $name -and $f[3] -ceq 'common') { $hasCommon = $true } }
            foreach ($r in $res) {
                $f = $r.Split("`t")
                if ($f[0] -cne 'standard' -and $f[0] -cne 'common') { continue }
                $ver[$f[1]] = $f[2]
                if (($f[0] -ceq 'common' -and -not $hasCommon) -or $done.ContainsKey($f[1])) { continue }
                $done[$f[1]] = 1
                $role = ''
                foreach ($x in $ini) { $g = $x.Split("`t"); if ($g[0] -ceq 'std' -and $g[1] -ceq $f[1] -and $g[5] -ceq 'common') { $role = 'common' } }
                foreach ($c in (Invoke-StdDoc $f[4] $role @())) {
                    $g = $c.Split("`t")
                    if ($g[0] -ceq 'confirm') { [void]$confirm.Append("$($f[1])`t$($g[1])`t$($g[2])`n") }
                }
            }
        }
        [IO.File]::WriteAllText((Join-Path $outDir 'confirm.tsv'), $confirm.ToString(), $utf8)
        [IO.File]::WriteAllText((Join-Path $outDir 'plan.tsv'), (($plan -join "`n") + "`n"), $utf8)
        # Summary: one line per report with its files, then the files no standard scores.
        Write-Line "$($reports.Count) report(s):"
        foreach ($r in $reports) {
            $tot = 0; $c = 0; $x = 0
            foreach ($l in $plan) {
                $a = $l.Split("`t")
                if ($a[0] -ceq 'report' -and $a[1] -ceq $r) { $tot = [int]$a[2] }
                if ($a[0] -ceq 'file' -and $a[2] -ceq $r -and $a[3] -ceq 'common') { $c++ }
                if ($a[0] -ceq 'file' -and $a[2] -ceq $r -and $a[3] -ceq 'none') { $x++ }
            }
            $line = "  - $r $($ver[$r]): $tot file(s)"
            if ($c -gt 0 -and $c -ne $tot) { $line += " ($c scored with the common standard)" }
            if ($x -gt 0) { $line += " ($x not covered by any standard)" }
            Write-Line $line
        }
        Write-Line "wrote $(Join-Path $outDir 'plan.tsv')"
    }
    default { Exit-WithError "unknown command $cmd (see Get-Help)" }
}
