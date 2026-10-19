# Readiness check for spec-context.md shared by check-context.sh and check-context.zsh (POSIX awk).
# Variable: qfile = where a subagent writes its questions for the user.
# Exit 0 ready, 1 waiting for the user, 3 a required input was declined (stop the review).
/^## / { section = $0; sub(/^## /, "", section); next }
section == "Inputs" && /^- [a-z-]+:/ {
    key = $0; sub(/^- /, "", key); sub(/:.*/, "", key)
    st = $0; sub(/^- [a-z-]+:[ \t]*/, "", st); sub(/[ \t].*$/, "", st)
    seen[key] = 1
    if (st !~ /^(unknown|pending|provided|declined)$/) { bad = bad "  - " key ": invalid status \"" st "\" (use unknown, pending, provided or declined)\n"; next }
    if ((key == "diff" || key == "pr-description") && st == "declined") stop = stop "  - " key " (required) was declined\n"
    else if (st == "unknown") wait = wait "  - " key ": not checked yet; ask the user whether it can be provided\n"
    else if (st == "pending") wait = wait "  - " key ": asked, waiting for the user's reply\n"
    else if (st == "declined") declined = declined "  - " key "\n"
    next
}
section == "Open questions" && /^- \[ \] / { wait = wait "  - open question: " substr($0, 7) "\n" }
END {
    if (!("diff" in seen) || !("pr-description" in seen)) bad = bad "  - the Inputs section must list diff and pr-description\n"
    if (bad != "") { printf "spec-context.md is malformed:\n%s", bad; exit 1 }
    if (stop != "") { printf "STOP: a required input is unavailable, so the PR cannot be scored. Tell the user why:\n%s", stop; exit 3 }
    if (wait != "") { printf "NOT READY: ask the user about all of these in one message (as a subagent: write them to %s and set the step to pending), record the replies, then run this check again:\n%s", qfile, wait; exit 1 }
    print "READY: all inputs are resolved and all open questions are answered."
    if (declined != "") printf "Declined optional inputs (record the affected checks as S lines or lower severities in findings.txt):\n%s", declined
}
