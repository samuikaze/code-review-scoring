# Step 5 of 5: Report

You are the subagent for step 5 of a code review scoring workflow. Load the `code-review-scoring-report` skill with your skill tool and follow it exactly. If the skill tool is unavailable or cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-report/SKILL.md` and follow it instead, resolving its relative paths (`scripts/`, `references/`, `assets/`) against `{{SKILLS_DIR}}/code-review-scoring-report/`. Workflow settings:

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Inputs: `{{ROOT}}/step1/spec-context.md`, the code review results in `{{ROOT}}/step2/` (`plan.tsv`, `skipped.tsv`, `<plugin>/cr.txt`), `{{ROOT}}/step3/findings.txt`, `{{ROOT}}/step4/score.tsv`, `{{ROOT}}/step4/score.json`
- Output: the final report in the `reports/` folder next to the review root, the working copy `{{ROOT}}/step5/report.md`, and `{{ROOT}}/step5/report-path.txt`

Tasks:
1. Run `render-report --root "{{ROOT}}"` without `--no-publish`, so the final report is published to `reports/`.
2. If it says the scores or code review results are missing or stale, report failed and name the step that must be redone. Do not edit numbers or rewrite the report by hand.
3. Report success with the published report path in the message. Do not paste the report; the main agent presents it.

## Status protocol (mandatory)

Status command: `{{STATE_CMD}}`

1. Before anything else run: `<status command> --step 5 --state working`. If it is refused, stop and report the refusal.
2. Put every file you produce under `{{ROOT}}/step5/`. Do not modify files of other steps.
3. You cannot talk to the user (even when the main agent runs this step itself, use the same files). If you need information from the user:
   - write all questions in one numbered list to `{{ROOT}}/step5/questions.md`, saying what each answer is used for;
   - run `<status command> --step 5 --state pending --message "<one line>"` and stop.
4. If `{{ROOT}}/step5/answers.md` exists, it holds the user's replies to your earlier questions. Apply them first.
5. When the step is complete run `<status command> --step 5 --state success --message "<one-line summary>"`. If it is refused, fix what it names and try again.
6. If you cannot complete the step, first write the details to `{{ROOT}}/step5/errors.log` (append; include the command you ran, its exit code and its full error output), then run `<status command> --step 5 --state failed --message "<one-line reason>"`. The status command adds that line to the same log.
7. Never leave the step in `working`. Your final reply is one short paragraph: the final state and a summary. Do not paste file contents.
