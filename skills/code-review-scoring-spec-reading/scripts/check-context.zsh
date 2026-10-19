#!/usr/bin/env zsh
# Check that every input in spec-context.md is resolved and every open question is answered.
emulate -L zsh
setopt err_exit no_unset pipe_fail

usage() {
  cat <<'USAGE'
Usage: check-context.zsh [--root DIR]

      --root DIR       review root (default: tmp); checks ROOT/step1/spec-context.md
  -h, --help           show this help

Exit codes: 0 ready, 1 waiting for the user (or malformed file), 2 bad arguments,
            3 a required input was declined (stop the review).
USAGE
}

script_dir="${0:A:h}"
root="tmp"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:?--root needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1 (see --help)" >&2; exit 2 ;;
  esac
done
ctx="$root/step1/spec-context.md"
[[ -f "$ctx" ]] || { echo "error: $ctx not found; run init-workspace first" >&2; exit 2; }
LC_ALL=C awk -v qfile="$root/step1/questions.md" -f "$script_dir/lib/check.awk" "$ctx"
