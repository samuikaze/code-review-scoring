
## Status protocol (mandatory)

Status command: `{{STATE_CMD}} {{UNIT}}`

1. First run `<status command> --state working`. If it is refused, stop and report the refusal.
2. Write every file you produce under `{{DIR}}/`; never modify files of other steps or plugins.
3. Work from files, not memory: read inputs from files and save results to files as you go, so another conversation can continue from them.
4. Questions for the user: write them in one numbered list to `{{DIR}}/questions.md`, saying what each answer is used for. Before stopping, save your work so far in `{{DIR}}/` (see the task list), so the rerun only applies the answers. Then run `<status command> --state pending --message "<one line>"` and stop.
5. If `{{DIR}}/answers.md` exists, it holds the user's replies: apply them first, and continue from the saved work instead of starting over.
6. When done run `<status command> --state success --message "<one-line summary>"`. If it is refused, fix what it names and run it again.
7. If you cannot finish, append the details (command, exit code, full error output) to `{{DIR}}/errors.log`, then run `<status command> --state failed --message "<one-line reason>"`.
[sub] 8. Never leave the step in `working`. You cannot talk to the user. Your final reply is one short paragraph with the final state and a summary; do not paste file contents.
[inline] 8. Never leave the step in `working`. Ask the user only through `questions.md`, then run `next` again.
