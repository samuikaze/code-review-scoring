# Validator and calculator shared by score.sh and score.zsh (POSIX awk). Run with LC_ALL=C.
# Variables: rules=output of "standard resolve" (standard, common, points, merge, severity, grade, cseverity and check
#                  records): the points, severity scale and grades of the rule all come from it
#            idxfile=output of diff-index.awk ("" = skip location checks)
#            crdir=ROOT/step2 with plan.tsv and <plugin>/cr.txt ("" = skip the code review comment checks)
#            cplan=the review plan (ROOT/step1/standards/plan.tsv) and cstd=the standard: check only its comments
#            tsvout / jsonout = output files  checkonly=1: validate only, write nothing
# Input: findings.txt (format: see references/findings-format.md of code-review-scoring-code-analysis).
# On validation errors: errors go to stderr, nothing is written, exit 1.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function err(msg) { nerr++; errs = errs "  - line " NR ": " msg "\n" }
function warn(msg) { nwarn++; warns = warns "  - " msg "\n" }
function jstr(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return "\"" s "\"" }
# Position of a severity in the scale (1 = the most severe); unknown codes sort last.
function sevrank(s) { return (s in srank) ? srank[s] : nsv + 1 }
function inlist(s, list) { return index("," list ",", "," s ",") > 0 }

# Checks that the record just finished has the continuation fields it needs.
function close_record() {
    if (rec == "F") {
        if (!(("problem") in fld)) err2(recline, recid " is missing \"problem:\"")
        if (!(("suggestion") in fld)) err2(recline, recid " is missing \"suggestion:\"")
        if (recfrom) check_from()
        else if (("from") in fld) err2(recline, recid ": from: is only used for check items of the common standard when its severity scale differs from that of the standard")
    } else if (rec == "U") {
        if (!(("content") in fld)) err2(recline, "upstream record is missing \"content:\"")
    }
    rec = ""; recfrom = 0; split("", fld)
}
function err2(ln, msg) { nerr++; errs = errs "  - line " ln ": " msg "\n" }
function err0(msg) { nerr++; errs = errs "  - " msg "\n" }

# A check item of the common standard when its scale differs from that of the standard: column 3 holds the closest
# severity of the standard's scale, any one of it. from: is recommended but optional; when present it names the
# severity on the common scale (the default, an allowed adjustment with its condition in column 5, or the lowest).
function check_from(    f) {
    if (!(("from") in fld)) return
    f = fld["from"]
    if (!(f in crank)) { err2(recline, recid ": from: " f " is not a severity of the common standard (" clist ")"); return }
    if (f != def[recid] && f != clowest) {
        if (!inlist(f, adj[recid])) { err2(recline, recid ": from: must be the default " def[recid] (adj[recid] != "-" ? ", the allowed adjustment " adj[recid] : "") " or " clowest ", not " f); return }
        if (recreason == "") { err2(recline, recid ": from: " f " is not the default severity and needs the matching adjustment condition in column 5"); return }
    }
    ffrom[recn] = f
}

# Comment ids are <plugin>#<n>: the n-th C record of the plugin's cr.txt (prepare-diff lists them in prepared.txt).
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

function load_comments(    l, x, a, f, c, t) {
    if (crdir == "" || (getline l < (crdir "/plan.tsv")) <= 0) return
    hascr = 1
    do {
        if (l == "") continue
        split(l, a, "\t"); f = crdir "/" a[1] "/cr.txt"; c = 0
        while ((getline x < f) > 0) if (x ~ /^[ \t]*C[ \t]*\|/) {
            c++; split(x, t, "|")
            if (cm_mine(trim(t[3]))) { ncm++; cmid[ncm] = a[1] "#" c; cmode[a[1] "#" c] = a[3] }
        }
        close(f)
    } while ((getline l < (crdir "/plan.tsv")) > 0)
    close(crdir "/plan.tsv")
}

