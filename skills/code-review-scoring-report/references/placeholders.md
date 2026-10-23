# Report template placeholders

## Inline placeholders

Can appear anywhere in a line, any number of times.

| Placeholder | Value |
| --- | --- |
| `{{PR_TITLE}}` | `- Title:` line of `spec-context.md`, or `--title`; label `title.missing` when empty |
| `{{REVIEW_DATE}}` | date the report was rendered (YYYY-MM-DD) |
| `{{STANDARD}}` | name and version of the scoring standard (`standard` line of `score.tsv`), followed by label `standard.common` with `{common}` replaced by the common standard when one was used |
| `{{GRADE}}` | the grade of the standard's grades (`grade` line of `score.tsv`), shown by its display name (`gradedef` lines) |
| `{{TOTAL}}` | total score (0–100) |
| `{{CAPPED_NOTE}}` | label `capped_note` with `{severity}` and `{grade}` replaced by the display names of the severity and the grade of the cap (`cap` line of `score.tsv`) when a deduction capped the grade, otherwise empty |
| `{{CR_TOTALS}}` | code review comment counts over all plugins, per severity of the standard's scale from the most severe, by the severity each comment was mapped to (`M` lines), e.g. `Critical 0、Major 2、Minor 1、Nit 3`; label `cr.no_plugins` or `cr.not_run` when there is nothing to count |

## Block placeholders

Must be alone on their line. Replaced by several lines; an empty block becomes the `none` label.

| Placeholder | Content | Source |
| --- | --- | --- |
| `{{CR_OVERVIEW}}` | Markdown table with one row per code review plugin: files reviewed, comment counts per severity of the standard's scale (one column each), conclusion (header from labels); or label `cr.no_plugins` / `cr.not_run` | `step2/plan.tsv` + `cr.txt` |
| `{{CR_DETAILS}}` | one `### <plugin>` section per plugin: conclusion, comments sorted by their mapped severity from the most severe, highlights. Each comment is `[severity \| rule \| status]` (the mapped severity; label `cr.plugin_severity` gives the plugin's own severity when it differs) with problem, suggestion, the rejection reason and every code and spec location as a sub-list. Status: the check ids of the records whose `source:` cites the comment (label `check.none` for records without a check id, `cr.upstream` for `U` records), or label `cr.rejected`, `cr.advisory` or `cr.unjudged`. Empty (not `none`) when no plugin ran | `step2/<plugin>/cr.txt` + `F`, `U`, `X`, `M` lines |
| `{{CR_SKIPPED}}` | plugins of `configs/plugins.ini` that did not run because no changed file matched their `applies` | `step2/skipped.tsv` |
| `{{SCORE_ROWS}}` | one Markdown table row per dimension: `\| A 正確性 \| 20/25 \| A1 Major -5 \|`, then a row for records without a check id (`row.other`) and one for upstream factors (`row.upstream`), both deducted from the total (put the header row in the template) | `score.tsv` |
| `{{FINDINGS}}` | numbered deductions sorted by severity from the most severe, each with problem, suggestion, optional assumption and, for deductions confirmed from code review comments, the comment ids | `score.tsv` + `F` lines |
| `{{SUGGESTIONS}}` | `N` lines | `findings.txt` |
| `{{UPSTREAM}}` | numbered suspected upstream factors with severity, deduction, content, code and vendor ticket | `U` lines + `score.tsv` |
| `{{HIGHLIGHTS}}` | bullet list | `H` lines |
| `{{SKIPPED}}` | bullet list `check id：reason` | `S` lines |
| `{{IGNORED}}` | bullet list | `I` lines |
| `{{REMARKS}}` | bullet list | `R` lines |
| `{{SCORE_JSON}}` | content of `score.json` (wrap it in a ```` ```json ```` fence in the template) | `score.json` |

## Labels

`labels.tsv` (next to `report-template.md` in the report language folder, see the skill's "Report language") holds `key<TAB>text` pairs. Keys: `language` (the language the agents write the narrative text in, e.g. `English`; not printed), `none`, `title.missing`, `capped_note` (`{severity}` and `{grade}` are replaced), `sep.list`, `sep.bracket`, `sep.colon`, `dim.A`–`dim.G`, `standard.common`, `field.*` (problem, suggestion, assumption, source, content, code, ticket), `check.none` (check id `-`), `loc.pr_wide` (location `-`), `row.other`, `row.upstream`, `upstream.*`, `sub.*`, `impact.*`, and for code review `cr.not_run`, `cr.no_plugins`, `cr.missing`, `cr.col.*` (table headers), `cr.summary`, `cr.highlights`, `cr.tag_sep` (separator in the comment tag, printed with a space on each side), `cr.upstream`, `cr.rejected`, `cr.reason` (rejection reason field), `cr.advisory`, `cr.unjudged` (comment status), `cr.code`, `cr.spec` (location field names), `cr.plugin_severity` (the plugin's own severity of a comment), `cr.no_comments`, `cr.skipped` (`{applies}` is replaced by the plugin's patterns), `cr.all_files`. A missing key is printed as the key itself.
