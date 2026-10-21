# Parser and checks for scoring standards: the Markdown document, its scan rule file and configs/standards.ini.
# Shared by standard.sh and standard.zsh; lib/standard.ps1 implements the same rules with the same messages.
# Run with LC_ALL=C: text is handled as bytes, and the full-width separator ｜ is matched as a byte string.
#
# Variables: mode=doc        input: the Markdown document; role=common for the common standard
#            mode=scan       input: a scan rule file; codes=FILE with the "mode=doc" output of its document
#            mode=standards  input: configs/standards.ini; settings=FILE with [points] (may be missing)
#            mode=diff       input: the "mode=doc" outputs of the old and the new document
#            mode=re         input: "!re" records; prints the line of the first regex awk cannot compile
#                            (awk itself stops with an error; only=N tests record N only)
# Output: TAB-separated records, and diagnostics "!error<TAB>line<TAB>message" / "!warn<TAB>line<TAB>message"
# (an empty line means the whole file).

function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function diag(kind, line, msg) { print "!" kind "\t" line "\t" msg }
function unquote(v) { if (v ~ /^".*"$/ || v ~ /^'.*'$/) v = substr(v, 2, length(v) - 2); return v }
# Continuation lines are joined with a space only between two ASCII characters (CJK text needs none).
function joinl(a, b) { return a ((substr(a, length(a), 1) ~ /^[!-~]$/ && substr(b, 1, 1) ~ /^[!-~]$/) ? " " : "") b }
function dash(v) { return v == "" ? "-" : v }
function sevmsg(s) { return "severity must be Critical, Major, Minor or Nit (case-sensitive), not \"" s "\"" }

