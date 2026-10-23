#!/usr/bin/env bash
# Checks and parses scoring standards: the rules project that [rules] root of configs/settings.ini names (rules.ini,
# defaults.ini and the rule.ini, Markdown document and scan rule file of each rule).
# "lint" is for the people who write standards and runs only when they ask for it; the scoring workflow uses
# "parse", which prints nothing about the format unless the document is broken.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: standard.sh lint [--settings FILE] [NAME ...]
       standard.sh lint --file DOC.md [--scan RULES.tsv] [--common]
       standard.sh parse --file DOC.md [--common]
       standard.sh diff OLD.md NEW.md
       standard.sh resolve [--settings FILE] [NAME]
       standard.sh plan --diff PR.diff --out DIR [--settings FILE]
       standard.sh stamp --file DOC.md --scan DRAFT.tsv --out RULES.tsv [--common]

The rules project: [rules] root of the settings names its folder (relative to the folder of the settings file). It
holds rules.ini (one [name] section per rule: path = the folder of its rule.ini, enable = true|false), defaults.ini
(the points, severities and grades of the rules that do not set their own) and a folder per rule with rule.ini
([rule] standard = the Markdown document, scan = the scan rule file, applies, role = common), the document and the
scan rules.

Commands:
  lint     check the rules project: rules.ini, defaults.ini and the rule.ini, document and scan rule file of every
           rule (only the NAMEs given), or one document that is not registered yet (--file; its severities are
           checked against the rule.ini in its folder, or defaults.ini). Prints what was parsed, then the errors and
           warnings with file and line. Regexes are compiled with awk, and with .NET when PowerShell is installed
  parse    print the parsed document as TAB-separated records (name, version, dim, check, confirm);
           stops at the first format error (exit 3)
  diff     list the dimensions, check items and confirmations that differ between two versions of a document
  resolve  for score: the enabled rule NAME (default: the only enabled framework rule, or the common one when there
           is none) and the enabled common rule, as TAB-separated records: "standard" / "common" (name, version,
           sha256, path of the document), "ruleini" (path, sha256), "applies" (the regex of the files of NAME), "scan"
           (path, sha256 of the scan rules), "points" (dimension, points), "merge", "severity" (code, points, cap,
           display name, meaning with its lines separated by |; from the most severe), "grade" (code, min, display
           name; from the highest), "cseverity" (code, display name, meaning of the common rule's scale), the "check"
           records of each document
           and "defaults" (path, sha256 of defaults.ini).
           Stops when the rules project or a document has a format error (exit 3)
  plan     for the review workflow: the enabled rules that score the PR. Each file goes to the framework rule whose
           applies covers it; the other files are common files, scored with the common rule in the report of their
           project (the framework of the nearest folder above them; every report when that is unclear), or on their
           own when no framework file changed. Writes DIR/plan.tsv ("report" name and file count, "file" path,
           report and kind framework|common|none), DIR/<name>.diff and DIR/<name>.resolve (the resolve output) for
           each report, and DIR/confirm.tsv (standard, check codes, what to confirm before scoring)
  stamp    write a reviewed scan rule file (--scan, e.g. a draft) to --out with the source line
           "# source: <document file> <version> sha256:<hash>" of the document (--file), so lint can tell when the
           document changes later; an existing source line is replaced

Options: --settings FILE   (default: configs/settings.ini in the project root; its [rules] root names the rules project)
         --common          the document is the common standard (its check codes start with CM-)

Exit codes: 0 ok (warnings allowed), 1 lint found errors, 2 bad arguments, unknown or disabled NAME, 3 the rules
            project or the document has a format error or is missing.
USAGE
}

# Absolute path; on Git Bash / MSYS use the Windows form (C:/...) so PowerShell can use it too.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
full() { local d; d="$(dirname "$1")"; if [[ -d "$d" ]]; then printf '%s/%s' "$(abspath "$d")" "$(basename "$1")"; else printf '%s' "$1"; fi; }
script_dir="$(abspath "$(dirname "${BASH_SOURCE[0]}")")"
lib="$script_dir/lib/standard.awk"
# Project root (two levels above the physical skill folder) holds configs/.
project_root="$(dirname "$(dirname "$(dirname "$script_dir")")")"

