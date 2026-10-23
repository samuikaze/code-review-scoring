# Notices

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

English | [繁體中文](../zh-tw/notices.md)

- [Scoring standards](#scoring-standards)
- [GitHub Copilot compatibility](#github-copilot-compatibility)

## Scoring standards

- **The location of the rules project differs per person**:
  `configs/settings.ini` is not under version control, and the rules project
  (`rules.ini`, `defaults.ini` and the rule folders) lives outside this
  project. On a new machine or for a new person, set `root` in the `[rules]`
  section of `configs/settings.ini` (see [configurations.md](configurations.md#the-rules-section)); on
  Windows, use forward slashes in paths.
- **The old scoring settings are no longer read**: `configs/standards.ini`
  and the `[points]`, `[deductions]` and `[grades]` sections of
  `configs/settings.ini` were replaced by the rules project in 3.0.0. The setup
  check reports them as `legacy:` and stops until they are moved into
  `rules.ini`, `defaults.ini` or the `rule.ini` of a rule and removed.
- **Do not change a standard during a scoring run**: step 1 saves a snapshot
  of each standard's content and sha256, and steps 3 to 5 score with that
  snapshot. If a standard document, a scan rule file, the `rule.ini` of the
  rule or `defaults.ini` change during the run, the status script refuses to
  continue; revert the change, or start over with
  `review-state init --reset`.
- **Run lint after changing a standard**: the scoring run does not run lint;
  when the format is wrong, the scoring scripts only stop with a hint. After a
  change, run `standard lint`, and use `standard diff <old> <new>` to see
  which check items actually changed. Lint only checks the format; whether the
  rules themselves are right still needs a human review.
- **Scan rule files can go stale**: the header of a scan rule file records
  the version and hash of the standard it was generated from. After the
  standard changes, lint warns that the rules are out of date; generate or
  review the scan rules again.
- **One PR can produce several reports**: one for each framework standard
  that matches the changed files. Common files whose owner cannot be
  determined (for example the README at the repository root) are listed in
  every report, and the CR comments on those files appear in every report as
  well.

## GitHub Copilot compatibility

This section summarizes how the PR scoring skills work on GitHub Copilot and
the known limitations, based on official documentation and issues checked in
October 2026. Copilot changes often; check the current state before use.

### Summary

Mostly compatible. Where the skills are placed, the main agent dispatching
subagents, and subagents asking questions through files all match how Copilot
behaves. The main limitations are that **the reasoning setting of subagents
cannot be applied yet**, and that **a model can only be specified within a
cost tier limit**.

### Item by item

| Rule | Works | Notes |
| --- | --- | --- |
| Skill location and format | ✅ | Copilot reads `.github/skills`, `.claude/skills` and `.agents/skills` in VS Code, Copilot CLI and the cloud coding agent; the SKILL.md format is the same. |
| Main agent dispatches subagents | ✅ | VS Code uses `runSubagent`. Subagents cannot dispatch further subagents by default, which matches the "only the main agent dispatches" design. |
| Subagents ask through `questions.md` | ✅ | Copilot subagents cannot ask the user questions anyway, which matches this design. |
| Specifying the subagent model | ⚠️ Conditional | `runSubagent` accepts a `model` parameter since VS Code 1.117. But if the model is in a higher cost tier than the model of the main chat, the subagent does not run. |
| Specifying the subagent reasoning | ❌ Not yet | `runSubagent` cannot set reasoning per call; only `reasoning-effort` in a custom agent file (`.agent.md`) can. The built-in local harness of VS Code ignores that value and the related issue is still open; Copilot CLI applies it. |
| Running scripts on Windows | ✅ | VS Code uses PowerShell on Windows by default; the `.ps1` scripts handle UTF-8. |
| Copilot CLI | ⚠️ | It has subagents, but no documentation was found on setting the model or reasoning per call. |
| Copilot coding agent (cloud) | ⚠️ Not recommended | It runs asynchronously as a PR and cannot relay `pending` questions in real time. |

### Concerns and workarounds

#### 1. The reasoning of `[Copilot]` in `configs/settings.ini` has no effect

- **Impact**: the setting is recorded, but subagents actually use the
  reasoning of the main chat.
- **Current behavior**: when saving the setting, the main agent tells the
  user that this value is not applied.
- **Possible improvement**: have the main agent generate a custom agent file
  with `model` and `reasoning-effort` from `configs/settings.ini` and dispatch
  subagents with it. This works in Copilot CLI but is still ignored by the
  local harness of VS Code, so it is not implemented yet.

#### 2. The subagent model cannot exceed the cost tier of the main chat

- **Impact**: when the configured model is in a higher tier, the subagent
  does not run and the step stays "not started".
- **Current behavior**: when a subagent ends but its step has still not
  started, the main agent suggests checking the cost tier and dispatches once
  more; if that fails too, it stops and tells the user.
- **Recommendation**: in `[Copilot]`, set a model no higher than the tier you
  normally use in the main chat.

#### 3. Copilot CLI may not be able to set the subagent model and reasoning

- **Impact**: subagents may use the default values.
- **Current behavior**: the main agent tells the user and falls back to the
  platform defaults; the workflow continues as usual.

#### 4. The Copilot coding agent (cloud) is not suited to the full workflow

- **Impact**: it cannot relay `pending` questions to the user in real time,
  so the workflow only completes when all inputs are provided up front.
- **Another limitation**: `.github/skills/` is listed in `.gitignore`, and
  Windows junctions cannot be committed to git. For the cloud environment to
  see the skills, run the link script in the cloud environment, or remove
  `.github/skills/` from `.gitignore` and commit symlinks or real
  directories.

#### 5. Not verified yet

- The full workflow has not been run on Copilot yet.
- It is not confirmed whether Copilot reads skills linked into
  `.github/skills` through a symlink or junction. If it does not, copy the
  real directories into `.github/skills` instead.

### References

- [Use Agent Skills in VS Code](https://code.visualstudio.com/docs/agent-customization/agent-skills)
- [Adding agent skills for GitHub Copilot - GitHub Docs](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/add-skills)
- [GitHub Copilot Skills: Where to Put Skills - SmartScope](https://smartscope.blog/en/generative-ai/github-copilot/github-copilot-skills-guide/)
- [Subagents in VS Code](https://code.visualstudio.com/docs/copilot/agents/subagents)
- [Using subagents in your IDE - GitHub Docs](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/use-copilot-agents/use-subagents?tool=vscode)
- [Allow sub-agents to be invoked with a different model · microsoft/vscode#310138](https://github.com/microsoft/vscode/issues/310138)
- [Local harness should honor reasoning-effort · microsoft/vscode#334592](https://github.com/microsoft/vscode/issues/334592)
- [Custom Agent YAML Frontmatter Should Support Reasoning Effort · github/copilot-cli#2904](https://github.com/github/copilot-cli/issues/2904)
- [Comparing GitHub Copilot CLI customization features - GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/comparing-cli-features)
- [GitHub Copilot CLI changelog (2026-01-14)](https://github.blog/changelog/2026-01-14-github-copilot-cli-enhanced-agents-context-management-and-new-ways-to-install/)
