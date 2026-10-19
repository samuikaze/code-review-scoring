---
name: code-review-scoring-report
description: Step 5 of the code-review-scoring workflow (read specs → analyze code → score → code review → report), usable on its own. Renders one final report that combines the code review results and the score results to reports/ (working copy in tmp/step5/report.md) from the earlier steps (spec-context.md, findings.txt, score.tsv, score.json, step4 code review results) using an editable report template and label file, then presents it. Use when dispatched by code-review-scoring, or when the user says 「產出分數報告」、「產生評分報告」、「輸出 PR 評分結果」、「給我評分報告」、「調整報告模板」.
compatibility: Requires bash or zsh with awk, or Windows PowerShell 5.1 / PowerShell 7+.
metadata:
  workflow-step: "5/5"
  rules-version: "v0.5"
---

# Code Review Scoring – Report

Render the review report: part one holds the code review results of every plugin, part two the score results. Do not write the report by hand and do not change any number or comment in it.

**Input:** `tmp/step1/spec-context.md`, `tmp/step2/findings.txt`, `tmp/step3/score.tsv`, `tmp/step3/score.json`, and the code review results `tmp/step4/plan.tsv`, `tmp/step4/skipped.tsv`, `tmp/step4/<plugin>/cr.txt` (`tmp` is the review root; scripts take `--root`). Without `tmp/step4/plan.tsv` the report states that no code review was run.
**Output:** the final report `reports/<YYYY-MM-DD>_<PR title>.md`, a working copy `tmp/step5/report.md`, and `tmp/step5/report-path.txt` with the final report's absolute path.

## Modes

- **Workflow mode:** you were dispatched by `code-review-scoring` with a prompt that contains a status command. Follow that prompt; do not paste the report, the main agent presents it.
- **Standalone mode:** the user invoked this skill directly. First ask whether they want the full workflow (then switch to `code-review-scoring`) or only this step. For this step only: write no status files and present the report yourself (procedure step 4).

## Script

Paths are relative to this skill's directory.

| bash | zsh | PowerShell |
| --- | --- | --- |
| `bash scripts/render-report.sh --root tmp` | `zsh scripts/render-report.zsh --root tmp` | `powershell -ExecutionPolicy Bypass -File scripts/render-report.ps1 -Root tmp` |

Options: `--template <file>` and `--labels <file>` use another template or label file, `--title <text>` overrides the PR title, `--reports <dir>` changes the publish directory (default `reports`, relative to the current directory), `--no-publish` writes only the working copy, `--out -` prints to stdout without writing anything.

The final report name is built from the render date and the PR title, with characters that are unsafe in file names replaced by `-`. Rendering the same PR again on the same day overwrites that file.

## Procedure

1. Run `render-report --root tmp`.
2. Exit 1 means the scores are missing or older than `findings.txt` (rerun `code-review-scoring-score`), or a planned code review plugin has no `cr.txt` yet (finish step 4). Then retry.
3. A warning about an unknown placeholder means the template has a typo or a block placeholder that is not alone on its line; fix the template.
4. Standalone mode: reply with the content of the published report (path in the `published` output line) exactly as rendered, followed by one line with its path.

## Customizing the report

- `assets/report-template.md`: layout and wording of the report. Move, rename or remove sections freely.
- `assets/labels.tsv`: wording the script inserts (dimension names, field names, upstream categories, "none" text, separators).
- Placeholders are listed in [references/placeholders.md](references/placeholders.md).

## Gotchas

- The report contains only what the earlier steps recorded. If something is missing or wrong in the content, fix `tmp/step2/findings.txt` (step 2), rerun scoring (step 3), then render again.
- Empty sections render as the `none` label (無) automatically; do not delete the placeholders to hide them.
