# /brain-save

Save the current session to the vault. Execute steps in strict order.

## Step 0: Check if CLAUDE.md needs updating

Before saving, quickly check — did this session change anything that belongs in CLAUDE.md Block 2?

Triggers (if any apply → update CLAUDE.md Block 2 first):
- Stack changed: new language, framework, tool added or removed
- New rule established: "we always do X", new convention, new agreement
- New constraint: "never do Y", something broke and should not repeat
- Workflow changed: new commands, new build/test/deploy steps

If triggered: open CLAUDE.md in current directory → update Block 2 → then proceed.
If nothing changed: skip this step.

---

## Identify current project

Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
Vault: `~/Workspace/second-brain-vault/`

## Step 0b: Bump updated date

Edit `$VAULT/$PROJECT/_PROJECT.md` frontmatter directly — set `updated:` to today.
If the field does not exist, add it.

**Do not use `obsidian property:set` here.** It does not edit the one field it is
given: it parses the whole frontmatter and re-serializes it, rewriting every other
property in the process. Measured 2026-07-22 on a probe file:

```
version: "1.4.3"              ->  version: 1.4.3        quotes stripped
tags: [session, obsidian-cli] ->  tags:                 inline list expanded to block
                                    - session             (the format every note here uses)
                                    - obsidian-cli
count: 007                    ->  count: 7              value changed — data loss
```

Nothing warns about this and the exit code is 0. Editing the file directly touches
one line and cannot reformat anything else. This is the only vault write that used
the CLI at all, so `/brain-save` no longer needs the `_obsidian_available` guard —
`/brain-lint` still uses it for its read-only queries.

A second reason not to reach for the CLI here: `property:set` reports success on
frontmatter it failed to parse. On a file carrying the old `status: superseded-by: x`
form (invalid YAML — see Step 2) it prints a parse error to stderr, writes nothing,
and still exits 0.

## Step 1: Create session log

File: `$VAULT/$PROJECT/sessions/[YYYY-MM-DD_HHMM]_session.md`
(Timestamp in filename prevents collision if multiple sessions per day.)

```markdown
---
tags: [session]
date: [TODAY]
project: $PROJECT
---

# Session [YYYY-MM-DD_HHMM]

## What we did
[brief summary — 2-5 sentences in Russian]

## Decisions made
[list decisions made in this session — if none, write "none"]

## What worked
[prompts, approaches, commands that worked well — so the next session can reuse them]

## Tech debt found, not fixed
[issues noticed but out of scope for this session — logged here, not touched]

## Next step
[concrete next action for the next session]

## Affected wiki files
[list of updated or created notes]
```

## Step 2: Update wiki

