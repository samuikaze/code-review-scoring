# Parser and checks for scoring standards: the PowerShell counterpart of lib/standard.awk.
# Each Invoke-Std* function returns the lines that standard.awk prints in the same mode, in the same order
# (TAB-separated records and "!error" / "!warn" diagnostics), so standard.ps1 can work like standard.sh.
# Saved as UTF-8 with BOM so Windows PowerShell 5.1 reads the Chinese text correctly. Keep the BOM when editing.

$script:FW = [string][char]0xFF5C
$script:Sev = @('Critical', 'Major', 'Minor', 'Nit')
$script:Let = @('A', 'B', 'C', 'D', 'E', 'F', 'G')
$script:Canon = @{ A = '正確性'; B = '安全性'; C = '測試品質'; D = '架構與設計'; E = '效能與資源使用'; F = '可讀性'; G = '可維護性' }

function New-StdMap { return [hashtable]::new([StringComparer]::Ordinal) }
function Get-StdTrim([string]$s) { return $s.Trim([char[]]@(' ', "`t")) }
function Get-StdUnquote([string]$v) { if ($v -cmatch '^".*"$' -or $v -cmatch "^'.*'$") { return $v.Substring(1, $v.Length - 2) } return $v }
function Get-StdDash([string]$v) { if ($v -eq '') { return '-' } return $v }
function Get-SevMsg([string]$s) { return "severity must be Critical, Major, Minor or Nit (case-sensitive), not `"$s`"" }
# Continuation lines are joined with a space only between two ASCII characters (CJK text needs none).
function Join-StdLine([string]$a, [string]$b) {
    $sep = ''
    if ($a.Length -gt 0 -and $b.Length -gt 0 -and [string]$a[$a.Length - 1] -cmatch '^[!-~]$' -and [string]$b[0] -cmatch '^[!-~]$') { $sep = ' ' }
    return $a + $sep + $b
}
# awk-style number: the leading digits of a string, or 0.
function Get-StdNumber([string]$v) { if ($v -match '^[ \t]*([-+]?[0-9]+)') { return [int]$Matches[1] } return 0 }

# Lines of a UTF-8 file like awk reads them: BOM and CR removed, non-breaking spaces turned into spaces.
function Read-StdLines([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false))).Replace([string][char]0xA0, ' ')
    $lines = @($text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() } else { $lines = $lines[0..($lines.Count - 2)] }
    }
    return , $lines
}

# ---------------------------------------------------------------- Markdown document

function Invoke-StdDoc([string]$Path, [string]$Role) {
    $out = New-Object System.Collections.Generic.List[string]
    $diag = { param($k, $l, $m) $out.Add("!$k`t$l`t$m") }
    $infm = $false; $hasfm = $false; $fm = New-StdMap; $fml = New-StdMap
    $infence = $false; $fencel = 0; $incomment = $false; $coml = 0
    $sec = 'free'; $secl = New-StdMap; $curdim = ''
    $dimhl = New-StdMap; $dimh = New-StdMap; $dimrow = New-StdMap; $dimname = New-StdMap; $dimfocus = New-StdMap; $dimhdr = $false
    $dimnone = New-StdMap; $cnt = New-StdMap; $chkl = New-StdMap
    $itk = ''; $it = ''; $itl = 0; $itd = ''
    $nchk = 0; $nbad = 0; $nadj = 0
    $rec = New-Object System.Collections.Generic.List[string]
    $con = New-Object System.Collections.Generic.List[string]
    $cref = New-Object System.Collections.Generic.List[object]

    # Removes HTML comments, which may span several lines. Dot-sourced: updates $incomment and $coml.
    $sbStrip = {
        param([string]$sl)
        $so = ''
        while ($sl -ne '') {
            if ($incomment) { $sp = $sl.IndexOf('-->', [StringComparison]::Ordinal); if ($sp -lt 0) { return $so } $sl = $sl.Substring($sp + 3); $incomment = $false; continue }
            $sp = $sl.IndexOf('<!--', [StringComparison]::Ordinal); if ($sp -lt 0) { $so += $sl; break }
            $so += $sl.Substring(0, $sp); $sl = $sl.Substring($sp + 4); $incomment = $true; $coml = $FNR
        }
        return $so
    }

    $sbDimRow = {
        param([string]$rl)
        if ($rl -cmatch '^[ \t]*\|[ \t:|-]+$') { return }
        if (-not $dimhdr) { $dimhdr = $true; return }
        $c = $rl.Split('|')
        if ($c.Count -lt 4) { & $diag 'error' $FNR 'a dimension row is | code | name | focus |'; return }
        $code = Get-StdTrim $c[1]
        if ($code -cnotmatch '^[A-G]$') { & $diag 'error' $FNR "dimension codes are A to G, not `"$code`""; return }
        if ($dimrow.ContainsKey($code)) { & $diag 'error' $FNR "dimension $code is listed more than once"; return }
        $dimrow[$code] = $FNR; $dimname[$code] = Get-StdTrim $c[2]
        $dimfocus[$code] = if ($c.Count -ge 5) { Get-StdTrim $c[3] } else { '' }
    }

    $sbCheck = {
        param([string]$text, $line, [string]$dim)
        if ($text -ceq '無') { $dimnone[$dim] = 1; return }
        $text = $text.Replace("`t", ' ')
        if ($text.IndexOf($FW, [StringComparison]::Ordinal) -lt 0) {
            if ($text.Contains('|')) { & $diag 'error' $line 'separate the fields with the full-width ｜, not |' }
            else { & $diag 'error' $line 'a check item is - code｜content｜severity, or - code｜content｜severity｜adjustable to｜condition' }
            return
        }
        $f = $text.Split([string[]]@($FW), [StringSplitOptions]::None)
        $n = $f.Count
        if ($n -ne 3 -and $n -ne 5) {
            $hint = if ($text.Contains('|')) { ' (the half-width | is not a separator)' } else { '' }
            & $diag 'error' $line "a check item has 3 or 5 fields separated by ｜, not $n$hint"; return
        }
        for ($i = 0; $i -lt $n; $i++) { $f[$i] = Get-StdTrim $f[$i] }
        $code = $f[0]; $ok = $true; $letter = ''
        if ($Role -ceq 'common') {
            if ($code -cnotmatch '^CM-[A-G][0-9]+$') { & $diag 'error' $line "check codes of the common standard are CM- plus the dimension letter and a number (e.g. CM-A1), not `"$code`""; $ok = $false }
            else { $letter = $code.Substring(3, 1) }
        }
        elseif ($code -cmatch '^CM') { & $diag 'error' $line "the CM prefix is reserved for the common standard (role=`"common`"): $code"; $ok = $false }
        elseif ($code -cnotmatch '^[A-G][0-9]+$') { & $diag 'error' $line "check codes are the dimension letter and a number (e.g. A1), not `"$code`""; $ok = $false }
        else { $letter = $code.Substring(0, 1) }
        if ($ok -and $dim -cmatch '^[A-G]$' -and $letter -cne $dim) { & $diag 'error' $line "$code is under ### $dim; the letter of a check code must match its dimension"; $ok = $false }
        if ($ok -and $chkl.ContainsKey($code)) { & $diag 'error' $line "$code is already defined on line $($chkl[$code])"; $ok = $false }
        if ($f[1] -eq '') { & $diag 'error' $line "$code has no content"; $ok = $false }
        if ($f[2] -cnotin $Sev) { & $diag 'error' $line (Get-SevMsg $f[2]); $ok = $false }
        $adj = '-'
        if ($n -eq 5) {
            $adj = ''
            if ($f[3] -eq '') { & $diag 'error' $line "$code has an empty adjustable-to field"; $ok = $false }
            $parts = if ($f[3] -eq '') { @() } else { $f[3].Split(',') }
            foreach ($p in $parts) {
                $s = Get-StdTrim $p
                if ($s -cnotin $Sev) { & $diag 'error' $line (Get-SevMsg $s); $ok = $false }
                elseif ($s -ceq $f[2]) { & $diag 'error' $line "$code lists its default severity $s as adjustable"; $ok = $false }
                elseif ($s -ceq 'Nit') { & $diag 'warn' $line "${code}: Nit is always allowed and does not need to be listed" }
                else { $adj = $adj + $(if ($adj -eq '') { '' } else { ',' }) + $s }
            }
            if ($adj -eq '') { $adj = '-' }
            if ($f[4] -eq '') { & $diag 'error' $line "$code has no condition for the adjustment"; $ok = $false }
        }
        if (-not $ok) { $nbad++; return }
        $chkl[$code] = $line; $cnt[$letter]++; $nchk++
        if ($adj -ne '-') { $nadj++ }
        $cond = if ($n -eq 5) { $f[4] } else { '-' }
        $rec.Add("check`t$code`t$($f[2])`t$adj`t$cond`t$($f[1])`t$line")
    }

    $sbConfirm = {
        param([string]$text, $line)
        $text = $text.Replace("`t", ' ')
        $f = $text.Split([string[]]@($FW), [StringSplitOptions]::None)
        if ($f.Count -ne 2) {
            $hint = if ($f.Count -eq 1 -and $text.Contains('|')) { ' (separate with the full-width ｜, not |)' } else { '' }
            & $diag 'error' $line "a confirmation is - codes｜what to confirm$hint"; return
        }
        $list = ''
        $parts = if ($f[0] -eq '') { @() } else { $f[0].Split(',') }
        foreach ($p in $parts) {
            $s = Get-StdTrim $p; if ($s -eq '') { continue }
            $cref.Add(@($s, $line)); $list = $list + $(if ($list -eq '') { '' } else { ',' }) + $s
        }
        if ($list -eq '') { & $diag 'error' $line 'a confirmation needs at least one check code'; return }
        if ((Get-StdTrim $f[1]) -eq '') { & $diag 'error' $line 'a confirmation needs the thing to confirm'; return }
        $con.Add("confirm`t$list`t$(Get-StdTrim $f[1])`t$line")
    }

    $sbClose = {
        if ($itk -eq '') { return }
        $k = $itk; $itk = ''
        if ($k -eq 'check') { . $sbCheck (Get-StdTrim $it) $itl $itd } else { . $sbConfirm (Get-StdTrim $it) $itl }
    }

    $lines = Read-StdLines $Path
    for ($FNR = 1; $FNR -le $lines.Count; $FNR++) {
        $l = $lines[$FNR - 1]
        if ($FNR -eq 1 -and $l -ceq '---') { $infm = $true; $hasfm = $true; continue }
        if ($infm) {
            if ($l -ceq '---') { $infm = $false; continue }
            if ($l -cmatch '^[ \t]*(#|$)') { continue }
            if ($l -cnotmatch '^[A-Za-z_-]+:') { & $diag 'error' $FNR 'front matter lines are key: value'; continue }
            $k = $l.Substring(0, $l.IndexOf(':', [StringComparison]::Ordinal)); $v = Get-StdUnquote (Get-StdTrim $l.Substring($l.IndexOf(':', [StringComparison]::Ordinal) + 1))
            if ($k -ceq 'name' -or $k -ceq 'version') { $fm[$k] = $v; $fml[$k] = $FNR }
            elseif ($k -ceq 'applies') { & $diag 'warn' $FNR 'applies is set in configs/standards.ini, not in the document; this line is ignored' }
            else { & $diag 'warn' $FNR "unknown front matter key $k is ignored" }
            continue
        }
        if ($l -cmatch '^[ \t]*(```|~~~)') { $infence = -not $infence; if ($infence) { $fencel = $FNR }; continue }
        if ($infence) { continue }
        $had = $incomment -or $l.Contains('<!--')
        $l = . $sbStrip $l
        if ($had -and $l -cmatch '^[ \t]*$') { continue }

        if ($l -cmatch '^#[ \t]') { . $sbClose; $sec = 'free'; $curdim = ''; continue }
        if ($l -cmatch '^##[ \t]') {
            . $sbClose; $curdim = ''
            $t = Get-StdTrim $l.Substring(2)
            $sec = switch -CaseSensitive ($t) { '面向' { 'dims' } '檢查項' { 'checks' } '事先確認事項' { 'confirms' } default { 'free' } }
            if ($sec -ne 'free') { if ($secl.ContainsKey($sec)) { & $diag 'error' $FNR "section ## $t appears more than once" } else { $secl[$sec] = $FNR } }
            continue
        }
        if ($sec -eq 'checks' -and $l -cmatch '^#') {
            . $sbClose
            if ($l -cnotmatch '^###[ \t]+[A-G]\.[ \t]*[^ \t]') { & $diag 'error' $FNR 'headings under ## 檢查項 are ### X. name, with X from A to G'; $curdim = '?'; continue }
            $t = $l -creplace '^###[ \t]+', ''; $curdim = $t.Substring(0, 1); $t = Get-StdTrim $t.Substring(2)
            if ($dimhl.ContainsKey($curdim)) { & $diag 'error' $FNR "dimension $curdim has more than one heading" }
            else { $dimhl[$curdim] = $FNR; $dimh[$curdim] = $t }
            continue
        }
        if ($sec -eq 'dims') { if ($l -cmatch '^[ \t]*\|') { . $sbDimRow $l }; continue }
        if ($sec -eq 'checks') {
            if ($curdim -eq '') { continue }
            if ($l.StartsWith('- ', [StringComparison]::Ordinal)) { . $sbClose; $it = $l.Substring(2); $itl = $FNR; $itk = 'check'; $itd = $curdim; continue }
            if ($l -cmatch '^[ \t]*$') { . $sbClose; continue }
            if ($l -cmatch '^  +[^ ]' -and $itk -ne '') { $it = Join-StdLine (Get-StdTrim $it) (Get-StdTrim $l); continue }
            . $sbClose
            if ((Get-StdTrim $l) -ceq '無') { $dimnone[$curdim] = 1; continue }
            & $diag 'error' $FNR 'unexpected text under a dimension heading; write check items (- code｜content｜severity), 無, or an HTML comment'
            continue
        }
        if ($sec -eq 'confirms') {
            if ($l.StartsWith('- ', [StringComparison]::Ordinal)) { . $sbClose; $it = $l.Substring(2); $itl = $FNR; $itk = 'confirm'; continue }
            if ($l -cmatch '^  +[^ ]' -and $itk -ne '') { $it = Join-StdLine (Get-StdTrim $it) (Get-StdTrim $l); continue }
            . $sbClose
        }
    }

    . $sbClose
    if ($infence) { & $diag 'error' $fencel 'this code block is not closed' }
    if ($incomment) { & $diag 'error' $coml 'this HTML comment is not closed' }
    if (-not $hasfm) { & $diag 'error' 1 'the document must start with front matter (---, name:, version:, ---)' }
    elseif ($infm) { & $diag 'error' 1 'the front matter is not closed with ---' }
    else {
        if (-not $fm['name']) { & $diag 'error' 1 'the front matter has no name' }
        elseif ($fm['name'] -cnotmatch '^[a-z0-9][a-z0-9-]*$') { & $diag 'error' $fml['name'] 'name may only contain lowercase letters, digits and -' }
        if (-not $fm['version']) { & $diag 'error' 1 'the front matter has no version' }
    }
    if (-not $secl.ContainsKey('dims')) { & $diag 'error' '' 'section ## 面向 is missing' }
    else {
        foreach ($x in $Let) {
            if (-not $dimrow.ContainsKey($x)) { & $diag 'error' $secl['dims'] "dimension $x ($($Canon[$x])) is missing from the ## 面向 table" }
            elseif ($dimname[$x] -cne $Canon[$x]) { & $diag 'error' $dimrow[$x] "dimension $x must be named $($Canon[$x]) (dimension codes and names cannot be changed)" }
        }
    }
    if (-not $secl.ContainsKey('checks')) { & $diag 'error' '' 'section ## 檢查項 is missing' }
    else {
        foreach ($x in $Let) {
            if (-not $dimhl.ContainsKey($x)) { & $diag 'warn' $secl['checks'] "### $x. $($Canon[$x]) is missing (keep the heading and write 無 when it has no check item)" }
            else {
                if ($dimh[$x] -cne $Canon[$x]) { & $diag 'warn' $dimhl[$x] "the heading should be ### $x. $($Canon[$x])" }
                if (-not $cnt[$x] -and -not $dimnone[$x]) { & $diag 'warn' $dimhl[$x] "### $x has no check item; write 無 if that is intended" }
            }
        }
        if ($nchk -eq 0 -and $nbad -eq 0) { & $diag 'error' $secl['checks'] 'the document has no check item' }
    }
    foreach ($r in $cref) { if (-not $chkl.ContainsKey($r[0])) { & $diag 'error' $r[1] "the confirmation refers to $($r[0]), which is not a check item" } }

    $out.Add("name`t$($fm['name'])"); $out.Add("version`t$($fm['version'])")
    foreach ($x in $Let) { if ($dimrow.ContainsKey($x)) { $out.Add("dim`t$x`t$($dimname[$x])`t$($dimfocus[$x])") } }
    foreach ($r in $rec) { $out.Add($r) }
    foreach ($r in $con) { $out.Add($r) }
    $per = ($Let | ForEach-Object { "$_ $([int]$cnt[$_])" }) -join ', '
    $out.Add("stats`t$nchk`t$per`t$nadj`t$($con.Count)")
    return , $out.ToArray()
}

# ---------------------------------------------------------------- scan rule file

# The syntax that POSIX ERE (awk) and .NET do not read the same way, or '' when the regex only uses the shared part.
function Get-StdReProblem([string]$re) {
    $n = $re.Length; $inb = -1; $bad = ''
    for ($i = 0; $i -lt $n -and $bad -eq ''; $i++) {
        $c = [string]$re[$i]; $dch = if ($i + 1 -lt $n) { [string]$re[$i + 1] } else { '' }
        if ($c -eq '\') { if ($dch -cmatch '^[bBsSdDwWyYpPkK<>`''1-9]$') { $bad = '\' + $dch }; $i++; continue }
        if ($c -eq '[' -and $re.Substring($i + 1) -cmatch '^:[a-z]+:\]') { $bad = '[:class:]'; continue }
        if ($inb -ge 0) { if ($c -eq ']' -and $i -gt $inb + 1 -and -not ($i -eq $inb + 2 -and [string]$re[$inb + 1] -eq '^')) { $inb = -1 }; continue }
        if ($c -eq '[') { $inb = $i; continue }
        if ($c -eq '(' -and $dch -eq '?') { $bad = '(?' }
        elseif ($c -cmatch '^[*+?}]$' -and $dch -eq '?') { $bad = $c + '?' }
    }
    return $bad
}

function Invoke-StdScan([string]$Path, [string[]]$DocLines) {
    $out = New-Object System.Collections.Generic.List[string]
    $diag = { param($k, $l, $m) $out.Add("!$k`t$l`t$m") }
    $known = New-StdMap
    foreach ($dl in $DocLines) { $a = $dl.Split("`t"); if ($a[0] -ceq 'check') { $known[$a[1]] = 1 } }
    $scope = New-StdMap; $nscope = 0; $npr = 0; $nrule = 0; $hassrc = $false
    $sref = New-Object System.Collections.Generic.List[object]

    $sbCheckRe = {
        param([string]$re, $line, [string]$what)
        $bad = Get-StdReProblem $re
        if ($bad -ne '') { & $diag 'error' $line "$what uses $bad, which POSIX ERE (awk) and .NET do not share; avoid \b \s \d \w, lookaround, lazy quantifiers, POSIX classes and back-references"; return }
        $out.Add("!re`t$line`t$re")
    }
    $sbCheckId = {
        param([string]$id, $line)
        if ($id -cmatch '^(CM-)?[A-G][0-9]+$') { if (-not $known.ContainsKey($id)) { & $diag 'error' $line "$id is not a check item of the standard (removed or renamed?)" } }
        elseif ($id -cnotmatch '^[A-Z][A-Z0-9_]*$') { & $diag 'error' $line "rule ids are check codes or uppercase tags (e.g. API), not `"$id`"" }
    }

    $lines = Read-StdLines $Path
    for ($FNR = 1; $FNR -le $lines.Count; $FNR++) {
        $l = $lines[$FNR - 1]
        if ($l -cmatch '^[ \t]*$') { continue }
        if ($l.StartsWith('#', [StringComparison]::Ordinal)) {
            if ($l.StartsWith('# source:', [StringComparison]::Ordinal)) {
                $t = @((Get-StdTrim $l.Substring(9)) -split '[ \t]+')
                if ($t.Count -ne 3 -or $t[2] -cnotmatch '^sha256:[0-9a-f]+$') { & $diag 'warn' $FNR 'the source line is # source: <document file> <version> sha256:<hash>' }
                else { $out.Add("!source`t$FNR`t$($t[0])`t$($t[1])`t$($t[2].Substring(7))") }
                $hassrc = $true
            }
            continue
        }
        $f = $l.Split("`t"); $n = $f.Count
        if ($f[0] -ceq '@scope') {
            if ($n -ne 4) { & $diag 'error' $FNR "@scope has 4 TAB-separated fields (@scope name within path-regex), not $n"; continue }
            $w = $f[2] -creplace '^!', ''
            if ($f[1] -cnotmatch '^[a-z][a-z0-9_-]*$') { & $diag 'error' $FNR 'scope names may only contain lowercase letters, digits, _ and -' }
            elseif ($f[1] -ceq 'any') { & $diag 'error' $FNR 'the scope any is built in and cannot be defined' }
            elseif ($scope.ContainsKey($f[1])) { & $diag 'error' $FNR "scope $($f[1]) is already defined on line $($scope[$f[1]])" }
            elseif ($f[2] -cne '-' -and -not $scope.ContainsKey($w)) { & $diag 'error' $FNR "within is -, a scope defined above, or !scope; $w is not defined above" }
            else { $scope[$f[1]] = $FNR; $nscope++ }
            . $sbCheckRe $f[3] $FNR 'the path regex'
            continue
        }
        if ($f[0] -ceq '@pr') {
            if ($n -ne 4) { & $diag 'error' $FNR "@pr has 4 TAB-separated fields (@pr id condition hint), not $n"; continue }
            . $sbCheckId $f[1] $FNR
            $parts = if ($f[2] -eq '') { @() } else { $f[2].Split(',') }
            foreach ($p in $parts) {
                $s = Get-StdTrim $p
                if ($s -cnotmatch '^(has|no|modified):[a-z][a-z0-9_-]*$') { & $diag 'error' $FNR "conditions are has:scope, no:scope or modified:scope, not `"$s`"" }
                else { $sref.Add(@($s.Substring($s.IndexOf(':', [StringComparison]::Ordinal) + 1), $FNR)) }
            }
            if ((Get-StdTrim $f[3]) -eq '') { & $diag 'error' $FNR 'the hint is empty' }
            $npr++
            continue
        }
        if ($f[0].StartsWith('@', [StringComparison]::Ordinal)) { & $diag 'error' $FNR "unknown directive $($f[0]) (use @scope or @pr)"; continue }
        if ($n -ne 7) { & $diag 'error' $FNR "a line rule has 7 TAB-separated fields (id scope flags regex prev-regex exclude-regex hint), not $n"; continue }
        . $sbCheckId $f[0] $FNR
        if ($f[1] -cne 'any') { $sref.Add(@($f[1], $FNR)) }
        if ($f[2] -cnotmatch '^(-|[ic]+)$') { & $diag 'error' $FNR "flags are -, i, c or ic, not `"$($f[2])`"" }
        if ($f[3] -eq '' -or $f[3] -ceq '-') { & $diag 'error' $FNR 'the regex is required' }
        else { . $sbCheckRe $f[3] $FNR 'the regex' }
        if ($f[4] -cne '-') { . $sbCheckRe $f[4] $FNR 'the prev-regex' }
        if ($f[5] -cne '-') { . $sbCheckRe $f[5] $FNR 'the exclude-regex' }
        if ((Get-StdTrim $f[6]) -eq '') { & $diag 'error' $FNR 'the hint is empty' }
        $nrule++
    }

    foreach ($r in $sref) { if ($r[0] -cne 'any' -and -not $scope.ContainsKey($r[0])) { & $diag 'error' $r[1] "scope $($r[0]) is not defined (define it with @scope)" } }
    if ($nrule -eq 0 -and $npr -eq 0) { & $diag 'warn' '' 'the file has no rule' }
    if (-not $hassrc) { & $diag 'warn' '' 'no # source: line, so it cannot be checked against the document; regenerate the file or add the line' }
    $out.Add("stats`t$nrule`t$nscope`t$npr")
    return , $out.ToArray()
}

# ---------------------------------------------------------------- configs/standards.ini

function Invoke-StdIni([string]$Path, [string]$Settings) {
    $out = New-Object System.Collections.Generic.List[string]
    $diag = { param($k, $l, $m) $out.Add("!$k`t$l`t$m") }
    $gpts = New-StdMap; $defaults = @(25, 15, 15, 15, 10, 10, 10)
    for ($i = 0; $i -lt 7; $i++) { $gpts[$Let[$i]] = [string]$defaults[$i] }
    if ($Settings -and [IO.File]::Exists($Settings)) {
        $insec = $false
        foreach ($sl in ([IO.File]::ReadAllText($Settings, (New-Object System.Text.UTF8Encoding($false))) -split "`n")) {
            $sl = $sl -creplace "`r$", ''
            if ($sl -cmatch '^[ \t]*\[') { $h = $sl -creplace '^[ \t]*\[|\][ \t]*$', ''; $insec = ($h -ceq 'points'); continue }
            if ($insec -and $sl -cmatch '^[ \t]*[A-G][ \t]*=') {
                $k = Get-StdTrim $sl.Substring(0, $sl.IndexOf('=', [StringComparison]::Ordinal)); $gpts[$k] = Get-StdUnquote (Get-StdTrim $sl.Substring($sl.IndexOf('=', [StringComparison]::Ordinal) + 1))
            }
        }
    }
    $stdl = New-StdMap; $order = New-Object System.Collections.Generic.List[string]
    $val = New-StdMap; $vall = New-StdMap; $pts = New-StdMap; $ptsl = New-StdMap
    $cur = ''; $dupsec = $false

    $lines = Read-StdLines $Path
    for ($FNR = 1; $FNR -le $lines.Count; $FNR++) {
        $l = Get-StdTrim $lines[$FNR - 1]
        if ($l -eq '' -or $l -cmatch '^[;#]') { continue }
        if ($l -cmatch '^\[.*\]$') {
            $cur = $l.Substring(1, $l.Length - 2)
            if ($cur -cnotmatch '^[a-z0-9][a-z0-9-]*$') { & $diag 'error' $FNR 'section names are the name of the standard: lowercase letters, digits and -' }
            if ($stdl.ContainsKey($cur)) { & $diag 'error' $FNR "[$cur] is already defined on line $($stdl[$cur])"; $cur = ''; $dupsec = $true }
            else { $stdl[$cur] = $FNR; $order.Add($cur); $dupsec = $false }
            continue
        }
        if ($l -cnotmatch '^[A-Za-z0-9_.]+[ \t]*=') { & $diag 'error' $FNR 'lines are [name], key="value" or ; comments'; continue }
        if ($cur -eq '') { if (-not $dupsec) { & $diag 'error' $FNR 'key outside a [section]' }; continue }
        $k = Get-StdTrim $l.Substring(0, $l.IndexOf('=', [StringComparison]::Ordinal)); $v = Get-StdUnquote (Get-StdTrim $l.Substring($l.IndexOf('=', [StringComparison]::Ordinal) + 1))
        if ($k -cin @('path', 'scan', 'applies', 'role')) { $val["$cur`t$k"] = $v; $vall["$cur`t$k"] = $FNR }
        elseif ($k -cmatch '^points\.[A-G]$') {
            $x = $k.Substring(7, 1)
            if ($v -cnotmatch '^[0-9]+$') { & $diag 'error' $FNR "$k must be a whole number, not `"$v`"" }
            else { $pts["$cur`t$x"] = $v; if (-not $ptsl[$cur]) { $ptsl[$cur] = $FNR } }
        }
        else { & $diag 'error' $FNR "unknown key $k (path, scan, applies, role, points.A to points.G)" }
    }

    if ($order.Count -eq 0) { & $diag 'error' '' 'no standard is registered; add a [name] section with path="..."'; return , $out.ToArray() }
    $owner = New-StdMap; $ncommon = 0
    foreach ($s in $order) {
        $get = { param($key) $v = $val["$s`t$key"]; if ($null -eq $v) { '' } else { $v } }
        if ((& $get 'path') -eq '') { & $diag 'error' $stdl[$s] "[$s] has no path" }
        $srole = & $get 'role'
        if ($srole -ne '' -and $srole -cne 'common') { & $diag 'error' $vall["$s`trole"] "role is `"common`" or not set, not `"$srole`"" }
        if ($srole -ceq 'common') {
            if (++$ncommon -gt 1) { & $diag 'error' $vall["$s`trole"] 'only one standard can have role="common"' }
            if ((& $get 'applies') -ne '') { & $diag 'warn' $vall["$s`tapplies"] 'applies is ignored for the common standard, which covers the files no framework standard covers' }
        }
        elseif ((& $get 'applies') -eq '') { & $diag 'error' $stdl[$s] "[$s] has no applies (framework standards need one)" }
        else {
            foreach ($a in (& $get 'applies').Split(',')) {
                $p = Get-StdTrim $a; if ($p -eq '') { continue }
                if ($owner.ContainsKey($p) -and $owner[$p] -cne $s) { & $diag 'error' $vall["$s`tapplies"] "the pattern $p is also in [$($owner[$p])]; a file may belong to one framework standard only" }
                else { $owner[$p] = $s }
            }
        }
        if ($ptsl[$s]) {
            $sum = 0
            foreach ($x in $Let) { $pv = if ($pts.ContainsKey("$s`t$x")) { $pts["$s`t$x"] } else { $gpts[$x] }; $sum += Get-StdNumber $pv }
            if ($sum -ne 100) { & $diag 'error' $ptsl[$s] "[$s] the seven dimensions must add up to 100 with the overrides, not $sum" }
        }
        # Empty values are written as - so that the shells can read the TAB-separated fields.
        $out.Add("std`t$s`t$($stdl[$s])`t$(Get-StdDash (& $get 'path'))`t$(Get-StdDash (& $get 'scan'))`t$(Get-StdDash $srole)")
        foreach ($x in $Let) { if ($pts.ContainsKey("$s`t$x")) { $out.Add("points`t$s`t$x`t$($pts["$s`t$x"])") } }
    }
    if ($ncommon -eq 0) { & $diag 'warn' '' 'no common standard (role="common"); files that no framework standard covers will not be scored' }
    return , $out.ToArray()
}

# ---------------------------------------------------------------- diff of two documents

function Invoke-StdDiff([string[]]$Old, [string[]]$New) {
    $out = New-Object System.Collections.Generic.List[string]
    $fields = @('content', 'severity', 'adjustable', 'condition')
    $side = {
        param([string[]]$doc)
        $r = @{ ver = ''; focus = (New-StdMap); ids = (New-Object System.Collections.Generic.List[string]); dv = (New-StdMap)
            cf = (New-Object System.Collections.Generic.List[string]); hascf = (New-StdMap) }
        foreach ($dl in $doc) {
            $a = $dl.Split("`t")
            if ($a[0] -ceq 'version') { $r.ver = $a[1] }
            elseif ($a[0] -ceq 'dim') { $r.focus[$a[1]] = $a[3] }
            elseif ($a[0] -ceq 'check') { $r.ids.Add($a[1]); $r.dv[$a[1]] = @{ content = $a[5]; severity = $a[2]; adjustable = $a[3]; condition = $a[4] } }
            elseif ($a[0] -ceq 'confirm') { $c = $a[1] + $FW + $a[2]; $r.cf.Add($c); $r.hascf[$c] = 1 }
        }
        return $r
    }
    $item = {
        param($r, [string]$c)
        $v = $r.dv[$c]; $s = $c + $FW + $v.content + $FW + $v.severity
        if ($v.adjustable -cne '-') { $s += $FW + $v.adjustable + $FW + $v.condition }
        return $s
    }
    $o = & $side $Old; $n = & $side $New
    $add = 0; $del = 0; $chg = 0
    if ($o.ver -cne $n.ver) { $out.Add("version: $($o.ver) -> $($n.ver)") }
    foreach ($x in $Let) {
        $fo = [string]$o.focus[$x]; $fn = [string]$n.focus[$x]
        if ($fo -cne $fn) { $out.Add("~ dimension $x focus: $fo -> $fn"); $chg++ }
    }
    foreach ($c in $n.ids) {
        if (-not $o.dv.ContainsKey($c)) { $out.Add('+ ' + (& $item $n $c)); $add++; continue }
        $dd = 0
        foreach ($f in $fields) { if ($o.dv[$c][$f] -cne $n.dv[$c][$f]) { $out.Add("~ $c ${f}: $($o.dv[$c][$f]) -> $($n.dv[$c][$f])"); $dd = 1 } }
        $chg += $dd
    }
    foreach ($c in $o.ids) { if (-not $n.dv.ContainsKey($c)) { $out.Add('- ' + (& $item $o $c)); $del++ } }
    foreach ($c in $n.cf) { if (-not $o.hascf.ContainsKey($c)) { $out.Add("+ confirm $c"); $add++ } }
    foreach ($c in $o.cf) { if (-not $n.hascf.ContainsKey($c)) { $out.Add("- confirm $c"); $del++ } }
    $out.Add("$add added, $del removed, $chg changed")
    return , $out.ToArray()
}
