# Parser and checks for scoring standards: the Markdown document, its scan rule file and the settings of the rules
# project (rules.ini, defaults.ini and the rule.ini of each rule).
# Shared by standard.sh and standard.zsh; lib/standard.ps1 implements the same rules with the same messages.
# Run with LC_ALL=C: text is handled as bytes, and the full-width separator ｜ is matched as a byte string.
#
# Variables: mode=doc        input: the Markdown document; role=common for the common standard; sevs=the severity
#                            codes of its scale, comma-separated from the most to the least severe ("" = not checked)
#            mode=scan       input: a scan rule file; codes=FILE with the "mode=doc" output of its document
#            mode=rules      no input: rules=the rules.ini of the rules project, rroot=its folder, defaults=its
#                            defaults.ini; reads the rule.ini of every rule
#            mode=scale      no input: rule=a rule.ini (may be ""), defaults=defaults.ini; prints the severity codes
#                            that apply to it ("sev" records)
#            mode=diff       input: the "mode=doc" outputs of the old and the new document
#            mode=plan       input: the PR diff; ini=FILE with the "mode=rules" output, out=DIR where the diff of
#                            each report is written (DIR/<name>.diff)
#            mode=re         input: "!re" records; prints the line of the first regex awk cannot compile
#                            (awk itself stops with an error; only=N tests record N only)
# Output: TAB-separated records, and diagnostics "!error<TAB>line<TAB>message[<TAB>file]" /
# "!warn<TAB>line<TAB>message[<TAB>file]" (an empty line means the whole file; without a file, the input file).

function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function diag(kind, line, msg) { print "!" kind "\t" line "\t" msg }
function unquote(v) { if (v ~ /^".*"$/ || v ~ /^'.*'$/) v = substr(v, 2, length(v) - 2); return v }
# Continuation lines are joined with a space only between two ASCII characters (CJK text needs none).
function joinl(a, b) { return a ((substr(a, length(a), 1) ~ /^[!-~]$/ && substr(b, 1, 1) ~ /^[!-~]$/) ? " " : "") b }
function dash(v) { return v == "" ? "-" : v }
# A severity of a check item: one of the scale (sevs) when it is known, otherwise any well-formed code.
function sevok(s) { return nsev ? (s in sev) : (s ~ /^[A-Za-z][A-Za-z0-9_-]*$/) }
function sevmsg(s) { return nsev ? "severity must be one of " sevlist " (case-sensitive), not \"" s "\"" : "severity codes are letters, digits, _ and -, not \"" s "\"" }

BEGIN {
    FW = "｜"; BOM = sprintf("%c%c%c", 239, 187, 191); NBSP = sprintf("%c%c", 194, 160)
    # The severity scale of the document (mode=doc): any code is accepted when it is not given.
    nsev = split(sevs, t, ","); sevlist = ""
    for (i = 1; i <= nsev; i++) { sev[t[i]] = 1; sevlist = sevlist (i > 1 ? ", " : "") t[i] }
    lowest = (nsev > 0) ? t[nsev] : ""
    split("A B C D E F G", LET, " ")
    split("正確性 安全性 測試品質 架構與設計 效能與資源使用 可讀性 可維護性", t, " ")
    for (i = 1; i <= 7; i++) canon[LET[i]] = t[i]
    split("Correctness|Security|Test quality|Architecture and design|Performance and resource use|Readability|Maintainability", t, "|")
    for (i = 1; i <= 7; i++) canonen[LET[i]] = t[i]
    sec = "free"
    if (mode == "scan") {
        while ((getline l < codes) > 0) { split(l, a, "\t"); if (a[1] == "check") known[a[2]] = 1 }
        close(codes)
    }
    # These modes read their files themselves; exit skips the main input.
    if (mode == "rules") { rules_main(); exit }
    if (mode == "scale") { scale_main(); exit }
}

mode == "plan" { plan_line($0); next }
{ sub(/\r$/, ""); if (FNR == 1 && substr($0, 1, 3) == BOM) $0 = substr($0, 4); gsub(NBSP, " ") }
mode == "doc" { doc_line($0); next }
mode == "scan" { scan_line($0); next }
mode == "diff" { diff_line(); next }
mode == "re" { if (only == "" || FNR == only + 0) { split($0, a, "\t"); if ("" ~ a[3]) { } } next }

END {
    if (mode == "doc") doc_end()
    else if (mode == "scan") scan_end()
    else if (mode == "diff") diff_end()
    else if (mode == "plan") plan_end()
}

# ---------------------------------------------------------------- Markdown document

# Removes HTML comments, which may span several lines.
function strip_comments(l,   out, p) {
    out = ""
    while (l != "") {
        if (incomment) { p = index(l, "-->"); if (!p) return out; l = substr(l, p + 3); incomment = 0; continue }
        p = index(l, "<!--"); if (!p) { out = out l; break }
        out = out substr(l, 1, p - 1); l = substr(l, p + 4); incomment = 1; coml = FNR
    }
    return out
}

