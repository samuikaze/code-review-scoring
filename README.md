# Code Review Scoring

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

English | [繁體中文](docs/zh-tw/README.md)

A framework for PR code review and code quality scoring, implemented as Agent
Skills following the [Agent Skills](https://agentskills.io) specification. It
works with any tool that supports skills, such as Claude Code, GitHub Copilot
and Codex.

- **Scoring**: scores against the scoring standard documents registered in
  `configs/standards.ini`, not tied to any technology. Each framework
  standard (for example Spring Boot 3 or Angular) produces its own report;
  files that belong to no framework (README, CI configuration, Dockerfile and
  so on) are scored with the common standard. Standard documents are written
  in Markdown and kept in the separate
  [code-review-scoring-rules](https://github.com/samuikaze/code-review-scoring-rules)
  repository; see [Scoring standards](#scoring-standards).
- **CR**: CR guidelines for other technologies (for example the frontend) or
  of other teams plug into the workflow as plugin skills, with no technology
  restriction.
- **Report**: the CR results and the scoring results are combined into one
  report.

## Scoring workflow

The workflow runs five steps, "read the spec → CR → analyze the code → score
→ write the report", controlled by a main workflow skill. The CR of step 2 is
done by the plugin skills registered in `configs/plugins.ini`; step 3 confirms
the CR comments while analyzing the code and turns those that match a check
item of the scoring standard into deductions, so the score reflects both the
scoring rules and the CR results. The final report contains both the CR
results and the score:

| Skill | Role | Outputs (under `tmp/` in this project's root; final reports in this project's `reports/`) |
| --- | --- | --- |
| `code-review-scoring` | Main agent: picks the execution mode, dispatches the subagents in order, relays questions, gates with status files | `request.md`, `inputs/`, `answers.md` |
| `code-review-scoring-spec-reading` | Step 1: reads the spec and plans which scoring standards this PR uses | `step1/pr.diff`, `step1/spec-context.md`, `step1/standards/` |
| Plugin CR skills (`configs/plugins.ini`) | Step 2: CR; the changed files decide which plugins run | `step2/plan.tsv`, `step2/<plugin>/cr.txt` |
| `code-review-scoring-code-analysis` | Step 3: analyzes the code (confirms the CR comments and turns them into deductions), once per scoring standard | `step3/<standard>/prepared.txt`, `step3/<standard>/findings.txt` |
| `code-review-scoring-score` | Step 4: scores (in the full workflow, `review-state finish` runs the script directly) | `step4/<standard>/score.tsv`, `step4/<standard>/score.json` |
| `code-review-scoring-report` | Step 5: writes the report (CR results + score; in the full workflow, `review-state finish` runs the script directly) | Final report `reports/<date>_<PR title>_<standard>.md`, working copy `step5/<standard>/report.md` |

### One report per scoring standard

A PR may change both the backend and the frontend. Step 1 plans the scoring
from `configs/standards.ini` (`standard plan`):

- Every framework standard (for example `springboot-3` or `angular`) with at
  least one file matching its `applies` produces its own report; steps 3 to 5
  run separately per standard, with separate status.
- Files that belong to no framework standard (README, CI configuration,
  Dockerfile and so on) are scored with the common standard and go into the
  report of the same project: starting from the file's directory and walking
  up, the nearest directory containing files of a framework standard decides
  the report. When this cannot be decided (for example the README at the
  root), the file is listed in every report.
- When the PR has no files of any framework standard, only one report is
  produced with the common standard, so every PR gets at least one report.
- Each report lists only the CR comments on its own files; comment numbers
  keep the plugin's original numbering for easy cross-reference.
- The confirmations (事先確認事項) of each standard are listed among the
  severity facts in `spec-context.md` and asked in step 1 together with the
  missing documents.
- Step 1 saves a snapshot of each parsed standard
  (`step1/standards/<standard>.resolve`) and records the standard names,
  versions and sha256 in `request.md`. Steps 3 to 5 then score with that
  snapshot; if a standard document, a scan rule file or the settings in
  `standards.ini` change during the run, the status script refuses to
  continue. Revert the change, or start over with `init --reset`.

### Execution modes

Before starting, the main agent asks the user:

- **Full workflow**: runs the five steps in order; a step can start only
  after the previous one succeeded, and no step can be skipped. Whether
  subagents are dispatched is decided by `subagent` in `[workflow]` of
  `configs/settings.ini`: with `true`, the main agent dispatches one subagent
  for each of steps 1 to 3 and for each CR plugin; with `false`, the main
  agent runs every step itself with the same prompts, status files and
  directories. On platforms without subagents, the main agent runs the steps
  itself even when this is `true`. Steps 4 and 5 only run scripts, so the main
  agent always completes them with `review-state finish` and never dispatches
  subagents for them.
- **Single step**: runs one step skill directly in the chat, without status
  files.

The main agent only needs to run `review-state next`; the script prints the
next action: the prompt of the step to run, a question to relay, a failure
reason, `finish`, or the final summary. When done, the main agent replies with
only the grade, the total score, the score per dimension and the report path,
and does not paste the report into the chat; read the files in `reports/` for
the full content.

Everything to hand over is written to `tmp/`: documents you paste in the chat
are saved as files in `tmp/inputs/`, and every step saves its work before
asking a question (for example `findings.draft.txt` of step 3), so after your
reply it only applies the answer instead of redoing the whole step. If a
scoring run is interrupted, say "繼續評分" (continue scoring) in a new chat to
resume from `tmp/`.

### Setup check (before every full workflow run)

After you choose the full workflow, the first thing the main agent does is run
`setup check`, which checks the two configuration files in the project root.
A single step does not use them, so they are not checked then.

| Configuration | When needed | When missing |
| --- | --- | --- |
| `configs/plugins.ini` | Every full workflow run | Which CR plugins to register; when you use no plugin, create a file without plugins to show that this was decided |
| `[workflow]` in `configs/settings.ini` | Every full workflow run | `subagent=true` (one subagent per step) or `subagent=false` (the main agent runs the steps) |
| The platform's section in `configs/settings.ini` | Only with `subagent=true` on a platform with subagents | The model and reasoning of the subagents |

When something is missing, the main agent tells you what and asks how to
create it:

- **Step-by-step script**: run the `wizard` command printed by `check`
  yourself in a terminal. The script asks for each plugin's name, path, scope
  and mode, whether to use subagents, and the model and reasoning, and it
  validates each plugin as it is registered (SKILL.md exists, names match).
  The AI cannot run it for you because it needs an interactive terminal; in
  Claude Code you can type `! <command>` to run it right in the chat.
- **Asked by the AI**: the main agent asks for everything in one message,
  then writes the configuration with `setup plugin`, `setup plugins --none`,
  `review-state config --subagent` and `review-state config --platform`. When
  a plugin fails validation, it tells you why and asks again.

The configuration files moved from the project root to `configs/`:
`configs.ini` was renamed to `configs/settings.ini`, and `plugins.ini` moved to
`configs/plugins.ini`. If the old `configs.ini` or `plugins.ini` is still in
the project root, `check` and `link-skills` stop and print the commands to
move them; move them yourself and run again. Relative paths in `plugins.ini`
need a `../` prefix.

When `check` passes, it prints an `execution:` line telling whether this run
uses subagents or the main agent runs the steps. After plugins are
registered, the main agent runs `link-skills` to link the plugin skills, then
runs `check` again and continues only when it passes. `review-state init` also
refuses to run when `configs/plugins.ini` does not exist, so the CR is never
silently skipped because the list was forgotten.

You can also run these directly in the project without the AI:

```bash
bash skills/code-review-scoring/scripts/setup.sh check --platform Claude
bash skills/code-review-scoring/scripts/setup.sh wizard --platform Claude
```

```powershell
powershell -ExecutionPolicy Bypass -File skills\code-review-scoring\scripts\setup.ps1 wizard --platform Claude
```

### Status control

Temporary files and reports are always written to `tmp/` and `reports/` in
this project's root, never into the project under review. The scripts find
this project's root two levels above the skill's real directory (also when
run through the links created by `link-skills`); `--root` selects another
directory, and the reports are then published to `reports/` next to it. git
commands still run in the project under review: the main agent runs `init` in
the root of the reviewed project, or passes it with `--repo`.

```text
tmp/
  .gitkeep             keeps the directory
  .gitignore           generated only when git does not ignore tmp/ yet (* and !.gitkeep)
  request.md           the PR, the diff range and the documents the user provided, recorded by the main agent
  inputs/              documents the user pasted in the chat, saved by the main agent (also cleared by --reset)
  stepN-working        a subagent started the step
  stepN-pending        the subagent needs the user's reply; the questions are in stepN/questions.md
  stepN-success        the step is done
  stepN-failed         the step failed; the reason is in the status file
  step2-<plugin>-<state>    status of each CR plugin in step 2
  stepN-<standard>-<state>  status of each scoring standard in steps 3 to 5
  step1/ … step5/      outputs of each step; questions.md (questions of the step), answers.md (the user's replies), errors.log (failures)
  step1/standards/     the scoring plan: plan.tsv (which files go to which report), <standard>.diff (the report's diff), <standard>.resolve (snapshot of the standard), confirm.tsv (confirmations)
  step2/<plugin>/      files.txt and diff.patch (the scope to review), raw/ (the plugin's own output), cr.txt (the normalized CR result)
  step3/<standard>/ … step5/<standard>/  outputs of steps 3 to 5 per scoring standard
  step3/<standard>/findings.draft.txt    draft deductions saved by step 3 before asking; work resumes from here after the reply
reports/
  <date>_<PR title>_<standard>.md   final report (CR results + score), one per scoring standard; must be published here before step 5 succeeds
```

- Subagents create the status files through the `review-state` script; a
  missing file means the step has not started.
- The script enforces the gates: a step cannot start unless the previous one
  is `success`; a step cannot be marked `success` when a required output is
  missing or stale; rerunning a step clears the status of the later steps.
  When step 3 is marked `success`, `findings.txt` is validated with
  `score --check`, so a format or location error is rejected right away
  instead of failing in step 4 and redoing all of step 3.
- Subagents cannot talk to the user directly. To ask, a subagent first saves
  its work, writes `stepN/questions.md` and marks the step `pending`; the main
  agent asks the user, writes the reply to `stepN/answers.md` and runs the
  same step again, which resumes from the saved work.
- The confirmations of the scoring standards (for example whether time zones
  are involved, or whether a table keeps growing) are asked in step 1 together
  with the missing documents, so step 3 rarely has to stop and ask.
- When a step fails, the details go to `errors.log` in the step's directory
  (for example `tmp/step4/springboot-3/errors.log`), and the status script
  appends a one-line summary when it marks the step `failed`.
- When a scoring standard changes after step 1 planned the scoring, status
  changes of steps 3 to 5 and `finish` are refused (exit code 5), so one
  report never mixes old and new rules.
- Supported subagent tools: the Agent tool of Claude Code, `runSubagent` of
  GitHub Copilot (VS Code agent mode), or the equivalent on other platforms.

### Execution mode and subagent settings

The settings are stored in `configs/settings.ini` in the project root (in the
same directory as the plugin list `configs/plugins.ini`). The setup check asks
you to create it the first time it is needed (see
[Setup check](#setup-check-before-every-full-workflow-run)), and it is reused
afterwards:

- `subagent` in `[workflow]`: `true` dispatches one subagent per step, `false`
  has the main agent run the steps. With `false`, no platform section is
  needed.
- One section per platform (`workflow` and `language` are reserved and
  cannot be platform names): the model and reasoning of the subagents,
  created the first time a platform runs with subagents.
- `report` in `[language]` (optional): the report language; see
  [Report language](#report-language).

```ini
[workflow]
subagent="true"

[Claude]
model="sonnet 5.5"
reasoning="high"

[Codex]
model="gpt-5.6"
reasoning="xhigh"
```

To change them, edit this file directly, or run
`review-state config --subagent true|false` and
`review-state config --platform <name> --model "<model>" --reasoning "<level>"`.
Before the first use, you can also copy the template
`configs/settings.example.ini` to `configs/settings.ini`, then uncomment and
edit the sections you need.

> [!WARNING]
> **Known limitations of GitHub Copilot**
>
> - The reasoning of `[Copilot]` is not applied to subagents yet:
>   `runSubagent` cannot set reasoning per call, and the local harness of
>   VS Code ignores `reasoning-effort` in custom agent files.
> - The subagent model cannot be in a higher cost tier than the model of the
>   main chat, or the subagent does not run.
> - Copilot CLI may not be able to set the subagent model and reasoning; the
>   cloud Copilot coding agent cannot relay pending questions in real time,
>   so it is not suited to the full workflow.
> - The full workflow has not been verified on Copilot yet, and it is not
>   confirmed whether Copilot reads skills linked through a symlink or
>   junction.
>
> See [docs/en/notices.md](docs/en/notices.md) for details and workarounds.

## Directory structure

```text
skills/
  code-review-scoring/
    SKILL.md
    assets/request-template.md
    assets/prompts/step1.md … step3.md   # prompt templates of steps 1 to 3 (step2.md is for CR plugins)
    assets/prompts/protocol.md            # status protocol shared by all steps (lines starting with [sub] / [inline] apply to that mode only)
    references/setup.md                   # setup check, platform settings, status commands and directories (loaded when needed)
    scripts/review-state.{sh,zsh,ps1}     # init / next / finish / show / cr-plan / prompt / set / config (--help lists the usage)
    scripts/setup.{sh,zsh,ps1}            # setup check and creation of configs/plugins.ini, configs/settings.ini (check / wizard / plugins / plugin)
    scripts/standard.{sh,zsh,ps1}         # lint / parse / diff / resolve / plan / stamp of scoring standards (lint and stamp only when maintaining standards; plan plans the scoring in step 1)
    scripts/lib/standard.{awk,ps1}        # parser of scoring standards (awk shared by bash and zsh; the PowerShell version has the same rules and messages)
  code-review-scoring-spec-reading/
    SKILL.md
    assets/spec-context-template.md
    scripts/init-workspace.{sh,zsh,ps1}   # saves the diff and creates spec-context.md
    scripts/check-context.{sh,zsh,ps1}    # checks that the inputs, open questions and confirmations of the standards are all handled
  code-review-scoring-code-analysis/
    SKILL.md
    references/upstream.md                # judging upstream factors (loaded only when an upstream factor is suspected)
    references/findings-format.md         # format of findings.txt
    scripts/prepare-diff.{sh,zsh,ps1}     # scan rules come from the scan rule files (scan) registered in configs/standards.ini
  code-review-scoring-score/
    SKILL.md
    scripts/score.{sh,zsh,ps1}            # check items and severities come from the standards registered in configs/standards.ini
  code-review-scoring-report/
    SKILL.md
    references/placeholders.md            # placeholders of the report template and keys of labels.tsv
  code-review-scoring-standard/           # for maintaining scoring standards (not part of the scoring workflow)
    SKILL.md                              # check, generate and review modes
    references/scan-format.md             # scan rule file format and regex restrictions
    references/review-checklist.md        # checklist for reviewing scan rules and the review.md format
    assets/generator-prompt.md            # prompt of the subagent that generates scan rules
scripts/
  link-skills.{sh,zsh,ps1}                # syncs the skill directories each tool reads from skills/ and configs/plugins.ini
configs/                                  # configuration (only *.example.ini is under version control)
  settings.example.ini                    # template for execution mode, subagent model and reasoning, report language and points (settings.ini is generated on first use)
  plugins.example.ini                     # template for the plugin skill list (copy to plugins.ini)
  standards.example.ini                   # template for the scoring standard list (copy to standards.ini)
docs/
  en/notices.md                           # notices (scoring standards, GitHub Copilot compatibility)
  zh-tw/README.md                         # Traditional Chinese version of this README
  zh-tw/notices.md                        # Traditional Chinese version of the notices
templates/                                # one folder per language; see "Report language"
  en/                                     # English
    scoring-rule-template.md              # template for scoring standard documents
    report-template.md                    # report template (customizable)
    labels.tsv                            # text the script inserts into the report, and the language the agents write in
  zh-tw/                                  # Traditional Chinese (same files)
tests/
  standards/                              # test cases of standard lint; compare.sh compares the output of the three shells with expected.txt
  score/                                  # test cases of score (the check items of legacy.md equal the old rules.tsv, so scores stay the same)
  prepare/                                # test cases of prepare-diff (legacy.tsv holds the rules of the old scan-rules.tsv, plus scan rules of the common standard)
  plan/                                   # test cases of standard plan (two framework standards and the common standard, common files at several levels)
  workflow/                               # end-to-end test of the full workflow (temporary git repository, two reports, routing of CR comments, refusal when a standard changes)
tmp/                                      # temporary files of a scoring run (default review root of all scripts, not under version control)
reports/                                  # final score reports (reports/ next to tmp/, not under version control)
.gitattributes                            # fixes the line endings of scripts and configuration files
.gitignore
```

### Excluded from version control

`.gitignore` excludes the following (`tmp/` and `reports/` keep only
`.gitkeep`):

- `tmp/*`, `reports/*`: scoring runs and reports, which contain PR content.
- `.agents/`, `.github/skills/`, `.claude/skills/`: the links created by
  `link-skills` and their `.managed` lists; each environment runs the script
  to create them.
- `configs/settings.ini`, `configs/plugins.ini`: each user's execution mode,
  subagent settings and plugin list (plugin paths differ per environment).
  `.gitignore` excludes them with `/configs/*.ini`, and only the
  `configs/*.example.ini` templates are under version control. If your team
  wants to share one configuration, add an exception to `.gitignore`, for
  example `!/configs/plugins.ini`.
- `.DS_Store`, `Thumbs.db`, `desktop.ini`: files created by the operating
  system.

### Line endings

`.gitattributes` fixes LF line endings for `.sh`, `.zsh`, `.awk`, `.tsv`,
`.ini` and `.md`. Without it, with `core.autocrlf=true` on Windows, checked-out
files become CRLF, the bash and zsh scripts fail on WSL, macOS and Linux, and
awk misreads the rule tables. `.ps1` files are left to git's per-platform
handling.

If your working copy was checked out before `.gitattributes` was added, run
the following once so git renormalizes the line endings:

```bash
git add --renormalize .
```

The `scripts/lib/` of each skill holds the awk core (shared by bash and zsh)
and the shared PowerShell functions. So that every skill can be installed on
its own, each skill has an identical copy of `lib/common.ps1`; update all
copies when you change it.

## Scoring standards

A scoring standard is a Markdown document; the AI and the scripts of the
scoring workflow read the same document:

- Write it from `templates/en/scoring-rule-template.md` (English) or
  `templates/zh-tw/scoring-rule-template.md` (Traditional Chinese). The
  sections Dimensions, Check items and Confirmations (面向, 檢查項 and
  事先確認事項 in Chinese) are parsed by the scripts and have a fixed format;
  Special rules and Judging hints (特例規則 and 判斷提示) are only for the AI
  and can be written freely. The scripts accept the headings, the dimension
  names and 「無」 / `None` in either language, so a standard can be written
  in either one regardless of the report language.
- In the project root, copy `configs/standards.example.ini` to
  `configs/standards.ini`, with one section per standard: the path of the
  standard document (`path`), the files it applies to (`applies`, required
  for framework standards), the scan rule file (`scan`, optional) and point
  overrides (`points.A` to `points.G`, optional). The common standard sets
  `role="common"` and its check codes start with `CM-`. See the comments in
  the template for every field.
- The standard documents and scan rule files are not kept in this project
  but in an external repository such as
  [code-review-scoring-rules](https://github.com/samuikaze/code-review-scoring-rules).
  Paths differ per environment, so `standards.ini` is not under version
  control; set it up yourself on each machine or for each person.
- After writing or changing a standard, run `standard lint` to check the
  format, overlapping `applies`, the point totals and the scan rules:

  ```bash
  bash skills/code-review-scoring/scripts/standard.sh lint
  ```

  ```powershell
  powershell -ExecutionPolicy Bypass -File skills\code-review-scoring\scripts\standard.ps1 lint
  ```

- The scoring workflow does not run lint. When a standard has a format
  error, the scoring scripts stop and tell you to run lint first.
- A scan rule file (TSV) lists candidate clues that regular expressions can
  find; they are only hints and never deduct by themselves. For the format
  and the `@scope` and `@pr` records, see the template and the examples in
  `tests/prepare/`.
- Do not change a standard during a scoring run: step 1 records the
  standards as they are, and the workflow refuses to continue when they change
  later (see [One report per scoring standard](#one-report-per-scoring-standard)).

### Using the existing scoring standards

[code-review-scoring-rules](https://github.com/samuikaze/code-review-scoring-rules)
currently provides the following standards, each with a standard document
(`.md`) and a scan rule file (`.tsv`):

| Code | Type | Applies to | Directory |
| --- | --- | --- | --- |
| `springboot-3` | Framework standard | Java / Spring Boot 3 projects | `springboot3-rule/` |
| `common` | Common standard | Other files, e.g. README, CI, Dockerfile | `common-rule/` |

1. Clone the standards repository anywhere on your machine:

   ```bash
   git clone https://github.com/samuikaze/code-review-scoring-rules.git
   ```

2. In this project's root, copy `configs/standards.example.ini` to
   `configs/standards.ini`, and point `path` and `scan` to the cloned files.
   Relative paths are relative to `configs/`; on Windows, use forward
   slashes:

   ```ini
   [springboot-3]
   path="/path/to/code-review-scoring-rules/springboot3-rule/springboot-3-cr-scoring-rule.md"
   scan="/path/to/code-review-scoring-rules/springboot3-rule/springboot-3-cr-scoring-rule.tsv"
   applies="*.java, *.kt, *.sql, *.xml, *.yml, *.yaml, *.properties, *.gradle, *.kts"

   [common]
   path="/path/to/code-review-scoring-rules/common-rule/common-cr-scoring-rule.md"
   scan="/path/to/code-review-scoring-rules/common-rule/common-cr-scoring-rule.tsv"
   role="common"
   ```

3. Run `standard lint` to check the configuration and the standards.

When the standards are updated, run `git pull` in the standards repository;
this project needs no change. Do not update during a scoring run, for the
reason above. To add or change a standard, see the README of the standards
repository.

### Maintaining scoring standards

The `code-review-scoring-standard` skill triggers only when you ask to
maintain a standard (for example 「檢查評分標準」 "check the scoring
standards", 「產生掃描規則」 "generate scan rules" or 「審核掃描規則」 "review
scan rules"); the scoring workflow never loads it:

- **Check mode**: runs lint on the standard documents and scan rule files and
  explains how to fix each error and warning, without changing any file.
- **Generate mode**: generates or updates the scan rule file from the
  standard document, so nobody writes regexes by hand.
  1. The standard document passes lint first.
  2. One subagent generates the draft `tmp/scan-rules/<standard>/draft.tsv`
     and lists in `notes.md` the check items that got no rule, with the
     reason.
  3. The script lints the draft (format, referenced codes and scopes, and
     that every regex compiles in both awk and .NET).
  4. The main agent reviews the draft against the standard document with a
     fixed checklist and writes the result to `review.md`; problems go back to
     the subagent, for at most 3 rounds.
  5. When it passes, the changes against the existing file are shown for your
     confirmation; only after you confirm, `standard stamp` writes it to the
     location set by `scan` in `standards.ini`, with the version and hash of
     the source standard document in the header.
- **Review mode**: runs lint and the review on an existing scan rule file
  only, writes the result to `review.md`, and changes no file.

On platforms without subagents (or with `subagent=false`), the main agent
does the generation and the review in turn, with the same steps and files but
less independence. You always change the standard documents and
`standards.ini` yourself; the AI only reports problems.

## Adjusting points

The maximum points per dimension, the deduction per severity and the grade
thresholds are set in the `[points]`, `[deductions]` and `[grades]` sections
of `configs/settings.ini` in the project root; unset items use the defaults:

| Dimension | Default max | | Severity | Default deduction | | Grade | Default minimum total |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A Correctness | 25 | | Critical | 10 | | S | 95 |
| B Security | 15 | | Major | 5 | | A | 85 |
| C Test quality | 15 | | Minor | 2 | | B | 70 |
| D Architecture and design | 15 | | Nit | 1 | | C | 55 |
| E Performance and resources | 10 | | | | | D | below C |
| F Readability | 10 | | | | | | |
| G Maintainability | 10 | | | | | | |

```ini
[points]
A="30"
B="20"
C="10"
D="10"
E="10"
F="10"
G="10"

[deductions]
Major="6"
merge="true"
```

- The seven dimensions must total 100, the grade thresholds must satisfy
  S > A > B > C, and all values are integers; otherwise the scoring step fails
  and lists the errors.
- A scoring standard can override the maximum points of dimensions with
  `points.A` to `points.G` in `configs/standards.ini`. Overrides take
  precedence over `[points]`, and the result must also total 100
  (`standard lint` checks this).
- Every problem deducts points, including Nit. Problems that match no A to G
  check item (check code `-`) and upstream factors are deducted from the
  total by severity, not from any dimension; the total is at least 0.
- With any Critical deduction, the grade is capped at B.
- Whether deductions are merged is decided by `merge` in `[deductions]`:
  - `merge="false"` (default): not merged; every occurrence is its own
    deduction, so a check code at three locations deducts three times.
  - `merge="true"`: merged; a check code is written once with all its
    locations and deducts once.
  - Step 3 learns the current mode from the `- deductions:` line of the
    `prepared.txt` summary; each dimension's score is at least 0.
- Changes take effect when you rerun scoring (step 4) and the report (step 5)
  (`review-state finish` in the full workflow); see
  `configs/settings.example.ini` for an example. The first
  `configs/settings.ini` is copied from the template, with the point sections
  commented out.

## Adjusting the report

- Layout and text: edit `templates/<language>/report-template.md`; you can
  freely change the order and headings of the CR part and the scoring part.
- Wording inserted by the script (dimension names, column names, upstream
  factor categories, CR table headers, "None" and so on): edit
  `templates/<language>/labels.tsv`.
- For the available placeholders and label keys, see
  `skills/code-review-scoring-report/references/placeholders.md`.

### Report language

The report templates live in `templates/` in the project root, one folder per
language: `templates/en/` and `templates/zh-tw/`.

- When `templates/` holds the report template of only one language (in a
  language folder, or `report-template.md` and `labels.tsv` right in
  `templates/`), that template is always used and the setting below is
  ignored.
- With several languages, `report` in the `[language]` section of
  `configs/settings.ini` picks the folder (default `zh-tw`):

  ```ini
  [language]
  report="en"
  ```

  A language without a folder stops the report step and lists the available
  languages.
- The `language` line of the folder's `labels.tsv` (for example `English`)
  tells the agents of steps 2 and 3 which language to write the CR comments
  and findings in, so the whole report is in one language.
- To add a language, copy a language folder to a new name (for example
  `templates/ja/`), translate `report-template.md` and `labels.tsv`, and set
  `report` to the folder name. `scoring-rule-template.md` is only a starting
  point for writing standards and is not needed for the report.

## Installing into each tool

You do not need to create `configs/plugins.ini` in advance: the first full
workflow run guides you through it in the setup check (see
[Setup check](#setup-check-before-every-full-workflow-run)). You can also run
`setup wizard` first, or copy the template `configs/plugins.example.ini` and
edit it.

`link-skills` syncs the skill directories each tool reads from `skills/` and
`configs/plugins.ini`: it creates missing links and removes the links of
plugins removed from the list. It is safe to run repeatedly; when everything
is up to date, it changes nothing.

```bash
# macOS / Linux (creates symlinks)
bash scripts/link-skills.sh                # default: .agents/skills and .github/skills
zsh  scripts/link-skills.zsh -t all        # also .claude/skills
bash scripts/link-skills.sh --check        # only check and list the changes it would make
```

```powershell
# Windows (creates junctions, no administrator rights needed)
powershell -ExecutionPolicy Bypass -File scripts\link-skills.ps1
powershell -ExecutionPolicy Bypass -File scripts\link-skills.ps1 -Target all
powershell -ExecutionPolicy Bypass -File scripts\link-skills.ps1 -Check
```

| Target | Directory | Used by |
| --- | --- | --- |
| `agents` | `.agents/skills` | Codex, Gemini CLI and other tools using the common location |
| `github` | `.github/skills` | GitHub Copilot |
| `claude` | `.claude/skills` | Claude Code |

Other options: `--config <file>` (`-Config` in PowerShell) uses another
plugin list; `--remove` (`-Remove`) removes every link this script created,
without deleting the skills themselves.

**Sync before you open a chat in the AI tool.** Most platforms scan skills
when a chat starts, so links created in the middle of a chat may not be seen
in that session. Run it by hand, or hook it into git (for example
`post-checkout` or `post-merge`) or a VS Code task that runs when the folder
opens.

Note: the link directories are listed in `.gitignore` and are not under
version control. For cloud environments such as the GitHub Copilot coding
agent to see the skills, run the link script in the cloud environment, or
remove `.github/skills/` from `.gitignore` and commit symlinks created on
macOS / Linux (Windows junctions cannot be tracked by git).

## Plugin skills

Skills that other teams or colleagues already built (for example CR skills
for the frontend or the backend) need no copying or rewriting: register their
paths in `configs/plugins.ini` in the project root (copied from
`configs/plugins.example.ini`) and run `link-skills` to plug them in:

```ini
[backend-code-review]
path="../../shared-skills/backend-code-review"
applies="*.java,*.kt,*.sql"
mode="mapped"

[frontend-code-review]
path="../../shared-skills/frontend-code-review"
applies="*.ts,*.tsx,*.vue,*.scss"
mode="advisory"
```

| Setting | Required | Description |
| --- | --- | --- |
| Section name | Yes | Must equal `name` in the skill's SKILL.md |
| `path` | Yes | Path of the skill folder; relative paths are relative to the directory of `configs/plugins.ini` (`configs/`) |
| `applies` | No | The files it applies to (comma-separated wildcards); empty means all changed files |
| `mode` | No | `mapped` (default): step 3 confirms the CR comments; every confirmed comment deducts points, and a rejected one needs a reason. `advisory`: the CR comments only appear in the report and do not affect the score |

With a CR plugin in `mapped` mode, comments that match no check item of the
scoring standard go to "other" and are deducted from the total by the
plugin's severity. When no scoring standard covers the technology a plugin
reviews, or you do not want the plugin to affect the score, use `advisory`.
Each report lists only the comments on its standard's files.

### Sync rules

- Only links this script created are changed; they are listed in the
  `.managed` file of each directory. Links and real directories created by
  other people or tools are never touched.
- Plugins removed from `configs/plugins.ini` are unlinked at the next sync.
- Links created by older versions of the script that point to the same
  location are taken over automatically.
- Before syncing, the following are checked; if any fails, nothing is changed
  and the reasons are listed:
  - SKILL.md exists;
  - the folder name and the plugin section name equal `name` in SKILL.md;
  - the name does not clash with another skill;
  - `disable-model-invocation: true` is not set (with it, subagents cannot
    load the skill through the skill tool);
  - the target location has no link or directory of the same name that this
    script did not create.

### Loading and caveats

- The main agent names the skill for every step of the workflow instead of
  letting the agent pick one, so there is no need to restrict which skills an
  agent can read.
- A subagent first loads the skill by name with the platform's skill tool; if
  the platform's subagents have no skill tool, or the skill is not found, it
  reads `SKILL.md` directly and follows it. Subagents of Claude Code can load
  skills through the skill tool; the GitHub Copilot documentation does not
  say, so this fallback stays.
- Write specific descriptions for plugin skills (for example "CR guidelines
  for the Vue / TypeScript frontend"). With a vague description, saying
  "review this PR" in the main chat may trigger the plugin instead of the main
  workflow skill.
- Plugin skills need no changes for this framework. The prompt the workflow
  gives them limits the review scope, the output location and the status
  protocol, and asks them to normalize the result into a common `cr.txt`.

### How plugins run in the workflow (step 2)

1. After step 1 succeeds, `review-state cr-plan` matches the files the PR
   actually changed (excluding build output, generated files and lock files)
   against each plugin's `applies` to decide which plugins run. The files each
   plugin reviews are written to `tmp/step2/<plugin>/files.txt`, with a
   `diff.patch` containing only those files. When no plugin applies, step 2
   counts as done right away.
2. Each applicable plugin runs in its own subagent, one after another (on
   platforms without subagents, the main agent runs it), following the same
   status protocol with the status files `tmp/step2-<plugin>-<state>`.
   `review-state next` runs `cr-plan` automatically when step 2 is not planned
   yet.
3. A plugin reads only its own `diff.patch` and reviews it by its own
   guidelines; its own output goes to `tmp/step2/<plugin>/raw/`, normalized
   into `cr.txt`:

   ```text
   S|整體結論
   C|Major|src/web/order/OrderForm.vue:42|FE-STATE-03
   problem: 表單送出後沒有處理 API 錯誤。
   suggestion: 在 catch 中顯示錯誤訊息。
   spec: docs/spec/order-sd.md:42,docs/spec/order-sd.md:57
   H|做得好的地方
   ```

   Severities map by meaning to Critical, Major, Minor and Nit; the plugin's
   own rule id goes in the 4th field; `spec:` (optional) lists every spec
   location the comment is based on. When the step is marked successful, the
   status script validates the format of `cr.txt`.
4. Step 3 can start only after every plugin succeeded.

### How CR results affect the score (step 3)

- `prepare-diff` lists in `prepared.txt` the id `<plugin>#<n>` of every
  comment (the n-th comment in that plugin's `cr.txt`).
- Every comment of a `mapped` plugin is checked against the code during the
  analysis, with one of two outcomes:
  - **Confirmed**: always deducts points, with `source: <comment id>` naming
    the comment. A comment matching an A to G check item deducts under that
    item with the scoring rules' default severity and adjustment conditions;
    one matching no check item uses check code `-` and is deducted from the
    total by the plugin's severity; one whose root cause seems to be upstream
    is recorded as an upstream factor and deducted.
  - **Rejected** (the plugin was wrong, it is outside this change, or it
    cannot be confirmed in the code): written as `X|<comment id>|reason`, and
    the reason appears in the report.
- Scoring checks that every `mapped` comment is either deducted or rejected
  with a reason; a missing one fails the check.
- Comments of `advisory` plugins are for reference only and never become
  deductions.

### Why CR comes before the code analysis

- **More accurate scores**: the score considers both the scoring rules and
  the CR guidelines, so problems found by the CR are reflected in the score.
- **Fewer tokens**: each plugin reads only the `diff.patch` of its own scope,
  not the whole PR; the analysis only confirms the problems the CR already
  found as clues instead of searching from scratch.

### Report contents

The final report has two parts:

- **Part 1, CR results**: an overview per plugin (files reviewed, comments
  per severity, conclusion), the comments of each plugin (sorted by severity)
  and highlights, and the plugins that did not run because no changed file
  matched. Each comment's header is "severity | rule | verdict", and all code
  locations and spec locations are listed one per line:

  ```text
  1. [Critical | EXT-CODE | A8]
     - 問題：取消訂單流程與規格不符。
     - 建議：依規格補上狀態檢查。
     - 程式碼位置：
       - `src/main/java/com/ex/order/OrderService.java:14`
       - `src/main/java/com/ex/order/OrderService.java:25`
     - 規格書位置：
       - `docs/spec/order-sd.md:42`
       - `docs/spec/order-sd.md:57`
  ```

  The verdict follows the `source:` of the deductions and upstream factors:
  - A deducted comment shows its check code, for example `A8`; one matching
    no check item shows 「其他」 (other), and one recorded as an upstream
    factor shows 「上游因素」 (upstream factor).
  - A rejected comment shows 「不成立」 (rejected), with an extra line
    「不成立原因」 (reason for rejection).
  - Comments of `advisory` plugins show 「僅供參考」 (for reference only).
- **Part 2, scoring results**: the score per dimension, the problem details,
  suggestions, upstream factors, highlights, scoring notes and the structured
  result.
  - After the seven dimensions, the score table has two more rows for the
    deductions of 「其他（未對應檢查項）」 (other, no matching check item) and
    「上游因素」 (upstream factors).
  - The problem details include Nit; deductions confirmed from CR comments
    show the comment id they came from.
  - 「建議（不扣分）」 (suggestions, no deduction) holds only the extra
    suggestions made in step 3.

The top of the report shows both the grade and the total number of CR
comments. Layout and wording can be adjusted in
`templates/<language>/report-template.md` and `templates/<language>/labels.tsv`
(see [Adjusting the report](#adjusting-the-report)).

## Why the scripts exist

- `link-skills`: syncs each tool's skill links from `skills/` and
  `configs/plugins.ini`, checking names and settings before any change.
- `setup`: before every full workflow run, checks `configs/plugins.ini` and
  `configs/settings.ini` and creates them step by step or by command,
  validating plugins as they are registered, so configuration errors are not
  discovered only in the CR step.
- `review-state`: manages the step status files, plans which CR plugins run,
  generates each step's prompt and enforces the order. `next` combines
  checking the status, planning the plugins and generating the prompt into
  one call, and `finish` runs the scripts of steps 4 and 5 directly, which
  cuts the main agent's round trips and tokens.
- `init-workspace` / `check-context`: fix where the handover files live, and
  block the later steps until all inputs and open questions are handled.
- `prepare-diff`: excludes generated files and lock files, numbers the lines
  of new files, and lists heuristic candidates with the scan rule files of the
  scoring standards, saving the tokens the AI would spend counting lines and
  scanning again. Files not covered by the `applies` of a framework standard
  are marked `[common]` and scanned with the common standard's rules; file
  categories (`@scope`) and PR-level hints (`@pr`, for example main code
  changed without any test file) are also defined in the scan rule files, so
  the script contains no framework-specific logic.
- `standard`: checks the format when writing a scoring standard (`lint`),
  parses the standard document into data the scripts can read (`parse`),
  lists the differences between two versions (`diff`), selects the standard
  to score with and the common standard and outputs the check items, point
  overrides, applicable files and scan rule files for `score` and
  `prepare-diff` (`resolve`), decides in step 1 which reports to produce from
  the changed files and cuts the diff of each report (`plan`), and writes a
  reviewed scan rule draft with its source header to its final location
  (`stamp`). The standard document is shared by the AI and the scripts, and a
  format error would make the scoring read the wrong rules, so the script
  checks strictly: field counts, severity spelling, duplicate codes, that all
  dimensions exist, the point totals and overlapping `applies` in
  `standards.ini`, and whether the regexes of the scan rules use only syntax
  shared by awk and .NET, whether the codes they reference still exist, and
  whether they are stale after the standard document changed. `lint` runs
  only when writing or maintaining standards; the scoring workflow calls
  `resolve` only through `plan` and the checks of `review-state`, which print
  no format messages when the format is correct and so cost no tokens. On a
  format error they stop (exit code 2 or 3); run `lint` to fix it first.
- `score`: validates the scoring result (check codes, severity adjustment
  conditions, whether locations are on added lines of the diff, and merged or
  per-occurrence deductions according to `merge`), and computes the scores
  and grade with the points of `configs/settings.ini` (the `points.*` of a
  standard in `configs/standards.ini` take precedence). Check codes and
  allowed severities come from the scoring standard document, which avoids
  calculation mistakes by the AI. `--check` only validates without writing
  files, for step 3 to check itself before finishing.
- `render-report`: combines the CR results and the score into one report from
  the template and publishes it to `reports/`; numbers and comments are taken
  directly from the files of the earlier steps, never retyped by the AI.

The prompts, messages and comments of the scripts are always in English, to
avoid garbled text under different console encodings. The wording the script
inserts into reports (including separators such as full-width brackets and
colons) is all in `templates/<language>/labels.tsv`.

The PowerShell scripts are saved as UTF-8 with BOM and switch the console and
git output to UTF-8 at run time, so Windows PowerShell 5.1 handles Chinese
correctly too. Keep the BOM when you edit a `.ps1` file.

When the bash scripts run in Git Bash on Windows, paths in the output and in
subagent prompts use the `C:/...` form instead of `/c/...` or `/tmp/...`, so
subagents find the same file whether they use PowerShell or bash.

The three script variants produce the same output for the same input (the
full five-step workflow was verified on Windows with PowerShell 5.1 and Git
Bash). The zsh version is converted from the bash version; update the zsh
version whenever you change the bash version.
