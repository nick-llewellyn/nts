# Agent Instructions

## Who this file is for

Most of this file applies to anyone changing the code, agent or human:
the pull request workflow, branch protection, the non-interactive
shell rules, the doc-snippet validator, the versioning policy, and the
zeroization conventions. The one maintainer-specific detail inside
that shared material is branch naming — the `NTS-` prefix in the
standard agent loop below is a Linear identifier contributors do not
have; they use `<type>/<short-slug>` instead, per
[`CONTRIBUTING.md`](CONTRIBUTING.md).

The rest documents the **maintainer's** issue-tracking setup — Beads
(`bd`), DoltHub, and Linear — which is not a prerequisite for
contributing. Those sections are marked with a
**`Maintainer-only`** note directly under their heading — except for
the generated Beads block, whose note sits just above it so
regenerating the block cannot drop it. Skip them
unless you have the tooling installed and credentialed. Third-party
contributors should start from
[`CONTRIBUTING.md`](CONTRIBUTING.md) instead.

## Quick Reference

> **Maintainer-only.** Requires `bd` and a credentialed DoltHub remote.

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Pull Request Workflow (mandatory)

`main` is protected; **never `git commit` or `git push` directly to
`main`**. Every change — including agent-authored ones — must land
through a pull request. The rule applies at *commit time*, not just
push time: see [Branch Protection](#branch-protection-read-this-before-any-git-commit)
below for the local hooks that enforce it mechanically once
`core.hooksPath` is activated for the clone. A fresh checkout
that has not opted in still permits the local commit on `main`;
the GitHub-side rule refuses only the later push or PR merge, so
recovery means resetting `main` back to its authoritative remote
(typically `origin/main`, but see the multi-remote caveat in the
"Recovery when the rule is broken" section below if you cloned
from a fork) rather than preventing the commit in the first place.
Required approvals are set to **0** so a *human* contributor can
self-merge once the required status checks pass; **agents must
not** self-merge — see [Agent merge policy](#agent-merge-policy-read-this-before-any-gh-pr-merge)
below. Every PR triggers the CI workflow (including doc-only
ones); the `build`, `rust`, `rust-bridge-sync`, `hooks-syntax`,
`hooks-behaviour`, `android-kgp-gate`, and `auggie-hooks` jobs all
skip the heavy work on doc-only diffs but still report a status, so branch
protection resolves without manual intervention. See
[`DEVELOPMENT.md`](DEVELOPMENT.md#contribution-workflow) for the
authoritative branch-protection table.

Standard agent loop on a fresh task:

```bash
# Maintainer form; contributors use `<type>/<short-slug>` (no Linear ID).
git switch -c <type>/NTS-<num>-<short-slug>  # e.g. feat/NTS-24-coverage-upload
# ... make edits, run local quality gates (see DEVELOPMENT.md) ...
git push -u origin HEAD                # push the feature branch
gh pr create --fill                    # uses .github/pull_request_template.md
# The Linear GitHub app picks up the bare Linear identifier (e.g. NTS-24)
# from the branch name and auto-attaches the PR to the Linear issue --
# no manual `save_issue_linear` call is required. See "Linear PR Linking"
# below for the full mechanism.
# ... wait for CI; fix anything red ...
# STOP HERE. Report PR URL + CI status to the user and wait for
# explicit "merge it" before running `gh pr merge`. See
# "Agent merge policy" below — branch protection allows the
# merge, but the policy here does not.
```

Operational notes:

- The PR template under `.github/pull_request_template.md` carries
  the canonical checklist. Tick the boxes you actually ran; do not
  blanket-check items you skipped.
- The `dependency-review` job runs PR-only and fails on `moderate`-
  or-higher advisories; if it fires on a transitive bump, prefer
  pinning the offending dep over disabling the gate.
- Branch-protection details (required checks, status-check names,
  linear history, etc.) live in
  [`DEVELOPMENT.md`](DEVELOPMENT.md#contribution-workflow). Treat
  that section as the source of truth when reconciling repo
  settings.

## Copilot PR Review Handling (mandatory — read before merging or clearing discussions on any PR Copilot reviewed)

> **Hard rule:** Do not merge a PR, and do not treat its review
> discussion as clean, until every Copilot finding — inline comment,
> suppressed finding, and any other section the Copilot integration
> renders inside the review body — has been read, adjudicated, and
> answered. `mergeStateStatus: CLEAN` and green CI are necessary, not
> sufficient: neither signal reads the review body text, so neither can
> tell you a collapsed section went unread.

### Why this exists

GitHub's Copilot code-review UI renders findings in more than one
shape, and the set of shapes has changed over the life of this repo:

- an **inline review comment** — a first-class comment object tied to a
  diff line, visible without expanding anything;
- a **suppressed finding** — text-only, nested inside a collapsed
  `<details><summary>Suppressed comments (N)</summary>` block in the
  review body, with no comment object of its own;
- other **collapsed `<details>` sections** the integration has
  introduced, and may introduce again, that render collapsed by default
  in the web UI's markdown but are present as plain text in the API's
  `body` field regardless of render state.

The failure mode this section exists to close: skimming the rendered PR
page, or even the review body's visible text, reads only the expanded
portions and silently skips whatever the web UI collapsed. On this
repo the same PR round-tripped through this exact miss twice on one
review round: three findings surfaced as "previously missed" in a
follow-up pass over code the first pass had already looked at (PR
#366), because the first read never expanded or grepped the `<details>`
block. A recurring miss means the review-*reading* step, not just the
reply-writing step, needs a mechanical checklist rather than a skim.

### Mandatory checklist (every review, every round, before merge)

1. **Enumerate every Copilot review on the PR, not just the latest.**
   ```bash
   gh api repos/<owner>/<repo>/pulls/<n>/reviews --paginate \
     --jq '.[] | select(.user.login|test("opilot";"i")) | {id, commit_id, submitted_at, state}' < /dev/null
   ```
   Always pass `--paginate` — the endpoint's default page size can omit
   older reviews on a long-lived PR, silently truncating the
   enumeration everything else in this checklist depends on. Match on
   `test("opilot";"i")` — the bot login has varied across accounts
   (`Copilot`, `copilot-pull-request-reviewer[bot]`,
   `github-copilot[bot]`), and a single PR can carry more than one
   casing at once: the reviews endpoint reports
   `copilot-pull-request-reviewer[bot]` while `/comments` reports
   `Copilot` for the same review. Dropping the leading `C` already
   covers those three, but `jq`'s `test` is case-sensitive by default,
   so the `"i"` flag is what keeps a future casing from being missed.
   An exact-match filter silently returns nothing and looks
   indistinguishable from "no findings." Keep each review's `commit_id`
   in the ledger — step 8 needs it.

2. **Fetch the raw `body` of every one of those reviews via the API,
   and save each to a file**, never by reading the rendered web page:
   ```bash
   gh api repos/<owner>/<repo>/pulls/<n>/reviews/<review-id> --jq '.body' < /dev/null \
     > "/tmp/review-<review-id>.txt"
   ```
   The API body is the literal markdown/HTML source, including
   `<details>` blocks the web UI renders collapsed. Reading the web UI
   instead means trusting its default collapsed state to have shown you
   everything, which is the assumption this whole section rejects.
   Persist the body to a file rather than only printing it — step 3
   scans the file this command produces, and a command that fetches the
   body and discards it has examined nothing.

3. **Extract every `<summary>` label from the fetched body with a
   stack-aware parser that only reports a label when its opening and
   closing tags nest correctly — not a
   `grep -o '<summary>[^<]*</summary>'`-style pattern, and not an
   aggregate open/close *count* reconciliation either. Copilot's
   `<summary>` elements routinely nest markup (`<strong>`, `<picture>`),
   and matching tags by count rather than by nesting order accepts
   malformed input: `<details><summary>Hidden (1)</details></summary>`
   has one opening and one closing `<details>` and one opening and one
   closing `<summary>` — its counts balance — yet the closing tags are
   swapped, so it is not the structure this checklist assumes. A stack
   catches that; a tally of counts does not:**
   ```bash
   python3 - <<'PY'
import html, re, sys
body = open('/tmp/review-<review-id>.txt').read()
def fail(msg):
    sys.exit(f'PARSE FAILURE: {msg}')
def at(pos):
    return f'offset {pos} (line {body.count(chr(10), 0, pos) + 1})'
if not body.strip():
    fail('empty review body')
# Blank out what GitHub does not render as markup -- fenced blocks, HTML
# comments, inline code spans -- with same-length whitespace, so every
# offset reported below still indexes the raw file.
hidden = []  # (kind, start, end) of every blanked region
def blank(text, pattern, kind, flags=0):
    def sub(m):
        hidden.append((kind, m.start(), m.end()))
        return re.sub(r'[^\n]', ' ', m.group(0))
    return re.sub(pattern, sub, text, flags=flags)
# A backtick fence's info string cannot contain a backtick; such a line
# is a code span, not a fence.
fence = r'^ {0,3}(?:(`{3,})[^`\n]*|(~{3,})[^\n]*)\n.*?^ {0,3}(?:\1`*|\2~*)[ \t]*$'
markup = blank(body, fence, 'CODE FENCE', re.S | re.M)
m = re.search(r'^ {0,3}(`{3,}[^`\n]*$|~{3,})', markup, re.M)
if m:
    fail(f'unclosed code fence at {at(m.start())}')
# HTML comments, autolinks, backslash escapes and code spans in one
# left-to-right pass: whichever opens first wins, so a `<!--` inside a
# code span, or a backtick inside a comment, does not affect the other.
autolink = (r'<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*>'
            r"|<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]"
            r'(?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
            r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*>')
token = re.compile(r'<!--|' + autolink + r'|\\[!-/:-@\[-`{-~]|`+')
pos = 0
while m := token.search(markup, pos):
    start, opener = m.start(), m.group(0)
    if opener == '<!--':
        end = markup.find('-->', start + 4)
        if end < 0:
            fail(f'unclosed HTML comment at {at(start)}')
        kind, end = 'HTML COMMENT', end + 3
    elif opener[0] == '<':
        kind, end = 'AUTOLINK', m.end()
    elif opener[0] == '\\':
        kind, end = 'ESCAPE', m.end()
    else:
        eol = markup.find('\n', start)
        eol = len(markup) if eol < 0 else eol
        close = re.compile(f'(?<!`){opener}(?!`)').search(markup, start + len(opener), eol)
        if not close:
            pos = start + len(opener)  # unmatched backticks are literal text
            continue
        kind, end = 'CODE SPAN', close.end()
    hidden.append((kind, start, end))
    markup = markup[:start] + re.sub(r'[^\n]', ' ', markup[start:end]) + markup[end:]
    pos = end
# Attributes must follow whitespace or '/'; quoted attribute values may
# contain '>', so consume them whole.
tag_re = re.compile(r'''<(/?)\s*([a-z][a-z0-9-]*)((?:[\s/](?:[^>"']|"[^"]*"|'[^']*')*)?)>''', re.I)
starts = {m.start() for m in tag_re.finditer(markup)}
for m in re.finditer(r'<\s*/?\s*(?:detail|summar)', markup, re.I):
    if m.start() not in starts:
        fail(f'unparsable tag at {at(m.start())} (unbalanced quote or invalid tag syntax?)')
stack = []  # each frame: [tag, content_start, tag_start, has_summary]
labels = []
for m in tag_re.finditer(markup):
    closing, tag = bool(m.group(1)), m.group(2).lower()
    if tag not in ('details', 'summary'):
        if tag.startswith(('detail', 'summar')):
            fail(f'unrecognized tag <{m.group(1)}{m.group(2)}> at {at(m.start())}')
        continue
    if not closing:
        if tag == 'details' and any(f[0] == 'summary' for f in stack):
            fail(f'<details> at {at(m.start())} is inside an open <summary>')
        if tag == 'summary':
            if not stack or stack[-1][0] != 'details' or stack[-1][3]:
                fail(f'<summary> at {at(m.start())} is not the first summary directly inside a <details>')
            a, b = stack[-1][1], m.start()
            if markup[a:b].strip() or any(k != 'HTML COMMENT' and s < b and e > a for k, s, e in hidden):
                fail(f'<summary> at {at(m.start())} is preceded by content inside its <details>')
            stack[-1][3] = True
        stack.append([tag, m.end(), m.start(), False])
        continue
    if not stack or stack[-1][0] != tag:
        top = stack[-1][0] if stack else 'nothing open'
        fail(f'</{tag}> at {at(m.start())} closes {top}')
    open_tag, content_start, tag_start, has_summary = stack.pop()
    if open_tag == 'summary':
        # Structure comes from the masked text; the label text restores
        # each code span's content, as the web UI renders it.
        a, b, parts = content_start, m.start(), []
        for kind, s, e in sorted(h for h in hidden if content_start <= h[1] < b):
            parts.append(html.unescape(tag_re.sub('', markup[a:s])))
            if kind == 'CODE SPAN':
                ticks = len(body[s:e]) - len(body[s:e].lstrip('`'))
                parts.append(body[s + ticks:e - ticks])
            elif kind in ('AUTOLINK', 'ESCAPE'):
                parts.append(body[s + 1:e - (kind == 'AUTOLINK')])
            elif kind == 'CODE FENCE':
                parts.append(' ' + body[s:e] + ' ')
            a = e
        parts.append(html.unescape(tag_re.sub('', markup[a:b])))
        label = ' '.join(''.join(parts).split())
        if not label:
            fail(f'empty <summary> at {at(tag_start)}')
        depth = sum(f[0] == 'details' for f in stack) - 1
        labels.append('  ' * depth + label)
    elif not has_summary:
        fail(f'<details> at {at(tag_start)} closed with no <summary>')
if stack:
    fail(f'unclosed tag(s): {[f"<{f[0]}> at {at(f[2])}" for f in stack]}')
for label in labels:
    print(label)
# Tags inside a blanked region are not structure, but they are text a
# reader must still see: list each so it is read in context.
for kind, start, end in hidden:
    for m in tag_re.finditer(body, start, end):
        if m.group(2).lower().startswith(('detail', 'summar')):
            print(f'IN {kind} at {at(m.start())}: {m.group(0)}')
PY
   ```
   Treat every label this prints as a section to account for, including
   one that has never appeared before. Extracting the tag structure
   itself, rather than grepping for one specific header string, is what
   survives the next time GitHub renames or adds a section; letting the
   stack — not a regex lookahead — decide where a label ends is what
   survives GitHub nesting markup inside the label itself, which it
   already does today (e.g.
   `<summary><strong>Open (7)</strong></summary>`); and `re.I` plus a
   quote-aware attribute pattern on the tag tokens is what keeps a
   differently-cased or attribute-carrying tag (`<DETAILS>`,
   `<details open>`, `<details title="a>b">`) from being missed or cut
   short at a `>` inside a quoted value. The same pattern strips inner
   markup from labels. A `details`/`summary`-like opener the pattern
   cannot match — typically an unbalanced quote, or a name followed by
   something other than whitespace or `/` — is a parse failure,
   not a skipped tag. Labels are printed with inner markup
   removed, HTML entities decoded (`&amp;` → `&`), code-span,
   autolink, and escaped-character text kept (masking hides it from the
   stack, not from the label), HTML comments dropped, and whitespace
   collapsed, so they read as the web UI renders them, and indented two
   spaces per enclosing `<details>`, so a label nested inside another
   block is visibly distinct from a top-level one (see step 5).

   The stack is the point of the snippet, not boilerplate: a closing
   tag that doesn't match the innermost open tag, or a tag left open at
   end of input, means the body's structure is not what this parser
   models, so its output is not evidence of anything. Each exits
   non-zero with a message naming the offending tag and its offset and
   line in the raw fetched file, rather than
   printing a partial list, because a partial list is indistinguishable
   from a complete one at a glance — which is the failure the "Strict
   parsing" rules below require this step to detect, and cannot detect
   on its behalf. The same-count-but-swapped-order case above is
   exactly what a pure open/close tally cannot see and a stack can.
   Placement is checked too: a `<summary>` must be the first summary
   directly inside an open `<details>`, with nothing but whitespace or
   HTML comments before it, so an orphan `<summary>`, a second summary
   in one block, a summary nested in a summary, or one preceded by
   other content (`<details><div>x</div><summary>…`) fails rather than
   printing a merged, unattached, or misplaced label. A `<details>`
   opened while a `<summary>` is still open fails for the same reason:
   `<details><summary>Outer <details><summary>Inner</summary></details></summary></details>`
   would otherwise print both `Inner` and a corrupted `Outer Inner`. An empty summary
   fails for the same reason — a blank label cannot be reconciled.

   The missing-summary check is per `<details>` frame, not a single
   global check run once at the end. Each `details` frame records
   whether a `summary` opened inside it before that frame closes; a
   frame that closes with the flag still false is a parse failure
   naming the offset of its own opening tag. This matters because a
   body can contain one well-formed block — `<details><summary>...
   </summary>...</details>` — followed by a second, malformed one,
   `<details>hidden finding</details>`, with no `<summary>` at all. The
   first block already produces a label, so a check that only asks "is
   the labels list non-empty?" at the very end passes the whole body,
   silently accepting the second block's missing summary. Tracking the
   flag per frame instead of aggregating across the whole body is what
   catches that.

   **Near-miss tag names fail.** The tokenizer reads every tag, not
   only the two it models, and any tag name that begins `detail` or
   `summar` but is not exactly `details` or `summary` — a typo such as
   `<detail>`, or a custom element such as `<details-x>` — is a parse
   failure rather than an ignored tag. Other tags (`<p>`, `<strong>`,
   `<img>`) are skipped.

   **Scope this does not cover.** The masking follows CommonMark
   closely enough for review bodies, not exactly: it does not model
   indented (four-space) code blocks, raw HTML blocks, or code spans
   that wrap across lines. If a review body ever looks
   inconsistent with what step 3 reports — e.g. the web UI's rendered
   nesting implies a `<details>` wrapper the parser didn't count — read
   the raw fetched file by hand before trusting the extraction.

   Note that `<details>` blocks nest: a hidden-findings section can
   carry one collapsed block per finding inside it, so the label list
   legitimately mixes section headers (`Previously missed (1)`) with
   individual finding titles. Both are labels to account for — see
   step 5 for which of them earn a ledger row.

   The masking before tokenizing is load-bearing for the same reason:
   a finding whose prose quotes `<details>` or `<summary>` inside
   backticks would otherwise contribute a stray tag with no matching
   partner, and the stack would report a parse failure that is an
   artifact of the finding's own text rather than of the body's
   structure. Attested on this repo — an earlier, count-only version of
   this parser falsely failed on a review whose own prose quoted both
   tag names in backticks. Fenced blocks (backtick or tilde, any fence
   length), HTML comments, autolinks, backslash escapes, and inline
   code spans (any backtick run length) are masked, because GitHub
   renders none of them as markup. A backtick line whose info string
   contains a backtick (```` ```<summary>``` ````) is a code span, not a
   fence opener, as CommonMark specifies; treating it as a fence made a
   valid review fail as an unclosed fence (attested on this PR, review
   5295693766). Likewise an email autolink (`<summary@example.com>`)
   and an escaped `\<summary>` are text, not tags.
   Comments, autolinks, escapes, and code spans are found in one
   left-to-right pass, and whichever opens first wins: a code span
   quoting `` `<!--` `` is not a comment opener, a backtick inside a
   comment does not start a code span, and `` \` `` is a literal
   backtick. Masking comments in a separate pass first made a review
   that quoted `` `<!--` `` fail as an unclosed comment (attested on
   this PR, review 5295401637).
   Each is replaced with same-length whitespace rather than deleted, so
   every reported offset indexes the raw file; an unclosed fence or
   comment is a parse failure, because everything after it would
   otherwise be masked silently.

   Masking must not hide text from the reader, only from the stack. A
   stray backtick can pair with a later one on the same line and mask
   a whole real `<details>` block between them, and an HTML comment can
   carry tags the web UI never shows. So every `details`/`summary`-like
   tag found inside a masked region is printed after the labels as an
   `IN CODE SPAN` / `IN CODE FENCE` / `IN HTML COMMENT` line with its
   location. Each such line must be read in the raw file: it is either
   a quotation in finding prose (no action) or a block the masking
   swallowed (treat as a parse failure and read the section by hand).

4. **Fetch inline review comments separately, including each
   comment's body:**
   ```bash
   gh api repos/<owner>/<repo>/pulls/<n>/comments --paginate \
     --jq '.[] | {id, path, subject_type, line, original_line, original_commit_id, body, in_reply_to: .in_reply_to_id, review: .pull_request_review_id}' < /dev/null
   ```
   A `null` `line` has two meanings, told apart by `subject_type`. With
   `subject_type == "file"` it is a current file-level comment, attached
   to `path` as a whole: record it as a `path`-only ledger row. With
   `subject_type == "line"` it is an *outdated* comment — one whose diff
   location a later commit invalidated so GitHub can no longer map it
   onto the current diff. A later push alone does not outdate a comment:
   one whose hunk survives keeps a current `line`. For an outdated
   comment, record `original_line` at `original_commit_id` as the
   finding's location, and read the current file to find where that
   code now lives; a `null` line is not a missing location.

   Also fetch top-level PR comments, because step 6 records some replies
   there and a ledger rebuilt without them sees the finding but not its
   answer:
   ```bash
   gh api repos/<owner>/<repo>/issues/<n>/comments --paginate \
     --jq '.[] | {id, user: .user.login, created_at, body}' < /dev/null
   ```
   Match each against the ledger by the review id and section label the
   step 6 fallback requires it to cite.
   `body` is not optional in this projection: it is the finding text
   that step 5 must adjudicate and step 6 must answer. A projection
   that drops it — keeping only `id`/`path`/`line`/`review` — retrieves
   metadata sufficient to *count* comments but not to *read* them,
   which silently defeats the "read every finding" hard rule at the
   top of this section while still looking like a complete fetch.

   A review whose `/comments` carry no rows for that
   `pull_request_review_id` is **not** automatically suppressed-only —
   it may instead have raised no findings at all (a body reading
   `Findings: None`, with no hidden-findings label for step 3 to have
   found). Do not infer either shape from the comment count alone: read
   the body pulled in steps 2–3 for that review to tell "zero findings"
   apart from "findings exist but every one landed in a collapsed
   section" — only the second shape needs a ledger row.

5. **Build a ledger before replying to anything:** one row per finding
   (inline or hidden), each with its `path:line` (step 4's
   `original_line` for an outdated comment, `path` alone for a
   file-level one), source review id, and
   adjudication (fix / fix differently / decline). First decide, for
   each label step 3 printed, whether its block is a **container**, a
   **finding**, or **informational**, from the block's structure in the
   raw file, never from its label text: a container's content after its
   `<summary>` is a list of items — bullets or nested `<details>` blocks
   (printed indented beneath it) — one per finding; a finding's content
   is the finding's own prose; an informational block is anything else,
   typically an overview that mixes prose with a restatement of the
   review's findings. Attested as `What changed in this PR` on this
   repo: a verdict paragraph, a change list, and one bullet per finding
   repeating the review's inline comments by `path:line`. An
   informational block gets no ledger row and no count check, but it
   must still be read: check every finding it names against the ledger,
   and give any finding the ledger does not already cover a
   hidden-finding row of its own. Finding titles are free-form and can end in
   `(N)` too (`Handle all (3) cases`), so a trailing count is read only
   once a block is known to be a container; a container with no
   trailing count is a failure under the rules below, and a finding
   whose title happens to end in `(N)` is still a finding and gets a
   row. A container is then flagged for reconciliation, but reconciling
   it correctly requires first classifying *what population it
   aggregates* — its label text alone does not say. `Suppressed comments (N)`, `Previously missed (N)`,
   and `Open (N)` are all attested labels on real reviews, but they are
   not interchangeable: on one review, `Open (N)` nested items that
   each linked to a `#discussion_r<id>` anchor — i.e., findings already
   fetched as inline comments in step 4 — while `Previously missed (N)`
   nested body-only bullets with no comment object of their own. Do not
   assume any specific label name (`Open` included) always means
   "hidden findings with no comment object"; that was true for
   `Previously missed` and `Suppressed comments` on the reviews seen so
   far, but is a property to verify per section, not to infer from the
   name. Classify each aggregate section by its nested items' contents,
   into one of three populations:
   - **This review's inline comments** — items link to
     `#discussion_r<id>` anchors whose ids step 4 attributes to *this*
     review (`review` equals this review's id). Reconcile the count
     against step 4's inline-comment count for this review, counting
     only top-level rows (`in_reply_to` is `null`): a threaded reply is
     discussion on a finding, not a finding, and counting replies
     inflates the total once findings have been answered.
   - **Earlier reviews' comments** — items link to `#discussion_r<id>`
     anchors whose ids step 4 attributes to an *earlier* review.
     Attested as `Resolved since last review (N)`: on this repo, one
     such section counted 7 and linked the 7 comments of the previous
     review, while its own review had 1 inline comment. Reconcile the
     count against the number of linked ids, check every id exists in
     step 4's output under an earlier review, and add no ledger rows —
     those findings already have rows from their own review. Reading
     each item is still required: Copilot saying a finding is resolved
     is a claim to check against the ledger, not a reply.
   - **Hidden findings** — items carry no `#discussion_r` link. This
     ledger's hidden-finding row count for this review must match.

   A section whose items mix populations, or link an id step 4 does not
   return, is a parse failure under the rules below. A count mismatch,
   once reconciled against the correct population, means step 3 missed
   an entry or double-counted one, and the ledger is not trustworthy
   yet.

6. **Answer every ledger row** — a threaded reply for an inline
   comment, a *new* inline comment (cited to the finding's `path:line`)
   for a hidden one, a top-level PR comment only as a last resort for a
   finding that names no file. For a finding adjudicated fix or fix
   differently, reply after the fix lands, so the reply can cite a real
   commit SHA; for a declined finding there is no fix to wait for, so
   reply once the rationale for declining is settled, stating that
   rationale. GitHub rejects a new inline comment
   (HTTP 422) on a line outside the PR's current diff; a hidden finding
   on such a line gets a top-level PR comment instead, which must cite
   the finding's `path:line`, its source review id, and the section
   label it came from, so it stays traceable to the ledger row.

7. **Thread resolution belongs to the user, never the agent.** An
   agent must not resolve a review thread — by API, by GraphQL
   `resolveReviewThread`, or through any tool — regardless of whether
   the thread has been answered, the fix has landed, or the user asked
   for a clean or merge-ready PR. Once every ledger row has a reply and
   step 8's refresh gate has just been re-run clean, report the
   answered threads to the user and leave resolving them to the user,
   in the same way as merging (the hard rule in "Agent merge policy"
   below). A new inline comment for a hidden finding opens its own
   thread; it is part of what the user resolves, not something the
   agent clears as part of answering the finding.

8. **Re-run this refresh-and-reconciliation gate at three separate
   points, not once:** immediately before reporting threads as ready
   for the user to resolve, immediately before requesting merge
   permission, and immediately
   again right before executing the merge itself. Treat each of the
   three as its own mandatory pass whose result does not carry forward
   to the next — a review or a push can land in the window between any
   two of them, and the gap between "permission requested" and "merge
   executed" can be arbitrarily long if the user does not respond
   immediately.

   At each pass, re-run steps 1–4 and check the result actually covers
   the PR's current head SHA — don't assume a re-run does:
   ```bash
   gh pr view <n> --json headRefOid --jq .headRefOid < /dev/null
   ```
   Compare that value against the `commit_id` step 1 now records for
   each review, and check whether a Copilot review is still in flight:
   ```bash
   gh api repos/<owner>/<repo>/pulls/<n>/requested_reviewers \
     --jq '[.users[].login | select(test("opilot";"i"))] | length' < /dev/null
   ```
   A non-zero count means a review was requested and has not been
   submitted; wait for it rather than treating an in-flight review as
   equivalent to no review. Do not look for a `PENDING` review instead:
   GitHub shows a pending review only to its own author, so Copilot's
   in-progress review never appears in step 1's output.

   If no review's `commit_id` matches the current head and no review is
   in flight, the head is **unreviewed**, not reviewed: commits pushed
   after the last review — a fix, a rebase — have not been read by
   Copilot. Whether waiting can end this state depends on the repo's
   Copilot review rule, which has changed over this repo's life
   (push-triggered re-reviews were recorded in August 2026; the rule
   now has them off), so read it rather than assuming:
   ```bash
   ids=$(gh api repos/<owner>/<repo>/rulesets --paginate --jq '.[].id' < /dev/null) ||
     { echo "FETCH FAILED: rulesets list" >&2; exit 1; }
   while read -r id; do
     [ -n "$id" ] || continue
     gh api "repos/<owner>/<repo>/rulesets/$id" < /dev/null \
       --jq 'select(.enforcement=="active") | .rules[] | select(.type=="copilot_code_review") | .parameters.review_on_push' ||
       { echo "FETCH FAILED: ruleset $id" >&2; exit 1; }
   done <<< "$ids"
   ```
   The list is captured before the loop rather than piped into it, so
   a failed list call stops with an error instead of running zero
   iterations and printing nothing — which would read as the
   explicit-request case below. A `FETCH FAILED` line is a parse
   failure under the rules below, not an answer.
   If any active rule prints `true`, a push requests a review
   automatically: re-check `requested_reviewers` above, and wait for
   that review rather than declaring the head unreviewed. If the
   re-check reads zero, re-run step 1 before deciding anything — the
   automatic review may have been requested and submitted since step 1
   ran, leaving no request to wait for and a stale review list. If the
   re-run shows a review at the head, reconcile it as below; if not,
   the head is unreviewed. If every rule prints `false`, or none prints
   anything and no command failed, Copilot reviews only on an
   explicit request and waiting does not end this state. Once the ledger covers
   every review that exists, the gate passes for those reviews; report
   to the user that the head commit is unreviewed, name the commits
   since the last reviewed `commit_id`, and ask whether to request a
   fresh review before going further. Do not request one unasked, and
   do not describe the head as Copilot-clean.

   SHA coverage is necessary but not sufficient: it means the ledger
   includes *a* review at the current head, not that every finding in
   that review has been reconciled. **If a pass surfaces a review or
   comment the ledger does not already cover — new or otherwise — stop
   and run steps 5–6 for it (add ledger rows, answer them) before
   continuing to whichever of the three points triggered this pass.** A
   fresh review discovered mid-gate and left unreconciled is the exact
   failure this checklist exists to close, only deferred to a later
   re-run instead of skipped outright. The checklist is a gate on the
   state at each of these three moments, not a one-time pass earlier in
   the session.

### Strict parsing — no silent fallbacks

The checklist above only closes the gap it targets if each step's
output is checked against an explicit expectation and treated as a
hard stop when it isn't met. A script (or an agent skimming output)
that tolerates an empty body, an unrecognized `<summary>` label, or a
hidden-finding-count mismatch by quietly moving on has reintroduced the
exact "skim and hope" failure this section exists to replace —
best-effort parsing and silent fallbacks are what let a renamed or
newly introduced section disappear in the first place. Concretely:

- **No hardcoded allowlist of expected `<summary>` labels.** Step 3's
  extraction must not be followed by logic that only reacts to one
  known label (`Suppressed comments`, `Open`, or any other single
  string) and ignores every other match. Every distinct label step 3
  returns — including one that has never appeared on this repo before
  — must be read before the checklist can call this review accounted
  for. Not every label earns a ledger row, though: an aggregate section
  header — a block whose content is a list of per-finding items, e.g.
  `Open (7)` or `Previously missed (2)` — is the container, not a
  finding; only the individual findings nested inside it get rows.
  Container status comes from that structure (step 5), never from a
  trailing `(N)` alone, since a finding title can end in one too. An
  informational block (step 5), such as an overview, is neither: it
  gets no row and no count check, but every finding it names must be
  matched to a ledger row, and one that matches none gets its own
  hidden-finding row. But which count that container
  cross-checks against is not fixed by its label text — see step 5:
  a container whose nested items link to this review's inline comments
  reconciles against step 4's top-level (non-reply) count for this
  review, one whose items
  link to earlier reviews' comments reconciles against its own linked
  ids and adds no rows, and one whose nested items carry no such link
  is what step 5's one-row-per-finding ledger count must match. Adding
  the
  header itself as a row, or cross-checking it against the wrong
  population, inflates or corrupts the count step 5 checks and makes a
  correct ledger look wrong. Finding a label outside the known set,
  aggregate or not, is not a warning to log and continue past; treat it
  the same as any other checklist failure — stop and read the section,
  classify it as container, finding, or informational (and, if a
  container, which population it aggregates), before going further.
- **No silent fallback on an empty, missing, or truncated `body`.** If
  step 2's fetch returns an empty string, `null`, or a response that
  looks paginated/truncated, that is a fetch failure, not "this review
  had no findings." Re-fetch or fix the query before treating the
  review as accounted for; do not let an empty body pass the checklist
  by default.
- **Assert every aggregate section's count against its correct
  population; don't just eyeball it.** Step 5's cross-check must fail
  loudly when a container's `(N)` disagrees with whatever count it was
  classified against — the ledger's hidden-finding row count for a
  container whose nested items carry no `#discussion_r...` link, step
  4's top-level (non-reply) inline-comment count for this review when
  they link this
  review's comments, or the number of linked ids when they link an
  earlier review's.
  Which check applies is read from the classification step 5 requires,
  never hardcoded by label name, since the label text itself is exactly
  what has changed release over release and a given name (`Open`
  included) is not reliably tied to one population or the other:
  ```bash
  n_header=$(printf '%s\n' "$section_label" | sed -n 's/.*(\([0-9][0-9]*\))[[:space:]]*$/\1/p')
  [ -n "$n_header" ] || { echo "NO COUNT: label has no trailing (N): $section_label" >&2; exit 1; }
  n_actual=<count for the population this container was classified as>
  [ "$n_header" = "$n_actual" ] || { echo "MISMATCH: header=$n_header actual=$n_actual" >&2; exit 1; }
  ```
  The count is the label's *trailing* `(N)` only, so a label such as
  `Fix (a) thing (3)` reads as 3, and a label with no trailing count
  or an empty `()` stops with its own message rather than an empty
  comparison.
  where `$section_label` is one of the labels step 3 extracted (e.g.
  `Suppressed comments (3)`, `Previously missed (3)`, `Open (7)`) — any
  of them may aggregate either population, so the classification must
  come before the count comparison, not be inferred from the label
  string. A mismatch means the ledger is wrong, or the classification
  was wrong, and must be corrected before any reply goes out — it is
  never acceptable to round the two numbers together, defer the
  discrepancy, or proceed on the larger/smaller of the two as a guess.
- **A non-zero exit code or an API error from any command in steps
  1–4 is a parse failure, not "no findings."** Do not interpret a
  failed `gh api` call, a `jq` parse error, or an empty match set from
  a command that should have matched something as evidence the review
  is clean. Surface the failure and re-run the step; a checklist step
  that fails closed (stops the workflow) is correct behavior here,
  not a bug to route around.
- **A tag structure step 3 cannot parse — any `PARSE FAILURE` it
  exits with: a closing tag that does not match the innermost open
  one, an unclosed tag, code fence, or HTML comment, a missing, empty,
  or misplaced `<summary>`, a `<details>` opened inside a `<summary>`,
  a near-miss tag name beginning `detail` or `summar`, or such a tag
  left unparsable by an unbalanced quote or a name not followed by
  whitespace or `/` — is itself a
  finding.** Letter case and attributes are not failures: step 3
  accepts `<DETAILS>`, `<details open>`, and `<details title="a>b">`
  as ordinary tags. Nor is an `IN CODE SPAN` / `IN CODE FENCE` /
  `IN HTML COMMENT` / `IN AUTOLINK` line, which is
  text to read in context rather than a failure. Do not fall back to reading the rendered web page as a
  substitute (see step 2's rationale for why) and do not assume the
  section is decorative. Record the parse failure in the ledger, flag
  it explicitly to the user, and treat the review as unaccounted-for
  until it is resolved by hand.

The underlying principle: every step in the checklist has a
pass/fail condition, and "I didn't see anything unusual" is not the
same as verifying the condition. GitHub is free to keep changing this
UI; the checklist survives that only if unrecognized output halts the
workflow instead of being silently absorbed as "nothing new here."

### Mechanics reference

The Augment skill `copilot-review-replies`
(`~/.augment/skills/copilot-review-replies/SKILL.md`) codifies steps
4–6 above with copy-pasteable commands: the payload shape for each
reply endpoint, the endpoint asymmetry between fetching and posting a
review comment, and adjudication guidance (fix / fix differently /
decline — Copilot is confidently wrong often enough that accepting
every finding degrades the branch). Use it in an Augment session; the
checklist above is written to stand on its own for any agent or human
running this workflow without it.

## Agent merge policy (read this before any `gh pr merge`)

> **Hard rule:** An agent must **never** call `gh pr merge` (or
> the GitHub web "Merge pull request" button via any tool) on a
> PR it authored, regardless of CI state, regardless of whether
> the PR appears trivial, and regardless of how recently the user
> said "merge the previous one". A separate explicit "merge it"
> from the user is required for **every** merge, **every** time.

Branch protection's `required_approving_review_count: 0` exists so
that a *human* contributor can self-merge their own work without
having to round-trip a reviewer for trivial changes. Agents are
not human contributors. The PR-creation step, plus the user's
review of the diff, plus the user's explicit instruction to
merge, are the agent-authored equivalent of the review-and-merge
loop that protection rule was designed for.

This policy applies even when:

- CI is fully green and all required status checks pass.
- The PR is small (one commit, one file, one line).
- An earlier PR in the same session was merged with the user's
  permission. Permission does **not** carry forward to the next
  PR.
- The user said "fine, ship it" or similar about a *different*
  PR, even minutes earlier.
- The change reverts an earlier agent action (revert PRs also
  need explicit merge permission).
- AGENTS.md, CLAUDE.md, or any other doc says "self-merge once
  green" — that language is for human contributors. The rule in
  this section overrides it for agents.

The agent-side workflow is therefore:

1. Push the branch and open the PR (`gh pr create`).
2. Report the PR URL, the diff summary, and the CI status to the
   user.
3. **Stop.** Wait for explicit "merge it" / "go ahead and merge"
   / equivalent unambiguous instruction.
4. On receiving that instruction, `gh pr merge --squash
   --delete-branch` and report the merge result.

Recovery when this rule is broken: open a revert PR
(`git revert <squash-sha>` on a `revert/pr-<n>-<short-slug>`
branch, push, `gh pr create`) and stop at step 3 of the
workflow above. Do **not** auto-merge the revert PR either —
that would compound the original failure with the same
mistake.

## Branch Protection (read this before any `git commit`)

> **Hard rule:** Never run `git commit` while `HEAD` points at `main`
> (or `master`). The PR-only policy applies at *commit time*, not
> just push time — landing a change starts with `git switch -c`,
> not with staging on `main`.

Before staging anything, confirm the working branch:

```bash
git branch --show-current        # MUST NOT print 'main' or 'master'
```

If it does, create a feature branch first. The marker below
combines `$$` (shell PID) with `$(date +%s)` (epoch seconds) so it
is unique *per invocation*, not just per shell. A bare `$$` would
collide with a stale stash left by an aborted earlier run in the
same terminal — the second run's `git stash push` is a no-op on a
clean tree, and a `grep -qF "$m"` against the bare PID would match
the stale entry and pop it onto the new branch. The `stash@{/$m}`
lookup also selects the entry by message rather than stack
position, so an unrelated push at `refs/stash` between the create
and the pop cannot redirect a plain `git stash pop` onto the wrong
commit. A stash-count guard would only verify that *some* entry
was added — `refs/stash` is shared across worktrees, so it cannot
distinguish *our* entry from a sibling shell's. The `--index` flag
on the pop restores the staged/unstaged split as it was before
the stash; without it, files that were staged when the hook fired
come back as unstaged on the new branch and the obvious follow-up
`git commit` records nothing (or worse, an empty commit if
`--allow-empty` is in muscle memory):

```bash
m=park-pre-branch-$$-$(date +%s)
git stash push -u -m "$m"                # no-op if working tree is clean
git switch -c <type>/<short-slug>
git stash list | grep -qF "$m" && git stash pop --index "stash@{/$m}"
```

### One-time setup per clone

This repo ships `pre-commit`, `pre-merge-commit`, and `pre-push`
hooks under `tool/hooks/` that refuse direct work on `main`/
`master`. Activate them once per clone (git deliberately does not
version `.git/hooks/`, so the opt-in must be re-run on every fresh
clone):

```bash
git config core.hooksPath tool/hooks
```

Verify with:

```bash
git config --get core.hooksPath  # MUST print 'tool/hooks'
```

A fresh agent session that skips this step gets no local protection;
treat it as part of the standard ramp-up alongside `bd prime`.

### Recovery when the rule is broken

If a commit lands on a local protected branch despite the above
(the hook was off, or `--no-verify` was used), substitute
`<protected-branch>` with the branch the commit landed on
(`main` or `master` — the `pre-commit` and `pre-merge-commit`
hooks reject both):

```bash
# 1. Move the commit onto a feature branch
git switch -c <type>/<short-slug>          # branch tracks current HEAD

# 2. Reset local <protected-branch> to its remote
git switch <protected-branch>
git fetch --prune origin
git reset --hard origin/<protected-branch>

# 3. Resume on the feature branch
git switch <type>/<short-slug>
```

The recipe assumes `origin` tracks the canonical repository. If
you cloned from a fork (the common multi-remote layout has
`origin` pointing at the fork and a separate remote -- often
named `upstream` -- pointing at the canonical repo), substitute
that authoritative remote name for both `origin` references in
step 2. Resetting `<protected-branch>` against the fork would
adopt the fork's history rather than the canonical branch's;
this is the same caveat the `pre-push` hook prints in its
epilogue, mirrored here so the doc and the hook agree.

Then push the branch and open a PR via the standard loop in the
"Pull Request Workflow (mandatory)" section above. **Do not push
local `<protected-branch>`.** The two layers of defence are
asymmetric across the two branch names:

- For `main`, GitHub branch protection (with `enforce_admins: true`)
  refuses the push at the remote, and the local `pre-push` hook
  refuses it too provided `core.hooksPath` was activated for this
  clone (see "Local hook setup" in `DEVELOPMENT.md`).
- For `master`, no remote-side rule is configured in this repo —
  the local `pre-push` hook is the only line of defence. A
  contributor pushing `master` from a clone that has not run
  `git config core.hooksPath tool/hooks` will not be refused at
  the remote.

In practice `main` is the branch to substitute for almost every
contributor; `master` is covered locally for parity with the hook
alternation arms (the `pre-push` hook rejects `refs/heads/master`
just as it does `refs/heads/main`) so a clone that has only ever
known `master` -- e.g. an older fork, or a downstream that hasn't
renamed -- gets local-layer protection without needing a separate
recipe, even though it has no remote-layer protection in this
repo.

### Why this section exists

Branch protection on `main` is enforced at two layers, with CI
acting as the upstream source of the signals the remote layer
consumes:

1. **Local hooks** (`tool/hooks/pre-commit`,
   `tool/hooks/pre-merge-commit`, `tool/hooks/pre-push`) —
   `pre-commit` refuses to record a plain commit on local `main`/
   `master`; `pre-merge-commit` covers `git merge` *when git is
   about to record an actual merge commit* (which does not fire
   `pre-commit`); `pre-push` refuses to update `refs/heads/main`/
   `refs/heads/master` on the remote regardless of source branch.
   Two commit-time bypasses exist and are caught only at push
   time: (a) rebases that replay history onto local `main` (each
   replayed commit runs in detached HEAD, so `pre-commit` falls
   through), and (b) fast-forward merges (`git merge feature/foo`
   while `main` has no diverging commits advances the ref without
   creating a commit, so `pre-merge-commit` does not fire). In
   both cases the resulting `main` cannot be published without
   tripping `pre-push` and layer 2. All three hooks require
   activation per clone: `git config core.hooksPath tool/hooks`.
   Without activation, layer 1 contributes nothing.
2. **GitHub branch protection** — the rule on `main` does the
   actual blocking at the remote and consists of two configured
   gates:
     - The protection rule itself refuses direct pushes from
       non-admin contributors. `enforce_admins: true` extends
       that refusal to admin/owner accounts, closing the
       maintainer-bypass path that otherwise would let a single
       `git push` skip every required check (re-apply with
       `gh api -X POST /repos/<owner>/<repo>/branches/main/protection/enforce_admins`).
     - `required_status_checks` refuses the PR merge until the eight
       listed contexts (`Detect changed paths`, `Dart tests gate`,
       `Verify FRB bindings are in sync`, `Rust build + tests +
       coverage`, `Hooks shell-syntax check`, `Hooks behaviour
       check`, `Android KGP gate matrix`, `Auggie hook tests gate`)
       report success.

CI is not a separate enforcement layer — it does not gate the
merge. It runs the workflows that publish the status checks
`required_status_checks` reads, so a regression in the workflows
is the most common way the gate ends up reporting green on
something that should not merge. The two `Hooks *` jobs in
particular exist so a PR that touches only `tool/hooks/**` still
gets validated rather than skipping every heavy job and reaching
the merge gate unverified.

The hook layer exists because the remote layer can only act once
a commit already exists locally: the branch protection rule
refuses the push from non-admin contributors (and from admins too
once `enforce_admins: true` is set), and the
`required_status_checks` gate refuses the PR merge after CI
publishes its statuses. A direct commit on local `main` is a
recoverable mistake (either remote gate plus the linear-history
rule will refuse the eventual push or merge), but it consumes a
`git reflog` window and reorders the natural workflow. Layer 1
closes that window for the two common shapes (plain commit, merge
commit) when `core.hooksPath` is activated.

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Doc-Snippet Validator

`tool/check_doc_snippets.dart` extracts fenced `dart` code blocks from the
docs (README, CHANGELOG, ARCHITECTURE, `example/example.md`), wraps fragments
in a harness, and runs `dart analyze`. CI runs it via the "Verify
documentation snippets" step.

On failure it prints the failing doc file, snippet index, and the analyzer
diagnostics. The **wrapped snippet body is suppressed by default** so verbatim
doc source is never echoed into the retained GitHub Actions log. When triaging
a real failure, opt back in:

```bash
dart run tool/check_doc_snippets.dart --print-snippets
# or, equivalently:
SNIPPET_VALIDATOR_VERBOSE=1 dart run tool/check_doc_snippets.dart
```

Prefer `--print-snippets` **locally**: a best-effort redaction pass strips
obvious secret-shaped tokens before printing, but it is defence-in-depth, not
a guarantee. `--help` lists all flags.

## DoltHub Session Completion (overrides the auto-generated block below)

> **Maintainer-only.** Requires `bd` and a credentialed DoltHub remote.

DoltHub (`nick-llewellyn/nts` on dolthub.com) is the **authoritative** store
for Beads issues. The `bd dolt push` step in the auto-generated "Session
Completion" block below is a no-op without a configured remote — this section
replaces that shorthand with the full ordering required now that the remote
exists.

Fresh-clone prerequisite (one-time per clone, not committed):
```bash
bd init   # automatically configures the DoltHub remote via sync.git-remote
# Requires Dolt Credentials (key-based). Use `dolt login` or add your
# public key at https://www.dolthub.com/settings/credentials
```

### Automatic push via the Auggie hooks

In an Auggie session the push is automated: `.augment/settings.json` runs
`.augment/hooks/beads-sync.sh` on `PostToolUse` (matcher `launch-process`)
and on `SessionEnd`. After any command the scanner classifies as a bead
write (`bd create` / `close` / `update` / `config set` / … — anything not on
its read-only allow-list), the hook runs `bd dolt commit` followed by
`bd dolt push --remote origin` in the store that was written, under a lock
with a pending-marker so concurrent invocations and the 60 s hook timeout
cannot lose a write or double-push. `bd prime` is injected at
`SessionStart` by `.augment/hooks/beads-prime.sh`.

The hooks need `bd`, `jq`, `shfmt` and `python3` on `PATH` — `shfmt` and
`python3` are the command scanner, which parses each command's syntax tree
rather than pattern-matching its text. Without `jq` the hook cannot read its
event at all, so it reports that and stands down, leaving bead writes local.
Without the scanner it keeps going: it reports the failed scan and syncs the
workspace roots anyway, so only a store outside them can be missed — one
named by `bd -C <dir>`, `bd --db <path>`, `BEADS_DIR` or `BEADS_DB`, or
found by walking up from wherever the command ran.
`HOMEBREW_NO_AUTO_UPDATE=1 brew install jq shfmt` if either warning appears.

The scan is static. It follows assignments, `cd`, wrappers (`sudo`, `env`,
`timeout`, `xargs` and the like — so the `xargs -I{} bd assign …` audit
under "Assignee Convention" syncs), substitutions and `-c` scripts, but a
`bd` whose *command name* is only known at run time — `"$BD" close X`,
`$(printf bd) close X`, `${CMD:-bd} close X` — is indistinguishable from
`"$EDITOR" file`, and syncing on every computed command name would cost a
DoltHub round-trip each. Write `bd` literally, or
run `bd dolt push --remote origin` yourself afterwards. A target the scan
cannot name (a `-C` path built from a substitution, a pattern such as
`-C /tmp/store-*`, or a variable last assigned on a path that may not
have run) is reported as unresolved rather than guessed, and so is script
the scan cannot read at all (`eval "$X"`, `bash -c "$(…)"`); act on that
warning the same way.

**Act on hook warnings.** Failures are prefixed `beads:` — e.g. `beads:
'bd dolt push' failed in <root>, local bead writes are NOT on DoltHub.` —
and reach you on two channels: a `PostToolUse` failure is delivered as
`additionalContext` on the tool result, while a `SessionEnd` failure and
the missing-`jq` case (`beads: jq not found, …`, on every event) go to
the hook's stderr, since `SessionEnd` has no tool result to attach to.
Treat any such line, on either channel, as the blocking error below and
fall back to the manual sequence; do not assume the next invocation will
retry successfully.

The hook does `commit` + `push`, **not** `pull`. The pull-before-push
ordering below is therefore still on the agent: run `bd dolt pull` at
session start (before the first bead write) and again at session close so
conflicts surface locally rather than in a hook-driven push.

`core.hooksPath` stays `tool/hooks` (branch protection). The `bd` git shims
under `.beads/hooks/` are untracked and intentionally **not** activated —
git supports one hooks path, and the Auggie hooks cover the standalone `bd`
writes the shims would only catch on a git operation.

Their test suites stub `bd` and run against scratch workspaces, so they
never touch the real bead store. CI runs all three on ubuntu and macOS
whenever `.augment/**` changes (`Auggie hook tests gate`); run them locally
after editing a hook, under `/bin/bash` so macOS exercises bash 3.2:

```bash
/bin/bash .augment/hooks/test/classification_test.sh   # which commands count as writes
/bin/bash .augment/hooks/test/prime_test.sh            # session-start context injection
/bin/bash .augment/hooks/test/lock_test.sh             # lock and pending-marker handoff (~7 min)
```

### Manual sequence (fallback, and the session-close order)

Required outside Auggie (Claude Code, Codex, a plain shell), whenever a
hook reported a `beads:` warning, and at every session close regardless —
the hook has no `pull` step and cannot verify the store is up to date.

1. `git pull --rebase` — catch up code changes from `origin/main`.
2. `bd dolt pull` — pull Beads commits from DoltHub **before** pushing local
   changes. Surfaces merge conflicts here, not on push. Resolve any conflicts
   with `bd dolt status` before proceeding.
3. `bd dolt push --remote origin` — **blocking requirement**. Work is not
   complete until this succeeds (a no-op when the hook already pushed
   everything). A failed push means the session's issue changes are not on
   DoltHub; fix auth / connectivity and retry until it succeeds.
4. Commit and push the code branch via the standard
   [Pull Request Workflow](#pull-request-workflow-mandatory).

```bash
# Full push sequence
git pull --rebase
bd dolt pull
# resolve any bd dolt status conflicts here
bd dolt push --remote origin          # MUST succeed before opening the PR
git push -u origin HEAD
gh pr create --fill
git status  # MUST show "up to date with origin"
```

**CRITICAL:** `bd dolt push --remote origin` failing — whether reported by
the hook or by the manual command — is a blocking error. Do not open the
PR, do not stop the session — fix the push first.

> **Maintainer-only.** The auto-generated block below — "Beads Issue
> Tracker" and "Session Completion" — requires `bd` and a credentialed
> DoltHub remote. The note sits outside the generated markers so
> regenerating the block does not drop it.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Linear Sync Configuration

> **Maintainer-only.** Requires `bd` and a `LINEAR_API_KEY`. Applies
> to every subsection through "Troubleshooting".

This project syncs `bd` issues to **Linear** (workspace `nick-llewellyn`, team `nts`).

### Workspace Identifiers

| Field | Value |
|---|---|
| Team | `nts` |
| Team ID | `331d8088-688e-4385-84ab-aa9642909146` |
| Project | `nts` |
| Project ID | `6cde53e1-e9e3-423b-a8a4-478bdf116d7f` |

### Initial Setup (per clone)

```bash
bd config set linear.team_id "331d8088-688e-4385-84ab-aa9642909146"
bd config set linear.project_id "6cde53e1-e9e3-423b-a8a4-478bdf116d7f"
```

The `LINEAR_API_KEY` is stored in the macOS Keychain and exported lazily via `~/.zshrc`. To verify it is set without revealing the value, run `[ -n "$LINEAR_API_KEY" ] && echo "set" || echo "not set"` before syncing.

### Sync Workflow

Always pull before pushing to avoid creating duplicates and to surface
conflicts locally:

```bash
bd linear sync --pull          # import from Linear first
bd linear sync --push          # then export local changes
```

`bd 1.0.5` adds several flags worth knowing (all confirmed via
`bd linear sync --help`):

| Flag | Purpose |
|---|---|
| `--prefer-linear` / `--prefer-local` | Conflict resolution — force one side to win when timestamps diverge. `--prefer-linear` is the *intended* way to make a pull adopt Linear's terminal state, but its behaviour is **unreliable in both directions**: it may fail to adopt Linear's state at all (see "Pull won't adopt Linear's state"), and when it *does* take it can flatten local-only fields such as `issue_type` as collateral (see "`--prefer-linear` flattens `issue_type`"). Verify both status *and* type after every `--prefer-linear` pull. |
| `--pull-if-stale [--threshold 20m]` | Pull only if the local Linear cache is older than the threshold (default 20m). This is the source of the recurring `⚠ Linear data is … stale` warning. |
| `--state` (`open`, `closed`, or `all`) | Restrict the sync to issues in a given local state (default `all`). |
| `--issues a,b` / `--parent TICKET` | Scope a push to specific beads or a ticket subtree. **Required** for any push that must succeed reliably — see Gotcha #4. |
| `--create-only` | On push, only create new Linear issues; never update existing ones. |
| `--relations` | On pull, import Linear blocking relations as bd dependencies. |
| `--milestones` | On pull, reconstruct Linear project milestones as local epic parents. |
| `--type t` / `--exclude-type t` | Filter the sync to/from specific issue types. |

### Claiming an issue

`bd update <id> --claim` (and `bd update <id> --status in_progress`) write only
to the local Dolt database. They do **not** notify Linear. Until an explicit
push is performed, Linear still shows the issue as "Todo" or whatever state it
was in before the claim.

> **Auggie sessions.** The `PostToolUse` hook pushes to DoltHub immediately
> after each `bd` write — before the `bd dolt pull` in the recipes below
> and in "Closing an issue". That ordering is what the manual recipes were
> written to avoid, so run `bd dolt pull` **once at session start**, before
> the first bead write, to keep the local store current; the trailing
> `bd dolt pull` / `bd dolt push --remote origin` pairs then remain
> correct as the fallback and as the session-close verification. See
> "Automatic push via the Auggie hooks" above.

The correct sequence for claiming an issue is:

```bash
# 1. Claim locally.
bd update <id> --claim          # or: bd update <id> --status in_progress

# 2. Push the updated state to Linear. ALWAYS scope with --issues — an
#    unscoped push errors on the workspace's ambiguous state_map (Gotcha #4).
bd linear sync --push --issues <id>

# 3. Persist to DoltHub using the mandatory pull-then-push order (see
#    "DoltHub Session Completion") — pull first to surface conflicts locally.
bd dolt pull
bd dolt push --remote origin
```

A scoped single-issue push of an `in_progress` bead succeeds in practice (the
name-keyed `In Progress = in_progress` override resolves the started-type
ambiguity). Do this **before** opening a branch or writing any code, so Linear
reflects "In Progress" for the full duration of the work.

Alternatively — and more robustly — let the **Linear GitHub app** drive the
status: opening the PR transitions the linked issue to "In Progress"
automatically (see "Linear PR Linking"). The manual push above only matters for
the window between claiming and opening the PR.

### Closing an issue

`bd close` writes only to the local Dolt database. It does **not** notify
Linear. Running `bd dolt push --remote origin` afterwards persists the `CLOSED`
state to DoltHub but still does not touch Linear.

**Preferred path: let the PR close the issue.** Merging the linked PR
transitions the Linear issue to "Done" automatically (Linear GitHub app), which
side-steps the push-side mapping ambiguity entirely. A subsequent
`bd linear sync --pull --prefer-linear` is *intended* to import that "Done" as a
local `CLOSED` (see "Issue State Synchronization"), but in practice the pull is
**unreliable** — see the "Pull won't adopt Linear's state" troubleshooting entry
and the manual `bd close` fallback below, which is the expected reconciliation,
not an exceptional one.

When the pull *does* adopt Linear's state, audit `issue_type` on every bead it
reports as updated before pushing to DoltHub — `--prefer-linear` flattens that
field to `task`. See "`--prefer-linear` flattens `issue_type`".

**Manual fallback** (the `--prefer-linear` pull did not adopt Linear's state —
the common case — or the issue was abandoned, or the GitHub integration did not
fire):

```bash
# 1. Close locally, then persist to DoltHub using the mandatory pull-then-push
#    order (see "DoltHub Session Completion") — pull first to surface conflicts.
bd close <id>
bd dolt pull
bd dolt push --remote origin

# 2. Transition Linear to Done directly — do NOT rely on a push to map it.
#    Use the save_issue_linear tool or the Linear UI:
#      save_issue_linear id="<LINEAR-ID>" state="Done"
```

Whether `bd linear sync --push` maps a local `CLOSED` to Linear **Done** or
**Canceled** is **not reliably determined** for this workspace — the
`completed` and `canceled` types both map to `closed`, leaving the push inverse
ambiguous (Gotcha #1, investigated in NTS-29). A `closed`-only push does not
*error*, but the resulting Linear state is unverified for a non-terminal
target. Set the terminal Linear state **explicitly** (step 2 above) rather than
trusting a push, and prefer the PR-merge path whenever possible.

### Known Gotchas (read before every sync)

> **`bd 1.0.5` note.** These behaviours were re-verified against `bd 1.0.5`
> (Homebrew) this session. `bd 1.0.5` did **not** retire the workarounds below;
> its hardened push validator (upstream PR #3328) actually *tightened* sync,
> introducing Gotcha #4. Treat the pull-centric, scoped-push flow as mandatory,
> not optional.

#### 1. Status Mapping: CLOSED → Done vs Canceled is ambiguous

`bd`'s `linear.state_map` maps Linear **state types** to beads statuses, and the
sensible defaults map *both* `completed` **and** `canceled` to `closed`. That
makes the **push inverse ambiguous**: a local `CLOSED` has no single,
deterministic Linear target, so it may land as **Canceled** rather than
**Done**.

This workspace carries name-keyed overrides (`linear.state_map.Done = closed`,
`In Progress = in_progress`, `Todo = open`) that *attempt* to disambiguate. A
`closed`-only push no longer errors, but **whether it produces Done or Canceled
for a non-terminal Linear target is unverified** — do not assume it is fixed.

**Workaround:** Do not trust a push to set the terminal Linear state. Set
**Done** explicitly (Linear UI or `save_issue_linear` with `state: "Done"`),
or — better — let the PR-merge webhook transition it (see "Closing an issue").

**Tracking:** NTS-29 (Done) is the full investigation record; NTS-8 (open)
tracks the underlying `bd`-side mapping limitation.

#### 2. State Clobbering: Manual Linear Edits Can Be Overwritten

A push re-applies local state and can **overwrite manual status changes made
directly in Linear** (e.g. a hand-set **Done** reverting if the local state
re-maps differently).

**Mitigations in `bd 1.0.5`:**
- **Conflict-resolution flags** — `--prefer-local` / `--prefer-linear` make the
  winning side explicit instead of relying on newer-timestamp-wins.
- **Scope every push** with `--issues` (or `--parent`) so a broad sync cannot
  touch issues you did not intend.

**Rule:** After correcting statuses in Linear, never run a blind, unscoped
`bd linear sync --push`. Scope it, and reach for `--prefer-linear` when Linear
should win.

#### 3. Push Only Touches Linked Issues (intentional, hardened)

An unscoped `bd linear sync --push` only updates issues that already have an
`external_ref`; locally-created issues that have never been linked are skipped.
As of `bd 1.0.5` this is **intentional, hardened behaviour**, not a bug — the
`"Linear data has never been pulled"` warning is the signal.

**To create new Linear issues from local beads,** use `--create-only` with an
explicit scope, after a pull:

```bash
bd linear sync --pull
bd linear sync --push --create-only --issues nts-abc,nts-def
```

…but note this create path is itself subject to Gotcha #4. When it errors, the
reliable fallback is to **create the Linear issue directly** (`save_issue_linear`)
and link the bead's `external_ref` to its URL, then use an `NTS-<n>` branch so
the Linear GitHub app attaches the PR.

#### 4. `bd 1.0.5` Push Ambiguity Rejection (the new failure mode)

`bd 1.0.5`'s push validator (upstream PR #3328) **errors** rather than guessing
when the `state_map` is ambiguous:

```text
linear.state_map maps beads status X to multiple Linear states
```

The nts team triggers this because it has **two started-type states**
(*In Progress*, *In Review*) and **two open-ish states** (*Backlog* = backlog,
*Todo* = unstarted). The beads → Linear inverse for `open` and `in_progress` is
therefore non-deterministic. Per NTS-29, **every** `state_map` variant tried
(display-name keys, type-based keys, name-keyed overrides) errored on either the
`open` or `in_progress` ambiguity; the config was restored to its original state
with no net change. Upstream PR #3500 (dotted state-NAME keys) is the candidate
fix but needs source-level investigation of the validator's grouping.

**Practical consequences:**
- **Always scope pushes** with `--issues` / `--parent`. A single linked,
  `in_progress` issue pushes fine (the `In Progress` override resolves the
  started-type case); broad unscoped pushes are the ones that error.
- **Do not rely on push to create `NTS-` IDs** for brand-new beads — create the
  Linear issue directly and link `external_ref` (see Gotcha #3).
- This is a `bd`/workspace limitation, not something to "fix" by editing the map
  blindly — NTS-29 already established that no config variant resolves it.

### Troubleshooting

#### Push fails: "maps beads status … to multiple Linear states"

This is Gotcha #4. The push you ran was unscoped (or spanned `open`/
`in_progress` issues). Re-run it scoped to a single linked issue:

```bash
bd linear sync --push --issues <id>
```

For brand-new issues, create the Linear side directly (`save_issue_linear`)
instead of pushing. See Gotcha #4 for the full explanation.

#### Pull won't adopt Linear's state (e.g. a merged issue stays open locally)

`bd`'s default conflict resolution is newer-timestamp-wins; local edits (claims,
pushes) can bump the local `updatedAt` so a plain pull keeps the local state.
The documented first move is to force Linear to win:

```bash
bd linear sync --pull --prefer-linear
```

**Caveat (observed, not theoretical):** `--prefer-linear` is **not reliable**
for this. During the NTS-40 close it was run twice against an issue Linear
already showed as **Done**, and the local bead stayed `in_progress` both times.
When `--prefer-linear` does not take, reconcile manually — Linear is the
authoritative side, so close the local bead to match and persist to DoltHub:

```bash
bd close <id>                 # match Linear's terminal state locally
bd dolt pull                  # MANDATORY before any push — surface conflicts here
bd dolt push --remote origin
```

The `bd dolt pull` step is not optional: per "DoltHub Session Completion" the
mandatory push order is always pull-then-push, so DoltHub conflicts surface
locally rather than on the push. This is the same manual reconciliation as in
"Closing an issue"; the only new point is that it is required **even after
`--prefer-linear`**, not just when the PR webhook failed to fire. This is an
upstream `bd` limitation, not a repo-fixable bug (investigated under NTS-8;
push-side counterpart under NTS-29).

#### `--prefer-linear` flattens `issue_type` on the beads it updates

This is the **inverse** failure mode of the entry above, and it bites on the
runs where `--prefer-linear` *works*. Linear has no equivalent of the beads
`issue_type` field (`epic`, `bug`, `chore`, `task`, …), so "Linear wins"
resolves that field to the default `task` rather than leaving it untouched.
Every bead the pull reports as updated loses its type.

Observed during the NTS-126 close: a `--prefer-linear` pull correctly adopted
Linear's **Done** for `nts-r11f.5`, reported
`✓ Pulled 2 issues (0 created, 2 updated)`, and silently reset `nts-r11f` from
`epic` → `task` and `nts-r11f.5` from `bug` → `task`. Only the status change
was intended.

The `N updated` count is the signal — it includes beads touched purely as
collateral, such as the parent epic, not just the one whose status changed.

**Always audit types after a `--prefer-linear` pull, before `bd dolt push`:**

```bash
bd linear sync --pull --prefer-linear    # note the "N updated" count

# Inspect every bead the pull touched, not just the one you were closing.
bd show <id>                             # header shows e.g. "[EPIC] … Type: epic"

# Restore any flattened type, then persist.
bd update <id> -t epic                   # or: bug, chore, task
bd dolt pull                             # MANDATORY before any push
bd dolt push --remote origin
```

Catching this **before** the DoltHub push matters: pushing first propagates the
flattened types to the authoritative database, so the epic/bug distinction has
to be reconstructed from memory rather than read back off the local state.

`bd show <id> --json` returns a **list**, not an object, so a `json.load(...)`
that assumes a dict fails with
`AttributeError: 'list' object has no attribute 'items'`.
Unwrap it (`d[0] if isinstance(d, list) else d`) when scripting the audit.

Upstream `bd` limitation like its sibling above, tracked under NTS-8.

#### Recurring `⚠ Linear data is … stale` warning

The local Linear cache has a staleness clock. Either pull, or gate pulls on the
threshold so they only run when actually stale:

```bash
bd linear sync --pull-if-stale                 # default 20m threshold
bd linear sync --pull-if-stale --threshold 5m  # pull if older than 5 minutes
```

#### GraphQL Argument Validation Error

If `bd linear sync` fails with a "GraphQL Argument Validation" error, the stored
sync timestamp is stale (usually from a different workspace). Reset it:

```bash
bd config set linear.last_sync "0001-01-01T00:00:00Z"
```

Then retry the sync.

## Assignee Convention

> **Maintainer-only.** Requires `bd`. Contributors do not assign
> issues; nothing on the pull request path reads this field.

This is a single-developer repository. Every issue — whether created locally
with `bd` or imported from Linear — must have its `assignee` set to
`nllewelln@gmail.com`. That is the field Linear recognises for this workspace,
so assignments round-trip across `bd linear sync` without a separate
user-mapping table.

In `bd` 1.0.5 `owner` and `assignee` are **distinct fields**, and the
convention targets `assignee` deliberately. `owner` is auto-derived from the
actor (git `user.name` / `user.email`) at `bd create` time and has **no CLI
setter** — `bd assign` and `bd update --assignee` write `assignee` only.
Locally-created beads get `owner` populated automatically; beads that arrive
via `bd linear sync --pull` land with `owner` unset and there is no sanctioned
way to backfill it. `assignee`, by contrast, is settable and round-trips to
Linear, so it is the field the audit below checks.

`bd` does not expose a `default.assignee` config key, so the rule is
agent-enforced rather than tool-enforced. The agent operating this repo
must apply it on every relevant command:

1. **Local creation.** Always pass `-a nllewelln@gmail.com` (or
   `--assignee nllewelln@gmail.com`) to `bd create`:

   ```bash
   bd create "Title" -a nllewelln@gmail.com -t task -p 2
   ```

2. **Linear pull.** `bd linear sync --pull` does not honour any default
   assignee — issues whose Linear assignee is unset land in the local
   database with an empty `assignee`. Immediately after every pull, backfill:

   ```bash
   bd linear sync --pull
   bd list --json \
     | python3 -c 'import json,sys;[print(i["id"]) for i in json.load(sys.stdin) if not i.get("assignee")]' \
     | xargs -I{} bd assign {} nllewelln@gmail.com
   ```

3. **Audit on every session.** Before claiming new work, run the same
   one-liner to catch anything that slipped through (manual `bd create`
   calls without the flag, third-party imports, schema migrations):

   ```bash
   bd list --json \
     | python3 -c 'import json,sys;[print(i["id"]) for i in json.load(sys.stdin) if not i.get("assignee")]' \
     | xargs -I{} bd assign {} nllewelln@gmail.com
   ```

   A silent run means zero unassigned issues. Note that Linear-imported beads
   may still show an empty `owner` (e.g. `nts-gbqn4m` / NTS-8); that is
   expected and harmless, because `owner` has no CLI setter and this audit
   tracks `assignee`, not `owner`.

`bd` filters assignee strings by exact match, so any divergence (e.g.
`Nicholas Llewellyn`, `nick.l`, capitalisation drift) will silently
fragment the database. Stick to the canonical `nllewelln@gmail.com`.


## Communication & Reference Convention

> **Maintainer-only.** Requires `bd` and Linear. Contributors have no
> Linear identifier to cite; name the GitHub issue instead, and use
> `<type>/<short-slug>` for the branch.

To ensure the human developer can easily map local activity to the Linear project:
1. **Use the Linear ID.** Every mention of an issue in chat or PR descriptions should use the Linear ID (e.g. `NTS-26`). The Beads ID is an internal detail of the local Dolt database and does not need to appear in branch names, PR titles, or PR bodies.
2. **Retrieving Mappings.** The Beads issue and Linear issue are already
   linked via the `external_ref` field in the local Dolt database. To go in
   either direction:
   - **Linear ID → Beads ID:** `bd search "NTS-26"` returns the Beads ID
     (e.g. `nts-6rh`).
   - **Beads ID → Linear ID:** `bd show nts-6rh` (or `bd show nts-6rh
     --json | jq -r .external_ref`) returns the Linear URL containing the
     identifier.
3. **Branch Naming.** Use `<type>/NTS-<num>-<slug>` (e.g.
   `feat/NTS-26-link-github-pr`). The Linear ID alone is sufficient — the
   Linear-GitHub app triggers on it, and the Beads issue is reachable via
   `bd search "NTS-26"`.

## Linear PR Linking

> **Maintainer-only.** The Linear GitHub app acts on identifiers the
> maintainer's issues carry; a contributor branch has none and is
> unaffected.

PR ↔ Linear-issue linkage and status tracking are handled automatically by
the **Linear GitHub app**. The app watches for the Linear identifier (e.g.
`NTS-26`) in the branch name, PR title, or PR description.

1. **Auto-Linkage.** As long as the branch name carries the Linear ID (e.g.
   `feat/NTS-26-link-github-pr`), Linear will automatically attach the PR
   to the issue.
2. **Auto-Status (Opened → In Progress).** Opening the PR automatically
   transitions the Linear issue to "In Progress".
3. **Auto-Status (Merged → Done).** Merging the PR in GitHub automatically
   transitions the Linear issue to "Done".
4. **Branch Format.** The Linear workspace is configured with the
   `identifier-title` branch format. This ensures that any branches
   manually generated via the Linear UI carry the required identifier
   and a readable slug, maintaining consistency with agent-authored
   branches.

## Issue State Synchronization

> **Maintainer-only.** Requires `bd`, a `LINEAR_API_KEY`, and a
> credentialed DoltHub remote.

Because of the automatic "Merged → Done" transition, agents should prefer
a **pull-centric** synchronization flow:

1. **Pull to Close.** At the start of a new session (or after a merge), run
   `bd linear sync --pull --prefer-linear`. The `--prefer-linear` flag matters:
   `bd`'s default newer-timestamp-wins conflict resolution means a plain
   `--pull` can *keep* a stale local `IN_PROGRESS`/`OPEN` when local edits (a
   claim, a push) bumped the local `updatedAt` after the Linear "Done".
   `--prefer-linear` is *intended* to make Linear's terminal state win,
   importing it as a local `CLOSED`. In practice this is **unreliable** — see
   "Pull won't adopt Linear's state" in Troubleshooting; an observed
   `--prefer-linear` pull left the local bead `in_progress` despite Linear
   showing **Done**. Treat the manual `bd close` reconciliation in step 4 as the
   expected fallback, not an exceptional one.
2. **Audit `issue_type`.** When the pull *does* take, it flattens
   `issue_type` to `task` on every bead it reports as updated — including
   ones touched only as collateral, such as the parent epic. Check each with
   `bd show <id>` and restore with `bd update <id> -t <type>` **before** the
   DoltHub push, or the flattened types become authoritative. See
   "`--prefer-linear` flattens `issue_type`" in Troubleshooting.
3. **DoltHub Sync.** After the pull and the type audit, persist the closed
   state to the authoritative database using the mandatory pull-then-push
   order from "DoltHub Session Completion" — `bd dolt pull` first to surface
   any conflicts locally, then `bd dolt push --remote origin`.
4. **Manual Fallback.** Manually run `bd close` whenever the `--prefer-linear`
   pull does not adopt Linear's terminal state (the common case when local edits
   bumped the local timestamp), as well as when the issue was abandoned or the
   GitHub integration failed to trigger. Do **not** rely on
   `bd linear sync --push` to set the terminal Linear state — its `CLOSED`
   inverse is ambiguous (Gotcha #1). Prefer letting the PR-merge webhook set
   **Done**, or set it explicitly via `save_issue_linear`.

## Versioning & Release Policy

This project follows a **release-only bumping** policy: metadata version
fields are not touched during ordinary feature work. Bumps land in a
dedicated release commit so that feature branches stay clean and the
version number on `main` always reflects the most recently *released*
artefact, not work-in-progress.

### Rules

1. **Metadata files stay at the current stable version during
   development.** Do not edit the `version:` field in `pubspec.yaml` or
   the `version = ` field in `rust/Cargo.toml` in any non-release PR —
   `feat`, `fix`, `refactor`, `chore`, `test`, and `docs` alike. They
   must remain pinned to the last released version (e.g. `5.1.0` /
   `0.5.0`) until the release commit lands.

2. **Document ongoing work under the next intended release header in
   `CHANGELOG.md`.** Do **not** use an `## Unreleased` section — file
   entries directly under the target version header (e.g. `## 5.1`,
   `## 5.2`). This makes the intended landing place explicit and
   avoids a separate "move entries from Unreleased → version" step at
   release time. The header may be a two-component version (`## 5.1`)
   while patch-level work is still accumulating; promote it to a full
   three-component header (`## 5.1.0`) only when the release commit
   itself lands.

3. **Bumps land in a dedicated release commit.** When preparing to cut
   a release, a single commit must:
   - increment `pubspec.yaml` to the new version,
   - increment `rust/Cargo.toml` **only if the Rust crate changed**
     since the previous release (any diff under `rust/` other than
     the version field itself). The two version numbers are
     independent — the Dart package and the Rust crate each follow
     semver against their own surface, so a Dart-only release leaves
     the crate version untouched,
   - finalise the `CHANGELOG.md` header for that release (e.g.
     `## 5.1` → `## 5.1.0`, or add the patch component for a point
     release),
   - contain no other functional changes.

4. **Compatibility exception.** If a Rust crate version increment is
   strictly required mid-feature for technical compatibility (e.g. a
   dependency-resolution constraint that cannot be expressed any other
   way), the bump may land in the feature PR. Document the reason in
   the PR description. The default action is to revert.

5. **A runtime behaviour change to a public Dart API forces a major
   bump.** If an existing caller's code still compiles and still
   resolves but *behaves differently* — a different return value, a
   different post-condition, a different error or lifecycle outcome —
   the release is major, not minor. This holds regardless of who
   caused the change: "forced by an upstream dependency" explains why
   the change is unavoidable, not why it is compatible. A consumer
   with an automated minor-version bump has no way to distinguish the
   two. Narrowness of the affected surface is likewise not an
   exemption; it is an argument that few will be affected, not that
   none will.

   Changes that only make a previously-resolving `pubspec.yaml` fail
   to resolve — most often a tightened dependency constraint — are
   **not** covered by this rule. They fail loudly at solve time, before
   any code runs, and are ordinary for a minor release.

6. **Deviating from rule 5 requires an explicit, recorded decision.**
   Shipping a runtime behaviour change as a minor may still be the
   right call — typically when the same release carries a
   resolution-blocking fix that a major would strand behind a
   constraint most consumers will not cross. When that applies:
   - state the reasoning in the release PR description,
   - describe the behaviour change and its blast radius in the
     `CHANGELOG.md` entry, not just the mechanism,
   - file an issue recording the deviation so the precedent is
     visible at the next release rather than inferred from history.

   Founding case (in flight at the time of writing; the latest
   published release is `9.2.1`): `9.3.0` is being cut as a minor
   despite the `flutter_rust_bridge` 2.13.0 `dispose()` semantics
   change, because the same release fixes a resolution failure (#320)
   for apps on `flutter_rust_bridge: ^2.13.0`; cutting `10.0.0` would
   have left every consumer on a `^9` constraint blocked by the bug
   the release existed to fix. Once it publishes, this is the
   precedent to reason from.

### Rationale

Version drift across feature branches (each branch carrying its own
speculative `+1` bump) produces noisy diffs at merge time and makes
the version field on `main` an unreliable indicator of what was
actually shipped. Concentrating bumps in a release commit also gives
the release a single, greppable handle for revert/cherry-pick
purposes.

Rules 5 and 6 exist because the compatible-looking case is the
dangerous one. A tightened constraint announces itself: the resolver
refuses, and the consumer reads an error before shipping. A changed
post-condition does not — it resolves, compiles, passes any suite that
does not happen to cover the affected behaviour, and surfaces in
production. A suite that *does* assert the old post-condition fails,
which is the good case; the dangerous one is the consumer whose tests
never pinned it. Making
the major bump the default for that class, and the minor an exception
that has to be written down, means the judgement is made deliberately
each time instead of by whichever framing came to hand.

## Issue References in Shipped Files

Anything that reaches a consumer must cite a reference that consumer
can open. Internal tracker identifiers cannot be: `linear.app` URLs
require workspace membership, and Beads IDs (`nts-abcd`) name rows in
a database that is not part of the package.

### Rules

1. **`CHANGELOG.md` cites the GitHub PR, never a tracker ID.** Use the
   linked form the file already uses —
   `([#328](https://github.com/nick-llewellyn/nts/pull/328))` — rather
   than a bare `#328`, because pub.dev renders the changelog outside
   the repository context that auto-links it. Cite the issue instead
   (`.../issues/320`) when the entry is better explained by the report
   than by the change.

2. **The same rule covers the rest of the consumer-facing prose**:
   `README.md`, `example/example.md`, the guides under `doc/` and
   `example/`, and dartdoc on public Dart API. These are the surfaces
   pub.dev renders, or that a consumer reads to use the package.

3. **Everything else keeps its `NTS-` references.** The test is
   whether a consumer *reads* the prose, not whether the file ships —
   those are different sets, in both directions:

   - Not shipped, and internal by audience too: `DEVELOPMENT.md`,
     `ARCHITECTURE.md`, `CONTRIBUTING.md`, `AGENTS.md`, `CLAUDE.md`,
     `tool/` scripts, and CI workflows, all excluded by `.pubignore`
     or by pub's own rules.
   - **Shipped, but implementation-facing**: Rust sources under
     `rust/src/`, `android/build.gradle.kts`, and the Kotlin under
     `android/src/`. These are build inputs — Native Assets compiles
     the Rust, Gradle consumes the script — and nothing renders their
     comments. Their audience is whoever next edits the code, for whom
     a tracker ID carries provenance a PR number does not, and who has
     access to it.

4. **Internal identifiers stay in commit bodies, branch names, and PR
   descriptions.** That is where the tracker linkage already lives —
   the Linear GitHub app reads the identifier off the branch name —
   so nothing is lost by keeping it out of the shipped text.

5. **Already-published sections are not rewritten.** Entries under a
   released version header are a historical record; correcting their
   references churns the diff without helping anyone, since the
   release they describe already shipped with the old text. The rule
   applies from the next unreleased entry onwards.

## Security: Zeroization

This project treats specific byte sequences as secrets that must not
linger in freed allocations: AEAD key material
(`rust/src/nts/aead.rs`), NTS cookies (`rust/src/nts/cookies.rs`,
`rust/src/nts/ntp.rs`, `rust/src/api/nts.rs`), the TLS exporter
outputs that derive the C2S / S2C keys (`rust/src/nts/ke.rs`), and
user-supplied root certificate bytes (`CustomRootsBytes` in
`rust/src/nts/ke.rs`). The conventions below apply uniformly to all
of these.

### Conventions

1. **Wrap heap-allocated secret bytes in `Zeroizing<Vec<u8>>` (or
   `Zeroizing<Box<[u8]>>`).** The `zeroize` crate's `Drop` impl wipes
   the backing allocation before it is returned to the allocator.

2. **Pin `zeroize ≥ 1.8`.** Its `impl Zeroize for Vec<T>` wipes the
   full capacity (`self.spare_capacity_mut().zeroize()`, added in
   1.8), so secrets stored in a `Vec<u8>` cannot leak via spare
   capacity at drop time. The lower bound is documented in
   `rust/Cargo.toml` next to the dep. Downgrading silently
   re-introduces the capacity-leak surface.

3. **Construct secret-bearing vectors without growth.** Use
   `slice.to_vec()`, `existing.clone()`, or `vec![0u8; N]` — never
   `push` / `extend` / `reserve` on a vector that will become a
   secret. Reallocation during growth leaves intermediate copies in
   the allocator that `Zeroize` cannot reach. The `zeroize` crate's
   own docstring flags this: *"Cannot ensure that previous
   reallocations did not leave values on the heap."*

4. **Prefer fixed-size arrays when the length is known statically.**
   `SivKey`, `SivKey512`, and `Aes128GcmSivKey` in `nts/aead.rs` wrap
   `[u8; N]` rather than `Vec<u8>`. Arrays have no spare capacity and
   no reallocation history by construction.

5. **Do not call `Vec::shrink_to_fit` on a secret-bearing vector
   immediately before wrapping in `Zeroizing` purely for
   capacity-leak reasons.** It is redundant with the `zeroize ≥ 1.8`
   `Vec` impl, and per the standard-library contract `shrink_to_fit`
   may itself reallocate and free a non-zeroised intermediate buffer,
   re-introducing the residual-memory surface it was meant to remove.
   The growth-free construction discipline in rule 3 is what
   actually closes the surface.

6. **Redact secret-bearing types in `Debug`.** Manual `impl
   std::fmt::Debug` implementations for `CustomRootsBytes`,
   `TrustMode`, `CookieJar`, `RecordKind` (for the `NewCookie`
   variant), `SivKey`, `SivKey512`, and `Aes128GcmSivKey` render
   placeholders (`<REDACTED: N bytes>`, count-only summaries) so
   accidental `{:?}` formatting in logs, panic messages, or
   diagnostic output cannot leak bytes.

### KE-side cookie pipeline

The records parser → KE outcome → [`CookieJar`] handoff is wrapped
end-to-end so a panic anywhere in the chain drops `Zeroizing`-aware
containers rather than naked `Vec<u8>` allocations
(`rust/src/nts/records.rs` `RecordKind::NewCookie(Zeroizing<Vec<u8>>)`,
`rust/src/nts/ke.rs` `KeOutcomePartial::cookies` /
`KeOutcome::cookies` as `Vec<Zeroizing<Vec<u8>>>`,
`rust/src/nts/cookies.rs` `CookieJar` storing
`VecDeque<Zeroizing<Vec<u8>>>` natively). The growth-free
construction discipline above still holds at every allocating
step (`body.to_vec()` and `Vec::clone()` both allocate exactly
`slice.len()` bytes with no reallocation history; `Zeroizing::new`
is a zero-cost wrapper that does not allocate or copy), so
neither the liveness surface nor the capacity surface remains
exposed.

The NTP-response cookie path
(`ServerResponse::fresh_cookies: Vec<Zeroizing<Vec<u8>>>` →
`SessionTable::deposit_cookies` → `CookieJar::put_many`) is also
closed (bd nts-wpvd / NTS-61): each cookie is wrapped in
`Zeroizing` at the parse site in `parse_server_response`
(`rust/src/nts/ntp.rs`), so the transit collection — including the
deposit-side discard paths (stale generation, evicted session)
that never reach the jar — wipes the bytes on drop instead of
freeing naked `Vec<u8>` allocations. Upstream of the collection,
the AEAD-decrypted extension body returned by
`AeadKey::open_packet` is `Zeroizing`-wrapped at the call site,
and every encrypted-extension body copied out of it is wrapped
*before* the cookie filter, so the decrypted plaintext and any
non-cookie encrypted extensions are wiped on drop too.
Allocations the AEAD crate makes internally while producing the
decrypted buffer are upstream-owned and out of scope, mirroring
the PEM-path caveat below. `ServerResponse` carries a manual
redacted `Debug` (`<redacted; N cookies>`) per the convention
above.

### Custom roots parsing pipeline

`CustomRootsBytes(Arc<Zeroizing<Vec<u8>>>)` (`rust/src/nts/ke.rs`)
guarantees the **input** buffer is wiped from RAM when the final
`Arc` clone drops. The guarantee does **not** extend through every
downstream copy made during trust-anchor parsing; the scope is:

- **Input buffer:** wiped on final-clone drop, as documented in
  the `CustomRootsBytes` rustdoc and section "Conventions" above.
- **DER path** (`build_with_custom_roots`): no intermediate copy
  exists. The function calls
  `CertificateDer::from_slice(bytes)` and hands the borrowed
  `CertificateDer<'_>` straight to `RootCertStore::add`. rustls
  0.23 extracts the trust anchor inside `add`
  (`anchor_from_trusted_cert(&der)?.to_owned()`) and retains only
  the parsed anchor — not the input DER — so the borrow window
  is bounded by the `add` call and nothing new is allocated that
  would need zeroising.
- **PEM path** (`build_with_custom_roots`): the upstream
  `CertificateDer::pem_slice_iter` iterator allocates a plain `Vec<u8>`
  per certificate inside the parser; those buffers are owned by
  the yielded `CertificateDer<'static>` values and are not under
  this crate's control, so they cannot be `Zeroizing`-wrapped
  without an upstream API change. The refactor processes one
  cert per loop iteration rather than accumulating a
  `Vec<CertificateDer>`, so each PEM-allocated buffer is dropped
  immediately after its `RootCertStore::add` call. This caps the
  residual liveness window to a single iteration but does **not**
  zeroise the bytes on drop. Full closure requires an upstream
  rustls / rustls-pki-types API that accepts a `Zeroizing`-aware
  backing buffer; tracked as `nts-xdo` (upstream-watch).
- **rustls trust anchors** (post-`add`): the parsed
  `TrustAnchor` (subject, SPKI, name constraints) lives inside
  the `RootCertStore` and then inside the returned
  `ClientConfig` for the lifetime of the TLS config. Those
  components are derived from the input DER but are not the
  original DER bytes; their zeroisation is upstream of this
  crate and out of scope for `CustomRootsBytes`.

The discipline above means that on the DER path the
`CustomRootsBytes` guarantee covers the *only* allocation that
holds the input bytes, and on the PEM path it covers everything
this crate allocates — the only residual liveness window is the
upstream-owned per-cert `Vec<u8>` inside each yielded
`CertificateDer`, which is now bounded to one loop iteration.
