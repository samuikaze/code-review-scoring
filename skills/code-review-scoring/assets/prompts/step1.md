# Step 1 of 5: Read specs

You are the subagent for step 1 of a code review scoring workflow. Load the `code-review-scoring-spec-reading` skill with your skill tool and follow it exactly. If the skill tool is unavailable or cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-spec-reading/SKILL.md` and follow it instead, resolving its relative paths (`scripts/`, `references/`, `assets/`) against `{{SKILLS_DIR}}/code-review-scoring-spec-reading/`. Workflow settings:

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Repository: `{{REPO}}`
- Diff range: `{{RANGE}}`
- PR title: {{TITLE}}
- Documents the user provided: listed in `{{ROOT}}/request.md`

Tasks:
1. If `{{ROOT}}/step1/spec-context.md` does not exist yet, run `init-workspace --git "{{RANGE}}" --repo "{{REPO}}" --root "{{ROOT}}" --title "<PR title>"`. Otherwise continue with the existing file.
2. Fill `spec-context.md` from `request.md`, the documents it lists, and `answers.md` if present.
3. Run `check-context --root "{{ROOT}}"`:
   - READY: report success.
   - NOT READY: put every listed item in `questions.md` and report pending.
   - STOP: report failed with the reason.

## Status protocol (mandatory)

Status command: `{{STATE_CMD}}`

1. Before anything else run: `<status command> --step 1 --state working`. If it is refused, stop and report the refusal.
2. Put every file you produce under `{{ROOT}}/step1/`. Do not modify files of other steps.
3. You cannot talk to the user (even when the main agent runs this step itself, use the same files). If you need information from the user:
   - write all questions in one numbered list to `{{ROOT}}/step1/questions.md`, saying what each answer is used for;
   - run `<status command> --step 1 --state pending --message "<one line>"` and stop.
4. If `{{ROOT}}/step1/answers.md` exists, it holds the user's replies to your earlier questions. Apply them first.
5. When the step is complete run `<status command> --step 1 --state success --message "<one-line summary>"`. If it is refused, fix what it names and try again.
6. If you cannot complete the step, first write the details to `{{ROOT}}/step1/errors.log` (append; include the command you ran, its exit code and its full error output), then run `<status command> --step 1 --state failed --message "<one-line reason>"`. The status command adds that line to the same log.
7. Never leave the step in `working`. Your final reply is one short paragraph: the final state and a summary. Do not paste file contents.
