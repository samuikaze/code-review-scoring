# Setup, settings and state commands

Read this file only when the setup check exits 7, when the user wants to change the settings, or when you need a state command that the workflow procedure does not mention.

## Setup check

Run from the skill's directory: `bash scripts/setup.sh check`, `zsh scripts/setup.zsh check` or `powershell -ExecutionPolicy Bypass -File scripts/setup.ps1 check`. Add `--platform <Claude|Copilot|Codex|Gemini|other platform name>` only when the platform has a subagent tool.

It covers, in the project root:

- `configs/plugins.ini`: the code review plugins (it may list none);
- `configs/settings.ini`, `[workflow]` section: `subagent=true` (each step runs in its own subagent) or `subagent=false` (you run every step yourself);
- `configs/settings.ini`, `[<platform>]` section: the subagent model and reasoning, needed only when `subagent=true` and `--platform` is given.

When exit 7 comes with `legacy:` lines, the old `configs.ini` / `plugins.ini` is still in the project root (these files moved into `configs/`). Show the user the `legacy:` and `note:` lines and the move commands that `check` printed, ask them to move the files themselves, and run `check` again afterwards. Never move, merge or delete them yourself.

Otherwise exit 7 means something is missing. Tell the user what is missing and ask which way to create it (one question):

- **Wizard in a terminal:** the user runs the `wizard` command that `check` printed; it needs an interactive terminal, so you cannot run it. In Claude Code the user can type `! <command>` to run it in this session.
- **Answer your questions:** ask in one message only what is missing:
  - plugins: whether code review plugins should be registered and, for each plugin, its name (the `name` in its SKILL.md), folder path, `applies` patterns (comma-separated, empty = all changed files) and mode (`mapped`, the default: every confirmed comment is deducted; `advisory`: report only);
  - execution style: subagents (`true`) or the main agent runs every step (`false`);
  - with `true` and a subagent tool: the subagent model and reasoning, offering only values the platform's subagent tool accepts.

  Save the answers with `setup plugin --name <name> --path <dir> [--applies "<patterns>"] [--mode mapped|advisory]` per plugin (if it is refused, tell the user the reason and ask again), `setup plugins --none` for no plugins, `review-state config --subagent true|false`, and `review-state config --platform <name> --model "<model>" --reasoning "<level>"`.

When plugins were added, run `scripts/link-skills` in the project root (the command is printed by `setup plugin` and by the wizard). If the skill tool does not offer a plugin linked during this conversation, the step 2 prompt falls back to reading its SKILL.md. Run `check` again and continue only after exit 0.

Create or change these files only through these commands, and never choose plugins, the execution style, models or reasoning levels for the user.

## Subagent settings

`review-state config --platform <name>` prints `model=…` and `reasoning=…`; use them for every subagent.

| Platform | Subagent tool | Model | Reasoning |
| --- | --- | --- | --- |
| Claude Code (`Claude`) | Agent tool | `model` parameter (alias such as `sonnet`, `opus`, `haiku`) | `effort` parameter (`low` … `max`) |
| GitHub Copilot in VS Code (`Copilot`) | `runSubagent` | `model` parameter (VS Code 1.117+); must not exceed the cost tier of the main chat model, or the subagent does not run | not settable per call; tell the user when saving the settings that the value is recorded but not applied |
| Other platforms | their subagent or task tool | if supported | if supported |

If the tool cannot apply a setting, tell the user once and continue with the platform default.

## State commands

Run `scripts/review-state.sh`, `.zsh` or `.ps1` (PowerShell: `powershell -ExecutionPolicy Bypass -File scripts/review-state.ps1`) from the root of the reviewed repository; all variants take the same arguments.

| Command | Purpose |
| --- | --- |
| `init --git <base>...<head> [--repo <dir>] [--title <text>] [--reset]` | create `tmp/`, `tmp/.gitignore`, `tmp/request.md` |
| `next [--inline] [--retry]` | the next action: a prompt to run, questions to relay, a failure, `finish`, or the result (runs `cr-plan` when step 2 has no plan) |
| `finish` | runs step 4 (score) and step 5 (report) with their scripts and prints the result summary |
| `show` | state of every step and plugin |
| `cr-plan` | step 2 planning: picks the plugins whose `applies` patterns match the changed files and cuts a `diff.patch` per plugin; rerunning it discards all step 2 results and clears steps 3 to 5 |
| `prompt --step 1\|2\|3 [--plugin <name>] [--inline]` | the prompt of one step, for debugging |
| `set --step N [--plugin <name>] --state <state> --message <text>` | records a state; used by whoever runs the step or plugin |
| `config [--subagent true\|false]` | read or save the execution style (`[workflow]` section) |
| `config --platform <name> [--model <m> --reasoning <r>]` | read or save the subagent settings of a platform |

## Layout

Review files never go to the reviewed repository: `--root` defaults to the `tmp/` folder in the project root of these skills (two levels above this skill's physical folder), and the final report is published to `reports/` next to it.

```text
tmp/
  request.md             PR, range and the documents the user provided (written by the main agent)
  inputs/                documents the user pasted into the conversation, saved as files (written by the main agent)
  stepN-<state>          status file: pending | working | success | failed (no file = not started)
  step2-<plugin>-<state> status file of one code review plugin
  step1/ … step5/        outputs of each step
    questions.md         questions for the user (written by the step)
    answers.md           the user's replies (written by the main agent)
    errors.log           failure details
  step2/plan.tsv         plugins chosen by cr-plan (name, path, mode, file count); step2/skipped.tsv: plugins with no matching file
  step2/<plugin>/        files.txt and diff.patch (what to review), raw/ (plugin output), cr.txt (normalized result)
  step3/findings.draft.txt  findings saved before a pending stop
  step5/report-path.txt  absolute path of the final report
reports/
  <YYYY-MM-DD>_<PR title>.md   final report (code review results + score results)
```
