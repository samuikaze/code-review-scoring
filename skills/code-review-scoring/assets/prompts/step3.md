# Step 3 of 5: Analyze code ({{STANDARD}})

[sub] You are the subagent for step 3 of a code review scoring workflow.
Load the `code-review-scoring-code-analysis` skill and follow its workflow mode (if the skill tool cannot find it, read `{{SKILLS_DIR}}/code-review-scoring-code-analysis/SKILL.md`; its relative paths are relative to that folder).

- Review root: `{{ROOT}}` (pass `--root "{{ROOT}}" --standard {{STANDARD}}` to the skill's scripts)
- Scoring standard: `{{STANDARD}}`, document `{{STANDARD_DOC}}`; common standard for the files no framework standard covers: `{{COMMON_DOC}}`. Use only the check items of these documents (their codes, rules and severities); when several standards score this PR, the other standards' files are reviewed in their own step 3.
- Inputs: `{{ROOT}}/step1/spec-context.md`, the code review results `{{ROOT}}/step2/plan.tsv` and `{{ROOT}}/step2/<plugin>/cr.txt` (`prepare-diff` lists this standard's comments and its part of the diff in `prepared.txt`; do not read `step1/pr.diff` separately)
- Outputs: `{{DIR}}/prepared.txt`, `{{DIR}}/findings.txt`
- Report language: write all narrative text of `findings.txt` in {{REPORT_LANGUAGE}}

Tasks:

1. If `{{DIR}}/findings.draft.txt` exists with `answers.md`, this is a rerun after questions: start from the draft, apply the answers to the findings they affect, and do not review the diff again.
2. Otherwise run `prepare-diff --root "{{ROOT}}" --standard {{STANDARD}}{{CONFIG_OPT}}`, settle every code review comment (skill section "Using code review results"), then review the remaining check items of the standard documents without re-deriving what the code review already found.
3. Questions (only facts that `spec-context.md` does not already answer) go to `questions.md` after the whole diff has been reviewed; save every finding so far to `{{DIR}}/findings.draft.txt` before reporting pending.
4. Write `findings.txt` in the skill's format, run `score --check --root "{{ROOT}}" --standard {{STANDARD}}{{CONFIG_OPT}}` from the `code-review-scoring-score` skill (`{{SKILLS_DIR}}/code-review-scoring-score/scripts/`) and fix every error it reports; the success gate runs the same check.
5. If `{{ROOT}}/step4/{{STANDARD}}/errors.log` is newer than `findings.txt`, scoring rejected the findings: fix every listed error (recheck the code and the check items, not only the format).