For each piece of new knowledge or decision made:
- Find existing note — REWRITE it (do not create a duplicate)
- If no note exists — create one with AI-First format (YAML + ## For future Claude)
- Ensure `## For future Claude` is current and in English

When rewriting a synthesis note:
- Update `date:` in frontmatter
- Update `## For future Claude` if the note's use case changed
- Remove outdated facts
- Add new facts and [[wikilinks]]

**Decision notes are an exception to rewrite:** if a new decision supersedes an old one,
write a NEW `decision-<slug>-because-<reason>.md` and mark the old note's frontmatter:

```yaml
status: superseded
superseded-by: decision-<new-slug>.md
```

Two separate fields. The old one-line form `status: superseded-by: decision-x.md` is
**not valid YAML** — a double colon is a nested mapping in compact form, which the
parser rejects. Obsidian then treats the whole frontmatter as unparseable: the note
drops out of property queries, and `obsidian property:set` on it prints a parse error
to stderr, writes nothing, and still exits 0. Never edit the body of an existing
decision note to reverse its meaning.

## Step 2b: Create decision note if triggered

Trigger: a decision with rationale was made in this session.

File: `$VAULT/$PROJECT/wiki/decision-<slug>-because-<reason>.md`

```markdown
---
status: accepted
date: [TODAY]
supersedes:
---

In context of <X>, facing <Y>, we chose <Z> to achieve <W>, accepting <V>.

## Context
[what forced this decision; data/facts on hand; what was tried]

## Alternatives rejected
- Option A — rejected because [...]

## Consequences
[gains / costs / risks accepted]

## Review by
[YYYY-MM-DD — condition that would reopen this decision]

## Links
[[../_PROJECT|_PROJECT]] · related: [[wiki/...]]
```

Then add the `[[wikilink]]` to this note from `_PROJECT.md` "Key decisions" section.

## Step 3: Update _PROJECT.md

### Current state
The status block — `## Current state` in projects created since this rule, `## Статус`
in older ones (same section, do not rename an existing heading just to match). Status
and open blockers only — never a session recap. If the full account of
something already lives (or was just written this session) in a wiki note,
`_PROJECT.md` does not restate it: replace the paragraph with a one-line pointer
plus `[[wikilink]]`. Target ~10 lines. See
[[decision-project-md-links-not-duplicates-wiki-because-recaps-belong-in-one-place]].

### Последняя сессия
Always maintain this section — create it if it does not exist yet. Do not let
session summaries default into "Current state" because this section is missing.

Append one line, newest first:
```
[DATE] ([HHMM]) — [one-line summary]. [[sessions/[timestamp]_session|session log]]
```
Never expand an entry into a paragraph — the full account is already in the
session log (Step 1) and, for anything durable, in a wiki note (Step 2). Keep
only the last ~5 entries; older ones are not lost (they remain in
`sessions/*.md`) — delete them from this list, don't archive them elsewhere.

### For future Claude (in _PROJECT.md itself)
A bounded, curated quick-reference of hard constraints and currently-relevant
gotchas a session needs before touching this project — not a technical archive.
Target ~15-20 lines regardless of project size. When adding a new fact:
- Rewrite in place, don't append — check whether it fits an existing bullet or
  supersedes one before adding a new line.
- If the fact's full mechanism/investigation lives in a wiki note, keep only the
  one-line consequence + `[[wikilink]]` here, never the mechanism itself.
- If a bullet has aged into a fact no longer surprising or safety-critical for a
  first-time-this-session read, drop it — it's still findable via Tier 2 grep in
  wiki/, that's what wiki/ is for.
This section previously had no governing rule at all (unlike the two above) and
was the one that drifted furthest unnoticed as a result — confirmed live in
`dimarch`'s `_PROJECT.md` (149 lines, several entries duplicating decision notes
almost verbatim) before this rule was written.

`updated:` frontmatter field was already bumped in Step 0b.

## Step 4: Update project taskboard

File: `$VAULT/$PROJECT/taskboard.md`

- Completed tasks → move to done section with date
- New tasks → add to backlog or in-progress
- Stalled tasks — do NOT delete, only add date and reason

## Step 5: Update architecture map (code / mixed projects only)

If this is a code or mixed project AND the codebase structure changed in this session
(new routes, modules, components, data sources, integrations, moved files):

Rewrite `$VAULT/$PROJECT/architecture-map.md` in place — update the affected rows
or sections. Do not append. If `architecture-map.md` does not exist yet, create it
using the project's current structure.

Update the `updated:` field in its frontmatter to today's date.

Skip this step entirely for content and config projects.

## Step 6: Update index.md

File: `$VAULT/00-system/index.md`

If new notes were created — add them to the project section.
Update `## Последние изменения` — keep the last ~8-10 *entries* (not lines; each
entry is typically multi-line). This is a vault-wide pulse across all projects,
not a replacement for any single project's own `_PROJECT.md` history — dropping
an entry here loses nothing, the full account stays in that project's own
`_PROJECT.md`/`sessions/*.md`. Raised from 3-5 (2026-06) to 8-10 (2026-07-21) once
the vault grew past ~5 concurrently active projects and the old cap started
turning over within a single working day.

## Step 7: Check for cross-project connections

If session produced knowledge applicable to OTHER projects:
- Add entry to `$VAULT/00-system/connections.md`
- Format: `[DATE] | [[$PROJECT/wiki/note]] → applicable in [other-project]`

## Result

```
✓ Session saved

Log:        sessions/[YYYY-MM-DD_HHMM]_session.md
Wiki:       [N] notes updated/created
Decisions:  [K] decision notes created
Arch map:   updated / not applicable
Taskboard:  updated

Don't forget: git add -A && git commit -m "[DATE]" && git push
```
