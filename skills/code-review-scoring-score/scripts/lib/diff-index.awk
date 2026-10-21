# Builds a line index from a unified diff so score can verify finding locations (POSIX awk).
# Output: L<TAB>path<TAB>new line number<TAB>"+" (added) or " " (context)
{ sub(/\r$/, ""); line = $0 }
inhunk && (oleft > 0 || nleft > 0) {
    tag = (line == "") ? " " : substr(line, 1, 1)
    if (tag == "\\") next
    if (tag == "+") { if (p != "") printf "L\t%s\t%d\t+\n", p, nno; nno++; nleft--; next }
    if (tag == "-") { oleft--; next }
    if (tag == " ") { if (p != "") printf "L\t%s\t%d\t \n", p, nno; nno++; oleft--; nleft--; next }
    inhunk = 0
}
/^diff --git / { p = ""; inhunk = 0; next }
/^\+\+\+ / {
    p = substr(line, 5); sub(/\t.*$/, "", p); gsub(/^"|"$/, "", p)
    if (p == "/dev/null") p = ""; else sub(/^b\//, "", p)
    if (p ~ /(^|\/)src\/test\// || p ~ /(Test|Tests|IT)\.(java|kt)$/) printf "T\t%s\n", p
    next
}
/^@@ / {
    if (match(line, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) {
        split(substr(line, 4, RLENGTH - 6), hp, " ")
        split(substr(hp[1], 2), o, ","); split(substr(hp[2], 2), nn, ",")
        oleft = (o[2] == "") ? 1 : o[2] + 0
        nno = nn[1] + 0; nleft = (nn[2] == "") ? 1 : nn[2] + 0
        inhunk = 1
    }
}
