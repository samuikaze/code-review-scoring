# Scan rule review checklist

Review the scan rules against the standard document item by item. Read both files completely; do not rely on the generator's notes alone. Lint has already checked the format, the check ids, the scopes and that every regex compiles, so this review is about meaning.

## Checklist

For every rule (`@scope`, `@pr` and line rules):

1. **Matches the check item.** What the regex finds is what the check item describes, not something nearby. Read the regex as code: alternatives, anchors, escaped characters, case.
2. **Hint is faithful.** The hint says what to confirm in the words of the check item. It does not change the meaning, add a condition, name a severity, or promise a deduction.
3. **Conditions are reminded.** For a check item with an applicability or severity condition (in the item itself, in 特例規則 or in 事先確認事項), the hint reminds step 3 to confirm the condition first (for example: `only when the project uses springdoc`).
4. **Scope is right.** The scope covers the files the check item is about and no more (test checks only on test files, configuration checks only on configuration files). Scope regexes match real paths of the technology (try two or three typical paths of a real project in your head).
5. **False positives and misses.** Name the obvious ones: comments, strings, constants, test fixtures, generated code, the same word in another construct. Ask for an `exclude-regex`, a narrower pattern or a narrower scope when a false positive would be common; accept a rare miss rather than a noisy rule.
6. **`@pr` hints** use conditions that the set of changed files really shows (`has:`, `no:`, `modified:`), and the hint lists what to confirm.

For the document as a whole:

7. **Coverage.** Every check item either has at least one rule, or is listed in `notes.md` as having no rule with a reason that holds (needs the surrounding code or intent, cannot be seen in a single line, depends on an input such as a vulnerability scan). Challenge a "no rule" reason when a simple, low-noise pattern exists.
8. **Stale rules.** No rule is left for a check item that the document removed or changed in a way the rule no longer fits (lint reports removed ids; changed wording is yours to catch). With an existing scan rule file, rules that still fit are kept unchanged.

## review.md format

```markdown
# Scan rule review: <standard> <version> (round <n>)

result: pass | changes needed

## Open items
- line <n> (<id>): <checklist item number> <what is wrong> → <what to change>
- <check id>: <coverage problem> → <what to add>

## Checked
- <id>: ok (<one short reason when it is not obvious>)
- <check id>: no rule, reason accepted: <reason>
```

`result: pass` only when there are no open items. Line numbers are those of the reviewed file. Keep it short: the generator reads it in the next round and the user reads the summary.
