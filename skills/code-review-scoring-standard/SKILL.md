---
name: code-review-scoring-standard
description: Maintains the scoring standards of code-review-scoring; never part of a scoring run. Checks standard documents and scan rule files (lint), generates or updates the scan rule file of a standard with a generator subagent and a fixed review, or reviews an existing scan rule file against its document. Use only when the user asks to maintain a standard, e.g. 「檢查評分標準」、「lint 評分規則」、「產生掃描規則」、「更新掃描規則」、「審核掃描規則」.
compatibility: Works with or without a subagent tool. Requires the code-review-scoring skill next to this one, and bash or zsh with awk, or Windows PowerShell 5.1 / PowerShell 7+.
---

# Code Review Scoring – Maintain Scoring Standards

A scoring standard is a Markdown document (written from `templates/<language>/scoring-rule-template.md` in the project root) registered in `configs/standards.ini`, optionally with a scan rule file (TSV, `scan=`). The people who write standards maintain only the document; the scan rules are generated and reviewed here, so nobody writes regexes by hand. The scan rules only list candidate lines for step 3 of the scoring; they never deduct by themselves.

You never edit a standard document or `configs/standards.ini`: report what is wrong and let the user change it. You write a scan rule file only in generate mode, only after the user confirms it.

## Script

`standard` of `code-review-scoring` (`../code-review-scoring/scripts/standard.sh`, `.zsh`, or `powershell -ExecutionPolicy Bypass -File ../code-review-scoring/scripts/standard.ps1`; paths relative to this skill's directory):

| Command | Use |
| --- | --- |
| `lint [NAME ...]` | check `configs/standards.ini` and the documents and scan rule files it lists |
| `lint --file DOC.md [--scan RULES.tsv] [--common]` | check one document, with a scan rule file such as a draft |
| `diff OLD.md NEW.md` | the dimensions, check items and confirmations that changed between two versions |
| `stamp --file DOC.md --scan DRAFT.tsv --out RULES.tsv [--common]` | write a reviewed draft to its place with the source line of the document |

`--common` is for the common standard (`role="common"`, check ids `CM-…`). Lint exit 1 means errors; warnings alone exit 0. The lint compiles every regex with awk and with .NET (when PowerShell is installed), so a rule that passes runs in every shell.

## Modes

Ask which mode when the request does not make it clear. Find the standard's document and scan rule file in `configs/standards.ini` (paths relative to `configs/`); for a document that is not registered yet, ask the user for its path.

### Check mode

Run `lint` (all standards, or the names the user gave) and report its errors and warnings with file and line, grouped by file. Explain how to fix each one in the document's terms (the template's rules), and suggest generate or review mode when lint warns that the scan rules are out of date (`the document has changed since`). Change nothing.

### Generate mode

Produce a new or updated scan rule file. Work in `tmp/scan-rules/<standard>/` in the project root (create it; keep earlier rounds' files until the end).

- [ ] 1. Run `lint --file <document> [--common]`. Stop on errors: the user fixes the document first.
- [ ] 2. Generate the draft: dispatch **one** subagent with [assets/generator-prompt.md](assets/generator-prompt.md), its placeholders filled in (see the file). Without a subagent tool, or with `subagent=false` in `[workflow]` of `configs/settings.ini`, follow the prompt yourself and tell the user once that the generator and the reviewer are the same agent this time. It writes `draft.tsv` and `notes.md`.
- [ ] 3. Run `lint --file <document> --scan tmp/scan-rules/<standard>/draft.tsv [--common]`. Ignore only the warning about the missing `# source:` line. Errors go back to the generator (step 5).
- [ ] 4. Review the draft against the document with every item of [references/review-checklist.md](references/review-checklist.md), and write `review.md` in its format. Read the checklist each round; do not review from memory.
- [ ] 5. Lint errors or `result: changes needed`: dispatch the generator again with the same prompt plus the review (`{{REVIEW}}`), then repeat steps 3 and 4. At most **3** rounds in all; if round 3 still fails, stop, show the user the open items of `review.md`, and write nothing.
- [ ] 6. Show the user the changes against the current scan rule file (`git diff --no-index <current file> tmp/scan-rules/<standard>/draft.tsv`, or the whole draft when there is none), grouped as added, changed and removed rules, with the review summary and the check items left without rules (from `notes.md`). Ask for confirmation.
- [ ] 7. Only after the user confirms: `stamp --file <document> --scan tmp/scan-rules/<standard>/draft.tsv --out <scan path> [--common]`, then `lint <standard>` to confirm. When `standards.ini` has no `scan=` for the standard yet, ask the user where to save the file and tell them to add `scan="<path>"` to the section themselves.

### Review mode

Check an existing scan rule file against its document without producing anything new: run steps 3 and 4 of generate mode on the registered scan rule file (instead of `draft.tsv`), write `tmp/scan-rules/<standard>/review.md`, and tell the user the result and the open items. Change no file. A lint warning that the document changed since the rules were made is an item of the review.

## Gotchas

- Scan rules are clues for step 3, which confirms every candidate in the code. Prefer a rule that misses some cases over one that floods step 3 with false positives, and never encode a severity or a condition in a rule: the hint says what to confirm.
- Checks that need the context (design, intent, test coverage of a logic change, comparison with the spec) get no line rule; `@pr` hints cover only what the set of changed files shows.
- Keep rules that an earlier review accepted unless the document changed them; the user reviews the diff, and a small diff is easier to check.
- The draft and `review.md` are working files; the user's confirmation is the only way into the registered scan rule file.
