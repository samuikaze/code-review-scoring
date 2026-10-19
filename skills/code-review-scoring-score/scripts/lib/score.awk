# Validator and calculator shared by score.sh and score.zsh (POSIX awk). Run with LC_ALL=C.
# Variables: rules=rules.tsv  idxfile=output of diff-index.awk ("" = skip location checks)
#            tsvout / jsonout = output files
# Input: findings.txt (format: see references/findings-format.md of code-review-scoring-code-analysis).
# On validation errors: errors go to stderr, nothing is written, exit 1.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function err(msg) { nerr++; errs = errs "  - line " NR ": " msg "\n" }
function warn(msg) { nwarn++; warns = warns "  - " msg "\n" }
function jstr(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return "\"" s "\"" }
function sevrank(s) { return s == "Critical" ? 1 : (s == "Major" ? 2 : (s == "Minor" ? 3 : 4)) }

# Checks that the record just finished has the continuation fields it needs.
function close_record() {
    if (rec == "F") {
        if (!(("problem") in fld)) err2(recline, recid " is missing \"problem:\"")
        if (recsev != "Nit" && !(("suggestion") in fld)) err2(recline, recid " is missing \"suggestion:\"")
    } else if (rec == "U") {
        if (!(("content") in fld)) err2(recline, "upstream record is missing \"content:\"")
    }
    rec = ""; split("", fld)
}
function err2(ln, msg) { nerr++; errs = errs "  - line " ln ": " msg "\n" }

