# Scan rule file format

A scan rule file is UTF-8 text with one record per line and TAB-separated fields. Lines starting with `#` are comments; empty lines are ignored. `prepare-diff` (step 3 of the scoring) runs the rules over the added lines of the PR and lists the matches as candidates; step 3 confirms every candidate in the code.

## Source line

```text
# source: <document file> <version> sha256:<hash>
```

Written by `standard stamp` when a reviewed draft is saved. Lint compares the hash with the document and warns when the document changed since. Drafts do not need it.

## @scope: file scopes

```text
@scope	<name>	<within>	<path-regex>
```

- A file is in the scope when its path (relative to the repository root, `/`-separated) matches `path-regex` and it meets `within`: `-` (no condition), `<scope>` (also in that scope) or `!<scope>` (not in that scope). `within` refers to a scope defined on an earlier line.
- Names: lowercase letters, digits, `_` and `-`. The built-in scope `any` covers every reviewed file and cannot be defined.
- The summary of `prepared.txt` counts the scopes named `main`, `test` and `migration` when they are defined; use these names for production code, test code and database migrations.
- Define test code before production code, so production can be `!test`:

```text
@scope	test	-	(^|/)src/test/|(Test|Tests|IT)\.(java|kt)$
@scope	main	!test	(^|/)src/main/(java|kotlin)/.+\.(java|kt)$
```

## @pr: hints about the whole PR

```text
@pr	<check id>	<conditions>	<hint>
```

- Conditions, comma-separated, all must hold: `has:<scope>` (the PR adds lines to a file in the scope), `no:<scope>` (the PR touches no file in the scope), `modified:<scope>` (the PR modifies, deletes or renames an existing file in the scope; the hint lists those files).
- Example: `@pr	C1	has:main,no:test	main code changed without any test file`.

## Line rules

```text
<id>	<scope>	<flags>	<regex>	<prev-regex>	<exclude-regex>	<hint>
```

| Field | Meaning |
| --- | --- |
| id | a check id of the document (`A1`, or `CM-A1` in the common standard), or an uppercase tag for a list that serves several checks (for example `API` for added endpoints) |
| scope | a defined scope or `any` |
| flags | `i` case-insensitive, `c` also match comment lines (comments are skipped by default), `ic`, or `-` |
| regex | matched against each added line |
| prev-regex | the previous non-blank new-side line must match; `-` for none |
| exclude-regex | matched against "previous line + current line"; a match drops the candidate; `-` for none |
| hint | what step 3 should confirm, in a few English words |

Several rules may share an id (different scopes or patterns). Order the rules by check id, scopes first, then `@pr`, then line rules.

## Regex subset

The same regex runs in POSIX ERE (awk) and .NET, so use only what both share; lint rejects the rest:

- Allowed: literals, `.`, `[...]` and `[^...]` with ranges, `*`, `+`, `?`, `{m,n}`, `( )`, `|`, `^`, `$`, escapes of special characters (`\.`, `\(`, `\[`, `\|`, `\$`, `\\`).
- Not allowed: `\b`, `\s`, `\d`, `\w` (use `[ \t]`, `[0-9]`, `[A-Za-z0-9_]`), lookaround, lazy quantifiers (`*?`), non-capturing or named groups (`(?`), POSIX classes (`[[:space:]]`), back-references.
- A literal TAB cannot appear in a field (it separates the fields); write `\t` inside brackets, as in `[ \t]`.
- Word boundaries: `(^|[^A-Za-z0-9_])name([^A-Za-z0-9_]|$)`.
- Case: prefer the `i` flag to `[Aa]` pairs.

## What makes a good rule

- One rule finds one kind of code that the check item describes, and its hint says what to confirm: `possible SQL built by string concatenation`, not `SQL injection (Critical)`.
- Scope it as narrowly as the check item allows (tests only for test checks, configuration files for configuration checks).
- Use `exclude-regex` for the common false positives you can name (a constant on the same line, a safe wrapper on the previous line).
- No rule for checks that need the surrounding code or intent to judge; list them in `notes.md` with the reason.
