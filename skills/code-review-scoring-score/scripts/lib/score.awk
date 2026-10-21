# Validator and calculator shared by score.sh and score.zsh (POSIX awk). Run with LC_ALL=C.
# Variables: rules=rules.tsv  idxfile=output of diff-index.awk ("" = skip location checks)
#            config=configs.ini with the [points], [deductions] (incl. merge) and [grades] sections ("" or missing file = defaults)
#            crdir=ROOT/step2 with plan.tsv and <plugin>/cr.txt ("" = skip the code review comment checks)
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
        if (!(("suggestion") in fld)) err2(recline, recid " is missing \"suggestion:\"")
    } else if (rec == "U") {
        if (!(("content") in fld)) err2(recline, "upstream record is missing \"content:\"")
    }
    rec = ""; split("", fld)
}
function err2(ln, msg) { nerr++; errs = errs "  - line " ln ": " msg "\n" }
function err0(msg) { nerr++; errs = errs "  - " msg "\n" }

# Comment ids are <plugin>#<n>: the n-th C record of the plugin's cr.txt (prepare-diff lists them in prepared.txt).
function load_comments(    l, x, a, f, c) {
    if (crdir == "" || (getline l < (crdir "/plan.tsv")) <= 0) return
    hascr = 1
    do {
        if (l == "") continue
        split(l, a, "\t"); f = crdir "/" a[1] "/cr.txt"; c = 0
        while ((getline x < f) > 0) if (x ~ /^[ \t]*C[ \t]*\|/) { c++; ncm++; cmid[ncm] = a[1] "#" c; cmode[a[1] "#" c] = a[3] }
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
function cfgerr(msg) { ncfg++; cfgerrs = cfgerrs "  - " msg "\n" }

# Reads the scoring settings of configs.ini; keys that are not set keep their defaults.
function load_config(file,    l, sec, k, v, sum, i, g) {
    if (file != "") {
        while ((getline l < file) > 0) {
            sub(/\r$/, "", l)
            if (l ~ /^[ \t]*[;#]/ || l ~ /^[ \t]*$/) continue
            if (l ~ /^[ \t]*\[/) { sec = l; gsub(/^[ \t]*\[|\][ \t]*$/, "", sec); continue }
            if ((sec != "points" && sec != "deductions" && sec != "grades") || l !~ /=/) continue
            k = l; sub(/=.*/, "", k); k = trim(k)
            v = l; sub(/^[^=]*=/, "", v); v = trim(v); gsub(/^"|"$/, "", v)
            if (sec == "deductions" && k == "merge") {
                v = tolower(v)
                if (v != "true" && v != "false") cfgerr("[deductions] merge: \"" v "\" is not true or false")
                else merge = (v == "true")
                continue
            }
            if (sec == "points" && !(k in dmax)) { cfgerr("[points] " k ": unknown dimension (allowed: A, B, C, D, E, F, G)"); continue }
            if (sec == "deductions" && !(k in pts)) { cfgerr("[deductions] " k ": unknown key (allowed: Critical, Major, Minor, Nit, merge)"); continue }
            if (sec == "grades" && !(k in gmin)) { cfgerr("[grades] " k ": unknown grade (allowed: S, A, B, C)"); continue }
            if (v !~ /^[0-9]+$/) { cfgerr("[" sec "] " k ": \"" v "\" is not a whole number"); continue }
            if (sec == "points") dmax[k] = v + 0
            else if (sec == "deductions") pts[k] = v + 0
            else gmin[k] = v + 0
        }
        close(file)
    }
    sum = 0
    for (i = 1; i <= 7; i++) sum += dmax[dims[i]]
    if (sum != 100) cfgerr("[points] the seven dimensions must add up to 100, not " sum)
    if (gmin["S"] > 100) cfgerr("[grades] S must be at most 100")
    split("S A B C", g, " ")
    for (i = 1; i < 4; i++) if (gmin[g[i]] <= gmin[g[i + 1]]) cfgerr("[grades] " g[i] " (" gmin[g[i]] ") must be higher than " g[i + 1] " (" gmin[g[i + 1]] ")")
}

BEGIN {
    FS = "|"
    split("A B C D E F G", dims, " ")
    # Defaults; configs.ini can change them
    dmax["A"] = 25; dmax["B"] = 15; dmax["C"] = 15; dmax["D"] = 15; dmax["E"] = 10; dmax["F"] = 10; dmax["G"] = 10
    pts["Critical"] = 10; pts["Major"] = 5; pts["Minor"] = 2; pts["Nit"] = 1
    gmin["S"] = 95; gmin["A"] = 85; gmin["B"] = 70; gmin["C"] = 55
    load_config(config)
    if (ncfg > 0) { printf "invalid scoring settings in %s:\n%s", config, cfgerrs > "/dev/stderr"; cfgfail = 1; exit 2 }
    load_comments()
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
    if (rec == "F" && key !~ /^(problem|suggestion|assumption|source)$/) { err("unknown field \"" key "\" for F (allowed: problem, suggestion, assumption, source)"); next }
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
        rec = "skip"; recid = id; recline = NR
        # Check id "-": no check of the checklist covers the problem; deducted from the total by its severity.
        other = (id == "-")
        if (!other && !(id in def)) { err("unknown check id " id " (use - when no check covers the problem)"); next }
        if (!(sev in pts)) { err(id ": severity \"" sev "\" is not Critical/Major/Minor/Nit"); next }
        if (!other && sev != def[id] && sev != "Nit") {
            if (("," adj[id] ",") !~ ("," sev ",")) { err(id ": severity must be the default " def[id] (adj[id] != "-" ? ", the allowed adjustment " adj[id] : "") " or Nit, not " sev); next }
            if (reason == "") { err(id ": non-default severity " sev " needs the matching adjustment condition in column 5"); next }
        }
        if (id == "C1" && sev == "Critical" && idxfile != "" && hastest) err("C1 Critical requires that the PR changes no test file, but the diff contains test files")
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
        nf_++; forder[nf_] = nf_; fid[nf_] = id; fsev[nf_] = sev; floc[nf_] = clean; rec = "F"
        next
    }
    if (t == "U") {
        rec = "skip"; recline = NR
        if (!($2 in utype)) { err("upstream type must be spec-gap, third-party or ownership-change"); next }
        if (("," utype[$2] ",") !~ ("," $3 ",")) { err("upstream subtype for " $2 " must be one of: " utype[$2]); next }
        if ($2 == "spec-gap" && $4 !~ /^(high|medium|low)$/) { err("spec-gap needs impact high, medium or low"); next }
        if ($2 != "spec-gap" && $4 != "-" && $4 != "") { err("impact is only used for spec-gap; write - instead"); next }
        if (!($5 in pts)) { err("upstream severity \"" $5 "\" is not Critical/Major/Minor/Nit"); next }
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
    if (t == "S") { if ($2 == "" || $3 == "") err("format is S|check-id|reason"); else { ns++; sid[ns] = $2; sr[ns] = $3 }; next }
    if (t == "H" || t == "N" || t == "I" || t == "R") { if ($2 == "") err(t " record has no text"); next }
    err("unknown record type \"" t "\" (allowed: F, U, X, S, H, N, I, R)")
}

END {
    if (cfgfail) exit 2
    close_record()
    # Every comment of a mapped plugin is either deducted (source: of an F or U record) or rejected (X).
    for (i = 1; i <= ncm; i++) {
        e = cmid[i]; if (cmode[e] != "mapped") continue
        if ((e in used) && (e in rejected)) err0("comment " e " is both deducted (source:) and rejected (X)")
        else if (!(e in used) && !(e in rejected)) err0("comment " e " is neither deducted (an F or U record with source: " e ") nor rejected (X|" e "|reason)")
    }
    if (nerr > 0) {
        printf "validation failed with %d error(s). Fix findings.txt and run again:\n%s", nerr, errs > "/dev/stderr"
        if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
        exit 1
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
            if (substr(fid[x], 1, 1) != d) continue
            ded += pts[fsev[x]]
        }
        sc[d] = dmax[d] - ded; if (sc[d] < 0) sc[d] = 0
        total += sc[d]
    }
    # Records without a check id and upstream factors are deducted from the total.
    othded = 0; upded = 0
    for (i = 1; i <= nf_; i++) { if (fid[i] == "-") othded += pts[fsev[i]]; if (fsev[i] == "Critical") crit = 1 }
    for (i = 1; i <= nu; i++) { upded += pts[usev[i]]; if (usev[i] == "Critical") crit = 1 }
    total -= othded + upded; if (total < 0) total = 0
    grade = total >= gmin["S"] ? "S" : (total >= gmin["A"] ? "A" : (total >= gmin["B"] ? "B" : (total >= gmin["C"] ? "C" : "D")))
    capped = 0
    if (crit && (grade == "S" || grade == "A")) { grade = "B"; capped = 1 }

    printf "total\t%d\ngrade\t%s\ncapped\t%d\ncritical\t%d\n", total, grade, capped, crit ? 1 : 0 > tsvout
    for (k = 1; k <= 7; k++) printf "dim\t%s\t%d\t%d\n", dims[k], sc[dims[k]], dmax[dims[k]] > tsvout
    for (i = 1; i <= nf_; i++) { x = forder[i]; printf "finding\t%s\t%s\t%d\t%s\t%d\n", fid[x], fsev[x], pts[fsev[x]], floc[x], x > tsvout }
    for (i = 1; i <= nu; i++) printf "upstream\t%d\t%s\t%d\n", i, usev[i], pts[usev[i]] > tsvout
    close(tsvout)

    printf "{\n  \"total\": %d,\n  \"grade\": \"%s\",\n  \"hasCritical\": %s,\n", total, grade, (crit ? "true" : "false") > jsonout
    printf "  \"dimensions\": { \"A\": %d, \"B\": %d, \"C\": %d, \"D\": %d, \"E\": %d, \"F\": %d, \"G\": %d },\n", sc["A"], sc["B"], sc["C"], sc["D"], sc["E"], sc["F"], sc["G"] > jsonout
    printf "  \"otherDeduction\": %d,\n  \"upstreamDeduction\": %d,\n", othded, upded > jsonout
    printf "  \"findings\": [" > jsonout
    sep = ""
    for (i = 1; i <= nf_; i++) {
        x = forder[i]
        n = (floc[x] == "-") ? 0 : split(floc[x], la, ","); ls = ""
        for (j = 1; j <= n; j++) ls = ls (j > 1 ? ", " : "") jstr(la[j])
        printf "%s\n    { \"id\": %s, \"severity\": %s, \"deduction\": %d, \"locations\": [%s] }", sep, (fid[x] == "-" ? "null" : jstr(fid[x])), jstr(fsev[x]), pts[fsev[x]], ls > jsonout
        sep = ","
    }
    printf "%s],\n", (sep == "" ? "" : "\n  ") > jsonout
    printf "  \"upstream\": [" > jsonout
    for (i = 1; i <= nu; i++) printf "%s\n    { \"type\": %s, \"subtype\": %s, \"impact\": %s, \"severity\": %s, \"deduction\": %d, \"reference\": %s }", (i > 1 ? "," : ""), jstr(ut[i]), jstr(us[i]), ((ui[i] == "" || ui[i] == "-") ? "null" : jstr(ui[i])), jstr(usev[i]), pts[usev[i]], jstr(ur[i]) > jsonout
    printf "%s],\n", (nu > 0 ? "\n  " : "") > jsonout
    printf "  \"rejectedComments\": [" > jsonout
    for (i = 1; i <= nx; i++) printf "%s\n    { \"comment\": %s, \"reason\": %s }", (i > 1 ? "," : ""), jstr(xid[i]), jstr(xr[i]) > jsonout
    printf "%s],\n", (nx > 0 ? "\n  " : "") > jsonout
    printf "  \"skippedChecks\": [" > jsonout
    for (i = 1; i <= ns; i++) printf "%s\n    { \"id\": %s, \"reason\": %s }", (i > 1 ? "," : ""), jstr(sid[i]), jstr(sr[i]) > jsonout
    printf "%s]\n}\n", (ns > 0 ? "\n  " : "") > jsonout
    close(jsonout)

    printf "grade %s, total %d/100%s\n", grade, total, (capped ? " (capped at B because of a Critical finding)" : "")
    for (k = 1; k <= 7; k++) printf "%s %d/%d  ", dims[k], sc[dims[k]], dmax[dims[k]]
    printf "\ndeductions: %d (without a check id: %d), upstream: %d, rejected comments: %d, skipped checks: %d\n", nf_, cnt_other(), nu, nx, ns
    if (nwarn > 0) printf "warnings:\n%s", warns > "/dev/stderr"
}

function cnt_other(    c, i) { c = 0; for (i = 1; i <= nf_; i++) if (fid[i] == "-") c++; return c }
function after(a, b) {
    if (sevrank(fsev[a]) != sevrank(fsev[b])) return sevrank(fsev[a]) > sevrank(fsev[b])
    if ((fid[a] == "-") != (fid[b] == "-")) return fid[a] == "-"
    return fid[a] > fid[b]
}
