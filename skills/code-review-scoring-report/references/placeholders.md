# Report template placeholders

## Inline placeholders

Can appear anywhere in a line, any number of times.

| Placeholder | Value |
| --- | --- |
| `{{PR_TITLE}}` | `- Title:` line of `spec-context.md`, or `--title`; label `title.missing` when empty |
| `{{REVIEW_DATE}}` | date the report was rendered (YYYY-MM-DD) |
| `{{GRADE}}` | S, A, B, C or D |
| `{{TOTAL}}` | total score (0–100) |
| `{{CAPPED_NOTE}}` | label `capped_note` when a Critical finding capped the grade at B, otherwise empty |
| `{{CR_TOTALS}}` | code review comment counts over all plugins, e.g. `Critical 0、Major 2、Minor 1、Nit 3`; label `cr.no_plugins` or `cr.not_run` when there is nothing to count |

## Block placeholders

Must be alone on their line. Replaced by several lines; an empty block becomes the `none` label.

| Placeholder | Content | Source |
| --- | --- | --- |
| `{{CR_OVERVIEW}}` | Markdown table with one row per code review plugin: files reviewed, comment counts per severity, conclusion (header from labels); or label `cr.no_plugins` / `cr.not_run` | `step4/plan.tsv` + `cr.txt` |
| `{{CR_DETAILS}}` | one `### <plugin>` section per plugin: conclusion, comments sorted Critical → Major → Minor → Nit with problem and suggestion, highlights. Empty (not `none`) when no plugin ran | `step4/<plugin>/cr.txt` |
| `{{CR_SKIPPED}}` | plugins of `plugins.ini` that did not run because no changed file matched their `applies` | `step4/skipped.tsv` |
| `{{SCORE_ROWS}}` | one Markdown table row per dimension: `\| A 正確性 \| 20/25 \| A1 Major -5 \|` (put the header row in the template) | `score.tsv` |
| `{{FINDINGS}}` | numbered deductions sorted Critical → Major → Minor, each with problem, suggestion and optional assumption | `score.tsv` + `F` lines |
| `{{SUGGESTIONS}}` | `Nit` findings, then `N` lines | `findings.txt` |
| `{{UPSTREAM}}` | numbered suspected upstream factors with content, code and vendor ticket | `U` lines |
| `{{HIGHLIGHTS}}` | bullet list | `H` lines |
| `{{SKIPPED}}` | bullet list `check id：reason` | `S` lines |
| `{{IGNORED}}` | bullet list | `I` lines |
| `{{REMARKS}}` | bullet list | `R` lines |
| `{{SCORE_JSON}}` | content of `score.json` (wrap it in a ```` ```json ```` fence in the template) | `score.json` |

## Labels

`assets/labels.tsv` holds `key<TAB>text` pairs. Keys: `none`, `title.missing`, `capped_note`, `sep.list`, `sep.bracket`, `sep.colon`, `dim.A`–`dim.G`, `field.*` (problem, suggestion, assumption, content, code, ticket), `upstream.*`, `sub.*`, `impact.*`, and for code review `cr.not_run`, `cr.no_plugins`, `cr.missing`, `cr.col.*` (table headers), `cr.summary`, `cr.highlights`, `cr.no_comments`, `cr.skipped` (`{applies}` is replaced by the plugin's patterns), `cr.all_files`. A missing key is printed as the key itself.
