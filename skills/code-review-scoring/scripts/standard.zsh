#!/usr/bin/env zsh
# Checks and parses scoring standards: the Markdown documents and scan rule files listed in configs/standards.ini.
# "lint" is for the people who write standards and runs only when they ask for it; the scoring workflow uses
# "parse", which prints nothing about the format unless the document is broken.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: standard.zsh lint [--standards FILE] [--settings FILE] [NAME ...]
       standard.zsh lint --file DOC.md [--scan RULES.tsv] [--common]
       standard.zsh parse --file DOC.md [--common]
       standard.zsh diff OLD.md NEW.md
       standard.zsh resolve [--standards FILE] [--settings FILE] [NAME]

Commands:
  lint     check configs/standards.ini and the documents and scan rule files it lists (only the NAMEs given),
           or one document that is not registered yet (--file). Prints what was parsed, then the errors and
           warnings with file and line. Regexes are compiled with awk, and with .NET when PowerShell is installed
  parse    print the parsed document as TAB-separated records (name, version, dim, check, confirm);
           stops at the first format error (exit 3)
  diff     list the dimensions, check items and confirmations that differ between two versions of a document
  resolve  for score: the standard NAME (default: the only framework standard, or the common one when there is
           none) and the common standard, as TAB-separated records: "standard" / "common" (name, version,
           sha256, path), "points" (the overrides of NAME) and the "check" records of each document.
           Stops when standards.ini or a document has a format error (exit 3)

Options: --standards FILE  (default: configs/standards.ini in the project root)
         --settings FILE   (default: configs/settings.ini in the project root; its [points] are checked with the overrides)
         --common          the document is the common standard (its check codes start with CM-)

Exit codes: 0 ok (warnings allowed), 1 lint found errors, 2 bad arguments or unknown NAME, 3 standards.ini or the document
            has a format error or is missing.
USAGE
}

# Absolute path; on Git Bash / MSYS use the Windows form (C:/...) so PowerShell can use it too.
abspath() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
full() { local d; d="$(dirname "$1")"; if [[ -d "$d" ]]; then printf '%s/%s' "$(abspath "$d")" "$(basename "$1")"; else printf '%s' "$1"; fi; }
script_dir="${0:A:h}"
lib="$script_dir/lib/standard.awk"
# Project root (two levels above the physical skill folder) holds configs/.
project_root="$(dirname "$(dirname "$(dirname "$script_dir")")")"

[[ $# -eq 0 ]] && { usage; exit 2; }
cmd="$1"; shift
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && { usage; exit 0; }
standards="$project_root/configs/standards.ini" settings="$project_root/configs/settings.ini"
file="" scan="" role="" names=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --standards) standards="${2:?--standards needs a value}"; shift 2 ;;
    --settings) settings="${2:?--settings needs a value}"; shift 2 ;;
    --file) file="${2:?--file needs a value}"; shift 2 ;;
    --scan) scan="${2:?--scan needs a value}"; shift 2 ;;
    --common) role="common"; shift ;;
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

