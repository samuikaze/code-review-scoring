# Diff preprocessor shared by prepare-diff.sh and prepare-diff.zsh (POSIX awk).
# Variables: std=output of "standard resolve" (standard, common, applies and scan records; a "scan" record before any
#            standard record is a scan rule file given on its own)  mode=all|summary|scan|view  maxper=max locations listed per check
#            merge=true|false ([deductions] merge of configs/settings.ini, shown in the summary for writing findings.txt)
#            crdir=ROOT/step2 with plan.tsv and <plugin>/cr.txt ("" = no code review comments section)
#            cplan=the review plan (ROOT/step1/standards/plan.tsv) and cstd=the standard: list only its comments
# Run with LC_ALL=C; strings are handled as bytes.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function snippet(s) {
    s = trim(s)
    if (length(s) > 140) {
        s = substr(s, 1, 140)
        sub(/[\300-\367][\200-\277]*$/, "", s)   # do not cut inside a UTF-8 sequence
        s = s "..."
    }
    return s
}

function is_comment(s, path) {
    s = trim(s)
    if (path ~ /\.(md|markdown)$/) return s ~ /^<!--/
    if (s ~ /^(\/\/|\/\*|\*)/) return 1
    if (s ~ /^#/ && (path ~ /\.(ya?ml|properties|sh|bash|zsh|ps1|psm1|py|rb|toml|ini|conf|cfg|env|tf)$/ || path ~ /(^|\/)(Dockerfile[^\/]*|Makefile|\.gitignore|\.dockerignore|\.gitattributes|\.editorconfig|\.env[^\/]*)$/)) return 1
    if (path ~ /\.ini$/ && s ~ /^;/) return 1
    if (path ~ /\.sql$/ && s ~ /^--/) return 1
    if (path ~ /\.(xml|html?|vue)$/ && s ~ /^<!--/) return 1
    return 0
}

function fail(msg) { print "error: " msg > "/dev/stderr"; failed = 1; exit 2 }

# Reads a scan rule file; o = "s" for the rules of the standard, "c" for those of the common standard.
# The scopes of each file are separate: a scope only holds the files of its owner (see classify).
function load_rules(file, o,    l, ln, n, a, r) {
    ln = 0
    while ((r = (getline l < file)) > 0) {
        ln++; sub(/\r$/, "", l)
        if (ln == 1 && substr(l, 1, 3) == BOM) l = substr(l, 4)
        if (l ~ /^#/ || l ~ /^[ \t]*$/) continue
        n = split(l, a, "\t")
        if (a[1] == "@scope" && n == 4) {
            nsc[o]++; scname[o, nsc[o]] = a[2]; scwithin[o, nsc[o]] = a[3]; scre[o, nsc[o]] = a[4]; hasscope[o, a[2]] = 1
        } else if (a[1] == "@pr" && n == 4) {
            np++; pid[np] = a[2]; pown[np] = o; pcond[np] = a[3]; phint[np] = a[4]
        } else if (a[1] !~ /^@/ && n == 7) {
            nr++
            rown[nr] = o; rid[nr] = a[1]; rscope[nr] = a[2]; rflags[nr] = a[3]
            rre[nr] = (a[3] ~ /i/) ? tolower(a[4]) : a[4]
            rprev[nr] = (a[3] ~ /i/ && a[5] != "-") ? tolower(a[5]) : a[5]
            rexcl[nr] = (a[3] ~ /i/ && a[6] != "-") ? tolower(a[6]) : a[6]
            rhint[nr] = a[7]
            if (!(a[1] in idorder)) { nid++; idlist[nid] = a[1]; idorder[a[1]] = nid }
        } else fail(file ":" ln ": not a valid scan rule line; run standard lint first")
    }
    if (r < 0) fail("cannot read scan rules " file)
    close(file)
}

function in_scope(o, scope, f) { return (scope == "any") ? (fown[f] == o) : ((o SUBSEP scope SUBSEP f) in insc) }

function classify(f,    p, o, k, w, m, oi) {
    p = path[f]
    # Files of the standard: those its applies covers (every file when there is no applies); the others go to the
    # common standard. A file is in a scope of its owner when its path matches and the within condition holds.
    fown[f] = (applies == "" || p ~ applies) ? "s" : "c"
    for (oi = 1; oi <= 2; oi++) {
        o = (oi == 1) ? "s" : "c"
        for (k = 1; k <= nsc[o]; k++) {
            delete insc[o, scname[o, k], f]
            m = (fown[f] == o && p ~ scre[o, k]); w = scwithin[o, k]
            if (m && w != "-") m = (substr(w, 1, 1) == "!") ? !((o SUBSEP substr(w, 2) SUBSEP f) in insc) : ((o SUBSEP w SUBSEP f) in insc)
            if (m) insc[o, scname[o, k], f] = 1
        }
    }
    excl[f] = ""
    if (p ~ /(^|\/)(target|build|out|dist|\.gradle|node_modules)\// || p ~ /(^|\/)generated(-sources|-test-sources)?\//) excl[f] = "build output / generated"
    else if (p ~ /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$/ || p ~ /\.lock$/) excl[f] = "lock file"
    else if (p ~ /\.(class|jar|war|png|jpe?g|gif|ico|pdf|zip)$/) excl[f] = "binary file"
}

# Whether a code review comment with these locations belongs to the standard cstd of the review plan cplan: one of its
# files is a file of cstd, or none of its files is in the plan (a comment on the whole PR, location -) and cstd is the
# first report. Without cstd every comment belongs to it.
function cm_mine(loc,    l, a, n, p, i, f, any) {
    if (cstd == "") return 1
    if (!plload) {
        plload = 1
        while ((getline l < cplan) > 0) {
            split(l, a, "\t")
            if (a[1] == "report" && plfirst == "") plfirst = a[2]
            else if (a[1] == "file") { plany[a[2]] = 1; if (a[3] == cstd) plmine[a[2]] = 1 }
        }
        close(cplan)
    }
    n = split(loc, p, ","); any = 0
    for (i = 1; i <= n; i++) { f = trim(p[i]); sub(/:[0-9][-0-9]*$/, "", f); if (f in plmine) return 1; if (f in plany) any = 1 }
    return !any && cstd == plfirst
}

# Lists every code review comment with its id <plugin>#<n> (the n-th C record of the plugin's cr.txt).
function list_comments(    l, x, a, f, c, n, t, j, out, show) {
    if (crdir == "" || (getline l < (crdir "/plan.tsv")) <= 0) return
    print "## Code review comments (cite the ids in source: of F/U lines or in X lines; see the skill)"
    out = ""
    do {
        if (l == "") continue
        split(l, a, "\t"); f = crdir "/" a[1] "/cr.txt"; c = 0
        while ((getline x < f) > 0) {
            sub(/\r$/, "", x)
            if (x ~ /^[ \t]*C[ \t]*\|/) {
                c++; n = split(x, t, "|"); for (j = 1; j <= n; j++) t[j] = trim(t[j])
                if ((show = cm_mine(t[3]))) out = out sprintf("- %s#%d [%s] %s %s | %s\n", a[1], c, a[3], t[2], (t[4] == "" ? "-" : t[4]), t[3])
            } else if (c > 0 && show && x ~ /^[ \t]*problem:/) out = out "  " trim(x) "\n"
        }
        close(f)
    } while ((getline l < (crdir "/plan.tsv")) > 0)
    close(crdir "/plan.tsv")
    printf "%s\n", (out == "" ? "- none\n" : out)
}

function new_file(p) {
    nf++
    path[nf] = p; status[nf] = "modified"; adds[nf] = 0; dels[nf] = 0; view[nf] = ""; prev = ""
    classify(nf)
}

function scan(f, ln, text,    i, t, lt, lp, both) {
    if (text ~ /^[ \t]*$/) return
    for (i = 1; i <= nr; i++) {
        if (!in_scope(rown[i], rscope[i], f)) continue
        if (rflags[i] !~ /c/ && is_comment(text, path[f])) continue
        t = text; lp = prev
        if (rflags[i] ~ /i/) { t = tolower(t); lp = tolower(lp) }
        if (t !~ rre[i]) continue
        if (rprev[i] != "-" && lp !~ rprev[i]) continue
        both = lp " " t
        if (rexcl[i] != "-" && both ~ rexcl[i]) continue
        key = rid[i] SUBSEP f SUBSEP ln
        if (key in seen) continue
        seen[key] = 1
        nc++; cid[nc] = rid[i]; cfile[nc] = f; cline[nc] = ln; chint[nc] = rhint[i]; ctext[nc] = snippet(text)
    }
}

BEGIN {
    FS = "\n"
    BOM = sprintf("%c%c%c", 239, 187, 191)
    if (maxper == "") maxper = 15
    if (mode == "") mode = "all"
    own = "s"
    while ((getline l < std) > 0) {
        split(l, a, "\t")
        if (a[1] == "standard") { own = "s"; sname = a[2]; sver = a[3] }
        else if (a[1] == "common") { own = "c"; cname = a[2]; cver = a[3] }
        else if (a[1] == "applies") applies = a[2]
        else if (a[1] == "scan") load_rules(a[2], own)
    }
    close(std)
}

{
    sub(/\r$/, "")
    line = $0
}

# hunk body: the header line counts decide where it ends
inhunk && (oleft > 0 || nleft > 0) {
    tag = substr(line, 1, 1); body = substr(line, 2)
    if (line == "") { tag = " "; body = "" }
    if (tag == "\\") next
    if (tag == "+") {
        adds[nf]++; nleft--
        view[nf] = view[nf] sprintf("+%5d  %s\n", nno, body)
        if (adds[nf] <= 15 && body ~ /@(javax|jakarta)\.annotation\.(processing\.)?Generated|DO NOT EDIT|[Aa]uto-generated/) excl[nf] = "marked as generated"
        scan(nf, nno, body)
        if (body !~ /^[ \t]*$/) prev = body
        nno++; next
    }
    if (tag == "-") { dels[nf]++; oleft--; view[nf] = view[nf] "-       " body "\n"; next }
    if (tag == " ") {
        view[nf] = view[nf] sprintf(" %5d  %s\n", nno, body)
        if (body !~ /^[ \t]*$/) prev = body
        nno++; oleft--; nleft--; next
    }
    inhunk = 0
}

/^diff --git / {
    p = line
    if (match(p, / "?b\/.*$/)) { p = substr(p, RSTART + 1); gsub(/^"|"$/, "", p); sub(/^b\//, "", p) }
    new_file(p); inhunk = 0; next
}
/^--- / {
    if (nf == 0 || hunks[nf] > 0) { new_file("") }
    if (line ~ /^--- \/dev\/null/) status[nf] = "added"
    next
}
nf == 0 { next }
/^\+\+\+ / {
    p = substr(line, 5); sub(/\t.*$/, "", p); gsub(/^"|"$/, "", p)
    if (p == "/dev/null") status[nf] = "deleted"
    else { sub(/^b\//, "", p); path[nf] = p; classify(nf) }
    next
}
/^new file mode/ { status[nf] = "added"; next }
/^deleted file mode/ { status[nf] = "deleted"; next }
/^rename from / { status[nf] = "renamed"; next }
/^Binary files / { status[nf] = "binary"; next }
/^@@ / {
    if (match(line, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) {
        h = substr(line, 4, RLENGTH - 6)
        split(h, hp, " ")
        split(substr(hp[1], 2), o, ","); split(substr(hp[2], 2), nn, ",")
        oleft = (o[2] == "") ? 1 : o[2] + 0
        nno = nn[1] + 0; nleft = (nn[2] == "") ? 1 : nn[2] + 0
        inhunk = 1; hunks[nf]++; prev = ""
        view[nf] = view[nf] line "\n"
    }
    next
}

# Whether every condition of PR hint k holds; the files of its modified: conditions go to pmod[k].
function pr_hint(k,    n, c, i, j, o, s, x, hit) {
    o = pown[k]; n = split(pcond[k], c, ","); pmod[k] = ""
    for (i = 1; i <= n; i++) {
        s = trim(c[i]); x = substr(s, index(s, ":") + 1); hit = 0
        for (j = 1; j <= nf; j++) {
            if (!((o SUBSEP x SUBSEP j) in insc)) continue
            if (s ~ /^has:/ && excl[j] == "" && adds[j] > 0) hit = 1
            else if (s ~ /^no:/ && excl[j] == "") hit = 1
            else if (s ~ /^modified:/ && (excl[j] == "" || excl[j] == "deleted file") && status[j] != "added") {
                hit = 1; pmod[k] = pmod[k] "  - " path[j] " (" status[j] ")\n"
            }
        }
        if (s ~ /^no:/ ? hit : !hit) return 0
    }
    return 1
}

function count_part(scope, label, n) { return (("s" SUBSEP scope) in hasscope) ? ", " label ": " n : "" }

END {
    if (failed) exit 2
    if (nf == 0) { print "error: no parsable diff in input" > "/dev/stderr"; exit 2 }
    for (f = 1; f <= nf; f++) {
        if (excl[f] == "" && status[f] == "deleted") excl[f] = "deleted file"
        if (excl[f] == "" && status[f] == "binary") excl[f] = "binary file"
        if (excl[f] != "") { nx++; continue }
        nk++
        if (("s" SUBSEP "test" SUBSEP f) in insc) ntest++
        if ((("s" SUBSEP "main" SUBSEP f) in insc) && adds[f] > 0) nmain++
        if (("s" SUBSEP "migration" SUBSEP f) in insc) nmig++
        if (fown[f] == "c") ncf++
    }

    if (mode == "all" || mode == "summary") {
        print "## Summary"
        if (sname != "") print "- standard: " sname " " sver (applies == "" ? "" : (cname != "" ? "; the files it does not cover ([common]) use the common standard " cname " " cver : "; the files it does not cover are marked [no standard] and are not scored"))
        print "- deductions: " (merge == "true" ? "merged (merge=true): one F line per check id with all its locations; deducted once" : "not merged (merge=false): one F line per location; every occurrence is deducted")
        parts = count_part("main", "main code changed", nmain + 0) count_part("test", "test files", ntest + 0) count_part("migration", "migrations", nmig + 0)
        if (ncf > 0) parts = parts ", " (cname != "" ? "common standard files: " : "files without a standard: ") ncf
        printf "- reviewable files: %d, excluded: %d%s\n", nk, nx, (parts == "" ? "" : "; " substr(parts, 3))
        for (f = 1; f <= nf; f++) {
            tagv = (("s" SUBSEP "test" SUBSEP f) in insc) ? " [test]" : ((("s" SUBSEP "migration" SUBSEP f) in insc) ? " [migration]" : "")
            if (fown[f] == "c") tagv = tagv (cname != "" ? " [common]" : " [no standard]")
            if (excl[f] != "") printf "  - (excluded: %s) %s\n", excl[f], path[f]
            else printf "  - %s [%s +%d -%d]%s\n", path[f], status[f], adds[f], dels[f], tagv
        }
        print ""
        list_comments()
    }

    if (mode == "all" || mode == "scan") {
        print "## Heuristic candidates (clues only: confirm in code before deducting; unlisted checks still need manual review)"
        if (nr == 0 && np == 0) print "- none: the standard has no scan rules (scan= in configs/standards.ini)"
        for (k = 1; k <= np; k++) if (pr_hint(k)) printf "- %s: %s\n%s", pid[k], phint[k], pmod[k]
        for (k = 1; k <= nid; k++) {
            id = idlist[k]; cnt = 0; out = ""
            for (c = 1; c <= nc; c++) {
                if (cid[c] != id || excl[cfile[c]] != "") continue
                cnt++
                if (cnt <= maxper) out = out sprintf("  - %s:%d  %s\n", path[cfile[c]], cline[c], ctext[c])
                if (cnt == 1) hint = chint[c]
            }
            if (cnt == 0) continue
            printf "- %s (%d hits) %s\n%s", id, cnt, hint, out
            if (cnt > maxper) printf "  - ... %d more not listed\n", cnt - maxper
        }
        print ""
    }

    if (mode == "all" || mode == "view") {
        print "## Compact diff (+ = added line; numbers are new-file line numbers, cite these in findings)"
        for (f = 1; f <= nf; f++) {
            if (excl[f] != "") continue
            printf "\n=== %s [%s +%d -%d]\n%s", path[f], status[f], adds[f], dels[f], view[f]
        }
    }
}
