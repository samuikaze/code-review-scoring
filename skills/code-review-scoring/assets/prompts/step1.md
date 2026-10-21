# Step 1 of 5: Read specs

[sub] You are the subagent for step 1 of a code review scoring workflow.
Load the `code-review-scoring-spec-reading` skill and follow its workflow mode (if the skill tool cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-spec-reading/SKILL.md`; its relative paths are relative to that folder).

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}"` to the skill's scripts)
- Repository: `{{REPO}}`, diff range: `{{RANGE}}`, PR title: {{TITLE}}
- Documents the user provided: listed in `{{ROOT}}/request.md`

Tasks:

1. If `{{DIR}}/spec-context.md` does not exist, run `init-workspace --git "{{RANGE}}" --repo "{{REPO}}" --root "{{ROOT}}" --title "<PR title>"`; otherwise continue with it.
2. Fill `spec-context.md` from `request.md`, the documents it lists and `answers.md`, keeping it short (see the skill).
3. Run `check-context --root "{{ROOT}}"`: READY → success; NOT READY → every listed item goes to `questions.md`, then pending (the filled `spec-context.md` is your saved work); STOP → failed with the reason.
