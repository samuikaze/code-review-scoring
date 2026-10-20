# Report renderer shared by render-report.sh and render-report.zsh (POSIX awk). Run with LC_ALL=C.
# Variables: labels, findings, scoretsv, scorejson, ctx (may be ""), title (may be ""), today,
#            crdir (step 4 directory with plan.tsv, skipped.tsv and <plugin>/cr.txt; may be "")
# Main input: the report template. Output: the rendered report on stdout.
# Exit 1 with a message on stderr when the inputs are inconsistent.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function L(k) { return (k in lab) ? lab[k] : k }
function fail(msg) { print "error: " msg > "/dev/stderr"; failed = 1; exit 1 }

# Literal (non-regex) replace of every occurrence of `from` in `s`.
function replace_all(s, from, to,    out, i) {
    out = ""
    while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
    return out s
}

function codes(locs,    n, a, i, out) {
    n = split(locs, a, ","); out = ""
    for (i = 1; i <= n; i++) out = out (i > 1 ? L("sep.list") : "") "`" trim(a[i]) "`"
    return out
}

# One sub-list item per comma-separated location, or the `none` label on the field line.
function loclist(field, locs,    n, a, i, out) {
    if (locs == "" || locs == "-") return "   - " field L("sep.colon") L("none") "\n"
    n = split(locs, a, ","); out = "   - " field L("sep.colon") "\n"
    for (i = 1; i <= n; i++) out = out "     - `" trim(a[i]) "`\n"
    return out
}

function locfiles(locs, files,    n, a, i, f) {
    n = split(locs, a, ",")
    for (i = 1; i <= n; i++) { f = trim(a[i]); sub(/:[^:]*$/, "", f); files[f] = 1 }
}

function shares_file(locs, files,    n, a, i, f) {
    n = split(locs, a, ",")
    for (i = 1; i <= n; i++) { f = trim(a[i]); sub(/:[^:]*$/, "", f); if (f in files) return 1 }
    return 0
}

# Links code review comments to the check ids of the F records whose `source:` names the plugin and rule.
# A record links to the comments with that rule in one of its files; when none is in its files, to all of them.
function link_findings(    r, s, ns, src, e, p, rule, i, j, hdr, files, k, m, hit) {
    for (r = 1; r <= nfr; r++) {
        if (!((frkey[r], "source") in fv)) continue
        s = fv[frkey[r], "source"]; gsub(/,/, "、", s); ns = split(s, src, "、")
        for (k in files) delete files[k]
        locfiles(frloc[r], files)
        for (e = 1; e <= ns; e++) {
            p = trim(src[e]); rule = p; sub(/[ \t].*/, "", p); sub(/^[^ \t]*[ \t]*/, "", rule); rule = trim(rule)
            if (p == "" || rule == "") continue
            for (i = 1; i <= np; i++) {
                if (pname[i] != p) continue
                m = 0
                for (j = 1; j <= nc[i]; j++) { hdr = i SUBSEP j; hit[j] = (crule[hdr] == rule && shares_file(cloc[hdr], files)); m += hit[j] }
                for (j = 1; j <= nc[i]; j++) {
                    hdr = i SUBSEP j
                    if (crule[hdr] != rule || (m > 0 && !hit[j]) || ((hdr, frid[r]) in linked)) continue
                    linked[hdr, frid[r]] = 1; clink[hdr] = clink[hdr] (clink[hdr] == "" ? "" : L("sep.list")) frid[r]
                }
            }
        }
    }
}

function sevrank(s) { return s == "Critical" ? 1 : (s == "Major" ? 2 : (s == "Minor" ? 3 : 4)) }