BEGIN {
    FW = "｜"; BOM = sprintf("%c%c%c", 239, 187, 191); NBSP = sprintf("%c%c", 194, 160)
    split("Critical Major Minor Nit", t, " "); for (i = 1; i <= 4; i++) sev[t[i]] = 1
    split("A B C D E F G", LET, " ")
    split("正確性 安全性 測試品質 架構與設計 效能與資源使用 可讀性 可維護性", t, " ")
    for (i = 1; i <= 7; i++) canon[LET[i]] = t[i]
    sec = "free"
    if (mode == "scan") {
        while ((getline l < codes) > 0) { split(l, a, "\t"); if (a[1] == "check") known[a[2]] = 1 }
        close(codes)
    }
    if (mode == "standards") {
        split("25 15 15 15 10 10 10", t, " "); for (i = 1; i <= 7; i++) gpts[LET[i]] = t[i]
        insec = 0
        while (settings != "" && (getline l < settings) > 0) {
            sub(/\r$/, "", l)
            if (l ~ /^[ \t]*\[/) { h = l; gsub(/^[ \t]*\[|\][ \t]*$/, "", h); insec = (h == "points"); continue }
            if (insec && l ~ /^[ \t]*[A-G][ \t]*=/) { k = trim(substr(l, 1, index(l, "=") - 1)); gpts[k] = unquote(trim(substr(l, index(l, "=") + 1))) }
        }
        if (settings != "") close(settings)
    }
}

{ sub(/\r$/, ""); if (FNR == 1 && substr($0, 1, 3) == BOM) $0 = substr($0, 4); gsub(NBSP, " ") }
mode == "doc" { doc_line($0); next }
mode == "scan" { scan_line($0); next }
mode == "standards" { std_line($0); next }
mode == "diff" { diff_line(); next }
mode == "re" { if (only == "" || FNR == only + 0) { split($0, a, "\t"); if ("" ~ a[3]) { } } next }

END {
    if (mode == "doc") doc_end()
    else if (mode == "scan") scan_end()
    else if (mode == "standards") std_end()
    else if (mode == "diff") diff_end()
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
        else if (k == "applies") diag("warn", FNR, "applies is set in configs/standards.ini, not in the document; this line is ignored")
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
        sec = (t == "面向") ? "dims" : (t == "檢查項") ? "checks" : (t == "事先確認事項") ? "confirms" : "free"
        if (sec != "free") { if (secl[sec]) diag("error", FNR, "section ## " t " appears more than once"); else secl[sec] = FNR }
        return
    }
    if (sec == "checks" && l ~ /^#/) {
        close_item()
        if (l !~ /^###[ \t]+[A-G]\.[ \t]*[^ \t]/) { diag("error", FNR, "headings under ## 檢查項 are ### X. name, with X from A to G"); curdim = "?"; return }
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
        if (trim(l) == "無") { dimnone[curdim] = 1; return }
        diag("error", FNR, "unexpected text under a dimension heading; write check items (- code｜content｜severity), 無, or an HTML comment")
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
    if (text == "無") { dimnone[dim] = 1; return }
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
    if (!(f[3] in sev)) { diag("error", line, sevmsg(f[3])); ok = 0 }
    adj = "-"
    if (n == 5) {
        adj = ""
        if (f[4] == "") { diag("error", line, code " has an empty adjustable-to field"); ok = 0 }
        na = split(f[4], a, ",")
        for (i = 1; i <= na; i++) {
            s = trim(a[i])
            if (!(s in sev)) { diag("error", line, sevmsg(s)); ok = 0 }
            else if (s == f[3]) { diag("error", line, code " lists its default severity " s " as adjustable"); ok = 0 }
            else if (s == "Nit") diag("warn", line, code ": Nit is always allowed and does not need to be listed")
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
    if (!secl["dims"]) diag("error", "", "section ## 面向 is missing")
    else for (i = 1; i <= 7; i++) {
        x = LET[i]
        if (!(x in dimrow)) diag("error", secl["dims"], "dimension " x " (" canon[x] ") is missing from the ## 面向 table")
        else if (dimname[x] != canon[x]) diag("error", dimrow[x], "dimension " x " must be named " canon[x] " (dimension codes and names cannot be changed)")
    }
    if (!secl["checks"]) diag("error", "", "section ## 檢查項 is missing")
    else {
        for (i = 1; i <= 7; i++) {
            x = LET[i]
            if (!(x in dimhl)) diag("warn", secl["checks"], "### " x ". " canon[x] " is missing (keep the heading and write 無 when it has no check item)")
            else {
                if (dimh[x] != canon[x]) diag("warn", dimhl[x], "the heading should be ### " x ". " canon[x])
                if (!cnt[x] && !dimnone[x]) diag("warn", dimhl[x], "### " x " has no check item; write 無 if that is intended")
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

# ---------------------------------------------------------------- configs/standards.ini

function std_line(l,   k, v, x) {
    l = trim(l)
    if (l == "" || l ~ /^[;#]/) return
    if (l ~ /^\[.*\]$/) {
        cur = substr(l, 2, length(l) - 2)
        if (cur !~ /^[a-z0-9][a-z0-9-]*$/) diag("error", FNR, "section names are the name of the standard: lowercase letters, digits and -")
        if (cur in stdl) { diag("error", FNR, "[" cur "] is already defined on line " stdl[cur]); cur = ""; dupsec = 1 }
        else { stdl[cur] = FNR; order[++nstd] = cur; dupsec = 0 }
        return
    }
    if (l !~ /^[A-Za-z0-9_.]+[ \t]*=/) { diag("error", FNR, "lines are [name], key=\"value\" or ; comments"); return }
    if (cur == "") { if (!dupsec) diag("error", FNR, "key outside a [section]"); return }
    k = trim(substr(l, 1, index(l, "=") - 1)); v = unquote(trim(substr(l, index(l, "=") + 1)))
    if (k == "path" || k == "scan" || k == "applies" || k == "role") { val[cur, k] = v; vall[cur, k] = FNR }
    else if (k ~ /^points\.[A-G]$/) {
        x = substr(k, 8, 1)
        if (v !~ /^[0-9]+$/) diag("error", FNR, k " must be a whole number, not \"" v "\"")
        else { pts[cur, x] = v; ptsl[cur] = ptsl[cur] ? ptsl[cur] : FNR }
    }
    else diag("error", FNR, "unknown key " k " (path, scan, applies, role, points.A to points.G)")
}

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

function std_end(   i, j, s, n, p, a, x, sum, ncommon, re) {
    if (!nstd) { diag("error", "", "no standard is registered; add a [name] section with path=\"...\""); return }
    for (i = 1; i <= nstd; i++) {
        s = order[i]; re = ""
        if (val[s, "path"] == "") diag("error", stdl[s], "[" s "] has no path")
        if (val[s, "role"] != "" && val[s, "role"] != "common") diag("error", vall[s, "role"], "role is \"common\" or not set, not \"" val[s, "role"] "\"")
        if (val[s, "role"] == "common") {
            if (++ncommon > 1) diag("error", vall[s, "role"], "only one standard can have role=\"common\"")
            if (val[s, "applies"] != "") diag("warn", vall[s, "applies"], "applies is ignored for the common standard, which covers the files no framework standard covers")
        }
        else if (val[s, "applies"] == "") diag("error", stdl[s], "[" s "] has no applies (framework standards need one)")
        else {
            n = split(val[s, "applies"], a, ",")
            for (j = 1; j <= n; j++) {
                p = trim(a[j]); if (p == "") continue
                re = re (re == "" ? "" : "|") glob_re(p)
                if ((p in owner) && owner[p] != s) diag("error", vall[s, "applies"], "the pattern " p " is also in [" owner[p] "]; a file may belong to one framework standard only")
                else owner[p] = s
            }
        }
        if (ptsl[s]) {
            sum = 0
            for (j = 1; j <= 7; j++) { x = LET[j]; sum += ((s SUBSEP x) in pts) ? pts[s, x] : gpts[x] }
            if (sum != 100) diag("error", ptsl[s], "[" s "] the seven dimensions must add up to 100 with the overrides, not " sum)
        }
        # Empty values are written as - so that the shells can read the TAB-separated fields.
        print "std\t" s "\t" stdl[s] "\t" dash(val[s, "path"]) "\t" dash(val[s, "scan"]) "\t" dash(val[s, "role"])
        if (val[s, "role"] != "common" && re != "") print "applies\t" s "\t" re
        for (j = 1; j <= 7; j++) if ((s SUBSEP LET[j]) in pts) print "points\t" s "\t" LET[j] "\t" pts[s, LET[j]]
    }
    if (!ncommon) diag("warn", "", "no common standard (role=\"common\"); files that no framework standard covers will not be scored")
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
