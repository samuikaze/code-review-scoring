# Parser and checks for scoring standards: the PowerShell counterpart of lib/standard.awk.
# Each Invoke-Std* function returns the lines that standard.awk prints in the same mode, in the same order
# (TAB-separated records and "!error" / "!warn" diagnostics), so standard.ps1 can work like standard.sh.
# Saved as UTF-8 with BOM so Windows PowerShell 5.1 reads the Chinese text correctly. Keep the BOM when editing.

$script:FW = [string][char]0xFF5C
$script:Let = @('A', 'B', 'C', 'D', 'E', 'F', 'G')
$script:Canon = @{ A = '正確性'; B = '安全性'; C = '測試品質'; D = '架構與設計'; E = '效能與資源使用'; F = '可讀性'; G = '可維護性' }
$script:CanonEn = @{ A = 'Correctness'; B = 'Security'; C = 'Test quality'; D = 'Architecture and design'; E = 'Performance and resource use'; F = 'Readability'; G = 'Maintainability' }

function New-StdMap { return [hashtable]::new([StringComparer]::Ordinal) }
function Get-StdTrim([string]$s) { return $s.Trim([char[]]@(' ', "`t")) }
function Get-StdUnquote([string]$v) { if ($v -cmatch '^".*"$' -or $v -cmatch "^'.*'$") { return $v.Substring(1, $v.Length - 2) } return $v }
function Get-StdDash([string]$v) { if ($v -eq '') { return '-' } return $v }
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