function doc_line(l,   k, v, t, had) {
    if (FNR == 1 && l == "---") { infm = 1; hasfm = 1; return }
    if (infm) {
        if (l == "---") { infm = 0; return }
        if (l ~ /^[ \t]*(#|$)/) return
        if (l !~ /^[A-Za-z_-]+:/) { diag("error", FNR, "front matter lines are key: value"); return }
        k = substr(l, 1, index(l, ":") - 1); v = unquote(trim(substr(l, index(l, ":") + 1)))
        if (k == "name" || k == "version") { fm[k] = v; fml[k] = FNR }
        else if (k == "applies") diag("warn", FNR, "applies is set in the rule.ini of the rule, not in the document; this line is ignored")
        else diag("warn", FNR, "unknown front matter key " k " is ignored")
        return
    }
    if (l ~ /^[ \t]*(```|~~~)/) { infence = !infence; if (infence) fencel = FNR; return }
    if (infence) return
    had = incomment || index(l, "<!--")
    l = strip_comments(l)
    if (had && l ~ /^[ \t]*$/) return

    if (l ~ /^#[ \t]/) { close_item(); sec = "free"; curdim = ""; return }
    if (l ~ /^##[ \t]/) {
        close_item(); curdim = ""
        t = trim(substr(l, 3))
        sec = (t == "面向" || t == "Dimensions") ? "dims" : (t == "檢查項" || t == "Check items") ? "checks" : (t == "事先確認事項" || t == "Confirmations") ? "confirms" : "free"
        if (sec != "free") { if (secl[sec]) diag("error", FNR, "section ## " t " appears more than once"); else secl[sec] = FNR }
        return
    }
    if (sec == "checks" && l ~ /^#/) {
        close_item()
        if (l !~ /^###[ \t]+[A-G]\.[ \t]*[^ \t]/) { diag("error", FNR, "headings under ## 檢查項 (Check items) are ### X. name, with X from A to G"); curdim = "?"; return }
        t = l; sub(/^###[ \t]+/, "", t); curdim = substr(t, 1, 1); t = trim(substr(t, 3))
        if (curdim in dimhl) diag("error", FNR, "dimension " curdim " has more than one heading")
        else { dimhl[curdim] = FNR; dimh[curdim] = t }
        return
    }
    if (sec == "dims") { if (l ~ /^[ \t]*\|/) dim_row(l); return }
    if (sec == "checks") {
        if (curdim == "") return
        if (l ~ /^- /) { close_item(); it = substr(l, 3); itl = FNR; itk = "check"; itd = curdim; return }
        if (l ~ /^[ \t]*$/) { close_item(); return }
        if (l ~ /^  +[^ ]/ && itk != "") { it = joinl(trim(it), trim(l)); return }
        close_item()
        if (trim(l) == "無" || trim(l) == "None") { dimnone[curdim] = 1; return }
        diag("error", FNR, "unexpected text under a dimension heading; write check items (- code｜content｜severity), 無 (None), or an HTML comment")
        return
    }
    if (sec == "confirms") {
        if (l ~ /^- /) { close_item(); it = substr(l, 3); itl = FNR; itk = "confirm"; return }
        if (l ~ /^  +[^ ]/ && itk != "") { it = joinl(trim(it), trim(l)); return }
        close_item()
    }
}

function dim_row(l,   n, c, code) {
    if (l ~ /^[ \t]*\|[ \t:|-]+$/) return
    if (!dimhdr) { dimhdr = 1; return }
    n = split(l, c, "|")
    if (n < 4) { diag("error", FNR, "a dimension row is | code | name | focus |"); return }
    code = trim(c[2])
    if (code !~ /^[A-G]$/) { diag("error", FNR, "dimension codes are A to G, not \"" code "\""); return }
    if (code in dimrow) { diag("error", FNR, "dimension " code " is listed more than once"); return }
    dimrow[code] = FNR; dimname[code] = trim(c[3]); dimfocus[code] = (n >= 5) ? trim(c[4]) : ""
}

function close_item(   k) {
    if (itk == "") return
    k = itk; itk = ""
    if (k == "check") check_item(trim(it), itl, itd); else confirm_item(trim(it), itl)
}

function check_item(text, line, dim,   n, f, i, code, ok, letter, a, na, s, adj) {
    if (text == "無" || text == "None") { dimnone[dim] = 1; return }
    gsub(/\t/, " ", text)
    if (!index(text, FW)) {
        if (index(text, "|")) diag("error", line, "separate the fields with the full-width ｜, not |")
        else diag("error", line, "a check item is - code｜content｜severity, or - code｜content｜severity｜adjustable to｜condition")
        return
    }
    n = split(text, f, FW)
    if (n != 3 && n != 5) { diag("error", line, "a check item has 3 or 5 fields separated by ｜, not " n (index(text, "|") ? " (the half-width | is not a separator)" : "")); return }
    for (i = 1; i <= n; i++) f[i] = trim(f[i])
    code = f[1]; ok = 1
    if (role == "common") {
        if (code !~ /^CM-[A-G][0-9]+$/) { diag("error", line, "check codes of the common standard are CM- plus the dimension letter and a number (e.g. CM-A1), not \"" code "\""); ok = 0 }
        else letter = substr(code, 4, 1)
    }
    else if (code ~ /^CM/) { diag("error", line, "the CM prefix is reserved for the common standard (role=\"common\"): " code); ok = 0 }
    else if (code !~ /^[A-G][0-9]+$/) { diag("error", line, "check codes are the dimension letter and a number (e.g. A1), not \"" code "\""); ok = 0 }
    else letter = substr(code, 1, 1)
    if (ok && dim ~ /^[A-G]$/ && letter != dim) { diag("error", line, code " is under ### " dim "; the letter of a check code must match its dimension"); ok = 0 }
    if (ok && (code in chkl)) { diag("error", line, code " is already defined on line " chkl[code]); ok = 0 }
    if (f[2] == "") { diag("error", line, code " has no content"); ok = 0 }
    if (!sevok(f[3])) { diag("error", line, sevmsg(f[3])); ok = 0 }
    adj = "-"
    if (n == 5) {
        adj = ""
        if (f[4] == "") { diag("error", line, code " has an empty adjustable-to field"); ok = 0 }
        na = split(f[4], a, ",")
        for (i = 1; i <= na; i++) {
            s = trim(a[i])
            if (!sevok(s)) { diag("error", line, sevmsg(s)); ok = 0 }
            else if (s == f[3]) { diag("error", line, code " lists its default severity " s " as adjustable"); ok = 0 }
            else if (s == lowest) diag("warn", line, code ": " s " is the lowest severity, which is always allowed and does not need to be listed")
            else adj = adj (adj == "" ? "" : ",") s
        }
        if (adj == "") adj = "-"
        if (f[5] == "") { diag("error", line, code " has no condition for the adjustment"); ok = 0 }
    }
    if (!ok) { nbad++; return }
    chkl[code] = line; cnt[letter]++; nchk++
    if (adj != "-") nadj++
    rec[++nrec] = "check\t" code "\t" f[3] "\t" adj "\t" (n == 5 ? f[5] : "-") "\t" f[2] "\t" line
}

function confirm_item(text, line,   n, f, c, nc, i, s, list) {
    gsub(/\t/, " ", text)
    n = split(text, f, FW)
    if (n != 2) { diag("error", line, "a confirmation is - codes｜what to confirm" ((n == 1 && index(text, "|")) ? " (separate with the full-width ｜, not |)" : "")); return }
    list = ""
    nc = split(f[1], c, ",")
    for (i = 1; i <= nc; i++) {
        s = trim(c[i]); if (s == "") continue
        cref[++ncref] = s; crefl[ncref] = line; list = list (list == "" ? "" : ",") s
    }
    if (list == "") { diag("error", line, "a confirmation needs at least one check code"); return }
    if (trim(f[2]) == "") { diag("error", line, "a confirmation needs the thing to confirm"); return }
    con[++ncon] = "confirm\t" list "\t" trim(f[2]) "\t" line
}

function doc_end(   i, x, per) {
    close_item()
    if (infence) diag("error", fencel, "this code block is not closed")
    if (incomment) diag("error", coml, "this HTML comment is not closed")
    if (!hasfm) diag("error", 1, "the document must start with front matter (---, name:, version:, ---)")
    else if (infm) diag("error", 1, "the front matter is not closed with ---")
    else {
        if (fm["name"] == "") diag("error", 1, "the front matter has no name")
        else if (fm["name"] !~ /^[a-z0-9][a-z0-9-]*$/) diag("error", fml["name"], "name may only contain lowercase letters, digits and -")
        if (fm["version"] == "") diag("error", 1, "the front matter has no version")
    }
    if (!secl["dims"]) diag("error", "", "section ## 面向 (Dimensions) is missing")
    else for (i = 1; i <= 7; i++) {
        x = LET[i]
        if (!(x in dimrow)) diag("error", secl["dims"], "dimension " x " (" canon[x] ") is missing from the ## 面向 (Dimensions) table")
        else if (dimname[x] != canon[x] && dimname[x] != canonen[x]) diag("error", dimrow[x], "dimension " x " must be named " canon[x] " or " canonen[x] " (dimension codes and names cannot be changed)")
    }
    if (!secl["checks"]) diag("error", "", "section ## 檢查項 (Check items) is missing")
    else {
        for (i = 1; i <= 7; i++) {
            x = LET[i]
            if (!(x in dimhl)) diag("warn", secl["checks"], "### " x ". " canon[x] " is missing (keep the heading and write 無 or None when it has no check item)")
            else {
                if (dimh[x] != canon[x] && dimh[x] != canonen[x]) diag("warn", dimhl[x], "the heading should be ### " x ". " canon[x] " or ### " x ". " canonen[x])
                if (!cnt[x] && !dimnone[x]) diag("warn", dimhl[x], "### " x " has no check item; write 無 or None if that is intended")
            }
        }
        if (!nchk && !nbad) diag("error", secl["checks"], "the document has no check item")
    }
    for (i = 1; i <= ncref; i++) if (!(cref[i] in chkl)) diag("error", crefl[i], "the confirmation refers to " cref[i] ", which is not a check item")

    print "name\t" fm["name"]; print "version\t" fm["version"]
    for (i = 1; i <= 7; i++) { x = LET[i]; if (x in dimrow) print "dim\t" x "\t" dimname[x] "\t" dimfocus[x] }
    for (i = 1; i <= nrec; i++) print rec[i]
    for (i = 1; i <= ncon; i++) print con[i]
    per = ""
    for (i = 1; i <= 7; i++) per = per (i > 1 ? ", " : "") LET[i] " " (cnt[LET[i]] + 0)
    print "stats\t" (nchk + 0) "\t" per "\t" (nadj + 0) "\t" (ncon + 0)
}

# ---------------------------------------------------------------- scan rule file

# Checks that a regex only uses syntax that POSIX ERE (awk) and .NET read the same way,
# and queues it for the compile test.
function check_re(re, line, what,   i, n, c, d, inb, bad) {
    n = length(re); inb = 0; bad = ""
    for (i = 1; i <= n && bad == ""; i++) {
        c = substr(re, i, 1); d = substr(re, i + 1, 1)
        if (c == "\\") { if (d ~ /^[bBsSdDwWyYpPkK<>`'1-9]$/) bad = "\\" d; i++; continue }
        if (c == "[" && substr(re, i + 1) ~ /^:[a-z]+:\]/) { bad = "[:class:]"; continue }
        if (inb) { if (c == "]" && i > inb + 1 && !(i == inb + 2 && substr(re, inb + 1, 1) == "^")) inb = 0; continue }
        if (c == "[") { inb = i; continue }
        if (c == "(" && d == "?") bad = "(?"
        else if (c ~ /^[*+?}]$/ && d == "?") bad = c "?"
    }
    if (bad != "") { diag("error", line, what " uses " bad ", which POSIX ERE (awk) and .NET do not share; avoid \\b \\s \\d \\w, lookaround, lazy quantifiers, POSIX classes and back-references"); return 0 }
    print "!re\t" line "\t" re
    return 1
}

function check_id(id, line) {
    if (id ~ /^(CM-)?[A-G][0-9]+$/) { if (!(id in known)) diag("error", line, id " is not a check item of the standard (removed or renamed?)") }
    else if (id !~ /^[A-Z][A-Z0-9_]*$/) diag("error", line, "rule ids are check codes or uppercase tags (e.g. API), not \"" id "\"")
}

function scan_line(l,   n, f, w, nc, c, i, s, t) {
    if (l ~ /^[ \t]*$/) return
    if (l ~ /^#/) {
        if (l ~ /^# source:/) {
            n = split(trim(substr(l, 10)), t, " ")
            if (n != 3 || t[3] !~ /^sha256:[0-9a-f]+$/) diag("warn", FNR, "the source line is # source: <document file> <version> sha256:<hash>")
            else print "!source\t" FNR "\t" t[1] "\t" t[2] "\t" substr(t[3], 8)
            hassrc = 1
        }
        return
    }
    n = split(l, f, "\t")
    if (f[1] == "@scope") {
        if (n != 4) { diag("error", FNR, "@scope has 4 TAB-separated fields (@scope name within path-regex), not " n); return }
        w = f[3]; sub(/^!/, "", w)
        if (f[2] !~ /^[a-z][a-z0-9_-]*$/) diag("error", FNR, "scope names may only contain lowercase letters, digits, _ and -")
        else if (f[2] == "any") diag("error", FNR, "the scope any is built in and cannot be defined")
        else if (f[2] in scope) diag("error", FNR, "scope " f[2] " is already defined on line " scope[f[2]])
        else if (f[3] != "-" && !(w in scope)) diag("error", FNR, "within is -, a scope defined above, or !scope; " w " is not defined above")
        else { scope[f[2]] = FNR; nscope++ }
        check_re(f[4], FNR, "the path regex")
        return
    }
    if (f[1] == "@pr") {
        if (n != 4) { diag("error", FNR, "@pr has 4 TAB-separated fields (@pr id condition hint), not " n); return }
        check_id(f[2], FNR)
        nc = split(f[3], c, ",")
        for (i = 1; i <= nc; i++) {
            s = trim(c[i])
            if (s !~ /^(has|no|modified):[a-z][a-z0-9_-]*$/) diag("error", FNR, "conditions are has:scope, no:scope or modified:scope, not \"" s "\"")
            else { sref[++nsref] = substr(s, index(s, ":") + 1); srefl[nsref] = FNR }
        }
        if (trim(f[4]) == "") diag("error", FNR, "the hint is empty")
        npr++
        return
    }
    if (f[1] ~ /^@/) { diag("error", FNR, "unknown directive " f[1] " (use @scope or @pr)"); return }
    if (n != 7) { diag("error", FNR, "a line rule has 7 TAB-separated fields (id scope flags regex prev-regex exclude-regex hint), not " n); return }
    check_id(f[1], FNR)
    if (f[2] != "any") { sref[++nsref] = f[2]; srefl[nsref] = FNR }
    if (f[3] !~ /^(-|[ic]+)$/) diag("error", FNR, "flags are -, i, c or ic, not \"" f[3] "\"")
    if (f[4] == "" || f[4] == "-") diag("error", FNR, "the regex is required")
    else check_re(f[4], FNR, "the regex")
    if (f[5] != "-") check_re(f[5], FNR, "the prev-regex")
    if (f[6] != "-") check_re(f[6], FNR, "the exclude-regex")
    if (trim(f[7]) == "") diag("error", FNR, "the hint is empty")
    nrule++
}

function scan_end(   i) {
    for (i = 1; i <= nsref; i++) if (sref[i] != "any" && !(sref[i] in scope)) diag("error", srefl[i], "scope " sref[i] " is not defined (define it with @scope)")
    if (!nrule && !npr) diag("warn", "", "the file has no rule")
    if (!hassrc) diag("warn", "", "no # source: line, so it cannot be checked against the document; regenerate the file or add the line")
    print "stats\t" (nrule + 0) "\t" (nscope + 0) "\t" (npr + 0)
}

# ---------------------------------------------------------------- rules project: rules.ini, defaults.ini, rule.ini

function fdiag(kind, file, line, msg) { print "!" kind "\t" line "\t" msg "\t" file }
function isabs(p) { return p ~ /^\// || p ~ /^[A-Za-z]:/ }
# A path in a settings file: backslashes become slashes, and a relative path is relative to the folder dir.
function pjoin(dir, p) { gsub(/\\/, "/", p); return (p == "" || isabs(p)) ? p : dir "/" p }
function okcode(c) { return c ~ /^[A-Za-z][A-Za-z0-9_-]*$/ }

# Reads an INI file as id: its sections in file order (secn, isec = line) and the keys of each section in order
# (keyn, ikv = value, ikl = line). Returns 0 when the file cannot be read.
function ini_read(file, id,    l, ln, r, s, k, v) {
    ln = 0; s = ""
    while ((r = (getline l < file)) > 0) {
        ln++; sub(/\r$/, "", l); if (ln == 1 && substr(l, 1, 3) == BOM) l = substr(l, 4); gsub(NBSP, " ", l); l = trim(l)
        if (l == "" || l ~ /^[;#]/) continue
        if (l ~ /^\[.*\]$/) {
            s = trim(substr(l, 2, length(l) - 2))
            if ((id SUBSEP s) in isec) { fdiag("error", file, ln, "[" s "] is already defined on line " isec[id, s]); s = "\001" }
            else { isec[id, s] = ln; nsec[id]++; secn[id, nsec[id]] = s }
            continue
        }
        if (l !~ /^[A-Za-z0-9_.]+[ \t]*=/) { fdiag("error", file, ln, "lines are [section], key=\"value\" or ; comments"); continue }
        if (s == "") { fdiag("error", file, ln, "key outside a [section]"); continue }
        if (s == "\001") continue
        k = trim(substr(l, 1, index(l, "=") - 1)); v = unquote(trim(substr(l, index(l, "=") + 1)))
        # meaning of a [severity:CODE] section may be repeated: the lines are joined with newlines.
        if ((id SUBSEP s SUBSEP k) in ikl && k == "meaning" && s ~ /^severity:/) { ikv[id, s, k] = ikv[id, s, k] "\n" v; continue }
        if ((id SUBSEP s SUBSEP k) in ikl) { fdiag("error", file, ln, k " is already set on line " ikl[id, s, k]); continue }
        ikv[id, s, k] = v; ikl[id, s, k] = ln; nkey[id, s]++; keyn[id, s, nkey[id, s]] = k
    }
    if (r < 0) return 0
    close(file)
    return 1
}

# Text shown in the report (name, meaning): without TAB or | (meaning may have several lines, see ini_read).
function oktext(file, id, s, k) {
    if (ikv[id, s, k] ~ /[\t|]/) { fdiag("error", file, ikl[id, s, k], k " may not contain a TAB or |"); return 0 }
    return 1
}

# Checks the rule.ini (kind "rule") or defaults.ini (kind "defaults") read as id, and records the groups it defines
# (grp[id, g] = line): "scoring" (merge), "points" (pv), "sev" (ns severities sc[id, i] from the most severe) and
# "grade" (ng grades gc[id, i] from the highest).
function set_read(file, id, kind,    i, j, s, k, v, c, ln, sum, x, all) {
    for (i = 1; i <= nsec[id]; i++) {
        s = secn[id, i]; ln = isec[id, s]
        if (s == "rule") {
            if (kind != "rule") { fdiag("error", file, ln, "[rule] belongs in the rule.ini of a rule"); continue }
            for (j = 1; j <= nkey[id, s]; j++) { k = keyn[id, s, j]; if (k !~ /^(standard|scan|applies|role)$/) fdiag("error", file, ikl[id, s, k], "unknown key " k " in [rule] (standard, scan, applies, role)") }
        }
        else if (s == "scoring") {
            grp[id, "scoring"] = ln; mergev[id] = "false"
            for (j = 1; j <= nkey[id, s]; j++) {
                k = keyn[id, s, j]; v = tolower(ikv[id, s, k])
                if (k != "merge") fdiag("error", file, ikl[id, s, k], "unknown key " k " in [scoring] (merge)")
                else if (v != "true" && v != "false") fdiag("error", file, ikl[id, s, k], "merge is \"true\" or \"false\", not \"" ikv[id, s, k] "\"")
                else mergev[id] = v
            }
        }
        else if (s == "points") {
            grp[id, "points"] = ln; sum = 0; all = 1
            for (j = 1; j <= nkey[id, s]; j++) {
                k = keyn[id, s, j]
                if (k !~ /^[A-G]$/) fdiag("error", file, ikl[id, s, k], "unknown dimension " k " in [points] (A to G)")
                else if (ikv[id, s, k] !~ /^[0-9]+$/) { fdiag("error", file, ikl[id, s, k], k " must be a whole number, not \"" ikv[id, s, k] "\""); all = 0 }
            }
            for (j = 1; j <= 7; j++) {
                x = LET[j]
                if (!((id SUBSEP s SUBSEP x) in ikl)) { fdiag("error", file, ln, "[points] needs all seven dimensions; " x " is missing"); all = 0 }
                else { pv[id, x] = ikv[id, s, x] + 0; sum += pv[id, x] }
            }
            if (all && sum != 100) fdiag("error", file, ln, "the seven dimensions of [points] must add up to 100, not " sum)
        }
        else if (s ~ /^severity:/) {
            c = substr(s, 10)
            if (!((id SUBSEP "sev") in grp)) grp[id, "sev"] = ln
            if (!okcode(c)) { fdiag("error", file, ln, "severity codes are letters, digits, _ and -, starting with a letter, not \"" c "\""); continue }
            for (j = 1; j <= nkey[id, s]; j++) { k = keyn[id, s, j]; if (k !~ /^(name|points|cap|meaning)$/) fdiag("error", file, ikl[id, s, k], "unknown key " k " in [" s "] (name, points, cap, meaning)") }
            ns[id]++; sc[id, ns[id]] = c; sln[id, c] = ln
            sname[id, c] = (ikv[id, s, "name"] != "" && oktext(file, id, s, "name")) ? ikv[id, s, "name"] : c
            if (ikv[id, s, "points"] !~ /^[0-9]+$/) fdiag("error", file, ln, "[" s "] needs points, the whole number deducted for each finding")
            spts[id, c] = ikv[id, s, "points"] + 0
            scap[id, c] = ikv[id, s, "cap"]
            if (ikv[id, s, "meaning"] == "") fdiag("error", file, ln, "[" s "] needs meaning, which tells the AI when to use it")
            smean[id, c] = oktext(file, id, s, "meaning") ? ikv[id, s, "meaning"] : ""
        }
        else if (s ~ /^grade:/) {
            c = substr(s, 7)
            if (!((id SUBSEP "grade") in grp)) grp[id, "grade"] = ln
            if (!okcode(c)) { fdiag("error", file, ln, "grade codes are letters, digits, _ and -, starting with a letter, not \"" c "\""); continue }
            for (j = 1; j <= nkey[id, s]; j++) { k = keyn[id, s, j]; if (k !~ /^(name|min)$/) fdiag("error", file, ikl[id, s, k], "unknown key " k " in [" s "] (name, min)") }
            ng[id]++; gc[id, ng[id]] = c; gln[id, c] = ln
            gname[id, c] = (ikv[id, s, "name"] != "" && oktext(file, id, s, "name")) ? ikv[id, s, "name"] : c
            if (ikv[id, s, "min"] !~ /^[0-9]+$/) fdiag("error", file, ln, "[" s "] needs min, the lowest total (a whole number) of the grade")
            gmin[id, c] = ikv[id, s, "min"] + 0
        }
        else if (s != "\001") fdiag("error", file, ln, "unknown section [" s "] (" (kind == "rule" ? "rule, " : "") "scoring, points, severity:CODE, grade:CODE)")
    }
    # Grades go from the highest to the lowest; the last one takes every total down to 0.
    for (i = 1; i <= ng[id]; i++) {
        c = gc[id, i]
        if (i == 1 && gmin[id, c] > 100) fdiag("error", file, gln[id, c], "the min of grade " c " must be at most 100")
        if (i > 1 && gmin[id, c] >= gmin[id, gc[id, i - 1]]) fdiag("error", file, gln[id, c], "grades go from the highest to the lowest: the min of " c " (" gmin[id, c] ") must be lower than that of " gc[id, i - 1] " (" gmin[id, gc[id, i - 1]] ")")
        if (i == ng[id] && gmin[id, c] != 0) fdiag("error", file, gln[id, c], "the last grade " c " is the lowest; its min must be 0")
    }
}

# The settings group g of the rule id: its own when its rule.ini defines it, otherwise that of defaults.ini ("D");
# "" when neither does.
function eff(id, g) { return ((id SUBSEP g) in grp) ? id : ((("D" SUBSEP g) in grp) ? "D" : "") }
function fileof(id) { return id == "D" ? defaults : setfile[id] }
function shortof(id) { return id == "D" ? "defaults.ini" : "rule.ini" }

# The applies patterns as one regex for the path relative to the repository root (POSIX ERE and .NET read it the
# same way): a pattern without / matches the file name, one with / the whole path; ** crosses directories.
function glob_re(p,   i, n, c, r) {
    r = (index(p, "/") ? "^" : "(^|/)"); sub(/^\//, "", p); n = length(p)
    for (i = 1; i <= n; i++) {
        c = substr(p, i, 1)
        if (substr(p, i, 3) == "**/") { r = r "(.*/)?"; i += 2 }
        else if (substr(p, i, 2) == "**") { r = r ".*"; i++ }
        else if (c == "*") r = r "[^/]*"
        else if (c == "?") r = r "[^/]"
        else if (index(".+()^$|{}[]\\", c)) r = r "\\" c
        else r = r c
    }
    return "(" r "$)"
}

# Checks rules.ini, defaults.ini and the rule.ini of every rule, and prints for each rule (enabled or not):
#   std <name> <line> <document> <scan rules> <role> <enable> <rule.ini>   (- for an empty field)
#   applies <name> <regex>, points <name> <dim> <points>, merge <name> true|false, from <name> <group> <file>,
#   severity <name> <code> <points> <cap> <display name> <meaning>   (from the most severe)
#   grade <name> <code> <min> <display name>                         (from the highest)
# and "defaults <defaults.ini>" at the end.
function rules_main(    i, j, s, id, ln, k, p, e, d, doc, scan, role, apps, re, n, a, x, src, gs, c, ok, ncommon, nen, ep, eg) {
    if (!ini_read(rules, "R")) { fdiag("error", rules, "", "file not found"); return }
    if (!ini_read(defaults, "D")) fdiag("error", defaults, "", "file not found; the rules project needs defaults.ini with the default points, severities and grades")
    else set_read(defaults, "D", "defaults")
    if (!nsec["R"]) fdiag("error", rules, "", "no rule is registered; add a [name] section with path=\"...\" and enable=\"true\"")
    for (i = 1; i <= nsec["R"]; i++) {
        s = secn["R", i]; ln = isec["R", s]; id = "r" i
        if (s !~ /^[a-z0-9][a-z0-9-]*$/) fdiag("error", rules, ln, "section names are the name of the rule: lowercase letters, digits and -")
        for (j = 1; j <= nkey["R", s]; j++) {
            k = keyn["R", s, j]
            if (k ~ /^(scan|applies|role|points\.[A-G])$/) fdiag("error", rules, ikl["R", s, k], k " is set in the rule.ini of the rule, not in rules.ini")
            else if (k != "path" && k != "enable") fdiag("error", rules, ikl["R", s, k], "unknown key " k " (path, enable)")
        }
        p = ikv["R", s, "path"]; e = tolower(ikv["R", s, "enable"])
        if (p == "") fdiag("error", rules, ln, "[" s "] has no path (the folder of its rule.ini)")
        if (!(("R" SUBSEP s SUBSEP "enable") in ikl)) { fdiag("error", rules, ln, "[" s "] has no enable (\"true\" or \"false\")"); e = "false" }
        else if (e != "true" && e != "false") { fdiag("error", rules, ikl["R", s, "enable"], "enable is \"true\" or \"false\", not \"" ikv["R", s, "enable"] "\""); e = "false" }
        if (e == "true") nen++
        d = pjoin(rroot, p); sub(/\/+$/, "", d); setfile[id] = (p == "" ? "" : d "/rule.ini")
        doc = ""; scan = ""; role = ""; re = ""; ok = 0
        if (p == "") { }
        else if (!ini_read(setfile[id], id)) fdiag("error", setfile[id], "", "file not found (the path of [" s "] in rules.ini)")
        else {
            ok = 1
            set_read(setfile[id], id, "rule")
            if (!((id SUBSEP "rule") in isec)) fdiag("error", setfile[id], "", "[rule] is missing (standard=\"<the Markdown document>\")")
            else if (ikv[id, "rule", "standard"] == "") fdiag("error", setfile[id], isec[id, "rule"], "[rule] has no standard (the Markdown document)")
            doc = pjoin(d, ikv[id, "rule", "standard"]); scan = pjoin(d, ikv[id, "rule", "scan"])
            role = ikv[id, "rule", "role"]; apps = ikv[id, "rule", "applies"]
            if (role != "" && role != "common") { fdiag("error", setfile[id], ikl[id, "rule", "role"], "role is \"common\" or not set, not \"" role "\""); role = "" }
            if (role == "common") {
                if (e == "true" && ++ncommon > 1) fdiag("error", rules, ln, "only one enabled rule can have role=\"common\"")
                if (apps != "") fdiag("warn", setfile[id], ikl[id, "rule", "applies"], "applies is ignored for the common standard, which covers the files no framework rule covers")
            }
            else if ((id SUBSEP "rule") in isec && apps == "") fdiag("error", setfile[id], isec[id, "rule"], "[rule] has no applies (framework rules need one)")
            else {
                n = split(apps, a, ",")
                for (j = 1; j <= n; j++) {
                    x = trim(a[j]); if (x == "") continue
                    re = re (re == "" ? "" : "|") glob_re(x)
                    if (e != "true") continue
                    if ((x in owner) && owner[x] != s) fdiag("error", setfile[id], ikl[id, "rule", "applies"], "the pattern " x " is also in [" owner[x] "]; a file may belong to one enabled framework rule only")
                    else owner[x] = s
                }
            }
        }
        # Empty values are written as - so that the shells can read the TAB-separated fields.
        print "std\t" s "\t" ln "\t" dash(doc) "\t" dash(scan) "\t" dash(role) "\t" e "\t" dash(setfile[id])
        if (!ok) continue
        if (role != "common" && re != "") print "applies\t" s "\t" re
        # The common rule never uses the [points], [grade:CODE] sections and caps of its own rule.ini: they are warned
        # about, and its points and grades come from defaults.ini.
        ep = eff(id, "points"); eg = eff(id, "grade")
        if (role == "common" && ep == id) {
            fdiag("warn", setfile[id], isec[id, "points"], "[points] is never used by the common rule (role=\"common\"); its points come from defaults.ini")
            ep = ((("D" SUBSEP "points") in grp) ? "D" : "")
        }
        if (role == "common" && eg == id) {
            fdiag("warn", setfile[id], gln[id, gc[id, 1]], "[grade:CODE] sections are never used by the common rule (role=\"common\"); its grades come from defaults.ini")
            eg = ((("D" SUBSEP "grade") in grp) ? "D" : "")
        }
        if (ep == "") fdiag("error", setfile[id], "", "no [points] in rule.ini or defaults.ini")
        if (eff(id, "sev") == "") fdiag("error", setfile[id], "", "no [severity:CODE] section in rule.ini or defaults.ini")
        if (eg == "") fdiag("error", setfile[id], "", "no [grade:CODE] section in rule.ini or defaults.ini")
        print "from\t" s "\tpoints\t" shortof(ep)
        print "from\t" s "\tseverities\t" shortof(eff(id, "sev"))
        print "from\t" s "\tgrades\t" shortof(eg)
        if ((src = ep) != "") for (j = 1; j <= 7; j++) print "points\t" s "\t" LET[j] "\t" pv[src, LET[j]] + 0
        src = eff(id, "scoring"); print "merge\t" s "\t" (src == "" ? "false" : mergev[src])
        if ((src = eff(id, "sev")) != "") for (j = 1; j <= ns[src]; j++) {
            c = sc[src, j]; x = scap[src, c]
            if (x != "" && role == "common" && src == id) {
                fdiag("warn", setfile[id], ikl[id, "severity:" c, "cap"], "cap is never used by the common rule (role=\"common\")")
                x = ""
            }
            # The grade a severity caps at must be one of the grades that apply (checked once per pair of files).
            if (x != "" && eg != "" && !((eg SUBSEP "grade:" x) in isec) && !((src, eg, c) in capdone)) {
                capdone[src, eg, c] = 1
                k = ""; for (n = 1; n <= ng[eg]; n++) k = k (n > 1 ? ", " : "") gc[eg, n]
                fdiag("error", fileof(src), ikl[src, "severity:" c, "cap"], "cap " x " is not one of the grades that apply to [" s "] (" k ")")
            }
            # The lines of a multi-line meaning are separated by | in the record (| cannot appear in the text).
            k = smean[src, c]; gsub(/\n/, "|", k)
            print "severity\t" s "\t" c "\t" spts[src, c] "\t" dash(x) "\t" sname[src, c] "\t" dash(k)
        }
        if ((src = eg) != "") for (j = 1; j <= ng[src]; j++) { c = gc[src, j]; print "grade\t" s "\t" c "\t" gmin[src, c] "\t" gname[src, c] }
    }
    if (nsec["R"] && !nen) fdiag("warn", rules, "", "no rule is enabled (enable=\"true\")")
    if (nsec["R"] && !ncommon) fdiag("warn", rules, "", "no enabled common rule (role=\"common\"); files that no framework rule covers will not be scored")
    print "defaults\t" defaults
}

# The severity codes that apply to a rule.ini (rule, may be ""): its own, otherwise those of defaults.ini.
function scale_main(    src, j) {
    if (ini_read(defaults, "D")) set_read(defaults, "D", "defaults")
    if (rule != "" && ini_read(rule, "X")) { setfile["X"] = rule; set_read(rule, "X", "rule") }
    src = eff("X", "sev")
    if (src != "") for (j = 1; j <= ns[src]; j++) print "sev\t" sc[src, j]
}

# ---------------------------------------------------------------- diff of two documents

function diff_line(   a, k) {
    split($0, a, "\t")
    k = (FNR == NR) ? "o" : "n"
    if (a[1] == "version") ver[k] = a[2]
    else if (a[1] == "dim") focus[k, a[2]] = a[4]
    else if (a[1] == "check") {
        ids[k, ++nid[k]] = a[2]; has[k, a[2]] = 1
        dv[k, a[2], "content"] = a[6]; dv[k, a[2], "severity"] = a[3]; dv[k, a[2], "adjustable"] = a[4]; dv[k, a[2], "condition"] = a[5]
    }
    else if (a[1] == "confirm") { cf[k, ++ncf[k]] = a[2] FW a[3]; hascf[k, a[2] FW a[3]] = 1 }
}

function item(k, c,   s) {
    s = c FW dv[k, c, "content"] FW dv[k, c, "severity"]
    if (dv[k, c, "adjustable"] != "-") s = s FW dv[k, c, "adjustable"] FW dv[k, c, "condition"]
    return s
}

function diff_end(   i, j, c, x, f, nf, add, del, chg, d) {
    split("content severity adjustable condition", f, " ")
    if (ver["o"] != ver["n"]) print "version: " ver["o"] " -> " ver["n"]
    for (i = 1; i <= 7; i++) { x = LET[i]; if (focus["o", x] != focus["n", x]) { print "~ dimension " x " focus: " focus["o", x] " -> " focus["n", x]; chg++ } }
    for (i = 1; i <= nid["n"]; i++) {
        c = ids["n", i]
        if (!has["o", c]) { print "+ " item("n", c); add++; continue }
        d = 0
        for (j = 1; j <= 4; j++) if (dv["o", c, f[j]] != dv["n", c, f[j]]) { print "~ " c " " f[j] ": " dv["o", c, f[j]] " -> " dv["n", c, f[j]]; d = 1 }
        chg += d
    }
    for (i = 1; i <= nid["o"]; i++) { c = ids["o", i]; if (!has["n", c]) { print "- " item("o", c); del++ } }
    for (i = 1; i <= ncf["n"]; i++) if (!hascf["o", cf["n", i]]) { print "+ confirm " cf["n", i]; add++ }
    for (i = 1; i <= ncf["o"]; i++) if (!hascf["n", cf["o", i]]) { print "- confirm " cf["o", i]; del++ }
    print (add + 0) " added, " (del + 0) " removed, " (chg + 0) " changed"
}

# ---------------------------------------------------------------- plan of a review

# Keeps the PR diff as one block per file (lines unchanged, so the diff of each report is a valid diff).
function plan_line(l,   p) {
    if (l ~ /^diff --git /) {
        p = l; sub(/\r$/, "", p)
        if (match(p, / "?b\/.*$/)) { p = substr(p, RSTART + 1); gsub(/^"|"$/, "", p); sub(/^b\//, "", p) }
        nb++; bpath[nb] = p; blk[nb] = l
    }
    else if (nb > 0) blk[nb] = blk[nb] "\n" l
}

# Each file goes to the first framework standard whose applies matches it. The others are common files: with one
# report they go to it; with several, to the framework of the nearest folder above them that holds files of
# frameworks, or to every report when that folder holds files of several frameworks (the repository root, for
# example). With no framework file at all the common standard makes the only report.
function plan_end(   l, a, i, j, k, p, d, n, hit, cm, f) {
    # Only the enabled rules score.
    while ((getline l < ini) > 0) {
        split(l, a, "\t")
        if (a[1] == "std" && a[7] != "true") continue
        if (a[1] == "std" && a[6] == "common") cm = a[2]
        else if (a[1] == "std") fw[++nfw] = a[2]
        else if (a[1] == "applies") app[a[2]] = a[3]
    }
    close(ini)
    if (!nb) { diag("error", "", "the diff lists no file"); return }
    for (i = 1; i <= nb; i++) {
        own[i] = ""
        for (k = 1; k <= nfw; k++) if (bpath[i] ~ app[fw[k]]) { own[i] = fw[k]; cnt[fw[k]]++; break }
    }
    for (k = 1; k <= nfw; k++) if (cnt[fw[k]]) rep[++nrep] = fw[k]
    if (!nrep) {
        if (cm == "") { diag("error", "", "no enabled framework rule covers the files of this PR and no common rule is enabled"); return }
        rep[++nrep] = cm
        for (i = 1; i <= nb; i++) { to[i, cm] = 1; kind[i] = "common" }
    }
    else for (i = 1; i <= nb; i++) {
        if (own[i] != "") { to[i, own[i]] = 1; kind[i] = "framework"; continue }
        kind[i] = (cm != "") ? "common" : "none"
        if (nrep == 1) { to[i, rep[1]] = 1; continue }
        d = bpath[i]
        do {
            d = (index(d, "/") ? substr(d, 1, match(d, /\/[^\/]*$/) - 1) : "")
            n = 0; split("", hit)
            for (j = 1; j <= nb; j++)
                if (own[j] != "" && !(own[j] in hit) && (d == "" || index(bpath[j], d "/") == 1)) { hit[own[j]] = 1; n++ }
        } while (n == 0 && d != "")
        for (k = 1; k <= nrep; k++) if (n != 1 || (rep[k] in hit)) to[i, rep[k]] = 1
    }
    for (k = 1; k <= nrep; k++) {
        n = 0; f = out "/" rep[k] ".diff"
        printf "" > f
        for (i = 1; i <= nb; i++) if ((i SUBSEP rep[k]) in to) { n++; print blk[i] > f }
        close(f)
        print "report\t" rep[k] "\t" n
    }
    for (i = 1; i <= nb; i++) for (k = 1; k <= nrep; k++) if ((i SUBSEP rep[k]) in to) print "file\t" bpath[i] "\t" rep[k] "\t" kind[i]
}
