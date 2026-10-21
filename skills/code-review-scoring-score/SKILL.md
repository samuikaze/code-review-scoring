---
name: code-review-scoring-score
description: Step 4 of code-review-scoring, usable on its own. Validates tmp/step3/findings.txt and computes the dimension scores, total and S–D grade into tmp/step4/score.tsv and score.json with a script. Use when the user says 「打分數」、「計算 PR 分數」、「幫 PR 計分」、「重新計分」、「分數算一下」.
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

- **Workflow mode:** `code-review-scoring` runs this step's script itself with `review-state finish`; no agent is dispatched. Validation errors make the step fail and send the workflow back to step 3, which owns `findings.txt`.
- **Standalone mode:** the user invoked this skill directly. First ask whether they want the full workflow (then switch to `code-review-scoring`) or only this step. For this step only: write no status files; you may fix `findings.txt` as described below, and when done suggest `code-review-scoring-report`. A findings file outside the `tmp` layout can be scored with `--findings <file> [--diff <file>]`.

## Script

Paths are relative to this skill's directory.

| bash | zsh | PowerShell |
| --- | --- | --- |
| `bash scripts/score.sh` | `zsh scripts/score.zsh` | `powershell -ExecutionPolicy Bypass -File scripts/score.ps1` |

`--check` (PowerShell `-Check`) only validates `findings.txt`, with the same rules and exit codes, and writes nothing; step 3 runs it before it reports success.

The check ids, their severities and the points overrides come from the scoring standard registered in `configs/standards.ini` in the project root, read with `standard resolve` of `code-review-scoring` (the sibling skill must be installed). By default the script uses the only framework standard, or the common standard when no framework standard is registered; with several framework standards, name one with `--standard NAME` (PowerShell `-Standard`). The check items of the common standard (ids starting with `CM-`) are always allowed as well. `score.tsv` and `score.json` record the name, version and sha256 of the standards used.

## Procedure

1. Run `score`.
2. Act on the exit code:
   - **0**: done. It prints the grade, the dimension scores and any warnings.
   - **1**: validation failed. Each error names the line in `findings.txt`. Standalone: fix it and run again until it passes. Workflow: `finish` records the failure and step 3 is redone. When an error questions a judgment (a severity that is not allowed, a location outside the diff), recheck the code and the checklist of `code-review-scoring-code-analysis` instead of only reformatting.
   - **3**: step 1 or step 3 still has unresolved inputs or unanswered questions. Standalone: ask the user in one round, record the replies, run again. Workflow: report failed.
   - **2**: wrong arguments, missing files, invalid scoring settings in `configs/settings.ini`, or a missing or invalid `configs/standards.ini` or standard document (tell the user what the error says and, for the standards, that `standard lint` lists every problem; do not edit these files yourself).
3. Treat warnings seriously. "unchanged context line" means the location is not new code: move the finding to the added line or drop it.

## Scoring rules (implemented by the script)

The points, deductions (including whether they are merged) and grade thresholds are settings: the `[points]`, `[deductions]` and `[grades]` sections of `configs/settings.ini` in the project root (`--config` for another file). Anything not set there keeps the default below. The `points.A`–`points.G` overrides of the standard in `configs/standards.ini` win over `[points]`. The script refuses invalid settings with exit 2 (the seven dimensions must add up to 100, grade thresholds must be S > A > B > C). Never change them on your own; they are the user's choice.

Defaults:

| Dimension | Points | | Severity | Deduction |
| --- | --- | --- | --- | --- |
| A Correctness | 25 | | Critical | 10 |
| B Security | 15 | | Major | 5 |
| C Test quality | 15 | | Minor | 2 |
| D Architecture and design | 15 | | Nit | 1 |
| E Performance and resource use | 10 | | | |
| F Readability | 10 | | | |
| G Maintainability | 10 | | | |

- `[deductions] merge` decides how a check id found in several places is deducted:
  - `false` (default): every `F` record is one occurrence with one location and is deducted on its own, so a check id found in three places is deducted three times. A record with several locations, or the same check id twice at the same location, fails validation.
  - `true`: one `F` record per check id with all its locations, deducted once. The same check id in two records fails validation.
- Every `F` and `U` record is deducted, `Nit` included.
- A check id belongs to the dimension of its first letter; ids of the common standard to the letter after `CM-` (`CM-B1` is B).
- Dimension score = points − sum of its deductions, never below 0. Total = sum of the seven dimension scores − deductions of `F` records without a check id (`-`) − deductions of suspected upstream factors (`U`), never below 0.
- Grades: S 95–100, A 85–94, B 70–84, C 55–69, D 0–54 (lower bounds of S, A, B, C are configurable).
- Any Critical deduction caps the grade at B, whatever the settings (a single deduction could not otherwise reflect a serious defect).
- Allowed severities per check come from the standard document: the default, the adjustment written for the check item, or `Nit`. Records without a check id and `U` records take any severity.
- With the review root, every comment of a `mapped` plugin in `tmp/step2` must be cited in `source:` (as `<plugin>#<n>`) or rejected in an `X` line, never both; comments of `advisory` plugins may be neither.

## Gotchas

- Do not edit `score.tsv` or `score.json`. To change a result, change `findings.txt` (step 3) and rerun.
- Rerun this step whenever `findings.txt` changes; the report step refuses stale scores.
- The diff used for location checks is `tmp/step1/pr.diff`. If the PR changed, start again from step 1 so every step uses the same diff.
