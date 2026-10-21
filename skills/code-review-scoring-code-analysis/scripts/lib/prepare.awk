# Diff preprocessor shared by prepare-diff.sh and prepare-diff.zsh (POSIX awk).
# Variables: rules=scan rule file  mode=all|summary|scan|view  maxper=max locations listed per check
#            merge=true|false ([deductions] merge of configs/settings.ini, shown in the summary for writing findings.txt)
#            crdir=ROOT/step2 with plan.tsv and <plugin>/cr.txt ("" = no code review comments section)
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
    if (s ~ /^(\/\/|\/\*|\*)/) return 1
    if (path ~ /\.(ya?ml|properties)$/ && s ~ /^#/) return 1
    if (path ~ /\.sql$/ && s ~ /^--/) return 1
    return 0
}

function in_scope(scope, f,    p) {
    p = path[f]
    if (scope == "any") return 1
    if (scope == "test") return is_test[f]
    if (scope == "nontest") return !is_test[f]
    if (scope == "java") return p ~ /\.(java|kt)$/
    if (scope == "main") return is_main[f]
    if (scope == "controller") return is_main[f] && p ~ /Controller[A-Za-z0-9_]*\.(java|kt)$/
    if (scope == "ctrltest") return is_test[f] && p ~ /(Controller|Repository)[A-Za-z0-9_]*(Test|Tests|IT)\.(java|kt)$/
    return 0
}

function classify(f,    p) {
    p = path[f]
    is_test[f] = (p ~ /(^|\/)src\/test\// || p ~ /(Test|Tests|IT)\.(java|kt)$/)
    is_main[f] = (!is_test[f] && p ~ /(^|\/)src\/main\/(java|kotlin)\/.+\.(java|kt)$/)
    is_mig[f] = (p ~ /(^|\/)(db\/migration|db\/changelog|liquibase|flyway)\// || p ~ /(^|\/)[VUR][0-9][0-9_.]*__[A-Za-z0-9_]+\.sql$/)
    excl[f] = ""
    if (p ~ /(^|\/)(target|build|out|dist|\.gradle|node_modules)\// || p ~ /(^|\/)generated(-sources|-test-sources)?\//) excl[f] = "build output / generated"
    else if (p ~ /(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|gradle\.lockfile)$/ || p ~ /\.lock$/) excl[f] = "lock file"
    else if (p ~ /\.(class|jar|war|png|jpe?g|gif|ico|pdf|zip)$/) excl[f] = "binary file"
}

# Lists every code review comment with its id <plugin>#<n> (the n-th C record of the plugin's cr.txt).
function list_comments(    l, x, a, f, c, n, t, j, out) {
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
                out = out sprintf("- %s#%d [%s] %s %s | %s\n", a[1], c, a[3], t[2], (t[4] == "" ? "-" : t[4]), t[3])
            } else if (c > 0 && x ~ /^[ \t]*problem:/) out = out "  " trim(x) "\n"
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
        if (!in_scope(rscope[i], f)) continue
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
    if (maxper == "") maxper = 15
    if (mode == "") mode = "all"
    while ((getline l < rules) > 0) {
        if (l ~ /^#/ || l ~ /^[ \t]*$/) continue
        n = split(l, a, "\t")
        if (n < 7) continue
        nr++
        rid[nr] = a[1]; rscope[nr] = a[2]; rflags[nr] = a[3]
        rre[nr] = (a[3] ~ /i/) ? tolower(a[4]) : a[4]
        rprev[nr] = (a[3] ~ /i/ && a[5] != "-") ? tolower(a[5]) : a[5]
        rexcl[nr] = (a[3] ~ /i/ && a[6] != "-") ? tolower(a[6]) : a[6]
        rhint[nr] = a[7]
        if (!(a[1] in idorder)) { nid++; idlist[nid] = a[1]; idorder[a[1]] = nid }
    }
    close(rules)
    if (nr == 0) { print "error: cannot read scan rules " rules > "/dev/stderr"; exit 2 }
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

END {
    if (nf == 0) { print "error: no parsable diff in input" > "/dev/stderr"; exit 2 }
    for (f = 1; f <= nf; f++) {
        if (excl[f] == "" && status[f] == "deleted") excl[f] = "deleted file"
        if (excl[f] == "" && status[f] == "binary") excl[f] = "binary file"
        if (excl[f] != "") { nx++; continue }
        nk++
        if (is_test[f]) ntest++
        if (is_main[f] && adds[f] > 0) nmain++
        if (is_mig[f]) { nmig++; if (status[f] != "added") migmod = migmod "  - " path[f] " (" status[f] ")\n" }
    }

    if (mode == "all" || mode == "summary") {
        print "## Summary"
        print "- deductions: " (merge == "true" ? "merged (merge=true): one F line per check id with all its locations; deducted once" : "not merged (merge=false): one F line per location; every occurrence is deducted")
        printf "- reviewable files: %d, excluded: %d; main code changed: %d, test files: %d, migrations: %d\n", nk, nx, nmain, ntest, nmig
        for (f = 1; f <= nf; f++) {
            tagv = is_test[f] ? " [test]" : (is_mig[f] ? " [migration]" : "")
            if (excl[f] != "") printf "  - (excluded: %s) %s\n", excl[f], path[f]
            else printf "  - %s [%s +%d -%d]%s\n", path[f], status[f], adds[f], dels[f], tagv
        }
        print ""
        list_comments()
    }

    if (mode == "all" || mode == "scan") {
        print "## Heuristic candidates (clues only: confirm in code before deducting; unlisted checks still need manual review)"
        if (nmain > 0 && ntest == 0) print "- C1: main code changed but the PR touches no test file (meets the C1 Critical condition if the change is business logic)"
        if (migmod != "") printf "- G6: existing migration file modified\n%s", migmod
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