# Sevs = the severity codes of the scale of the document, from the most to the least severe (empty = not checked).
function Invoke-StdDoc([string]$Path, [string]$Role, [string[]]$Sevs) {
    $out = New-Object System.Collections.Generic.List[string]
    $diag = { param($k, $l, $m) $out.Add("!$k`t$l`t$m") }
    $Sevs = @($Sevs | Where-Object { $_ -ne '' })
    $lowest = if ($Sevs.Count -gt 0) { $Sevs[$Sevs.Count - 1] } else { '' }
    # A severity of a check item: one of the scale when it is known, otherwise any well-formed code.
    $sevok = { param($s) if ($Sevs.Count -gt 0) { return $s -cin $Sevs } return $s -cmatch '^[A-Za-z][A-Za-z0-9_-]*$' }
    $sevmsg = {
        param($s)
        if ($Sevs.Count -gt 0) { return "severity must be one of $($Sevs -join ', ') (case-sensitive), not `"$s`"" }
        return "severity codes are letters, digits, _ and -, not `"$s`""
    }
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
        if ($text -ceq '無' -or $text -ceq 'None') { $dimnone[$dim] = 1; return }
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
        if (-not (& $sevok $f[2])) { & $diag 'error' $line (& $sevmsg $f[2]); $ok = $false }
        $adj = '-'
        if ($n -eq 5) {
            $adj = ''
            if ($f[3] -eq '') { & $diag 'error' $line "$code has an empty adjustable-to field"; $ok = $false }
            $parts = if ($f[3] -eq '') { @() } else { $f[3].Split(',') }
            foreach ($p in $parts) {
                $s = Get-StdTrim $p
                if (-not (& $sevok $s)) { & $diag 'error' $line (& $sevmsg $s); $ok = $false }
                elseif ($s -ceq $f[2]) { & $diag 'error' $line "$code lists its default severity $s as adjustable"; $ok = $false }
                elseif ($s -ceq $lowest) { & $diag 'warn' $line "${code}: $s is the lowest severity, which is always allowed and does not need to be listed" }
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
            elseif ($k -ceq 'applies') { & $diag 'warn' $FNR 'applies is set in the rule.ini of the rule, not in the document; this line is ignored' }
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
            $sec = switch -CaseSensitive ($t) { '面向' { 'dims' } 'Dimensions' { 'dims' } '檢查項' { 'checks' } 'Check items' { 'checks' } '事先確認事項' { 'confirms' } 'Confirmations' { 'confirms' } default { 'free' } }
            if ($sec -ne 'free') { if ($secl.ContainsKey($sec)) { & $diag 'error' $FNR "section ## $t appears more than once" } else { $secl[$sec] = $FNR } }
            continue
        }
        if ($sec -eq 'checks' -and $l -cmatch '^#') {
            . $sbClose
            if ($l -cnotmatch '^###[ \t]+[A-G]\.[ \t]*[^ \t]') { & $diag 'error' $FNR 'headings under ## 檢查項 (Check items) are ### X. name, with X from A to G'; $curdim = '?'; continue }
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
            if ((Get-StdTrim $l) -ceq '無' -or (Get-StdTrim $l) -ceq 'None') { $dimnone[$curdim] = 1; continue }
            & $diag 'error' $FNR 'unexpected text under a dimension heading; write check items (- code｜content｜severity), 無 (None), or an HTML comment'
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
    if (-not $secl.ContainsKey('dims')) { & $diag 'error' '' 'section ## 面向 (Dimensions) is missing' }
    else {
        foreach ($x in $Let) {
            if (-not $dimrow.ContainsKey($x)) { & $diag 'error' $secl['dims'] "dimension $x ($($Canon[$x])) is missing from the ## 面向 (Dimensions) table" }
            elseif ($dimname[$x] -cne $Canon[$x] -and $dimname[$x] -cne $CanonEn[$x]) { & $diag 'error' $dimrow[$x] "dimension $x must be named $($Canon[$x]) or $($CanonEn[$x]) (dimension codes and names cannot be changed)" }
        }
    }
    if (-not $secl.ContainsKey('checks')) { & $diag 'error' '' 'section ## 檢查項 (Check items) is missing' }
    else {
        foreach ($x in $Let) {
            if (-not $dimhl.ContainsKey($x)) { & $diag 'warn' $secl['checks'] "### $x. $($Canon[$x]) is missing (keep the heading and write 無 or None when it has no check item)" }
            else {
                if ($dimh[$x] -cne $Canon[$x] -and $dimh[$x] -cne $CanonEn[$x]) { & $diag 'warn' $dimhl[$x] "the heading should be ### $x. $($Canon[$x]) or ### $x. $($CanonEn[$x])" }
                if (-not $cnt[$x] -and -not $dimnone[$x]) { & $diag 'warn' $dimhl[$x] "### $x has no check item; write 無 or None if that is intended" }
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

# ---------------------------------------------------------------- rules project: rules.ini, defaults.ini, rule.ini

function Test-StdAbs([string]$p) { return $p -cmatch '^/' -or $p -cmatch '^[A-Za-z]:' }
# A path in a settings file: backslashes become slashes, and a relative path is relative to the folder dir.
function Join-StdPath([string]$dir, [string]$p) { $p = $p.Replace('\', '/'); if ($p -eq '' -or (Test-StdAbs $p)) { return $p } return "$dir/$p" }
function Test-StdCode([string]$c) { return $c -cmatch '^[A-Za-z][A-Za-z0-9_-]*$' }
function Add-StdDiag($out, [string]$kind, [string]$file, $line, [string]$msg) { $out.Add("!$kind`t$line`t$msg`t$file") }

# Reads an INI file: its sections in file order (secs, isec = line) and the keys of each section in order
# (keys, kv = value, kl = line). Returns $null when the file cannot be read.
function Read-StdIni($out, [string]$File) {
    if (-not [IO.File]::Exists($File)) { return $null }
    $dup = [string][char]1
    $r = @{ file = $File; secs = (New-Object System.Collections.Generic.List[string]); isec = (New-StdMap); keys = (New-StdMap); kv = (New-StdMap); kl = (New-StdMap) }
    $lines = Read-StdLines $File; $s = ''
    for ($ln = 1; $ln -le $lines.Count; $ln++) {
        $l = Get-StdTrim $lines[$ln - 1]
        if ($l -eq '' -or $l -cmatch '^[;#]') { continue }
        if ($l -cmatch '^\[.*\]$') {
            $s = Get-StdTrim $l.Substring(1, $l.Length - 2)
            if ($r.isec.ContainsKey($s)) { Add-StdDiag $out 'error' $File $ln "[$s] is already defined on line $($r.isec[$s])"; $s = $dup }
            else { $r.isec[$s] = $ln; $r.secs.Add($s); $r.keys[$s] = New-Object System.Collections.Generic.List[string] }
            continue
        }
        if ($l -cnotmatch '^[A-Za-z0-9_.]+[ \t]*=') { Add-StdDiag $out 'error' $File $ln 'lines are [section], key="value" or ; comments'; continue }
        if ($s -eq '') { Add-StdDiag $out 'error' $File $ln 'key outside a [section]'; continue }
        if ($s -eq $dup) { continue }
        $k = Get-StdTrim $l.Substring(0, $l.IndexOf('=', [StringComparison]::Ordinal)); $v = Get-StdUnquote (Get-StdTrim $l.Substring($l.IndexOf('=', [StringComparison]::Ordinal) + 1))
        # meaning of a [severity:CODE] section may be repeated: the lines are joined with newlines.
        if ($r.kl.ContainsKey("$s`t$k") -and $k -ceq 'meaning' -and $s.StartsWith('severity:', [StringComparison]::Ordinal)) { $r.kv["$s`t$k"] += "`n$v"; continue }
        if ($r.kl.ContainsKey("$s`t$k")) { Add-StdDiag $out 'error' $File $ln "$k is already set on line $($r.kl["$s`t$k"])"; continue }
        $r.kv["$s`t$k"] = $v; $r.kl["$s`t$k"] = $ln; $r.keys[$s].Add($k)
    }
    return $r
}
function Get-StdIniValue($ini, [string]$s, [string]$k) { $v = $ini.kv["$s`t$k"]; if ($null -eq $v) { return '' } return [string]$v }

# Checks a rule.ini (kind "rule") or defaults.ini (kind "defaults") read with Read-StdIni, and adds the groups it
# defines (grp: name = line): "scoring" (merge), "points" (pv), "sev" (sc, the codes from the most severe) and
# "grade" (gc, the codes from the highest).
function Read-StdSet($out, $ini, [string]$Kind) {
    $file = $ini.file
    $ini.grp = New-StdMap; $ini.merge = 'false'; $ini.pv = New-StdMap
    $ini.sc = New-Object System.Collections.Generic.List[string]; $ini.sname = New-StdMap; $ini.spts = New-StdMap; $ini.scap = New-StdMap; $ini.smean = New-StdMap
    $ini.gc = New-Object System.Collections.Generic.List[string]; $ini.gname = New-StdMap; $ini.gmin = New-StdMap; $ini.gln = New-StdMap
    # Text shown in the report (name, meaning): without TAB or | (meaning may have several lines, see Read-StdIni).
    $text = {
        param($s, $k)
        if ((Get-StdIniValue $ini $s $k) -cmatch '[\t|]') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "$k may not contain a TAB or |"; return $false }
        return $true
    }
    foreach ($s in $ini.secs) {
        $ln = $ini.isec[$s]
        if ($s -ceq 'rule') {
            if ($Kind -cne 'rule') { Add-StdDiag $out 'error' $file $ln '[rule] belongs in the rule.ini of a rule'; continue }
            foreach ($k in $ini.keys[$s]) { if ($k -cnotmatch '^(standard|scan|applies|role)$') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "unknown key $k in [rule] (standard, scan, applies, role)" } }
        }
        elseif ($s -ceq 'scoring') {
            $ini.grp['scoring'] = $ln
            foreach ($k in $ini.keys[$s]) {
                $v = (Get-StdIniValue $ini $s $k).ToLowerInvariant()
                if ($k -cne 'merge') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "unknown key $k in [scoring] (merge)" }
                elseif ($v -cne 'true' -and $v -cne 'false') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "merge is `"true`" or `"false`", not `"$(Get-StdIniValue $ini $s $k)`"" }
                else { $ini.merge = $v }
            }
        }
        elseif ($s -ceq 'points') {
            $ini.grp['points'] = $ln; $sum = 0; $all = $true
            foreach ($k in $ini.keys[$s]) {
                if ($k -cnotmatch '^[A-G]$') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "unknown dimension $k in [points] (A to G)" }
                elseif ((Get-StdIniValue $ini $s $k) -cnotmatch '^[0-9]+$') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "$k must be a whole number, not `"$(Get-StdIniValue $ini $s $k)`""; $all = $false }
            }
            foreach ($x in $Let) {
                if (-not $ini.kl.ContainsKey("$s`t$x")) { Add-StdDiag $out 'error' $file $ln "[points] needs all seven dimensions; $x is missing"; $all = $false }
                else { $ini.pv[$x] = Get-StdNumber (Get-StdIniValue $ini $s $x); $sum += $ini.pv[$x] }
            }
            if ($all -and $sum -ne 100) { Add-StdDiag $out 'error' $file $ln "the seven dimensions of [points] must add up to 100, not $sum" }
        }
        elseif ($s -cmatch '^severity:') {
            $c = $s.Substring(9)
            if (-not $ini.grp.ContainsKey('sev')) { $ini.grp['sev'] = $ln }
            if (-not (Test-StdCode $c)) { Add-StdDiag $out 'error' $file $ln "severity codes are letters, digits, _ and -, starting with a letter, not `"$c`""; continue }
            foreach ($k in $ini.keys[$s]) { if ($k -cnotmatch '^(name|points|cap|meaning)$') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "unknown key $k in [$s] (name, points, cap, meaning)" } }
            $ini.sc.Add($c)
            $ini.sname[$c] = if ((Get-StdIniValue $ini $s 'name') -ne '' -and (& $text $s 'name')) { Get-StdIniValue $ini $s 'name' } else { $c }
            if ((Get-StdIniValue $ini $s 'points') -cnotmatch '^[0-9]+$') { Add-StdDiag $out 'error' $file $ln "[$s] needs points, the whole number deducted for each finding" }
            $ini.spts[$c] = Get-StdNumber (Get-StdIniValue $ini $s 'points')
            $ini.scap[$c] = Get-StdIniValue $ini $s 'cap'
            if ((Get-StdIniValue $ini $s 'meaning') -eq '') { Add-StdDiag $out 'error' $file $ln "[$s] needs meaning, which tells the AI when to use it" }
            $ini.smean[$c] = if (& $text $s 'meaning') { Get-StdIniValue $ini $s 'meaning' } else { '' }
        }
        elseif ($s -cmatch '^grade:') {
            $c = $s.Substring(6)
            if (-not $ini.grp.ContainsKey('grade')) { $ini.grp['grade'] = $ln }
            if (-not (Test-StdCode $c)) { Add-StdDiag $out 'error' $file $ln "grade codes are letters, digits, _ and -, starting with a letter, not `"$c`""; continue }
            foreach ($k in $ini.keys[$s]) { if ($k -cnotmatch '^(name|min)$') { Add-StdDiag $out 'error' $file $ini.kl["$s`t$k"] "unknown key $k in [$s] (name, min)" } }
            $ini.gc.Add($c); $ini.gln[$c] = $ln
            $ini.gname[$c] = if ((Get-StdIniValue $ini $s 'name') -ne '' -and (& $text $s 'name')) { Get-StdIniValue $ini $s 'name' } else { $c }
            if ((Get-StdIniValue $ini $s 'min') -cnotmatch '^[0-9]+$') { Add-StdDiag $out 'error' $file $ln "[$s] needs min, the lowest total (a whole number) of the grade" }
            $ini.gmin[$c] = Get-StdNumber (Get-StdIniValue $ini $s 'min')
        }
        else {
            $known = if ($Kind -ceq 'rule') { 'rule, ' } else { '' }
            Add-StdDiag $out 'error' $file $ln "unknown section [$s] (${known}scoring, points, severity:CODE, grade:CODE)"
        }
    }
    # Grades go from the highest to the lowest; the last one takes every total down to 0.
    for ($i = 0; $i -lt $ini.gc.Count; $i++) {
        $c = $ini.gc[$i]
        if ($i -eq 0 -and $ini.gmin[$c] -gt 100) { Add-StdDiag $out 'error' $file $ini.gln[$c] "the min of grade $c must be at most 100" }
        if ($i -gt 0) {
            $p = $ini.gc[$i - 1]
            if ($ini.gmin[$c] -ge $ini.gmin[$p]) { Add-StdDiag $out 'error' $file $ini.gln[$c] "grades go from the highest to the lowest: the min of $c ($($ini.gmin[$c])) must be lower than that of $p ($($ini.gmin[$p]))" }
        }
        if ($i -eq $ini.gc.Count - 1 -and $ini.gmin[$c] -ne 0) { Add-StdDiag $out 'error' $file $ini.gln[$c] "the last grade $c is the lowest; its min must be 0" }
    }
}

# The settings group g of a rule: its own when its rule.ini defines it, otherwise that of defaults.ini; $null when
# neither does.
function Get-StdEff($rule, $def, [string]$g) {
    if ($null -ne $rule -and $rule.grp.ContainsKey($g)) { return $rule }
    if ($null -ne $def -and $def.grp.ContainsKey($g)) { return $def }
    return $null
}
function Get-StdShort($set, $def) { if ($null -ne $set -and [object]::ReferenceEquals($set, $def)) { return 'defaults.ini' } return 'rule.ini' }

# The applies patterns as one regex for the path relative to the repository root (POSIX ERE and .NET read it the
# same way): a pattern without / matches the file name, one with / the whole path; ** crosses directories.
function Get-StdGlobRe([string]$p) {
    $r = if ($p.Contains('/')) { '^' } else { '(^|/)' }
    if ($p.StartsWith('/')) { $p = $p.Substring(1) }
    for ($i = 0; $i -lt $p.Length; $i++) {
        $c = $p[$i]; $rest = $p.Substring($i)
        if ($rest.StartsWith('**/')) { $r += '(.*/)?'; $i += 2 }
        elseif ($rest.StartsWith('**')) { $r += '.*'; $i++ }
        elseif ($c -eq '*') { $r += '[^/]*' }
        elseif ($c -eq '?') { $r += '[^/]' }
        elseif ('.+()^$|{}[]\'.IndexOf($c) -ge 0) { $r += '\' + $c }
        else { $r += $c }
    }
    return "($r`$)"
}

# Checks rules.ini, defaults.ini and the rule.ini of every rule, and returns for each rule (enabled or not):
#   std <name> <line> <document> <scan rules> <role> <enable> <rule.ini>   (- for an empty field)
#   applies <name> <regex>, points <name> <dim> <points>, merge <name> true|false, from <name> <group> <file>,
#   severity <name> <code> <points> <cap> <display name> <meaning>   (from the most severe)
#   grade <name> <code> <min> <display name>                         (from the highest)
# and "defaults <defaults.ini>" at the end.
function Invoke-StdRules([string]$Rules, [string]$RRoot, [string]$Defaults) {
    $out = New-Object System.Collections.Generic.List[string]
    $ri = Read-StdIni $out $Rules
    if ($null -eq $ri) { Add-StdDiag $out 'error' $Rules '' 'file not found'; return , $out.ToArray() }
    $def = Read-StdIni $out $Defaults
    if ($null -eq $def) { Add-StdDiag $out 'error' $Defaults '' 'file not found; the rules project needs defaults.ini with the default points, severities and grades' }
    else { Read-StdSet $out $def 'defaults' }
    if ($ri.secs.Count -eq 0) { Add-StdDiag $out 'error' $Rules '' 'no rule is registered; add a [name] section with path="..." and enable="true"' }
    $owner = New-StdMap; $capdone = New-StdMap; $ncommon = 0; $nen = 0
    foreach ($s in $ri.secs) {
        $ln = $ri.isec[$s]
        if ($s -cnotmatch '^[a-z0-9][a-z0-9-]*$') { Add-StdDiag $out 'error' $Rules $ln 'section names are the name of the rule: lowercase letters, digits and -' }
        foreach ($k in $ri.keys[$s]) {
            if ($k -cmatch '^(scan|applies|role|points\.[A-G])$') { Add-StdDiag $out 'error' $Rules $ri.kl["$s`t$k"] "$k is set in the rule.ini of the rule, not in rules.ini" }
            elseif ($k -cne 'path' -and $k -cne 'enable') { Add-StdDiag $out 'error' $Rules $ri.kl["$s`t$k"] "unknown key $k (path, enable)" }
        }
        $p = Get-StdIniValue $ri $s 'path'; $e = (Get-StdIniValue $ri $s 'enable').ToLowerInvariant()
        if ($p -eq '') { Add-StdDiag $out 'error' $Rules $ln "[$s] has no path (the folder of its rule.ini)" }
        if (-not $ri.kl.ContainsKey("$s`tenable")) { Add-StdDiag $out 'error' $Rules $ln "[$s] has no enable (`"true`" or `"false`")"; $e = 'false' }
        elseif ($e -cne 'true' -and $e -cne 'false') { Add-StdDiag $out 'error' $Rules $ri.kl["$s`tenable"] "enable is `"true`" or `"false`", not `"$(Get-StdIniValue $ri $s 'enable')`""; $e = 'false' }
        if ($e -ceq 'true') { $nen++ }
        $d = (Join-StdPath $RRoot $p) -creplace '/+$', ''
        $setfile = if ($p -eq '') { '' } else { "$d/rule.ini" }
        $doc = ''; $scan = ''; $role = ''; $re = ''; $rule = $null
        if ($p -ne '') {
            $rule = Read-StdIni $out $setfile
            if ($null -eq $rule) { Add-StdDiag $out 'error' $setfile '' "file not found (the path of [$s] in rules.ini)" }
            else {
                Read-StdSet $out $rule 'rule'
                if (-not $rule.isec.ContainsKey('rule')) { Add-StdDiag $out 'error' $setfile '' '[rule] is missing (standard="<the Markdown document>")' }
                elseif ((Get-StdIniValue $rule 'rule' 'standard') -eq '') { Add-StdDiag $out 'error' $setfile $rule.isec['rule'] '[rule] has no standard (the Markdown document)' }
                $doc = Join-StdPath $d (Get-StdIniValue $rule 'rule' 'standard'); $scan = Join-StdPath $d (Get-StdIniValue $rule 'rule' 'scan')
                $role = Get-StdIniValue $rule 'rule' 'role'; $apps = Get-StdIniValue $rule 'rule' 'applies'
                if ($role -ne '' -and $role -cne 'common') { Add-StdDiag $out 'error' $setfile $rule.kl["rule`trole"] "role is `"common`" or not set, not `"$role`""; $role = '' }
                if ($role -ceq 'common') {
                    if ($e -ceq 'true') { $ncommon++; if ($ncommon -gt 1) { Add-StdDiag $out 'error' $Rules $ln 'only one enabled rule can have role="common"' } }
                    if ($apps -ne '') { Add-StdDiag $out 'warn' $setfile $rule.kl["rule`tapplies"] 'applies is ignored for the common standard, which covers the files no framework rule covers' }
                }
                elseif ($rule.isec.ContainsKey('rule') -and $apps -eq '') { Add-StdDiag $out 'error' $setfile $rule.isec['rule'] '[rule] has no applies (framework rules need one)' }
                else {
                    foreach ($a in $apps.Split(',')) {
                        $x = Get-StdTrim $a; if ($x -eq '') { continue }
                        $re += $(if ($re -eq '') { '' } else { '|' }) + (Get-StdGlobRe $x)
                        if ($e -cne 'true') { continue }
                        if ($owner.ContainsKey($x) -and $owner[$x] -cne $s) { Add-StdDiag $out 'error' $setfile $rule.kl["rule`tapplies"] "the pattern $x is also in [$($owner[$x])]; a file may belong to one enabled framework rule only" }
                        else { $owner[$x] = $s }
                    }
                }
            }
        }
        # Empty values are written as - so that the shells can read the TAB-separated fields.
        $out.Add("std`t$s`t$ln`t$(Get-StdDash $doc)`t$(Get-StdDash $scan)`t$(Get-StdDash $role)`t$e`t$(Get-StdDash $setfile)")
        if ($null -eq $rule) { continue }
        if ($role -cne 'common' -and $re -ne '') { $out.Add("applies`t$s`t$re") }
        $ep = Get-StdEff $rule $def 'points'; $es = Get-StdEff $rule $def 'sev'; $eg = Get-StdEff $rule $def 'grade'
        # The common rule never uses the [points], [grade:CODE] sections and caps of its own rule.ini: they are warned
        # about, and its points and grades come from defaults.ini.
        if ($role -ceq 'common' -and [object]::ReferenceEquals($ep, $rule)) {
            Add-StdDiag $out 'warn' $setfile $rule.isec['points'] '[points] is never used by the common rule (role="common"); its points come from defaults.ini'
            $ep = Get-StdEff $null $def 'points'
        }
        if ($role -ceq 'common' -and [object]::ReferenceEquals($eg, $rule)) {
            Add-StdDiag $out 'warn' $setfile $rule.gln[$rule.gc[0]] '[grade:CODE] sections are never used by the common rule (role="common"); its grades come from defaults.ini'
            $eg = Get-StdEff $null $def 'grade'
        }
        if ($null -eq $ep) { Add-StdDiag $out 'error' $setfile '' 'no [points] in rule.ini or defaults.ini' }
        if ($null -eq $es) { Add-StdDiag $out 'error' $setfile '' 'no [severity:CODE] section in rule.ini or defaults.ini' }
        if ($null -eq $eg) { Add-StdDiag $out 'error' $setfile '' 'no [grade:CODE] section in rule.ini or defaults.ini' }
        $out.Add("from`t$s`tpoints`t$(Get-StdShort $ep $def)")
        $out.Add("from`t$s`tseverities`t$(Get-StdShort $es $def)")
        $out.Add("from`t$s`tgrades`t$(Get-StdShort $eg $def)")
        if ($null -ne $ep) { foreach ($x in $Let) { $out.Add("points`t$s`t$x`t$([int]$ep.pv[$x])") } }
        $em = Get-StdEff $rule $def 'scoring'
        $out.Add("merge`t$s`t$(if ($null -eq $em) { 'false' } else { $em.merge })")
        if ($null -ne $es) {
            foreach ($c in $es.sc) {
                $cap = $es.scap[$c]
                if ($cap -ne '' -and $role -ceq 'common' -and [object]::ReferenceEquals($es, $rule)) {
                    Add-StdDiag $out 'warn' $setfile $rule.kl["severity:$c`tcap"] 'cap is never used by the common rule (role="common")'
                    $cap = ''
                }
                # The grade a severity caps at must be one of the grades that apply (checked once per pair of files).
                if ($cap -ne '' -and $null -ne $eg -and -not $eg.isec.ContainsKey("grade:$cap")) {
                    $key = "$($es.file)`t$($eg.file)`t$c"
                    if (-not $capdone.ContainsKey($key)) {
                        $capdone[$key] = 1
                        Add-StdDiag $out 'error' $es.file $es.kl["severity:$c`tcap"] "cap $cap is not one of the grades that apply to [$s] ($($eg.gc -join ', '))"
                    }
                }
                # The lines of a multi-line meaning are separated by | in the record (| cannot appear in the text).
                $out.Add("severity`t$s`t$c`t$($es.spts[$c])`t$(Get-StdDash $cap)`t$($es.sname[$c])`t$(Get-StdDash ([string]$es.smean[$c]).Replace("`n", '|'))")
            }
        }
        if ($null -ne $eg) { foreach ($c in $eg.gc) { $out.Add("grade`t$s`t$c`t$($eg.gmin[$c])`t$($eg.gname[$c])") } }
    }
    if ($ri.secs.Count -gt 0 -and $nen -eq 0) { Add-StdDiag $out 'warn' $Rules '' 'no rule is enabled (enable="true")' }
    if ($ri.secs.Count -gt 0 -and $ncommon -eq 0) { Add-StdDiag $out 'warn' $Rules '' 'no enabled common rule (role="common"); files that no framework rule covers will not be scored' }
    $out.Add("defaults`t$Defaults")
    return , $out.ToArray()
}

# The severity codes that apply to a rule.ini (RuleIni, may be ''): its own, otherwise those of defaults.ini.
function Get-StdScale([string]$RuleIni, [string]$Defaults) {
    $out = New-Object System.Collections.Generic.List[string]
    $def = Read-StdIni $out $Defaults
    if ($null -ne $def) { Read-StdSet $out $def 'defaults' }
    $rule = $null
    if ($RuleIni -ne '') { $rule = Read-StdIni $out $RuleIni; if ($null -ne $rule) { Read-StdSet $out $rule 'rule' } }
    $es = Get-StdEff $rule $def 'sev'
    if ($null -eq $es) { return , @() }
    return , $es.sc.ToArray()
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

# ---------------------------------------------------------------- plan of a review

# Each file goes to the first framework standard whose applies matches it. The others are common files: with one
# report they go to it; with several, to the framework of the nearest folder above them that holds files of
# frameworks, or to every report when that folder holds files of several frameworks (the repository root, for
# example). With no framework file at all the common standard makes the only report. Writes OutDir/<name>.diff
# with the blocks of the diff unchanged (read and written byte for byte, like awk).
function Invoke-StdPlan([string]$DiffPath, [string[]]$Ini, [string]$OutDir) {
    $out = New-Object System.Collections.Generic.List[string]
    $bytes = New-Object System.Text.UTF8Encoding($false)
    $latin = [Text.Encoding]::GetEncoding(28591)
    $fw = New-Object System.Collections.Generic.List[string]; $app = New-StdMap; $cm = ''
    # Only the enabled rules score.
    foreach ($l in $Ini) {
        $a = $l.Split("`t")
        if ($a[0] -ceq 'std' -and $a[6] -cne 'true') { continue }
        if ($a[0] -ceq 'std' -and $a[5] -ceq 'common') { $cm = $a[1] }
        elseif ($a[0] -ceq 'std') { $fw.Add($a[1]) }
        elseif ($a[0] -ceq 'applies') { $app[$a[1]] = [regex]::new($a[2]) }
    }
    $paths = New-Object System.Collections.Generic.List[string]; $blocks = New-Object System.Collections.Generic.List[object]
    $lines = $latin.GetString([IO.File]::ReadAllBytes($DiffPath)).Split("`n")
    $n = $lines.Count; if ($n -gt 0 -and $lines[$n - 1] -eq '') { $n-- }
    for ($i = 0; $i -lt $n; $i++) {
        $l = $lines[$i]
        if ($l.StartsWith('diff --git ', [StringComparison]::Ordinal)) {
            $p = $l.TrimEnd("`r")
            if ($p -cmatch ' "?b/.*$') { $p = $Matches[0].Substring(1).Trim('"'); if ($p.StartsWith('b/')) { $p = $p.Substring(2) } }
            $paths.Add($p); $sb = New-Object System.Text.StringBuilder; [void]$sb.Append($l); $blocks.Add($sb)
        }
        elseif ($blocks.Count -gt 0) { [void]$blocks[$blocks.Count - 1].Append("`n").Append($l) }
    }
    if ($paths.Count -eq 0) { $out.Add("!error`t`tthe diff lists no file"); return , $out.ToArray() }
    $own = @(); $cnt = New-StdMap
    foreach ($p in $paths) {
        $o = ''
        foreach ($f in $fw) { if ($app.ContainsKey($f) -and $app[$f].IsMatch($p)) { $o = $f; $cnt[$f] = 1 + [int]$cnt[$f]; break } }
        $own += $o
    }
    $rep = New-Object System.Collections.Generic.List[string]
    foreach ($f in $fw) { if ($cnt.ContainsKey($f)) { $rep.Add($f) } }
    $to = New-StdMap; $kind = @()
    if ($rep.Count -eq 0) {
        if ($cm -eq '') { $out.Add("!error`t`tno enabled framework rule covers the files of this PR and no common rule is enabled"); return , $out.ToArray() }
        $rep.Add($cm)
        for ($i = 0; $i -lt $paths.Count; $i++) { $to["$i`t$cm"] = 1; $kind += 'common' }
    }
    else {
        for ($i = 0; $i -lt $paths.Count; $i++) {
            if ($own[$i] -ne '') { $to["$i`t$($own[$i])"] = 1; $kind += 'framework'; continue }
            $kind += $(if ($cm -ne '') { 'common' } else { 'none' })
            if ($rep.Count -eq 1) { $to["$i`t$($rep[0])"] = 1; continue }
            $d = $paths[$i]
            do {
                $d = if ($d.Contains('/')) { $d.Substring(0, $d.LastIndexOf('/')) } else { '' }
                $hit = New-StdMap
                for ($j = 0; $j -lt $paths.Count; $j++) {
                    if ($own[$j] -ne '' -and ($d -eq '' -or $paths[$j].StartsWith("$d/", [StringComparison]::Ordinal))) { $hit[$own[$j]] = 1 }
                }
            } while ($hit.Count -eq 0 -and $d -ne '')
            foreach ($r in $rep) { if ($hit.Count -ne 1 -or $hit.ContainsKey($r)) { $to["$i`t$r"] = 1 } }
        }
    }
    foreach ($r in $rep) {
        $sb = New-Object System.Text.StringBuilder; $c = 0
        for ($i = 0; $i -lt $paths.Count; $i++) { if ($to.ContainsKey("$i`t$r")) { $c++; [void]$sb.Append($blocks[$i].ToString()).Append("`n") } }
        [IO.File]::WriteAllBytes((Join-Path $OutDir "$r.diff"), $latin.GetBytes($sb.ToString()))
        $out.Add("report`t$r`t$c")
    }
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $p = $bytes.GetString($latin.GetBytes($paths[$i]))
        foreach ($r in $rep) { if ($to.ContainsKey("$i`t$r")) { $out.Add("file`t$p`t$r`t$($kind[$i])") } }
    }
    return , $out.ToArray()
}
