# Review output format

Every review posts one summary comment in the structure below, in
addition to any inline comments. This applies to reviews with no
findings: a clean review still states its verdict and its re-review
position explicitly, so "Copilot found nothing" and "Copilot did not
finish" are never confused for one another.

Inline comments carry the detail and the suggested change. The summary
comment is the index: it must be readable on its own and must let the
developer decide what to do next without opening a single inline
thread.

## Structure

### 1. Executive summary

One short paragraph, then a verdict line. The verdict is exactly one
of the following, rendered in bold:

| Verdict | Use when |
|---|---|
| **Ready to Merge** | No Critical/Bug findings. Any remaining findings are follow-up material and are labelled as such. |
| **Changes Requested** | At least one Critical/Bug finding, or a Documentation or Test Coverage finding whose action is *Fix required before merge*. |
| **Needs Clarification** | The diff cannot be assessed without an answer from the author — intent is ambiguous, or a claim could not be verified against the code. Do not use this as a hedge; use it only when a specific question genuinely blocks the assessment, and state the question. |

The paragraph says what the PR does and what the headline concern is.
Do not restate the PR description back to the author.

### 2. Findings by severity

Group findings under these four headings, in this order. **Omit
headings with no findings** — do not emit an empty section.

| Heading | Contents |
|---|---|
| **Critical / Bug** | Incorrect behaviour, unsound FFI usage, a secret-handling regression, a broken invariant, an unintended breaking API change. |
| **Documentation** | Docs contradicting code, missing CHANGELOG entry, a stale doc comment, a rustdoc/dartdoc claim not matching the implementation. |
| **Test Coverage** | Untested branch, a hand-maintained list that can drift from the type it mirrors, a test asserting something weaker than its name implies. |
| **Optimization** | Performance, clarity, structure. Never blocking. |

Within each heading, one bullet per finding:

```markdown
- **`path/to/file.dart:123`** — Concise statement of the finding.
  Why it matters, in one or two sentences. If confidence is not high,
  say so here explicitly.
  *Action: Fix required before merge.*
```

Requirements per finding:

- **Location.** File path with a line number where one applies.
- **Statement.** What is wrong, not a description of what the code does.
- **Consequence.** Why it matters. A finding with no stated
  consequence is unactionable, and the developer has to reconstruct
  the reasoning to triage it.
- **Confidence, when it is not high.** State the limitation plainly:
  "I could not verify this from the diff alone — `ke.rs` is not in
  this PR." Never let low confidence become silence; see the
  reporting-threshold rule in `SKILL.md`.
- **Action line.** Exactly one of the three below, in italics.

### 3. Action vocabulary

Every finding ends with exactly one of:

| Action | Meaning |
|---|---|
| *Action: Fix required before merge.* | Blocking. The PR should not merge in its current state. |
| *Action: Consider for follow-up.* | Non-blocking. Worth doing, does not need to happen here. File an issue or fix it later. |
| *Action: Clarification requested.* | The author needs to answer something before this can be assessed either way. |

Do not invent other action phrasings, and do not leave a finding
without one. The action line is what makes the review triageable at a
glance — a finding without one forces the developer to infer severity
from tone, which is exactly the ambiguity this format removes.

The action must be consistent with the verdict. Any *Fix required
before merge* means the verdict cannot be **Ready to Merge**. Any
*Clarification requested* means the verdict is **Needs Clarification**
unless something more severe already forces **Changes Requested**.

### 4. Review status

Close with an explicit statement, under a `## Review Status` heading,
covering both of:

1. **Whether a re-review is expected**, in these words:
   - "Re-review requested once the blocking findings are addressed."
   - "No re-review needed — remaining findings are non-blocking."
   - "Re-review after the clarification is answered."
2. **What was not checked**, if anything. Name any check you could not
   complete and why: an MCP lookup that failed, a CI status not yet
   reported, a file you could not read. Silence here means every check
   in `SKILL.md` was performed.

## Worked example

```markdown
## Executive Summary

Adds `TrustMode` selection to the example CLI and threads it through
to `ntsQuery`. The plumbing is correct; the user-facing documentation
of the fallback behaviour describes only one of the two paths that
exist.

**Verdict: Changes Requested**

## Findings

### Documentation

- **`example/CLI_GUIDE.md:102`** — Describes `platform-with-fallback`
  as falling back per-chain, but there are two distinct fallback
  paths: build-time, when platform verifier *construction* fails
  (`rust/src/nts/ke.rs:1363`), and per-chain, on a `Revoked` or JNI
  verdict for an individual chain
  (`rust/src/nts/hybrid_verifier.rs:252` and `:282`). A reader
  configuring `platform-only` from this guide will not anticipate the
  build-time `TrustBackendUnavailable`.
  *Action: Fix required before merge.*

### Test Coverage

- **`example/test/nts_format_test.dart:192`** — The tag-collision set
  enumerates ten `NtsError` variants by hand and omits
  `AbiMismatch`. The list has no mechanical link to the sealed type,
  so it drifted silently when that variant was added and will drift
  again on the next one.
  *Action: Consider for follow-up.*

## Review Status

Re-review requested once the blocking findings are addressed. The
"Verify FRB bindings are in sync" check had not reported when this
review ran; I did not verify binding freshness.
```
