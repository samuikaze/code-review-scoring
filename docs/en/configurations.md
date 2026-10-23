# Configuration

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

English | [繁體中文](../zh-tw/configurations.md)

- [Configuration files](#configuration-files)
- [settings.ini](#settingsini)
- [plugins.ini](#pluginsini)

## Configuration files

The configuration files in `configs/` are not under version control; only
the templates `configs/*.example.ini` are. The templates hold only the
sections to uncomment; every section and key is explained in this document.

| File | Template | Contents |
| --- | --- | --- |
| `configs/settings.ini` | `configs/settings.example.ini` | Execution mode, the model and reasoning of the subagents of each platform, the report language and the location of the rules project |
| `configs/plugins.ini` | `configs/plugins.example.ini` | The plugin skill list |

All configuration files are INI files; values are in double quotes, and
lines starting with `;` or `#` are comments. Relative paths are always
relative to the folder of the file (`configs/`).

## settings.ini

You do not need to create it by hand: the first time the full workflow runs,
the configuration check guides you through creating `configs/settings.ini`.
To set it up in advance, copy the template in the project root, then
uncomment and edit the sections you need:

```bash
cp configs/settings.example.ini configs/settings.ini
```

### The workflow section

Required.

| Key | Description |
| --- | --- |
| `subagent` | `"true"`: each step is dispatched to a subagent; `"false"`: the main agent runs every step itself. On platforms without subagents, the main agent runs every step even when it is `"true"`. |

```ini
[workflow]
subagent="true"
```

### Platform sections

Needed only when `subagent` is `"true"`. The section name is the platform
name, for example `Claude`, `Copilot`, `Codex` or `Gemini`; `workflow`,
`language` and `rules` are reserved and cannot be platform names.

| Key | Description |
| --- | --- |
| `model` | The model of the subagents; must be a value the subagent tool of the platform accepts. |
| `reasoning` | The reasoning level of the subagents. GitHub Copilot does not apply it yet; see the [notices](notices.md#github-copilot-compatibility). |

```ini
[Claude]
model="sonnet 5.5"
reasoning="high"

[Codex]
model="gpt-5.6"
reasoning="xhigh"
```

### The language section

Optional.

| Key | Description |
| --- | --- |
| `report` | The language of the report: the name of a language folder in `templates/` in the project root, for example `zh-tw` or `en`; default `zh-tw`. It decides the report template (`report-template.md`, `labels.tsv`) and the language steps 2 and 3 write the narrative text in. |

When `templates/` holds the report template of only one language (in a
language folder or not), that template is always used and this setting is
ignored.

```ini
[language]
report="en"
```

### The rules section

Required.

| Key | Description |
| --- | --- |
| `root` | The root folder of the rules project (for example code-review-scoring-rules), as a full path or relative to `configs/`. On Windows, use forward slashes, for example `C:/Users/me/Documents/code-review-scoring-rules`. |

The root of the rules project has `rules.ini` (registers and enables the
rules), `defaults.ini` (the default points, severity scale and grades) and
one folder per rule (`rule.ini`, the scoring rule document and the scan
rules); see
[`templates/en/rule-template.ini`](../../templates/en/rule-template.ini) for
how to write `rule.ini`.

```ini
[rules]
root="../../code-review-scoring-rules"
```

## plugins.ini

The plugin skill list. To create `configs/plugins.ini`:

- Let the configuration check guide you when scoring, or run `wizard` of
  `skills/code-review-scoring/scripts/setup.*` step by step.
- Copy the template in the project root and edit it:

  ```bash
  cp configs/plugins.example.ini configs/plugins.ini
  ```

Without `configs/plugins.ini`, the workflow asks you to create one first.
When you use no plugins, create a `plugins.ini` without plugins as well
(`setup plugins --none`).

`scripts/link-skills.*` links the skills listed here together with those in
`skills/` to `.agents/skills` and the other skill folders; plugins removed
from the list are unlinked at the next sync. Step 2 (CR) of the workflow
runs the plugins whose `applies` matches the files changed by the PR.

One section per plugin; the section name must equal `name` in the
`SKILL.md` of the skill.

| Key | Description |
| --- | --- |
| `path` | The skill folder, required. A relative path is relative to `configs/`. |
| `applies` | The files it applies to, as comma-separated wildcards; optional, all changed files when not set. |
| `mode` | `mapped`: CR comments are confirmed while analysing the code; confirmed ones always deduct points, and rejected ones need a reason (default). `advisory`: CR comments are only shown in the report and do not affect the score. |

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