function comment_ok(e, what) {
    if (e !~ /^[^#]+#[0-9]+$/) { err(what "\"" e "\" is not a comment id <plugin>#<n> (listed in prepared.txt)"); return 0 }
    if (!hascr) return 1
    if (!(e in cmode)) { err(what e " is not a code review comment of step 2"); return 0 }
    if (cmode[e] != "mapped") { err(what e " belongs to an advisory plugin; advisory comments are never deducted or rejected"); return 0 }
    return 1
}

# source: lists the code review comments a deduction confirms, separated by 、 or commas.
function use_sources(val,    n, s, i, e) {
    gsub(/,/, "、", val); n = split(val, s, "、")
    for (i = 1; i <= n; i++) { e = trim(s[i]); if (e != "" && comment_ok(e, "source ")) used[e] = 1 }
}

BEGIN {
    FS = "|"
    split("A B C D E F G", dims, " ")
    # The rule as "standard resolve" printed it: points, merge, severity scale, grades and check items of the rule and
    # of the common rule (whose check items start with CM-), and the severity scale of the common rule.
    while ((getline l < rules) > 0) {
        split(l, a, "\t")
        if (a[1] == "check") { def[a[2]] = a[3]; adj[a[2]] = a[4] }
        else if (a[1] == "points") { dmax[a[2]] = a[3] + 0; npts++ }
        else if (a[1] == "merge") merge = (a[2] == "true")
        else if (a[1] == "severity") {
            scode[++nsv] = a[2]; srank[a[2]] = nsv; pts[a[2]] = a[3] + 0; scap[a[2]] = (a[4] == "-" ? "" : a[4]); sname[a[2]] = a[5]
            sevlist = sevlist (nsv > 1 ? ", " : "") a[2]
        }
        else if (a[1] == "grade") { gcode[++ngr] = a[2]; grank[a[2]] = ngr; gmin[a[2]] = a[3] + 0; gname[a[2]] = a[4] }
        else if (a[1] == "cseverity") { ccode[++ncs] = a[2]; crank[a[2]] = ncs; clist = clist (ncs > 1 ? ", " : "") a[2] }
        else if (a[1] == "standard") { stdname = a[2]; stdver = a[3]; stdhash = a[4]; owner = "s" }
        else if (a[1] == "common") { cmname = a[2]; cmver = a[3]; cmhash = a[4]; owner = "c" }
        else if (a[1] == "ruleini") { if (owner == "c") cmrule = a[3]; else stdrule = a[3] }
        else if (a[1] == "defaults") defhash = a[3]
    }
    close(rules)
    if (npts != 7 || !nsv || !ngr) { printf "error: %s has no points, severity scale or grades of the standard; run standard lint and standard resolve again\n", rules > "/dev/stderr"; cfgfail = 1; exit 2 }
    lowest = scode[nsv]
    # The common rule uses the scale of the standard when its scale has the same codes in the same order.
    samescale = 1
    if (ncs) { if (ncs != nsv) samescale = 0; else for (i = 1; i <= nsv; i++) if (ccode[i] != scode[i]) samescale = 0 }
    clowest = ncs ? ccode[ncs] : lowest
    load_comments()
    utype["spec-gap"] = "missing,wrong,ambiguous"
    utype["third-party"] = "spec-missing,spec-wrong,behavior-mismatch,not-delivered,bug"
    utype["ownership-change"] = "spec,interface,process"
    if (idxfile != "") {
        while ((getline l < idxfile) > 0) {
            split(l, a, "\t")
            if (a[1] == "L") { kind[a[2] SUBSEP a[3]] = a[4]; known[a[2]] = 1 }
        }
        close(idxfile)
    }
}

{ sub(/\r$/, "") }
/^[ \t]*$/ || /^[ \t]*#/ { next }

# Continuation line "key: value" belongs to the previous F or U record.
/^[ \t]*[a-z]+:/ && $0 !~ /^[A-Z]\|/ {
    if (rec == "skip") next
    line = trim($0); key = line; sub(/:.*/, "", key); val = line; sub(/^[a-z]+:[ \t]*/, "", val)
    if (rec == "F" && key !~ /^(problem|suggestion|assumption|source|from)$/) { err("unknown field \"" key "\" for F (allowed: problem, suggestion, assumption, source, from)"); next }
    if (rec == "U" && key !~ /^(content|code|ticket|source)$/) { err("unknown field \"" key "\" for U (allowed: content, code, ticket, source)"); next }
    if (rec == "") { err("field \"" key "\" is not under an F or U record"); next }
    if (val == "") { err("field \"" key "\" is empty"); next }
    if (key == "source") use_sources(val)
    fld[key] = val
    next
}

{
    close_record()
    for (i = 1; i <= NF; i++) $i = trim($i)
    t = $1
    if (t == "F") {
        id = $2; sev = $3; locs = $4; reason = $5
        rec = "skip"; recid = id; recline = NR; recreason = reason
        # Check id "-": no check item of the standard covers the problem; deducted from the total by its severity.
        other = (id == "-")
        if (!other && !(id in def)) { err("unknown check id " id " (use - when no check covers the problem)"); next }
        if (!(sev in pts)) { err(id ": severity \"" sev "\" is not one of the scale of the standard (" sevlist ")"); next }
        # A check item of the common standard on another scale: its own severity is checked with from: (close_record).
        fromcheck = (!other && substr(id, 1, 3) == "CM-" && !samescale)
        if (!other && !fromcheck && sev != def[id] && sev != lowest) {
            if (!inlist(sev, adj[id])) { err(id ": severity must be the default " def[id] (adj[id] != "-" ? ", the allowed adjustment " adj[id] : "") " or " lowest ", not " sev); next }
            if (reason == "") { err(id ": non-default severity " sev " needs the matching adjustment condition in column 5"); next }
        }
        if (locs == "") { err(id ": missing file:line location"); next }
        if (locs == "-" && !other) { err(id ": location - (whole PR) is only allowed when the check id is -; give file:line"); next }
        # merge=true: one F record per check id with all its locations, deducted once.
        # merge=false: one F record per occurrence with one location, each deducted.
        # Records without a check id (-) are always deducted one by one.
        if (merge && !other && (id in idseen)) { err(id " appears more than once. Deductions are merged (merge=true): put every location of a check id into one record"); next }
        if (!merge && index(locs, ",") > 0) { err(id ": several locations in one record. Deductions are not merged (merge=false): write one F record per location"); next }
        n = (locs == "-") ? 0 : split(locs, la, ","); clean = (locs == "-") ? "-" : ""
        for (j = 1; j <= n; j++) {
            loc = trim(la[j])
            if (!match(loc, /:[0-9]+(-[0-9]+)?$/)) { err(id ": location \"" loc "\" is not file:line"); continue }
            fpath = substr(loc, 1, RSTART - 1); ln = substr(loc, RSTART + 1); sub(/-.*/, "", ln)
            if (idxfile != "") {
                if (!(fpath in known)) err(id ": file \"" fpath "\" is not in the diff (use the full path from the diff, no ...)")
                else if (!((fpath SUBSEP ln) in kind)) err(id ": " loc " is outside the diff hunks")
                else if (kind[fpath SUBSEP ln] != "+") warn(id ": " loc " is an unchanged context line; make sure the problem is in added or changed code")
            }
            clean = clean (clean == "" ? "" : ",") loc
        }
        if (!merge && !other && ((id SUBSEP clean) in seen)) { err(id " at " clean " is recorded twice; one problem at one location is deducted once"); next }
        idseen[id] = 1; seen[id SUBSEP clean] = 1
        nf_++; forder[nf_] = nf_; fid[nf_] = id; fsev[nf_] = sev; floc[nf_] = clean; rec = "F"; recn = nf_; recfrom = fromcheck
        next
    }
    if (t == "U") {
        rec = "skip"; recline = NR
        if (!($2 in utype)) { err("upstream type must be spec-gap, third-party or ownership-change"); next }
        if (("," utype[$2] ",") !~ ("," $3 ",")) { err("upstream subtype for " $2 " must be one of: " utype[$2]); next }
        if ($2 == "spec-gap" && $4 !~ /^(high|medium|low)$/) { err("spec-gap needs impact high, medium or low"); next }
        if ($2 != "spec-gap" && $4 != "-" && $4 != "") { err("impact is only used for spec-gap; write - instead"); next }
        if (!($5 in pts)) { err("upstream severity \"" $5 "\" is not one of the scale of the standard (" sevlist ")"); next }
        if ($6 == "") { err("upstream record needs a reference (spec section/version, change-log date or vendor ticket); without one, do not list it"); next }
        nu++; ut[nu] = $2; us[nu] = $3; ui[nu] = $4; usev[nu] = $5; ur[nu] = $6; rec = "U"
        next
    }
    # X|<plugin>#<n>|reason: a code review comment that step 3 found not to be a real problem in this PR.
    if (t == "X") {
        if ($2 == "" || $3 == "") { err("format is X|<plugin>#<n>|reason"); next }
        if (!comment_ok($2, "rejected comment ")) next
        if ($2 in rejected) { err("comment " $2 " is rejected twice"); next }
        rejected[$2] = 1; nx++; xid[nx] = $2; xr[nx] = $3
        next
    }
    # M|<plugin>#<n>|severity: the severity of the standard's scale closest to that of a code review comment.
    if (t == "M") {
        if ($2 == "" || $3 == "" || NF != 3) { err("format is M|<plugin>#<n>|severity"); next }
        if ($2 !~ /^[^#]+#[0-9]+$/) { err("\"" $2 "\" is not a comment id <plugin>#<n> (listed in prepared.txt)"); next }
        if (hascr && !($2 in cmode)) { err("mapped comment " $2 " is not a code review comment of step 2"); next }
        if ($2 in msev) { err("comment " $2 " is mapped twice"); next }
        if (!($3 in pts)) { err($2 ": severity \"" $3 "\" is not one of the scale of the standard (" sevlist ")"); next }
        msev[$2] = $3; nm++; mid[nm] = $2
        next
    }
    if (t == "S") { if ($2 == "" || $3 == "") err("format is S|check-id|reason"); else { ns++; sid[ns] = $2; sr[ns] = $3 }; next }
    if (t == "H" || t == "N" || t == "I" || t == "R") { if ($2 == "") err(t " record has no text"); next }
    err("unknown record type \"" t "\" (allowed: F, U, X, M, S, H, N, I, R)")
}

END {
    if (cfgfail) exit 2
    close_record()
    # Every comment of a mapped plugin is either deducted (source: of an F or U record) or rejected (X), and every
    # comment of the report has its severity mapped to the scale of the standard (M).
    for (i = 1; i <= ncm; i++) {
        e = cmid[i]
        if (!(e in msev)) err0("comment " e " has no M|" e "|<severity> line with the closest severity of the standard (" sevlist ")")
        if (cmode[e] != "mapped") continue
        if ((e in used) && (e in rejected)) err0("comment " e " is both deducted (source:) and rejected (X)")
        else if (!(e in used) && !(e in rejected)) err0("comment " e " is neither deducted (an F or U record with source: " e ") nor rejected (X|" e "|reason)")
    }
    if (nerr > 0) {
        printf "validation failed with %d error(s). Fix findings.txt and run again:\n%s", nerr, errs > "/dev/stderr"
        if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
        exit 1
    }
    if (checkonly) {
        printf "findings.txt is valid (%d deductions, %d upstream, %d rejected comments)\n", nf_, nu, nx
        if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
        exit 0
    }
    # stable insertion sort by severity, then check id with records without one (-) last;
    # occurrences of one id keep their order in findings.txt
    for (i = 2; i <= nf_; i++) {
        v = forder[i]; j = i - 1
        while (j >= 1 && after(forder[j], v)) { forder[j + 1] = forder[j]; j-- }
        forder[j + 1] = v
    }
    total = 0
    for (k = 1; k <= 7; k++) {
        d = dims[k]; ded = 0
        for (i = 1; i <= nf_; i++) {
            x = forder[i]
            if (dimof(fid[x]) != d) continue
            ded += pts[fsev[x]]
        }
        sc[d] = dmax[d] - ded; if (sc[d] < 0) sc[d] = 0
        total += sc[d]
    }
    # Records without a check id and upstream factors are deducted from the total. The severities found cap the grade.
    othded = 0; upded = 0
    for (i = 1; i <= nf_; i++) { if (fid[i] == "-") othded += pts[fsev[i]]; used_sev[fsev[i]] = 1 }
    for (i = 1; i <= nu; i++) { upded += pts[usev[i]]; used_sev[usev[i]] = 1 }
    total -= othded + upded; if (total < 0) total = 0
    grade = gcode[ngr]
    for (i = 1; i <= ngr; i++) if (total >= gmin[gcode[i]]) { grade = gcode[i]; break }
    # The strictest cap (the lowest grade) of the severities found; the most severe of them names it.
    capi = 0; capsev = ""
    for (i = 1; i <= nsv; i++) { s = scode[i]; if ((s in used_sev) && scap[s] != "" && grank[scap[s]] > capi) { capi = grank[scap[s]]; capsev = s } }
    capped = 0
    if (capi && grank[grade] < capi) { grade = gcode[capi]; capped = 1 }

    printf "total\t%d\ngrade\t%s\ncapped\t%d\n", total, grade, capped > tsvout
    if (capped) printf "cap\t%s\t%s\n", capsev, grade > tsvout
    printf "standard\t%s\t%s\t%s\n", stdname, stdver, stdhash > tsvout
    if (cmname != "") printf "common\t%s\t%s\t%s\n", cmname, cmver, cmhash > tsvout
    # sha256 of the settings in effect: the rule.ini of the standard and of the common rule, and defaults.ini
    printf "ruleini\tstandard\t%s\n", stdrule > tsvout
    if (cmname != "") printf "ruleini\tcommon\t%s\n", cmrule > tsvout
    printf "defaults\t%s\n", defhash > tsvout
    for (k = 1; k <= 7; k++) printf "dim\t%s\t%d\t%d\n", dims[k], sc[dims[k]], dmax[dims[k]] > tsvout
    for (i = 1; i <= nf_; i++) { x = forder[i]; printf "finding\t%s\t%s\t%d\t%s\t%d\n", fid[x], fsev[x], pts[fsev[x]], floc[x], x > tsvout }
    for (i = 1; i <= nu; i++) printf "upstream\t%d\t%s\t%d\n", i, usev[i], pts[usev[i]] > tsvout
    for (i = 1; i <= nsv; i++) { s = scode[i]; printf "severity\t%s\t%s\t%d\t%s\n", s, sname[s], pts[s], (scap[s] == "" ? "-" : scap[s]) > tsvout }
    for (i = 1; i <= ngr; i++) { g = gcode[i]; printf "gradedef\t%s\t%s\t%d\n", g, gname[g], gmin[g] > tsvout }
    close(tsvout)

    printf "{\n  \"total\": %d,\n  \"grade\": \"%s\",\n", total, grade > jsonout
    if (capped) printf "  \"cap\": { \"severity\": %s, \"grade\": %s },\n", jstr(capsev), jstr(grade) > jsonout
    else printf "  \"cap\": null,\n" > jsonout
    printf "  \"standard\": { \"name\": %s, \"version\": %s, \"hash\": %s, \"ruleIniHash\": %s },\n", jstr(stdname), jstr(stdver), jstr(stdhash), jstr(stdrule) > jsonout
    if (cmname != "") printf "  \"common\": { \"name\": %s, \"version\": %s, \"hash\": %s, \"ruleIniHash\": %s },\n", jstr(cmname), jstr(cmver), jstr(cmhash), jstr(cmrule) > jsonout
    else printf "  \"common\": null,\n" > jsonout
    printf "  \"defaultsHash\": %s,\n", jstr(defhash) > jsonout
    printf "  \"severities\": [" > jsonout
    for (i = 1; i <= nsv; i++) { s = scode[i]; printf "%s\n    { \"code\": %s, \"name\": %s, \"points\": %d, \"cap\": %s }", (i > 1 ? "," : ""), jstr(s), jstr(sname[s]), pts[s], (scap[s] == "" ? "null" : jstr(scap[s])) > jsonout }
    printf "\n  ],\n  \"grades\": [" > jsonout
    for (i = 1; i <= ngr; i++) { g = gcode[i]; printf "%s\n    { \"code\": %s, \"name\": %s, \"min\": %d }", (i > 1 ? "," : ""), jstr(g), jstr(gname[g]), gmin[g] > jsonout }
    printf "\n  ],\n" > jsonout
    printf "  \"dimensions\": { \"A\": %d, \"B\": %d, \"C\": %d, \"D\": %d, \"E\": %d, \"F\": %d, \"G\": %d },\n", sc["A"], sc["B"], sc["C"], sc["D"], sc["E"], sc["F"], sc["G"] > jsonout
    printf "  \"otherDeduction\": %d,\n  \"upstreamDeduction\": %d,\n", othded, upded > jsonout
    printf "  \"findings\": [" > jsonout
    sep = ""
    for (i = 1; i <= nf_; i++) {
        x = forder[i]
        n = (floc[x] == "-") ? 0 : split(floc[x], la, ","); ls = ""
        for (j = 1; j <= n; j++) ls = ls (j > 1 ? ", " : "") jstr(la[j])
        printf "%s\n    { \"id\": %s, \"severity\": %s, \"from\": %s, \"deduction\": %d, \"locations\": [%s] }", sep, (fid[x] == "-" ? "null" : jstr(fid[x])), jstr(fsev[x]), (x in ffrom ? jstr(ffrom[x]) : "null"), pts[fsev[x]], ls > jsonout
        sep = ","
    }
    printf "%s],\n", (sep == "" ? "" : "\n  ") > jsonout
    printf "  \"upstream\": [" > jsonout
    for (i = 1; i <= nu; i++) printf "%s\n    { \"type\": %s, \"subtype\": %s, \"impact\": %s, \"severity\": %s, \"deduction\": %d, \"reference\": %s }", (i > 1 ? "," : ""), jstr(ut[i]), jstr(us[i]), ((ui[i] == "" || ui[i] == "-") ? "null" : jstr(ui[i])), jstr(usev[i]), pts[usev[i]], jstr(ur[i]) > jsonout
    printf "%s],\n", (nu > 0 ? "\n  " : "") > jsonout
    printf "  \"mappedComments\": [" > jsonout
    for (i = 1; i <= nm; i++) printf "%s\n    { \"comment\": %s, \"severity\": %s }", (i > 1 ? "," : ""), jstr(mid[i]), jstr(msev[mid[i]]) > jsonout
    printf "%s],\n", (nm > 0 ? "\n  " : "") > jsonout
    printf "  \"rejectedComments\": [" > jsonout
    for (i = 1; i <= nx; i++) printf "%s\n    { \"comment\": %s, \"reason\": %s }", (i > 1 ? "," : ""), jstr(xid[i]), jstr(xr[i]) > jsonout
    printf "%s],\n", (nx > 0 ? "\n  " : "") > jsonout
    printf "  \"skippedChecks\": [" > jsonout
    for (i = 1; i <= ns; i++) printf "%s\n    { \"id\": %s, \"reason\": %s }", (i > 1 ? "," : ""), jstr(sid[i]), jstr(sr[i]) > jsonout
    printf "%s]\n}\n", (ns > 0 ? "\n  " : "") > jsonout
    close(jsonout)

    printf "grade %s, total %d/100%s\n", grade, total, (capped ? " (capped at " grade " because of a " capsev " finding)" : "")
    for (k = 1; k <= 7; k++) printf "%s %d/%d  ", dims[k], sc[dims[k]], dmax[dims[k]]
    printf "\ndeductions: %d (without a check id: %d), upstream: %d, rejected comments: %d, skipped checks: %d\n", nf_, cnt_other(), nu, nx, ns
    printf "standard: %s %s%s\n", stdname, stdver, (cmname != "" ? ", common: " cmname " " cmver : "")
    if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
}

# Dimension of a check id: its first letter, or the letter after CM- for the common standard.
function dimof(id) { return substr(id, 1, 3) == "CM-" ? substr(id, 4, 1) : substr(id, 1, 1) }
function cnt_other(    c, i) { c = 0; for (i = 1; i <= nf_; i++) if (fid[i] == "-") c++; return c }
function after(a, b) {
    if (sevrank(fsev[a]) != sevrank(fsev[b])) return sevrank(fsev[a]) > sevrank(fsev[b])
    if ((fid[a] == "-") != (fid[b] == "-")) return fid[a] == "-"
    return fid[a] > fid[b]
}
