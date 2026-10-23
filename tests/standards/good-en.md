---
# Standard code: only lowercase letters, digits and -; must equal the section name in rules.ini of the rules project
name: english
# Standard version, recorded in the score report
version: v1.0
---

# Standard Name PR Code Quality Scoring Rules

<!-- markdownlint-disable MD028 -->
<!-- markdownlint-disable MD033 -->

<!--
How to write this document (delete this comment after copying the template):
- The AI and the scoring scripts read the same document, so follow the format
  of each section strictly.
- The sections "Dimensions", "Check items" and "Confirmations" are parsed by
  the scripts; the other sections are only for the AI and can be written
  freely.
- Content in code blocks and HTML comments is never taken as a rule.
- This document lives in the folder of its rule in the rules project and is
  set by standard in the rule.ini of that folder; see rule-template.ini in
  the template folder for how to write rule.ini.
- Automatic scan rules (optional) are saved as a separate TSV file, set by
  scan in rule.ini.
- The files this standard applies to are set by applies in rule.ini, not in
  this document.
- The points of the dimensions, the severity scale and the grades are set in
  rule.ini; what rule.ini does not set comes from defaults.ini of the rules
  project.
- General rules such as the scoring scope, deductions requiring evidence and
  upstream factors are handled by the scoring workflow; write only what is
  specific to this standard here.
- The section headings may also be written in Chinese (面向, 檢查項,
  事先確認事項); both are accepted.
-->

Describe in one paragraph the technology, the kind of project and the purpose
of scoring that this standard covers.

## Dimensions

All standards share the following seven dimensions. Points are set by
`[points]` in `rule.ini`, or by `[points]` in `defaults.ini` of the rules
project when `rule.ini` does not set them. The first letter of a check code is
its dimension. Codes and dimension names cannot be changed; the "Focus" text can
be adapted to this standard's technology.

| Code | Dimension | Focus |
| --- | --- | --- |
| A | Correctness | Does the code work as intended; are edge cases and exceptions handled |
| B | Security | Does it introduce security weaknesses |
| C | Test quality | Are the tests sufficient and meaningful |
| D | Architecture and design | Layering, separation of responsibilities, framework conventions |
| E | Performance and resource use | Query efficiency, resource management, external calls |
| F | Readability | Is it easy for others to understand |
| G | Maintainability | Is it easy to change and extend later |

## Check items

Write each check item as one list item, with fields separated by the
full-width `｜` (U+FF5C):

- Fixed severity: `- code｜content｜default severity`
- Adjustable severity:
  `- code｜content｜default severity｜adjustable to｜condition`

Field rules:

- Code: the dimension letter plus a sequence number, for example `A1`, unique
  within the document. The common standard (`role="common"`) prefixes its
  codes with `CM-`, for example `CM-A1`; codes of framework standards cannot
  start with `CM`.
- Severity: only the severity codes of this rule (case-sensitive), that is the
  `[severity:CODE]` sections of `rule.ini`, or the scale of `defaults.ini`
  when `rule.ini` does not set one. The examples below use the default
  `Critical`, `Major`, `Minor` and `Nit`.
- Adjustable to: the severities that may be used when the condition holds,
  separated by half-width commas.
- Any check item can be lowered to the lowest severity (the last one of the
  scale, `Nit` by default); it does not need to be listed in "adjustable to".
- Content and conditions cannot contain the full-width `｜`; put code in
  backticks.
- A long check item can wrap; indent continuation lines with two spaces.

<!-- One subsection per dimension; for a dimension without check items, keep
the heading and write "None". -->

### A. Correctness

- A1｜Edge cases are not handled, such as null or an empty collection｜Major
- A2｜Time handling does not specify the time zone explicitly｜Minor｜Major｜
  when the PR description or the spec clearly involves business across time
  zones

### B. Security

- B1｜Passwords, tokens or keys are hard-coded in code or
  configuration｜Critical

### C. Test quality

- C1｜New or changed business logic has no corresponding unit test｜Major

### D. Architecture and design

- D1｜Business logic is written in a controller｜Major

### E. Performance and resource use

- E1｜A query has no paging and loads a whole table at once｜Minor

### F. Readability

- F1｜A method has more than 50 lines, or nesting deeper than 3 levels｜Minor

### G. Maintainability

None

## Confirmations

At the start, the scoring workflow asks about the items listed here together
with the missing documents.
Format: `- related codes｜what to confirm`, with several codes separated by
half-width commas.

- A2｜Does the feature involve business across time zones
- E1｜Will the table of the new query keep growing, and roughly how many rows

## Special rules

<!-- Only for the AI; write freely. For example, when a check item applies,
or when it does not deduct. -->

- Code written to work around a third-party system problem does not deduct
  under the check items of dimensions F and G when a comment explains the
  reason and gives the vendor's ticket number.

## Judging hints

<!-- Only for the AI; write freely. For example, patterns that are easy to
misjudge, or check items that need human judgment. -->

- A1 and D1 need the context of the code to judge; keywords alone are not
  enough.