[[ $# -eq 0 ]] && { usage; exit 2; }
cmd="$1"; shift
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
settings="$project_root/configs/settings.ini"
file="" scan="" role="" names=() pdiff="" pout=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings) settings="${2:?--settings needs a value}"; shift 2 ;;
    --file) file="${2:?--file needs a value}"; shift 2 ;;
    --scan) scan="${2:?--scan needs a value}"; shift 2 ;;
    --common) role="common"; shift ;;
    --diff) pdiff="${2:?--diff needs a value}"; shift 2 ;;
    --out) pout="${2:?--out needs a value}"; shift 2 ;;
    --standards) echo "error: --standards was removed: the rules come from [rules] root of the settings (--settings)" >&2; exit 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT
nerr=0 nwarn=0
run_awk() { LC_ALL=C awk -f "$lib" "$@"; }
field() { awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$2"; }
sha() { { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi; } | awk '{ print $1 }'; }
# The first error of an awk run ($1 = file shown when the record names none, $2 = the output) as "FILE:LINE: message".
first_error() { awk -F'\t' -v f="$1" '$1 == "!error" { print ($4 != "" ? $4 : f) ($2 != "" ? ":" $2 : "") ": " $3; exit }' "$2"; }

# Prints the diagnostics of an awk run ($1 = file shown when the record names none, $2 = the output) and counts them.
report() {
  local n
  awk -F'\t' -v f="$1" '$1 == "!error" || $1 == "!warn" { print ($1 == "!error" ? "error" : "warning") ": " ($4 != "" ? $4 : f) ($2 != "" ? ":" $2 : "") ": " $3 }' "$2"
  n="$(grep -c '^!error' "$2" || true)"; nerr=$((nerr + n))
  n="$(grep -c '^!warn' "$2" || true)"; nwarn=$((nwarn + n))
}
# A path of the rules project as the awk output wrote it, made absolute ("" for -).
path_of() { [[ "$1" == "-" ]] || full "$1"; }
problem() { [[ "$1" == "error" ]] && nerr=$((nerr + 1)) || nwarn=$((nwarn + 1)); echo "$1: $2"; }

# The rules project: [rules] root of the settings, relative to the folder of the settings file. Prints its folder, or
# the reason it cannot be used (return 3).
rules_root() {
  local v
  [[ -f "$settings" ]] || { echo "$settings: file not found; run setup check"; return 3; }
  v="$(LC_ALL=C awk '
    /^[ \t]*\[/ { h = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", h); insec = (h == "rules"); next }
    insec && /^[ \t]*root[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*$/, "", v); gsub(/^"|"$/, "", v); val = v }
    END { print val }' "$settings")"
  [[ -n "$v" ]] || { echo "$settings: [rules] root is not set; set it to the folder of the code-review-scoring-rules project"; return 3; }
  v="${v//\\//}"
  [[ "$v" = /* || "$v" =~ ^[A-Za-z]: ]] || v="$(dirname "$settings")/$v"
  [[ -d "$v" ]] || { echo "$settings: [rules] root $v is not a folder"; return 3; }
  abspath "$v"
}
# Reads the rules project into $tmpd/ini (the "mode=rules" output); $rroot is its folder.
load_rules() {
  rroot="$(rules_root)" || return 3
  run_awk -v mode=rules -v rules="$rroot/rules.ini" -v rroot="$rroot" -v defaults="$rroot/defaults.ini" > "$tmpd/ini"
}
# Like load_rules, for the commands that need a valid rules project: prints the first error and exits 3.
need_rules() {
  local e
  load_rules || { echo "error: $rroot" >&2; exit 3; }
  e="$(first_error "$rroot/rules.ini" "$tmpd/ini")"
  [[ -z "$e" ]] || { echo "error: $e; run standard lint first" >&2; exit 3; }
}
# The severity codes of the rule $1 in the rules project, comma-separated from the most severe.
sevs_of() { awk -F'\t' -v n="$1" '$1 == "severity" && $2 == n { s = s (s == "" ? "" : ",") $3 } END { print s }' "$tmpd/ini"; }

# Compiles every queued regex ($2, "!re" records of $1) with awk and, when PowerShell is installed, with .NET.
test_re() {
  local shown="$1" re="$2" n i ps f l
  [[ -s "$re" ]] || return 0
  if ! run_awk -v mode=re "$re" >/dev/null 2>&1; then
    n="$(awk 'END { print NR }' "$re")"
    for ((i = 1; i <= n; i++)); do
      run_awk -v mode=re -v only="$i" "$re" >/dev/null 2>&1 ||
        problem error "$shown:$(awk -F'\t' -v n="$i" 'NR == n { print $2 ": the regex does not compile in awk: " $3 }' "$re")"
    done
  fi
  ps="$(command -v pwsh || command -v powershell.exe || command -v powershell || true)"
  [[ -n "$ps" ]] || return 0
  f="$re"; command -v cygpath >/dev/null 2>&1 && f="$(cygpath -w "$re")"
  while IFS= read -r l; do
    [[ -n "$l" ]] && problem error "$shown:$(awk -F'\t' -v n="$l" 'NR == n { print $2 ": the regex does not compile in .NET: " $3 }' "$re")"
  done < <("$ps" -NoProfile -NonInteractive -Command "\$n = 0; foreach (\$l in [IO.File]::ReadAllLines('$f', [Text.Encoding]::UTF8)) { \$n++; try { [void][regex]::new(\$l.Split([char]9)[2]) } catch { [Console]::WriteLine(\$n) } }" </dev/null 2>/dev/null | tr -d '\r')
}

# Lints one document ($2) and its scan rule file ($4); $1 = the rule name it must have ("" = any), $3 = role,
# $5 = the severity codes of its scale ("" = not checked).
lint_doc() {
  local want="$1" doc="$2" role="$3" scan="$4" sevs="$5" out="$tmpd/doc" name st src h
  [[ -f "$doc" ]] || { problem error "$doc: file not found"; return 0; }
  run_awk -v mode=doc -v role="$role" -v sevs="$sevs" "$doc" > "$out"
  name="$(field name "$out")"
  st="$(awk -F'\t' '$1 == "stats" { print $2 " check items (" $3 "), " $4 " adjustable, " $5 " confirmations" }' "$out")"
  echo "document: ${name:-?} $(field version "$out"), $st"
  report "$doc" "$out"
  [[ -z "$want" || -z "$name" || "$name" == "$want" ]] || problem error "$doc: the front matter name $name does not match the section [$want] in rules.ini"
  [[ -n "$scan" ]] || return 0
  [[ -f "$scan" ]] || { problem error "$scan: file not found"; return 0; }
  run_awk -v mode=scan -v codes="$out" "$scan" > "$tmpd/scan"
  awk -F'\t' '$1 == "stats" { print "scan rules: " $2 " line rules, " $3 " scopes, " $4 " PR hints" }' "$tmpd/scan"
  report "$scan" "$tmpd/scan"
  grep '^!re' "$tmpd/scan" > "$tmpd/re" || true
  test_re "$scan" "$tmpd/re"
  src="$(awk -F'\t' '$1 == "!source" { print $2 "\t" $3 " " $4 "\t" $5; exit }' "$tmpd/scan")"
  if [[ -n "$src" ]]; then
    h="$(sha "$doc")"
    [[ "${src##*$'\t'}" == "$h" ]] || problem warning "$scan:${src%%$'\t'*}: the scan rules were made from $(printf '%s' "$src" | cut -f2), and the document has changed since; regenerate them or run the review mode"
  fi
}

case "$cmd" in
  lint)
    if [[ -n "$file" ]]; then
      # An unregistered document: the scale of the rule.ini in its folder, or that of defaults.ini.
      file="$(full "$file")" sevs=""
      if rroot="$(rules_root 2>/dev/null)"; then
        rf=""; [[ -f "$(dirname "$file")/rule.ini" ]] && rf="$(dirname "$file")/rule.ini"
        sevs="$(run_awk -v mode=scale -v rule="$rf" -v defaults="$rroot/defaults.ini" | awk -F'\t' '$1 == "sev" { s = s (s == "" ? "" : ",") $2 } END { print s }')"
      fi
      [[ -n "$sevs" ]] || problem warning "no severity scale found (rule.ini next to the document, or defaults.ini of the rules project); severities are not checked"
      lint_doc "" "$file" "$role" "${scan:+$(full "$scan")}" "$sevs"
    else
      [[ -z "$scan" && -z "$role" ]] || { echo "error: --scan and --common go with --file" >&2; exit 2; }
      settings="$(full "$settings")"
      if ! load_rules; then
        echo "== $settings"
        problem error "$rroot"
      else
        echo "== $rroot/rules.ini"
        awk -F'\t' '$1 == "std" { n++; l = l (n > 1 ? ", " : "") $2 ($7 == "true" ? "" : " (disabled)") } END { print "rules: " (n + 0) " registered" (n ? " (" l ")" : "") }' "$tmpd/ini"
        report "$rroot/rules.ini" "$tmpd/ini"
        for n in "${names[@]+"${names[@]}"}"; do
          awk -F'\t' -v n="$n" '$1 == "std" && $2 == n { f = 1 } END { exit !f }' "$tmpd/ini" || problem error "$rroot/rules.ini: [$n] is not registered"
        done
        while IFS=$'\t' read -r -u 3 k1 name k2 dpath spath role enable ruleini; do
          if [[ ${#names[@]} -gt 0 ]]; then
            keep=0; for n in "${names[@]}"; do [[ "$n" == "$name" ]] && keep=1; done
            [[ $keep -eq 1 ]] || continue
          fi
          echo
          echo "== [$name]$([[ "$ruleini" == "-" ]] || echo " $(path_of "$ruleini")")$([[ "$enable" == "true" ]] || echo " (disabled)")"
          awk -F'\t' -v n="$name" '$2 != n { next }
            $1 == "from" { src[$3] = $4 } $1 == "merge" { m = $3 }
            $1 == "severity" { s = s (s == "" ? "" : ", ") $3 } $1 == "grade" { g = g (g == "" ? "" : ", ") $3 }
            END { if (src["points"] != "") print "settings: points (" src["points"] "), severities " s " (" src["severities"] "), grades " g " (" src["grades"] "), merge=" m }' "$tmpd/ini"
          [[ "$dpath" == "-" ]] && continue
          lint_doc "$name" "$(path_of "$dpath")" "${role#-}" "$(path_of "$spath")" "$(sevs_of "$name")"
        done 3< <(awk -F'\t' '$1 == "std"' "$tmpd/ini")
      fi
    fi
    echo
    echo "result: $nerr error(s), $nwarn warning(s)"
    [[ $nerr -eq 0 ]] || exit 1
    ;;

  parse)
    [[ -n "$file" ]] || { echo "error: parse needs --file DOC.md" >&2; exit 2; }
    [[ -f "$file" ]] || { echo "error: file not found: $file" >&2; exit 2; }
    run_awk -v mode=doc -v role="$role" "$file" > "$tmpd/doc"
    e="$(first_error "$file" "$tmpd/doc")"
    [[ -z "$e" ]] || { echo "error: $e; run standard lint first" >&2; exit 3; }
    awk -F'\t' '$1 !~ /^!/ && $1 != "stats"' "$tmpd/doc"
    ;;

  stamp)
    [[ -n "$file" && -n "$scan" && -n "$pout" ]] || { echo "error: stamp needs --file DOC.md --scan DRAFT.tsv --out RULES.tsv" >&2; exit 2; }
    for f in "$file" "$scan"; do [[ -f "$f" ]] || { echo "error: file not found: $f" >&2; exit 2; }; done
    run_awk -v mode=doc -v role="$role" "$file" > "$tmpd/doc"
    e="$(first_error "$file" "$tmpd/doc")"
    [[ -z "$e" ]] || { echo "error: $e; run standard lint first" >&2; exit 3; }
    src="# source: $(basename "$file") $(field version "$tmpd/doc") sha256:$(sha "$file")"
    # The source line replaces the first existing one (others are dropped), or goes first.
    awk -v src="$src" '{ sub(/\r$/, "") } /^# source:/ { if (!d) o[++n] = src; d = 1; next } { o[++n] = $0 }
      END { while (n > 0 && o[n] == "") n--; if (!d) print src; for (i = 1; i <= n; i++) print o[i] }' "$scan" > "$tmpd/stamped"
    mkdir -p "$(dirname "$pout")"
    cp "$tmpd/stamped" "$pout"
    echo "wrote $(full "$pout")"
    echo "$src"
    ;;

  diff)
    [[ ${#names[@]} -eq 2 ]] || { echo "error: diff needs OLD.md NEW.md" >&2; exit 2; }
    i=0
    for doc in "${names[@]}"; do
      [[ -f "$doc" ]] || { echo "error: file not found: $doc" >&2; exit 2; }
      run_awk -v mode=doc -v role="$role" "$doc" > "$tmpd/d$i"
      e="$(first_error "$doc" "$tmpd/d$i")"
      [[ -z "$e" ]] || { echo "error: $e; run standard lint first" >&2; exit 3; }
      i=$((i + 1))
    done
    run_awk -v mode=diff "$tmpd/d0" "$tmpd/d1"
    ;;

  resolve)
    [[ ${#names[@]} -le 1 ]] || { echo "error: resolve takes at most one NAME" >&2; exit 2; }
    settings="$(full "$settings")"
    need_rules
    want="${names[0]:-}"
    if [[ -z "$want" ]]; then
      # Without a NAME: the only enabled framework rule, or the common one when there is no framework rule.
      want="$(awk -F'\t' '$1 == "std" && $7 == "true" && $6 != "common" { n++; l = l (n > 1 ? ", " : "") $2; w = $2 }
        $1 == "std" && $7 == "true" && $6 == "common" { c = $2 }
        END { if (n > 1) print "!several rules are enabled (" l "); pick one by name"; else if (n == 1) print w; else if (c != "") print c; else print "!no rule is enabled" }' "$tmpd/ini")"
      [[ "$want" != !* ]] || { echo "error: $rroot/rules.ini: ${want#!}" >&2; exit 2; }
    fi
    awk -F'\t' -v n="$want" '$1 == "std" && $2 == n { f = 1 } END { exit !f }' "$tmpd/ini" || { echo "error: $rroot/rules.ini: [$want] is not registered" >&2; exit 2; }
    awk -F'\t' -v n="$want" '$1 == "std" && $2 == n && $7 == "true" { f = 1 } END { exit !f }' "$tmpd/ini" || { echo "error: $rroot/rules.ini: [$want] is disabled (enable=\"false\")" >&2; exit 2; }
    # The rule itself first, then the enabled common rule (when it is another one); each with its check items.
    while IFS=$'\t' read -r -u 3 k1 name k2 dpath spath role enable ruleini; do
      dpath="$(path_of "$dpath")" ruleini="$(path_of "$ruleini")"
      [[ -f "$dpath" ]] || { echo "error: $dpath: file not found; run standard lint first" >&2; exit 3; }
      run_awk -v mode=doc -v role="${role#-}" -v sevs="$(sevs_of "$name")" "$dpath" > "$tmpd/doc"
      e="$(first_error "$dpath" "$tmpd/doc")"
      [[ -z "$e" ]] || { echo "error: $e; run standard lint first" >&2; exit 3; }
      printf '%s\t%s\t%s\tsha256:%s\t%s\n' "$([[ "$name" == "$want" ]] && echo standard || echo common)" "$name" "$(field version "$tmpd/doc")" "$(sha "$dpath")" "$dpath"
      printf 'ruleini\t%s\tsha256:%s\n' "$ruleini" "$(sha "$ruleini")"
      if [[ "$name" == "$want" ]]; then awk -F'\t' -v n="$name" '$1 == "applies" && $2 == n { print "applies\t" $3 }' "$tmpd/ini"; fi
      if [[ "$spath" != "-" ]]; then
        spath="$(path_of "$spath")"
        [[ -f "$spath" ]] || { echo "error: $spath: file not found; run standard lint first" >&2; exit 3; }
        printf 'scan\t%s\tsha256:%s\n' "$spath" "$(sha "$spath")"
      fi
      if [[ "$name" == "$want" ]]; then
        awk -F'\t' -v n="$name" '$2 != n { next } $1 == "points" { print "points\t" $3 "\t" $4 } $1 == "merge" { print "merge\t" $3 }
          $1 == "severity" { print "severity\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 } $1 == "grade" { print "grade\t" $3 "\t" $4 "\t" $5 }' "$tmpd/ini"
      else
        awk -F'\t' -v n="$name" '$1 == "severity" && $2 == n { print "cseverity\t" $3 "\t" $6 "\t" $7 }' "$tmpd/ini"
      fi
      awk -F'\t' '$1 == "check"' "$tmpd/doc"
    done 3< <(awk -F'\t' -v n="$want" '$1 == "std" && $2 == n { print } $1 == "std" && $6 == "common" && $7 == "true" && $2 != n { c = $0 } END { if (c != "") print c }' "$tmpd/ini")
    d="$(awk -F'\t' '$1 == "defaults" { print $2 }' "$tmpd/ini")"
    printf 'defaults\t%s\tsha256:%s\n' "$(path_of "$d")" "$(sha "$d")"
    ;;

  plan)
    [[ -n "$pdiff" && -n "$pout" && ${#names[@]} -eq 0 ]] || { echo "error: plan needs --diff PR.diff --out DIR" >&2; exit 2; }
    [[ -f "$pdiff" ]] || { echo "error: diff file not found: $pdiff" >&2; exit 2; }
    settings="$(full "$settings")"
    need_rules
    mkdir -p "$pout"
    rm -f "$pout"/plan.tsv "$pout"/confirm.tsv "$pout"/*.diff "$pout"/*.resolve
    run_awk -v mode=plan -v ini="$tmpd/ini" -v out="$pout" "$pdiff" > "$tmpd/plan"
    e="$(awk -F'\t' '$1 == "!error" { print $3; exit }' "$tmpd/plan")"
    [[ -z "$e" ]] || { echo "error: $pdiff: $e" >&2; exit 2; }
    : > "$pout/confirm.tsv"
    while IFS=$'\t' read -r -u 3 k1 name n; do
      bash "$script_dir/standard.sh" resolve --settings "$settings" "$name" > "$pout/$name.resolve" || exit $?
      # The confirmations of the standard, and those of the common standard when the report has common files.
      while IFS=$'\t' read -r -u 4 kind sname k2 k3 dpath; do
        [[ "$kind" == "standard" ]] || awk -F'\t' -v n="$name" '$1 == "file" && $3 == n && $4 == "common" { f = 1 } END { exit !f }' "$tmpd/plan" || continue
        grep -q "^$sname"$'\t' "$pout/confirm.tsv" && continue
        role="$(awk -F'\t' -v n="$sname" '$1 == "std" && $2 == n && $6 == "common" { print "common" }' "$tmpd/ini")"
        run_awk -v mode=doc -v role="$role" "$dpath" | awk -F'\t' -v n="$sname" '$1 == "confirm" { print n "\t" $2 "\t" $3 }' >> "$pout/confirm.tsv"
      done 4< <(awk -F'\t' '$1 == "standard" || $1 == "common"' "$pout/$name.resolve")
    done 3< <(awk -F'\t' '$1 == "report"' "$tmpd/plan")
    cp "$tmpd/plan" "$pout/plan.tsv"
    # Summary: one line per report with its files, then the files no standard scores.
    awk -F'\t' 'FNR == NR { if ($1 == "standard" || $1 == "common") ver[$2] = $3; next }
      $1 == "report" { r[++n] = $2; tot[$2] = $3 }
      $1 == "file" && $4 == "common" { c[$3]++ } $1 == "file" && $4 == "none" { x[$3]++ }
      END {
        print n " report(s):"
        for (i = 1; i <= n; i++) {
          s = r[i]; printf "  - %s %s: %d file(s)", s, ver[s], tot[s]
          if (c[s] && c[s] != tot[s]) printf " (%d scored with the common standard)", c[s]
          if (x[s]) printf " (%d not covered by any standard)", x[s]
          print ""
        }
      }' <(cat "$pout"/*.resolve) "$pout/plan.tsv"
    echo "wrote $(full "$pout")/plan.tsv"
    ;;

  *) echo "error: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac
