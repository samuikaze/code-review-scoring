---
name: code-review-scoring-report
description: Step 5 of code-review-scoring, usable on its own. Renders the final report (code review results and score results) to reports/ from the earlier steps' files with an editable template and label file. Use when the user says 「產出分數報告」、「產生評分報告」、「輸出 PR 評分結果」、「給我評分報告」、「調整報告模板」.
compatibility: Requires bash or zsh with awk, or Windows PowerShell 5.1 / PowerShell 7+.
metadata:
  workflow-step: "5/5"
  rules-version: "v0.5"
---

# Code Review Scoring – Report

Render the review report: part one holds the code review results of every plugin, part two the score results. Do not write the report by hand and do not change any number or comment in it.

**Input:** `tmp/step1/spec-context.md`, the code review results `tmp/step2/plan.tsv`, `tmp/step2/skipped.tsv`, `tmp/step2/<plugin>/cr.txt`, `tmp/step3/findings.txt`, `tmp/step4/score.tsv` and `tmp/step4/score.json` (`tmp` is the review root: the `tmp/` folder in the project root of these skills, two levels above this skill's physical folder; the scripts use it by default and take `--root` for another one). Without `tmp/step2/plan.tsv` the report states that no code review was run.
**Output:** the final report `reports/<YYYY-MM-DD>_<PR title>.md` (`reports/` next to the review root), a working copy `tmp/step5/report.md`, and `tmp/step5/report-path.txt` with the final report's absolute path.

## Modes

- **Workflow mode:** `code-review-scoring` runs this step's script itself with `review-state finish`; no agent is dispatched.
- **Standalone mode:** the user invoked this skill directly. First ask whether they want the full workflow (then switch to `code-review-scoring`) or only this step. For this step only: write no status files and present the result yourself (procedure step 4).

## Script

Paths are relative to this skill's directory.

| bash | zsh | PowerShell |
| --- | --- | --- |
| `bash scripts/render-report.sh` | `zsh scripts/render-report.zsh` | `powershell -ExecutionPolicy Bypass -File scripts/render-report.ps1` |

Options: `--template <file>` and `--labels <file>` use another template or label file, `--title <text>` overrides the PR title, `--reports <dir>` changes the publish directory (default `reports`, relative to the current directory), `--no-publish` writes only the working copy, `--out -` prints to stdout without writing anything.

The final report name is built from the render date and the PR title, with characters that are unsafe in file names replaced by `-`. Rendering the same PR again on the same day overwrites that file.

## Procedure

1. Run `render-report`.
2. Exit 1 means the scores are missing or older than `findings.txt` (rerun `code-review-scoring-score`), or a planned code review plugin has no `cr.txt` yet (finish step 2). Then retry.
3. A warning about an unknown placeholder means the template has a typo or a block placeholder that is not alone on its line; fix the template.
4. Standalone mode: reply with the grade, the total and the dimension scores (from `tmp/step4/score.tsv`) and the path of the published report (the `published` output line). Do not paste the report; show its content only when the user asks.

## Customizing the report

- `assets/report-template.md`: layout and wording of the report. Move, rename or remove sections freely.
- `assets/labels.tsv`: wording the script inserts (dimension names, field names, upstream categories, "none" text, separators).
- Placeholders are listed in [references/placeholders.md](references/placeholders.md).

## Gotchas

- The report contains only what the earlier steps recorded. If something is missing or wrong in the content, fix `tmp/step3/findings.txt` (step 3), rerun scoring (step 4), then render again.
- Empty sections render as the `none` label (無) automatically; do not delete the placeholders to hide them.
