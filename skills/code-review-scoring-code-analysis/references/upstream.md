# Upstream factors

A PR's quality depends on upstream material: the SD spec, which in turn relies on the third-party core-system spec and on the specs and processes of the owning unit. When the root cause of a problem is upstream, the implementer is not deducted.

**You can only decide "suspected". The final attribution is confirmed by a person.** Any problem you judge as a suspected upstream factor gets **no** deduction: write it as a `U` line instead of an `F` line.

## Categories

| Type (findings code) | When | Input needed |
| --- | --- | --- |
| Suspected spec gap (`spec-gap`) | The implementation follows the SD spec, and the problem comes from the spec missing something, being wrong, or being ambiguous | SD spec |
| Suspected third-party issue (`third-party`) | The problem comes from the third-party core system: missing or wrong vendor spec, behavior that differs from the vendor spec, an undelivered feature, or a bug | Third-party spec, or a vendor ticket number in a code comment |
| Suspected ownership change (`ownership-change`) | The problem comes from a spec, interface or process change made after development started | Change log |

## Rules

- If you suspect an upstream factor but the needed input was not provided, ask the user for it (record it under **Open questions**). If the user says it cannot be provided, you may not use that category: score as usual and explain the suspicion in an `R` line.
- Every `U` line needs a reference: spec section or version, change-log date, or vendor ticket number. No reference, no `U` line.
- Judge compliance against the spec and process versions **in effect when development started**. Later changes do not make a finished PR wrong.
- A change communicated only verbally, without written confirmation, does not count; the original version still applies.
- For 5 working days after a process change, a PR is not deducted for not following the new process.
- When it cannot be determined whether the cause is the SD spec or the third-party system (for example, the vendor spec version at the time is unknown), classify it as a suspected third-party issue.
- Do not decide who is responsible, and never name the author of a spec.

## Subtypes and impact

`spec-gap` subtypes:

| Code | Meaning | Example |
| --- | --- | --- |
| `missing` | the spec lacks necessary content | no error handling defined, missing field rules, a business scenario left out |
| `wrong` | the spec contradicts the requirements or the existing system | field type differs from the existing table, flow differs from the requirements spec |
| `ambiguous` | the text allows several readings | "notify the user when data is abnormal" without saying how or whom |

`spec-gap` impact (required):

| Code | Meaning |
| --- | --- |
| `high` | finished implementation must be reworked |
| `medium` | the implementer had to ask or design the missing part to continue |
| `low` | inferable from context, but the spec should state it |

`third-party` subtypes: `spec-missing`, `spec-wrong`, `behavior-mismatch`, `not-delivered`, `bug`.

`ownership-change` subtypes: `spec`, `interface`, `process`.