# Loads ROOT/step2: the plan, skipped plugins and every plugin's normalized cr.txt.
function load_cr(    l, a, n, i, f, t, cur, key, val) {
    crstate = "not_run"
    if (crdir == "" || (getline l < (crdir "/plan.tsv")) < 0) return
    crstate = "ok"
    do {
        if (l == "") continue
        split(l, a, "\t"); np++; pname[np] = a[1]; pfiles[np] = a[4]
    } while ((getline l < (crdir "/plan.tsv")) > 0)
    close(crdir "/plan.tsv")
    while ((getline l < (crdir "/skipped.tsv")) > 0) { if (l == "") continue; split(l, a, "\t"); nsk++; skname[nsk] = a[1]; skapp[nsk] = a[2] }
    close(crdir "/skipped.tsv")
    for (i = 1; i <= np; i++) {
        f = crdir "/" pname[i] "/cr.txt"; cur = ""; pok[i] = 0
        while ((getline l < f) > 0) {
            pok[i] = 1
            sub(/\r$/, "", l)
            if (l ~ /^[ \t]*$/ || l ~ /^[ \t]*#/) continue
            if (l ~ /^[ \t]*[a-z]+:/ && l !~ /^[A-Z]\|/) {
                l = trim(l); key = l; sub(/:.*/, "", key); val = l; sub(/^[a-z]+:[ \t]*/, "", val)
                if (cur != "") cv[cur, key] = val
                continue
            }
            n = split(l, a, "|"); for (t = 1; t <= n; t++) a[t] = trim(a[t])
            cur = ""
            if (a[1] == "S") psum[i] = psum[i] (psum[i] == "" ? "" : " ") a[2]
            else if (a[1] == "H") { nh[i]++; ph[i, nh[i]] = a[2] }
            else if (a[1] == "C") {
                nc[i]++; cur = i SUBSEP nc[i]
                csev[cur] = a[2]; cloc[cur] = a[3]; crule[cur] = (a[4] == "" ? "-" : a[4])
                cnt[i, a[2]]++; tot[a[2]]++
            }
        }
        close(f)
    }
}

function cr_blocks(    i, j, k, out, b, c, order, m, tmp, hdr, ts, sevs, s) {
    b = L("sep.bracket"); c = L("sep.colon"); split("Critical Major Minor Nit", sevs, " ")
    if (crstate == "not_run") { blk["CR_OVERVIEW"] = L("cr.not_run") "\n"; blk["CR_DETAILS"] = ""; inl["CR_TOTALS"] = L("cr.not_run"); blk["CR_SKIPPED"] = ""; return }
    out = ""
    for (k = 1; k <= 4; k++) { s = sevs[k]; out = out (out == "" ? "" : L("sep.list")) s " " (tot[s] + 0) }
    inl["CR_TOTALS"] = (np == 0) ? L("cr.no_plugins") : out
    if (np == 0) { blk["CR_OVERVIEW"] = L("cr.no_plugins") "\n"; blk["CR_DETAILS"] = "" }
    else {
        out = "| " L("cr.col.plugin") " | " L("cr.col.files") " | Critical | Major | Minor | Nit | " L("cr.col.summary") " |\n| --- | --- | --- | --- | --- | --- | --- |\n"
        for (i = 1; i <= np; i++)
            out = out "| " pname[i] " | " pfiles[i] " | " (cnt[i, "Critical"] + 0) " | " (cnt[i, "Major"] + 0) " | " (cnt[i, "Minor"] + 0) " | " (cnt[i, "Nit"] + 0) " | " (pok[i] ? psum[i] : L("cr.missing")) " |\n"
        blk["CR_OVERVIEW"] = out
        out = ""
        for (i = 1; i <= np; i++) {
            out = out (i > 1 ? "\n" : "") "### " pname[i] "\n\n"
            if (!pok[i]) { out = out L("cr.missing") "\n"; continue }
            out = out "**" L("cr.summary") "**" c psum[i] "\n\n"
            # comments sorted by severity, keeping the plugin's order within a severity
            m = 0; ts = " " L("cr.tag_sep") " "
            for (j = 1; j <= nc[i]; j++) { m++; order[m] = j }
            for (j = 2; j <= m; j++) { tmp = order[j]; k = j - 1; while (k >= 1 && sevrank(csev[i, order[k]]) > sevrank(csev[i, tmp])) { order[k + 1] = order[k]; k-- } order[k + 1] = tmp }
            if (m == 0) out = out L("cr.no_comments") "\n"
            for (j = 1; j <= m; j++) {
                hdr = i SUBSEP order[j]
                out = out j ". [" csev[hdr] ts crule[hdr] ts (clink[hdr] == "" ? L("cr.unscored") : clink[hdr]) "]\n"
                out = out "   - " L("field.problem") c cv[hdr, "problem"] "\n"
                if ((hdr, "suggestion") in cv) out = out "   - " L("field.suggestion") c cv[hdr, "suggestion"] "\n"
                out = out loclist(L("cr.code"), cloc[hdr]) loclist(L("cr.spec"), cv[hdr, "spec"])
            }
            if (nh[i] > 0) {
                out = out "\n**" L("cr.highlights") "**\n\n"
                for (j = 1; j <= nh[i]; j++) out = out "- " ph[i, j] "\n"
            }
        }
        blk["CR_DETAILS"] = out
    }
    out = ""
    for (i = 1; i <= nsk; i++) out = out "- " skname[i] c replace_all(L("cr.skipped"), "{applies}", (skapp[i] == "" ? L("cr.all_files") : skapp[i])) "\n"
    blk["CR_SKIPPED"] = out
}

function bullets(kind,    i, out) {
    out = ""
    for (i = 1; i <= nl[kind]; i++) out = out "- " lt[kind, i] "\n"
    return out
}

function load_findings(    l, t, a, n, key, val) {
    while ((getline l < findings) > 0) {
        sub(/\r$/, "", l)
        if (l ~ /^[ \t]*$/ || l ~ /^[ \t]*#/) continue
        if (l ~ /^[ \t]*[a-z]+:/ && l !~ /^[A-Z]\|/) {
            l = trim(l); key = l; sub(/:.*/, "", key); val = l; sub(/^[a-z]+:[ \t]*/, "", val)
            if (cur != "") fv[cur, key] = val
            continue
        }
        n = split(l, a, "|"); for (i = 1; i <= n; i++) a[i] = trim(a[i])
        t = a[1]; cur = ""
        if (t == "F") {
            # A check id may have several records (merge=false), so the key is the id and its locations.
            lk = a[4]; gsub(/[ \t]*,[ \t]*/, ",", lk)
            cur = "F:" a[2] "@" lk; nfr++; frid[nfr] = a[2]; frloc[nfr] = lk; frkey[nfr] = cur
            if (a[3] == "Nit") { nnit++; nit[nnit] = a[2]; nitloc[nnit] = lk } else fdeduct[a[2] "@" lk] = 1
        } else if (t == "U") {
            nu++; cur = "U:" nu; ut[nu] = a[2]; us[nu] = a[3]; ui[nu] = a[4]; ur[nu] = a[5]
        } else if (t == "S") {
            nl["S"]++; lt["S", nl["S"]] = a[2] L("sep.colon") a[3]
        } else if (t == "H" || t == "N" || t == "I" || t == "R") {
            nl[t]++; lt[t, nl[t]] = a[2]
        }
    }
    close(findings)
}

BEGIN {
    FS = "\n"
    while ((getline l < labels) > 0) {
        if (l ~ /^#/ || l !~ /\t/) continue
        k = l; sub(/\t.*/, "", k); v = l; sub(/^[^\t]*\t/, "", v); lab[k] = v
    }
    close(labels)
    load_findings()

    while ((getline l < scoretsv) > 0) {
        n = split(l, a, "\t")
        if (a[1] == "total") total = a[2]
        else if (a[1] == "grade") grade = a[2]
        else if (a[1] == "capped") capped = a[2]
        else if (a[1] == "dim") { nd++; dcode[nd] = a[2]; dsc[nd] = a[3]; dmx[nd] = a[4] }
        else if (a[1] == "finding") { nf++; sid[nf] = a[2]; ssev[nf] = a[3]; spts[nf] = a[4]; sloc[nf] = a[5]; inscore[a[2] "@" a[5]] = 1 }
    }
    close(scoretsv)
    if (nd != 7 || grade == "") fail("score.tsv is missing or incomplete; run the scoring skill first")
    for (k in fdeduct) if (!(k in inscore)) fail("finding " k " is in findings.txt but not in score.tsv; rerun the scoring skill")
    for (i = 1; i <= nf; i++) if (!((sid[i] "@" sloc[i]) in fdeduct)) fail("finding " sid[i] "@" sloc[i] " is in score.tsv but not in findings.txt; rerun the scoring skill")

    json = ""
    while ((getline l < scorejson) > 0) json = json (json == "" ? "" : "\n") l
    close(scorejson)
    if (json == "") fail("score.json is missing or empty; run the scoring skill first")

    if (title == "" && ctx != "") {
        while ((getline l < ctx) > 0) if (l ~ /^- Title:/) { sub(/^- Title:[ \t]*/, "", l); title = trim(l); break }
        close(ctx)
    }
    if (title == "") title = L("title.missing")

    # Block placeholders
    blk["SCORE_ROWS"] = ""
    for (k = 1; k <= nd; k++) {
        items = ""
        for (i = 1; i <= nf; i++) if (substr(sid[i], 1, 1) == dcode[k]) items = items (items == "" ? "" : L("sep.list")) sid[i] " " ssev[i] " -" spts[i]
        blk["SCORE_ROWS"] = blk["SCORE_ROWS"] "| " dcode[k] " " L("dim." dcode[k]) " | " dsc[k] "/" dmx[k] " | " (items == "" ? L("none") : items) " |\n"
    }
    b = L("sep.bracket"); c = L("sep.colon"); out = ""
    for (i = 1; i <= nf; i++) {
        key = "F:" sid[i] "@" sloc[i]
        out = out i ". **[" sid[i] b ssev[i] b "-" spts[i] "]** " codes(sloc[i]) "\n"
        out = out "   - " L("field.problem") c fv[key, "problem"] "\n"
        out = out "   - " L("field.suggestion") c fv[key, "suggestion"] "\n"
        if ((key, "assumption") in fv) out = out "   - " L("field.assumption") c fv[key, "assumption"] "\n"
        if ((key, "source") in fv) out = out "   - " L("field.source") c fv[key, "source"] "\n"
    }
    blk["FINDINGS"] = out
    out = ""
    for (i = 1; i <= nnit; i++) {
        key = "F:" nit[i] "@" nitloc[i]
        out = out "- [" nit[i] "] " codes(nitloc[i]) c fv[key, "problem"]
        if ((key, "suggestion") in fv) out = out L("paren.open") L("field.suggestion") c fv[key, "suggestion"] L("paren.close")
        out = out "\n"
    }
    blk["SUGGESTIONS"] = out bullets("N")
    out = ""
    for (i = 1; i <= nu; i++) {
        tag = L("upstream." ut[i]) b L("sub." us[i]) ((ui[i] != "" && ui[i] != "-") ? b L("impact." ui[i]) : "")
        out = out i ". **[" tag "]** " ur[i] "\n"
        out = out "   - " L("field.content") c fv["U:" i, "content"] "\n"
        if (("U:" i, "code") in fv) out = out "   - " L("field.code") c codes(fv["U:" i, "code"]) "\n"
        if (("U:" i, "ticket") in fv) out = out "   - " L("field.ticket") c fv["U:" i, "ticket"] "\n"
    }
    blk["UPSTREAM"] = out
    blk["HIGHLIGHTS"] = bullets("H")
    blk["SKIPPED"] = bullets("S")
    blk["IGNORED"] = bullets("I")
    blk["REMARKS"] = bullets("R")
    blk["SCORE_JSON"] = json "\n"
    load_cr()
    link_findings()
    cr_blocks()

    inl["PR_TITLE"] = title; inl["REVIEW_DATE"] = today; inl["GRADE"] = grade; inl["TOTAL"] = total
    inl["CAPPED_NOTE"] = (capped == 1) ? L("capped_note") : ""
}

{
    line = $0; sub(/\r$/, "", line)
    if (match(line, /^[ \t]*\{\{[A-Z_]+\}\}[ \t]*$/)) {
        name = trim(line); gsub(/[{}]/, "", name)
        if (name in blk) {
            v = blk[name]
            if (v == "" && name != "SCORE_ROWS" && name != "CR_DETAILS") v = L("none") "\n"
            printf "%s", v
            next
        }
    }
    for (k in inl) line = replace_all(line, "{{" k "}}", inl[k])
    if (line ~ /\{\{[A-Z_]+\}\}/) { match(line, /\{\{[A-Z_]+\}\}/); unknown[substr(line, RSTART, RLENGTH)] = 1 }
    print line
}

END {
    if (failed) exit 1
    for (u in unknown) printf "warning: unknown placeholder %s left as is (block placeholders must be alone on their line)\n", u > "/dev/stderr"
}