BEGIN {
    FS = "|"
    split("A B C D E F G", dims, " ")
    dmax["A"] = 25; dmax["B"] = 15; dmax["C"] = 15; dmax["D"] = 15; dmax["E"] = 10; dmax["F"] = 10; dmax["G"] = 10
    pts["Critical"] = 10; pts["Major"] = 5; pts["Minor"] = 2; pts["Nit"] = 0
    utype["spec-gap"] = "missing,wrong,ambiguous"
    utype["third-party"] = "spec-missing,spec-wrong,behavior-mismatch,not-delivered,bug"
    utype["ownership-change"] = "spec,interface,process"
    while ((getline l < rules) > 0) {
        if (l ~ /^#/ || l ~ /^[ \t]*$/) continue
        split(l, a, "\t"); def[a[1]] = a[2]; adj[a[1]] = a[3]
    }
    close(rules)
    if (idxfile != "") {
        while ((getline l < idxfile) > 0) {
            split(l, a, "\t")
            if (a[1] == "L") { kind[a[2] SUBSEP a[3]] = a[4]; known[a[2]] = 1 }
            else if (a[1] == "T") hastest = 1
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
    if (rec == "F" && key !~ /^(problem|suggestion|assumption)$/) { err("unknown field \"" key "\" for F (allowed: problem, suggestion, assumption)"); next }
    if (rec == "U" && key !~ /^(content|code|ticket)$/) { err("unknown field \"" key "\" for U (allowed: content, code, ticket)"); next }
    if (rec == "") { err("field \"" key "\" is not under an F or U record"); next }
    if (val == "") { err("field \"" key "\" is empty"); next }
    fld[key] = val
    next
}

{
    close_record()
    for (i = 1; i <= NF; i++) $i = trim($i)
    t = $1
    if (t == "F") {
        id = $2; sev = $3; locs = $4; reason = $5
        rec = "skip"; recid = id; recsev = sev; recline = NR
        if (!(id in def)) { err("unknown check id " id); next }
        if (!(sev in pts)) { err(id ": severity \"" sev "\" is not Critical/Major/Minor/Nit"); next }
        if (sev != def[id] && sev != "Nit") {
            if (("," adj[id] ",") !~ ("," sev ",")) { err(id ": severity must be the default " def[id] (adj[id] != "-" ? ", the allowed adjustment " adj[id] : "") " or Nit, not " sev); next }
            if (reason == "") { err(id ": non-default severity " sev " needs the matching adjustment condition in column 5"); next }
        }
        if (id == "C1" && sev == "Critical" && idxfile != "" && hastest) err("C1 Critical requires that the PR changes no test file, but the diff contains test files")
        if (id in fsev) { err(id " appears more than once. A check id is deducted once: merge all locations into one record"); next }
        if (locs == "") { err(id ": missing file:line locations"); next }
        n = split(locs, la, ","); clean = ""
        for (j = 1; j <= n; j++) {
            loc = trim(la[j])
            if (!match(loc, /:[0-9]+(-[0-9]+)?$/)) { err(id ": location \"" loc "\" is not file:line"); continue }
            fpath = substr(loc, 1, RSTART - 1); ln = substr(loc, RSTART + 1); sub(/-.*/, "", ln)
            if (sev != "Nit" && idxfile != "") {
                if (!(fpath in known)) err(id ": file \"" fpath "\" is not in the diff (use the full path from the diff, no ...)")
                else if (!((fpath SUBSEP ln) in kind)) err(id ": " loc " is outside the diff hunks")
                else if (kind[fpath SUBSEP ln] != "+") warn(id ": " loc " is an unchanged context line; make sure the problem is in added or changed code")
            }
            clean = clean (clean == "" ? "" : ",") loc
        }
        nf_++; forder[nf_] = id; fsev[id] = sev; floc[id] = clean; rec = "F"
        next
    }
    if (t == "U") {
        rec = "skip"; recline = NR
        if (!($2 in utype)) { err("upstream type must be spec-gap, third-party or ownership-change"); next }
        if (("," utype[$2] ",") !~ ("," $3 ",")) { err("upstream subtype for " $2 " must be one of: " utype[$2]); next }
        if ($2 == "spec-gap" && $4 !~ /^(high|medium|low)$/) { err("spec-gap needs impact high, medium or low"); next }
        if ($2 != "spec-gap" && $4 != "-" && $4 != "") { err("impact is only used for spec-gap; write - instead"); next }
        if ($5 == "") { err("upstream record needs a reference (spec section/version, change-log date or vendor ticket); without one, do not list it"); next }
        nu++; ut[nu] = $2; us[nu] = $3; ui[nu] = $4; ur[nu] = $5; rec = "U"
        next
    }
    if (t == "S") { if ($2 == "" || $3 == "") err("format is S|check-id|reason"); else { ns++; sid[ns] = $2; sr[ns] = $3 }; next }
    if (t == "H" || t == "N" || t == "I" || t == "R") { if ($2 == "") err(t " record has no text"); next }
    err("unknown record type \"" t "\" (allowed: F, U, S, H, N, I, R)")
}

END {
    close_record()
    if (nerr > 0) {
        printf "validation failed with %d error(s). Fix findings.txt and run again:\n%s", nerr, errs > "/dev/stderr"
        if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
        exit 1
    }
    # stable insertion sort by severity, then id
    for (i = 2; i <= nf_; i++) {
        v = forder[i]; j = i - 1
        while (j >= 1 && (sevrank(fsev[forder[j]]) > sevrank(fsev[v]) || (sevrank(fsev[forder[j]]) == sevrank(fsev[v]) && forder[j] > v))) { forder[j + 1] = forder[j]; j-- }
        forder[j + 1] = v
    }
    total = 0
    for (k = 1; k <= 7; k++) {
        d = dims[k]; ded = 0
        for (i = 1; i <= nf_; i++) {
            id = forder[i]
            if (substr(id, 1, 1) != d || fsev[id] == "Nit") continue
            ded += pts[fsev[id]]
            if (fsev[id] == "Critical") crit = 1
        }
        sc[d] = dmax[d] - ded; if (sc[d] < 0) sc[d] = 0
        total += sc[d]
    }
    grade = total >= 95 ? "S" : (total >= 85 ? "A" : (total >= 70 ? "B" : (total >= 55 ? "C" : "D")))
    capped = 0
    if (crit && (grade == "S" || grade == "A")) { grade = "B"; capped = 1 }

    printf "total\t%d\ngrade\t%s\ncapped\t%d\ncritical\t%d\n", total, grade, capped, crit ? 1 : 0 > tsvout
    for (k = 1; k <= 7; k++) printf "dim\t%s\t%d\t%d\n", dims[k], sc[dims[k]], dmax[dims[k]] > tsvout
    for (i = 1; i <= nf_; i++) { id = forder[i]; if (fsev[id] != "Nit") printf "finding\t%s\t%s\t%d\t%s\n", id, fsev[id], pts[fsev[id]], floc[id] > tsvout }
    close(tsvout)

    printf "{\n  \"total\": %d,\n  \"grade\": \"%s\",\n  \"hasCritical\": %s,\n", total, grade, (crit ? "true" : "false") > jsonout
    printf "  \"dimensions\": { \"A\": %d, \"B\": %d, \"C\": %d, \"D\": %d, \"E\": %d, \"F\": %d, \"G\": %d },\n", sc["A"], sc["B"], sc["C"], sc["D"], sc["E"], sc["F"], sc["G"] > jsonout
    printf "  \"findings\": [" > jsonout
    sep = ""
    for (i = 1; i <= nf_; i++) {
        id = forder[i]; if (fsev[id] == "Nit") continue
        n = split(floc[id], la, ","); ls = ""
        for (j = 1; j <= n; j++) ls = ls (j > 1 ? ", " : "") jstr(la[j])
        printf "%s\n    { \"id\": %s, \"severity\": %s, \"deduction\": %d, \"locations\": [%s] }", sep, jstr(id), jstr(fsev[id]), pts[fsev[id]], ls > jsonout
        sep = ","
    }
    printf "%s],\n", (sep == "" ? "" : "\n  ") > jsonout
    printf "  \"upstream\": [" > jsonout
    for (i = 1; i <= nu; i++) printf "%s\n    { \"type\": %s, \"subtype\": %s, \"impact\": %s, \"reference\": %s }", (i > 1 ? "," : ""), jstr(ut[i]), jstr(us[i]), ((ui[i] == "" || ui[i] == "-") ? "null" : jstr(ui[i])), jstr(ur[i]) > jsonout
    printf "%s],\n", (nu > 0 ? "\n  " : "") > jsonout
    printf "  \"skippedChecks\": [" > jsonout
    for (i = 1; i <= ns; i++) printf "%s\n    { \"id\": %s, \"reason\": %s }", (i > 1 ? "," : ""), jstr(sid[i]), jstr(sr[i]) > jsonout
    printf "%s]\n}\n", (ns > 0 ? "\n  " : "") > jsonout
    close(jsonout)

    printf "grade %s, total %d/100%s\n", grade, total, (capped ? " (capped at B because of a Critical finding)" : "")
    for (k = 1; k <= 7; k++) printf "%s %d/%d  ", dims[k], sc[dims[k]], dmax[dims[k]]
    printf "\ndeductions: %d, upstream: %d, skipped checks: %d\n", (nf_ > 0 ? cnt_deduct() : 0), nu, ns
    if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
}

function cnt_deduct(    c, i) { c = 0; for (i = 1; i <= nf_; i++) if (fsev[forder[i]] != "Nit") c++; return c }
