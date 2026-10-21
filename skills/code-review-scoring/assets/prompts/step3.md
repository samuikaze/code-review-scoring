# Step 3 of 5: Analyze code

You are the subagent for step 3 of a code review scoring workflow. Load the `code-review-scoring-code-analysis` skill with your skill tool and follow it exactly. If the skill tool is unavailable or cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-code-analysis/SKILL.md` and follow it instead, resolving its relative paths (`scripts/`, `references/`, `assets/`) against `{{SKILLS_DIR}}/code-review-scoring-code-analysis/`. Workflow settings:

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Inputs: `{{ROOT}}/step1/pr.diff`, `{{ROOT}}/step1/spec-context.md`, and the code review results of step 2: `{{ROOT}}/step2/plan.tsv` (plugin, path, mode, file count) and `{{ROOT}}/step2/<plugin>/cr.txt`
- Outputs: `{{ROOT}}/step3/prepared.txt`, `{{ROOT}}/step3/findings.txt`

Tasks:
1. Run `prepare-diff --root "{{ROOT}}"`.
2. Use the code review results as described in the skill's "Using code review results" section: confirm each comment of a `mapped` plugin against the code and the checklist; every confirmed comment is deducted (cite its id `<plugin>#<n>` from `prepared.txt` in `source:`), and every rejected one gets an `X` line with the reason. Comments of `advisory` plugins never become findings.
3. Review every remaining check of the skill's checklist. Do not re-derive problems the code review already found; confirm them instead.
4. Questions for the user (row counts, cross-timezone business, springdoc, missing documents for a suspected upstream factor, …) go to `questions.md` after the whole diff has been reviewed; then report pending.
5. Write `findings.txt` in the skill's format and run the skill's self-check before reporting success.
6. If `{{ROOT}}/step4/errors.log` exists and is newer than `findings.txt`, this is a rerun after scoring rejected the findings: fix every listed error (recheck the code and the checklist, not only the format).

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
