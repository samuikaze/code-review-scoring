# Upstream factors

A PR's quality depends on upstream material: the SD spec, which in turn relies on the third-party core-system spec and on the specs and processes of the owning unit. The root cause of a problem may be upstream.

**You can only decide "suspected". The final attribution is confirmed by a person.** Write a problem you judge as a suspected upstream factor as a `U` line instead of an `F` line. It is still deducted, from dimension G (shared with records without a check id) by its severity, and the report lists it for human confirmation.

## Categories

| Type (findings code) | When | Input needed |
| --- | --- | --- |
| Suspected spec gap (`spec-gap`) | The implementation follows the SD spec, and the problem comes from the spec missing something, being wrong, or being ambiguous | SD spec |
| Suspected third-party issue (`third-party`) | The problem comes from the third-party core system: missing or wrong vendor spec, behavior that differs from the vendor spec, an undelivered feature, or a bug | Third-party spec, or a vendor ticket number in a code comment |
| Suspected ownership change (`ownership-change`) | The problem comes from a spec, interface or process change made after development started | Change log |

## Rules

- If you suspect an upstream factor but the needed input was not provided, ask the user for it (record it under **Open questions**). If the user says it cannot be provided, you may not use that category: score as usual and explain the suspicion in an `R` line.
- Every `U` line needs a reference: spec section or version, change-log date, or vendor ticket number. No reference, no `U` line.
- The organization's rules for judging upstream factors (which spec version applies, which changes count, grace periods, how to classify an unclear cause) are in the `## 全域規則` (`## Global rules`) section of the global standard; apply them.
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
