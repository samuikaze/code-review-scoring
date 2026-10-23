---
name: code-review-scoring-score
description: Step 4 of code-review-scoring, usable on its own. Validates tmp/step3/findings.txt and computes the dimension scores, total and grade (on the severity scale and grades of the scoring standard) into tmp/step4/score.tsv and score.json with a script. Use when the user says 「打分數」、「計算 PR 分數」、「幫 PR 計分」、「重新計分」、「分數算一下」.
compatibility: Requires bash or zsh with awk and git, or Windows PowerShell 5.1 / PowerShell 7+.
metadata:
  workflow-step: "4/5"
---

# Code Review Scoring – Score

Turn the findings into scores. **Never calculate scores or grades by hand**; the script is the single source of the numbers.

**Input:** `tmp/step3/findings.txt`, `tmp/step1/pr.diff`, `tmp/step1/spec-context.md` (`tmp` is the review root: the `tmp/` folder in the project root of these skills, two levels above this skill's physical folder; the scripts use it by default and take `--root` for another one).
**Output:** `tmp/step4/score.tsv` (for the report renderer) and `tmp/step4/score.json` (structured result).

With the review plan of the workflow (`tmp/step1/standards/plan.tsv`, written in step 1), each scoring standard has its own folders: `tmp/step3/<standard>/`, `tmp/step4/<standard>/` and `tmp/step5/<standard>/`; pass `--standard <standard>` (PowerShell `-Standard`) to the scripts (it may be left out when only one standard scores the PR). They then read only that standard's part of the diff (`tmp/step1/standards/<standard>.diff`), its snapshot `tmp/step1/standards/<standard>.resolve` and the code review comments on its files.

## Modes

- **Workflow mode:** `code-review-scoring` runs this step's script itself with `review-state finish`; no agent is dispatched. Validation errors make the step fail and send the workflow back to step 3, which owns `findings.txt`.
- **Standalone mode:** the user invoked this skill directly. First ask whether they want the full workflow (then switch to `code-review-scoring`) or only this step. For this step only: write no status files; you may fix `findings.txt` as described below, and when done suggest `code-review-scoring-report`. A findings file outside the `tmp` layout can be scored with `--findings <file> [--diff <file>]`.

## Script

Paths are relative to this skill's directory.

| bash | zsh | PowerShell |
| --- | --- | --- |
| `bash scripts/score.sh` | `zsh scripts/score.zsh` | `powershell -ExecutionPolicy Bypass -File scripts/score.ps1` |

`--check` (PowerShell `-Check`) only validates `findings.txt`, with the same rules and exit codes, and writes nothing; step 3 runs it before it reports success.

The check ids, their severities, the severity scale, the points and the grades come from the scoring standard: an enabled rule of the rules project that `[rules] root` of `configs/settings.ini` in the project root names (`--config` for another settings file), read with `standard resolve` of `code-review-scoring` (the sibling skill must be installed). By default the script uses the only enabled framework rule, or the common rule when no framework rule is enabled; with several framework standards, name one with `--standard NAME` (PowerShell `-Standard`). The check items of the common standard (ids starting with `CM-`) are always allowed as well. The common rule always takes its points and grades from `defaults.ini`. `score.tsv` and `score.json` record the name, version and sha256 of the standards used, and the sha256 of the `rule.ini` of each and of `defaults.ini` (`ruleini` and `defaults` records; `ruleIniHash` and `defaultsHash`).

## Procedure

1. Run `score`.
2. Act on the exit code:
   - **0**: done. It prints the grade, the dimension scores and any warnings.
   - **1**: validation failed. Each error names the line in `findings.txt`. Standalone: fix it and run again until it passes. Workflow: `finish` records the failure and step 3 is redone. When an error questions a judgment (a severity that is not allowed, a location outside the diff), recheck the code and the check items of the scoring standard instead of only reformatting.
   - **3**: step 1 or step 3 still has unresolved inputs or unanswered questions. Standalone: ask the user in one round, record the replies, run again. Workflow: report failed.
   - **2**: wrong arguments, missing files, a missing `[rules] root` in `configs/settings.ini`, or an invalid rules project or standard document (tell the user what the error says and, for the rules, that `standard lint` lists every problem; do not edit these files yourself).
3. Treat warnings seriously. "unchanged context line" means the location is not new code: move the finding to the added line or drop it.

## Scoring rules (implemented by the script)

The points, the severity scale (codes, deductions, grade caps), the grades and whether deductions are merged are settings of the rules project: the `[points]`, `[severity:CODE]`, `[grade:CODE]` and `[scoring]` sections of the standard's `rule.ini`, or of `defaults.ini` of the rules project for the groups that `rule.ini` does not set (see `templates/<language>/rule-template.ini`). `standard lint` checks them, and the script refuses a standard whose settings cannot be read with exit 2. Never change them on your own; they are the user's choice.

Defaults of the template (`rule-template.ini`):

| Dimension | Points | | Severity | Deduction | Caps the grade at | | Grade | Lowest total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A Correctness | 25 | | Critical | 10 | B | | A | 95 |
| B Security | 15 | | Major | 5 | | | B | 85 |
| C Test quality | 15 | | Minor | 2 | | | C | 70 |
| D Architecture and design | 15 | | Nit | 1 | | | D | 60 |
| E Performance and resource use | 10 | | | | | | F | 0 |
| F Readability | 10 | | | | | | | |
| G Maintainability | 10 | | | | | | | |

- `[scoring] merge` decides how a check id found in several places is deducted:
  - `false` (default): every `F` record is one occurrence with one location and is deducted on its own, so a check id found in three places is deducted three times. A record with several locations, or the same check id twice at the same location, fails validation.
  - `true`: one `F` record per check id with all its locations, deducted once. The same check id in two records fails validation.
- Every `F` and `U` record is deducted, the lowest severity of the scale included. A severity outside the scale fails validation.
- A check id belongs to the dimension of its first letter; ids of the common standard to the letter after `CM-` (`CM-B1` is B).
- Dimension score = points − sum of its deductions, never below 0. Total = sum of the seven dimension scores − deductions of `F` records without a check id (`-`) − deductions of suspected upstream factors (`U`), never below 0.
- Grade: the first grade, from the highest, whose lowest total the total reaches.
- A deduction whose severity has a cap limits the grade to that grade at most; with several, the lowest cap applies. `score.tsv` (`cap` record) and `score.json` (`cap`) name the severity and the grade.
- Allowed severities per check come from the standard document: the default, the adjustment written for the check item, or the lowest severity of the scale. Records without a check id and `U` records take any severity of the scale.
- When the common standard has its own severity scale (other codes, or another order), column 3 of its check items (`CM-…`) holds the closest severity of the standard's scale, any one of it. `from:` with their severity on the common scale is recommended but optional; when present, it is checked as above against the common document. With the same scale, `from:` is refused.
- Every code review comment of the report (`mapped` and `advisory` plugins) needs one `M|<plugin>#<n>|<severity>` line with a severity of the standard's scale; the report counts and sorts the comments by it.
- With the review root, every comment of a `mapped` plugin in `tmp/step2` must be cited in `source:` (as `<plugin>#<n>`) or rejected in an `X` line, never both; comments of `advisory` plugins may be neither.

## Gotchas

- Do not edit `score.tsv` or `score.json`. To change a result, change `findings.txt` (step 3) and rerun.
- Rerun this step whenever `findings.txt` changes; the report step refuses stale scores.
- The diff used for location checks is `tmp/step1/pr.diff`. If the PR changed, start again from step 1 so every step uses the same diff.