# Prints the diagnostics of an awk run ($1 = file shown in the messages, $2 = the output) and counts them.
report() {
  local n
  awk -F'\t' -v f="$1" '$1 == "!error" || $1 == "!warn" { print ($1 == "!error" ? "error" : "warning") ": " f ($2 != "" ? ":" $2 : "") ": " $3 }' "$2"
  n="$(grep -c '^!error' "$2" || true)"; nerr=$((nerr + n))
  n="$(grep -c '^!warn' "$2" || true)"; nwarn=$((nwarn + n))
}
# Paths in standards.ini: backslashes become slashes, and relative paths are relative to its folder.
resolve() {
  local p="${1//\\//}"
  [[ "$p" == "-" ]] && p=""
  [[ -z "$p" || "$p" = /* || "$p" =~ ^[A-Za-z]: ]] || p="$base/$p"
  [[ -z "$p" ]] || p="$(full "$p")"
  printf '%s' "$p"
}
problem() { [[ "$1" == "error" ]] && nerr=$((nerr + 1)) || nwarn=$((nwarn + 1)); echo "$1: $2"; }

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

# Lints one document ($2) and its scan rule file ($4); $1 = the section name it must have ("" = any), $3 = role.
lint_doc() {
  local want="$1" doc="$2" role="$3" scan="$4" out="$tmpd/doc" name st src h
  [[ -f "$doc" ]] || { problem error "$doc: file not found"; return 0; }
  run_awk -v mode=doc -v role="$role" "$doc" > "$out"
  name="$(field name "$out")"
  st="$(awk -F'\t' '$1 == "stats" { print $2 " check items (" $3 "), " $4 " adjustable, " $5 " confirmations" }' "$out")"
  echo "document: ${name:-?} $(field version "$out"), $st"
  report "$doc" "$out"
  [[ -z "$want" || -z "$name" || "$name" == "$want" ]] || problem error "$doc: the front matter name $name does not match the section [$want] in standards.ini"
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
      lint_doc "" "$(full "$file")" "$role" "${scan:+$(full "$scan")}"
    else
      [[ -z "$scan" && -z "$role" ]] || { echo "error: --scan and --common go with --file" >&2; exit 2; }
      standards="$(full "$standards")"
      echo "== $standards"
      if [[ ! -f "$standards" ]]; then
        problem error "$standards: file not found; copy configs/standards.example.ini to configs/standards.ini"
      else
        base="$(dirname "$standards")"
        run_awk -v mode=standards -v settings="$settings" "$standards" > "$tmpd/ini"
        report "$standards" "$tmpd/ini"
        for n in "${names[@]+"${names[@]}"}"; do
          awk -F'\t' -v n="$n" '$1 == "std" && $2 == n { f = 1 } END { exit !f }' "$tmpd/ini" || problem error "$standards: [$n] is not registered"
        done
        while IFS=$'\t' read -r -u 3 k1 name k2 dpath scan role; do
          if [[ ${#names[@]} -gt 0 ]]; then
            keep=0; for n in "${names[@]}"; do [[ "$n" == "$name" ]] && keep=1; done
            [[ $keep -eq 1 ]] || continue
          fi
          [[ "$dpath" == "-" ]] && continue
          dpath="$(resolve "$dpath")"; scan="$(resolve "$scan")"
          echo
          echo "== [$name] $dpath"
          lint_doc "$name" "$dpath" "${role#-}" "$scan"
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
    e="$(awk -F'\t' '$1 == "!error" { print ($2 != "" ? ":" $2 : "") ": " $3; exit }' "$tmpd/doc")"
    [[ -z "$e" ]] || { echo "error: $file$e; run standard lint first" >&2; exit 3; }
    awk -F'\t' '$1 !~ /^!/ && $1 != "stats"' "$tmpd/doc"
    ;;

  diff)
    [[ ${#names[@]} -eq 2 ]] || { echo "error: diff needs OLD.md NEW.md" >&2; exit 2; }
    i=0
    for doc in "${names[@]}"; do
      [[ -f "$doc" ]] || { echo "error: file not found: $doc" >&2; exit 2; }
      run_awk -v mode=doc -v role="$role" "$doc" > "$tmpd/d$i"
      e="$(awk -F'\t' '$1 == "!error" { print ($2 != "" ? ":" $2 : "") ": " $3; exit }' "$tmpd/d$i")"
      [[ -z "$e" ]] || { echo "error: $doc$e; run standard lint first" >&2; exit 3; }
      i=$((i + 1))
    done
    run_awk -v mode=diff "$tmpd/d0" "$tmpd/d1"
    ;;

  resolve)
    [[ ${#names[@]} -le 1 ]] || { echo "error: resolve takes at most one NAME" >&2; exit 2; }
    standards="$(full "$standards")"
    [[ -f "$standards" ]] || { echo "error: $standards: file not found; copy configs/standards.example.ini to configs/standards.ini" >&2; exit 3; }
    base="$(dirname "$standards")"
    run_awk -v mode=standards -v settings="$settings" "$standards" > "$tmpd/ini"
    e="$(awk -F'\t' '$1 == "!error" { print ($2 != "" ? ":" $2 : "") ": " $3; exit }' "$tmpd/ini")"
    [[ -z "$e" ]] || { echo "error: $standards$e; run standard lint first" >&2; exit 3; }
    want="${names[1]:-}"
    if [[ -z "$want" ]]; then
      # Without a NAME: the only framework standard, or the common one when there is no framework standard.
      want="$(awk -F'\t' '$1 == "std" && $6 != "common" { n++; l = l (n > 1 ? ", " : "") $2; w = $2 }
        $1 == "std" && $6 == "common" { c = $2 }
        END { if (n > 1) print "!several standards are registered (" l "); pick one by name"; else if (n == 1) print w; else if (c != "") print c; else print "!no standard is registered" }' "$tmpd/ini")"
      [[ "$want" != !* ]] || { echo "error: $standards: ${want#!}" >&2; exit 2; }
    fi
    awk -F'\t' -v n="$want" '$1 == "std" && $2 == n { f = 1 } END { exit !f }' "$tmpd/ini" || { echo "error: $standards: [$want] is not registered" >&2; exit 2; }
    # The standard itself first, then the common standard (when it is another one); each with its check items.
    while IFS=$'\t' read -r -u 3 k1 name k2 dpath k3 role; do
      dpath="$(resolve "$dpath")"
      [[ -f "$dpath" ]] || { echo "error: $dpath: file not found; run standard lint first" >&2; exit 3; }
      run_awk -v mode=doc -v role="${role#-}" "$dpath" > "$tmpd/doc"
      e="$(awk -F'\t' '$1 == "!error" { print ($2 != "" ? ":" $2 : "") ": " $3; exit }' "$tmpd/doc")"
      [[ -z "$e" ]] || { echo "error: $dpath$e; run standard lint first" >&2; exit 3; }
      printf '%s\t%s\t%s\tsha256:%s\t%s\n' "$([[ "$name" == "$want" ]] && echo standard || echo common)" "$name" "$(field version "$tmpd/doc")" "$(sha "$dpath")" "$dpath"
      if [[ "$name" == "$want" ]]; then awk -F'\t' -v n="$name" '$1 == "points" && $2 == n { print "points\t" $3 "\t" $4 }' "$tmpd/ini"; fi
      awk -F'\t' '$1 == "check"' "$tmpd/doc"
    done 3< <(awk -F'\t' -v n="$want" '$1 == "std" && $2 == n { print } $1 == "std" && $6 == "common" && $2 != n { c = $0 } END { if (c != "") print c }' "$tmpd/ini")
    ;;

  *) echo "error: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac
