---
name: code-review-scoring-score
description: Step 4 of the code-review-scoring workflow (read specs → code review → analyze code → score → report), usable on its own. Validates tmp/step3/findings.txt (check ids, allowed severities, locations on added diff lines, one deduction per id) and computes the seven dimension scores, the total and the S–D grade into tmp/step4/score.tsv and score.json. Use when dispatched by code-review-scoring, or when the user says 「打分數」、「計算 PR 分數」、「幫 PR 計分」、「重新計分」、「分數算一下」.
compatibility: Requires bash or zsh with awk and git, or Windows PowerShell 5.1 / PowerShell 7+.
metadata:
  workflow-step: "4/5"
  rules-version: "v0.5"
---

# Code Review Scoring – Score

Turn the findings into scores. **Never calculate scores or grades by hand**; the script is the single source of the numbers.

**Input:** `tmp/step3/findings.txt`, `tmp/step1/pr.diff`, `tmp/step1/spec-context.md` (`tmp` is the review root: the `tmp/` folder in the project root of these skills, two levels above this skill's physical folder; the scripts use it by default and take `--root` for another one).
**Output:** `tmp/step4/score.tsv` (for the report renderer) and `tmp/step4/score.json` (structured result).

## Modes

- **Workflow mode:** you were dispatched by `code-review-scoring` with a prompt that contains a status command. Follow that prompt: do not edit `findings.txt` (it belongs to step 3); validation errors make the step fail.
- **Standalone mode:** the user invoked this skill directly. First ask whether they want the full workflow (then switch to `code-review-scoring`) or only this step. For this step only: write no status files; you may fix `findings.txt` as described below, and when done suggest `code-review-scoring-report`. A findings file outside the `tmp` layout can be scored with `--findings <file> [--diff <file>]`.

## Script

Paths are relative to this skill's directory.

| bash | zsh | PowerShell |
| --- | --- | --- |
| `bash scripts/score.sh` | `zsh scripts/score.zsh` | `powershell -ExecutionPolicy Bypass -File scripts/score.ps1` |

## Procedure

1. Run `score`.
2. Act on the exit code:
   - **0**: done. It prints the grade, the dimension scores and any warnings.
   - **1**: validation failed. Each error names the line in `findings.txt`. Standalone: fix it and run again until it passes. Workflow: follow the dispatch prompt (step 3 is redone). When an error questions a judgment (a severity that is not allowed, a location outside the diff), recheck the code and the checklist of `code-review-scoring-code-analysis` instead of only reformatting.
   - **3**: step 1 or step 3 still has unresolved inputs or unanswered questions. Standalone: ask the user in one round, record the replies, run again. Workflow: report failed.
   - **2**: wrong arguments or missing files.
3. Treat warnings seriously. "unchanged context line" means the location is not new code: move the finding to the added line or drop it.

## Scoring rules (implemented by the script)

| Dimension | Points | | Severity | Deduction |
| --- | --- | --- | --- | --- |
| A Correctness | 25 | | Critical | 10 |
| B Security | 15 | | Major | 5 |
| C Test quality | 15 | | Minor | 2 |
| D Architecture and design | 15 | | Nit | 0 |
| E Performance and resource use | 10 | | | |
| F Readability | 10 | | | |
| G Maintainability | 10 | | | |

- Dimension score = points − sum of its deductions, never below 0. Total = sum of the seven dimension scores.
- Grades: S 95–100, A 85–94, B 70–84, C 55–69, D 0–54.
- Any Critical deduction caps the grade at B (Critical only costs 10 points, so the total alone could hide a serious defect).
- Suspected upstream factors (`U`) and `Nit` findings are never deducted.
- Allowed severities per check are in `scripts/rules.tsv`: the default, the adjustments written in the checklist, or `Nit`.

## Gotchas

- Do not edit `score.tsv` or `score.json`. To change a result, change `findings.txt` (step 3) and rerun.
- Rerun this step whenever `findings.txt` changes; the report step refuses stale scores.
- The diff used for location checks is `tmp/step1/pr.diff`. If the PR changed, start again from step 1 so every step uses the same diff.
