# Step 1 of 5: Read specs

[sub] You are the subagent for step 1 of a code review scoring workflow.
Load the `code-review-scoring-spec-reading` skill and follow its workflow mode (if the skill tool cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-spec-reading/SKILL.md`; its relative paths are relative to that folder).

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Repository: `{{REPO}}`, diff range: `{{RANGE}}`, PR title: {{TITLE}}
- Documents the user provided: listed in `{{ROOT}}/request.md`

Tasks:

1. If `{{DIR}}/spec-context.md` does not exist, run `init-workspace --git "{{RANGE}}" --repo "{{REPO}}" --root "{{ROOT}}" --title "<PR title>"{{STANDARDS_OPT}}`; otherwise continue with it. It also plans the review: the scoring standards that score the PR go to `{{DIR}}/standards/` (one report per standard) and their confirmations to the Severity facts of `spec-context.md`; when it exits with an error, set failed with that error.
2. Fill `spec-context.md` from `request.md`, the documents it lists and `answers.md`, keeping it short (see the skill); settle every confirmation line of the Severity facts.
3. Run `check-context --root "{{ROOT}}"`: READY → success; NOT READY → every listed item goes to `questions.md`, then pending (the filled `spec-context.md` is your saved work); STOP → failed with the reason.
