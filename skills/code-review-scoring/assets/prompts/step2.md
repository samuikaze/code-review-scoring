# Step 2 of 5: Analyze code

You are the subagent for step 2 of a code review scoring workflow. Load the `code-review-scoring-code-analysis` skill with your skill tool and follow it exactly. If the skill tool is unavailable or cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-code-analysis/SKILL.md` and follow it instead, resolving its relative paths (`scripts/`, `references/`, `assets/`) against `{{SKILLS_DIR}}/code-review-scoring-code-analysis/`. Workflow settings:

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Inputs: `{{ROOT}}/step1/pr.diff`, `{{ROOT}}/step1/spec-context.md`
- Outputs: `{{ROOT}}/step2/prepared.txt`, `{{ROOT}}/step2/findings.txt`

Tasks:
1. Run `prepare-diff --root "{{ROOT}}"` and review every check of the skill's checklist.
2. Questions for the user (row counts, cross-timezone business, springdoc, missing documents for a suspected upstream factor, …) go to `questions.md` after the whole diff has been reviewed; then report pending.
3. Write `findings.txt` in the skill's format and run the skill's self-check before reporting success.
4. If `{{ROOT}}/step3/errors.log` exists and is newer than `findings.txt`, this is a rerun after scoring rejected the findings: fix every listed error (recheck the code and the checklist, not only the format).

## Status protocol (mandatory)

Status command: `{{STATE_CMD}}`

1. Before anything else run: `<status command> --step 2 --state working`. If it is refused, stop and report the refusal.
2. Put every file you produce under `{{ROOT}}/step2/`. Do not modify files of other steps.
3. You cannot talk to the user (even when the main agent runs this step itself, use the same files). If you need information from the user:
   - write all questions in one numbered list to `{{ROOT}}/step2/questions.md`, saying what each answer is used for;
   - run `<status command> --step 2 --state pending --message "<one line>"` and stop.
4. If `{{ROOT}}/step2/answers.md` exists, it holds the user's replies to your earlier questions. Apply them first.
5. When the step is complete run `<status command> --step 2 --state success --message "<one-line summary>"`. If it is refused, fix what it names and try again.
6. If you cannot complete the step, first write the details to `{{ROOT}}/step2/errors.log` (append; include the command you ran, its exit code and its full error output), then run `<status command> --step 2 --state failed --message "<one-line reason>"`. The status command adds that line to the same log.
7. Never leave the step in `working`. Your final reply is one short paragraph: the final state and a summary. Do not paste file contents.
