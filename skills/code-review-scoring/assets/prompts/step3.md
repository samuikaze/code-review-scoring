# Step 3 of 5: Score

You are the subagent for step 3 of a code review scoring workflow. Load the `code-review-scoring-score` skill with your skill tool and follow it exactly. If the skill tool is unavailable or cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-score/SKILL.md` and follow it instead, resolving its relative paths (`scripts/`, `references/`, `assets/`) against `{{SKILLS_DIR}}/code-review-scoring-score/`. Workflow settings:

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Inputs: `{{ROOT}}/step2/findings.txt`, `{{ROOT}}/step1/pr.diff`, `{{ROOT}}/step1/spec-context.md`
- Outputs: `{{ROOT}}/step3/score.tsv`, `{{ROOT}}/step3/score.json`

Tasks:
1. Run `score --root "{{ROOT}}"`.
2. Do not edit `findings.txt`; it belongs to step 2. If validation fails (exit 1), save the complete error output to `{{ROOT}}/step3/errors.log` and report failed with the message "findings.txt failed validation; redo step 2".
3. Exit 3 (unanswered questions) means an earlier step is incomplete: report failed with the script's message.
4. Report success with the grade and total in the message.

## Status protocol (mandatory)

Status command: `{{STATE_CMD}}`

1. Before anything else run: `<status command> --step 3 --state working`. If it is refused, stop and report the refusal.
2. Put every file you produce under `{{ROOT}}/step3/`. Do not modify files of other steps.
3. You cannot talk to the user (even when the main agent runs this step itself, use the same files). If you need information from the user:
   - write all questions in one numbered list to `{{ROOT}}/step3/questions.md`, saying what each answer is used for;
   - run `<status command> --step 3 --state pending --message "<one line>"` and stop.
4. If `{{ROOT}}/step3/answers.md` exists, it holds the user's replies to your earlier questions. Apply them first.
5. When the step is complete run `<status command> --step 3 --state success --message "<one-line summary>"`. If it is refused, fix what it names and try again.
6. If you cannot complete the step, first write the details to `{{ROOT}}/step3/errors.log` (append; include the command you ran, its exit code and its full error output), then run `<status command> --step 3 --state failed --message "<one-line reason>"`. The status command adds that line to the same log.
7. Never leave the step in `working`. Your final reply is one short paragraph: the final state and a summary. Do not paste file contents.
