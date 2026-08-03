# /brain-save

Save the current session to the vault. Execute steps in strict order.

## Identify current project

Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
Vault: `~/Workspace/second-brain-vault/` → that is `$VAULT`.

## Step 0: Sync the vault before writing anything

The vault is shared across machines, and some of its files are append-only registries
that *every* session on *any* machine edits — `00-system/index.md`,
`00-system/connections.md`, and the project's own `_PROJECT.md`. Writing this session
on top of a stale checkout guarantees a conflict at push time, in exactly those files,
every time. Pull first and the same write is a fast-forward.

Run before any vault write:

```bash
BRAIN="$HOME/.claude/skills/second-brain/lib/brain.sh"
bash "$BRAIN" vault-sync "$VAULT"; rc=$?
```

Act on the exit code — the outcome rules are the code's, not yours to re-derive:
- **0** → synced, or skipped on purpose (not a git repo / no remote). A local-only vault
  is a supported setup; never run `git init` or add a remote on the user's behalf.
  Proceed to Step 0a.
- **2** → remote unreachable or `timeout` fired. The reason is printed on stderr; repeat
  it to the user in **one** line and proceed with the save anyway. An unsaved session is
  a worse loss than a deferred sync, and the push at the end surfaces the divergence.
  Never let an unreachable remote block the save.
- **3** → the rebase stopped on a conflict and the vault is mid-rebase. **Stop. Write
  nothing.** The conflicting files are listed on stderr — hand them to the user. Writing
  into a tree that is mid-rebase mixes two sessions' edits into one unreviewable diff,
  and the conflict markers land inside the notes themselves.

`--autostash` (inside the helper) covers the common case of a previous session that
edited the vault but never committed: that work is set aside, the rebase runs, and it is
restored on top.

## Step 0a: Check if CLAUDE.md needs updating

Before saving, quickly check — did this session change anything that belongs in CLAUDE.md Block 2?

Triggers (if any apply → update CLAUDE.md Block 2 first):
- Stack changed: new language, framework, tool added or removed
- New rule established: "we always do X", new convention, new agreement
- New constraint: "never do Y", something broke and should not repeat
- Workflow changed: new commands, new build/test/deploy steps

If triggered: open CLAUDE.md in current directory → update Block 2 → then proceed.
If nothing changed: skip this step.

**Write only what cannot expire, and phrase it so it cannot.** Apply the expiry test
from `SKILL.md` ("What belongs where"): anything that can be false tomorrow — a version,
a status, what is pinned or committed, which phase is active — goes to `_PROJECT.md` /
`taskboard.md` / the session log, never here. A gotcha resolved this session goes in as
a *method* ("check X with `ldd`, not `pacman -Si`"), not as a *state* ("X is pinned").
Never open a `## Current state` section here, and never append a dated session
paragraph — this file is read in full every session, before the topic is known.

---

## Step 0b: Bump updated date

```bash
PM="$VAULT/$PROJECT/_PROJECT.md"
bash "$BRAIN" stamp-field "$PM" updated "$(date +%F)"
bash "$BRAIN" stamp-field "$PM" brain-version "\"$(bash "$BRAIN" version)\""
```

Each call rewrites one line, adds the key if absent, and refuses a file with no
frontmatter — it cannot reformat anything else. Verify afterwards that the file it
printed is the one you meant.

**Why `brain-version` is stamped here.** It used to be written once by `/brain-init` from
a hardcoded literal and then read or updated by nobody — a field that recorded the version
a project was *created* under, drifting silently from the version actually in use
(measured 2026-08-03: 8 projects on `1.3`, two on `1.5.0`, none on 1.6.0). Stamping the
real installed version on every save turns it into a fact: if a machine has been running
an un-updated copy, the vault now shows it, with dates, instead of everyone assuming the
fleet is in sync.

**Compare only real stamps.** A value is a stamp if it is in the format
`brain.sh version` prints — `v<MAJOR>.<MINOR>.<PATCH>`, optionally followed by
`-<N>-g<sha>`. Anything else (`1.3`, `1.5.0`) is the old `/brain-init` literal: written
once at project creation, never touched again, and evidence about no machine at all.
The two formats are not ordered against each other, so "lower" is undefined between
them. So: if this project's value is below another project's *stamp*, say in one line
that this machine skipped `update.sh`. If the other values are legacy literals, say
only that those projects have not been saved since stamping began — never that they
sit on an un-updated copy. Measured 2026-08-03, on the first save under this code:
it reported five projects as running an old install; all five had simply not been
saved yet, and their `1.3` was the literal this very paragraph describes.

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

## Step 0c: Find this project's local frontmatter conventions

Do this **before** writing anything below. Some projects require frontmatter keys this
package knows nothing about — `goprofi-voronka` requires `zone:` on session logs and
decision notes, because that repo is a monorepo split into zones.

```bash
# keys used by the most recent session log of this project
ls -1 "$VAULT/$PROJECT/sessions/"*.md 2>/dev/null | tail -1 | xargs -r awk '
  /^---$/ {n++; next} n==1 && /^[a-zA-Z_-]+:/ {print}'
grep -nE 'frontmatter|zone:|обязательн|required' "$PROJECT_CLAUDE_MD" 2>/dev/null | head
```

Take the **keys** from what you find; derive each **value** for the entry you are
writing. Never copy a value across — in the session that surfaced this, the session log
needed `zone: root` (it crossed both zones) while the decision note written minutes
later needed `zone: backend` (it was about delivery). Copying the key with its old value
would have been silently wrong, which is worse than omitting it.

If nothing turns up, the templates below are complete as written.

## Step 1: Create session log

File: `$VAULT/$PROJECT/sessions/[YYYY-MM-DD_HHMM]_session.md`
(Timestamp in filename prevents collision if multiple sessions per day.)

**This frontmatter is a minimum, not the full list.** Add whatever Step 0c turned up for
this project. The reason this is spelled out: the rule requiring `zone:` was loaded in
context the whole session — it sits in `goprofi-voronka/CLAUDE.md`, read at every session
start — and the field was still missed, because at the moment of writing a fenced block
with three keys reads as exhaustive. An explicit template at hand beats a rule read two
hundred messages ago, so the template has to say out loud that it is incomplete.

```markdown
---
tags: [session]
date: [TODAY]
project: $PROJECT
# + any project-specific keys found in Step 0c (e.g. zone:)
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

### When the new decision only reverses PART of the old one's scope

Plain two-field supersession still applies — `status: superseded` on the old note,
`superseded-by:` pointing at the new one. Do **not** invent a status value like
`partially-superseded-by <note>` to hedge this: `status` answers one binary question,
"is this note still the current authority?" — never "how much of it changed." A
made-up enum value is a schema violation with the same shape as the legacy
`status: superseded-by: x` bug above: a fact smuggled into a field that cannot hold it,
invisible to every property query that filters on `status`.

Found live 2026-07-22 in `puzzlebot-voronka`: a decision retiring all video from block
group `03-O-biznese` was later partly reversed — video restored for sub-blocks 005-007,
while 001-004 stayed video-free. The note recording the reversal is written correctly
already, and this is the rule to follow: **its body restates the full current policy
for the whole scope, not just the delta.** It says explicitly that 001-004 remain
video-free, even though that part didn't change. A reader who opens only the new note
gets complete current policy; nothing sends them back to the old note to reconstruct
what still applies. The old note keeps `status: superseded` — it stopped being the
authority for any part of its original scope the moment a newer note took over that
scope, even the part it left unchanged.

### When only a supporting fact went stale — `corrected-by:`

Supersession is the wrong tool when the decision still stands and only one fact
inside its body has been disproved (a CLI advantage that no longer exists, a
threshold that has since moved, a measurement that later turned out wrong).
Marking such a note `superseded` would falsely retire a rule that is still in force;
leaving it untouched lets a future session read the stale fact as current.

Add one field to the old note's frontmatter — nothing else changes:

```yaml
status: accepted
corrected-by: decision-<slug>.md
```

Rules:
- `status` stays as it was. `corrected-by:` is orthogonal to supersession.
- The **body is not edited.** Immutability is unchanged.
- Multiple corrections accumulate as a YAML list, newest last.
- The correcting note names the stale fact explicitly, so a reader can tell which
  part of the old note to distrust rather than doubting all of it.
- The marker belongs in the old note. A backlink from the new note is not a
  substitute: it is only visible to a reader who already found the correction.

## Step 2b: Create decision note if triggered

Trigger: a decision with rationale was made in this session.

File: `$VAULT/$PROJECT/wiki/decision-<slug>-because-<reason>.md`

**Minimum frontmatter, same as Step 1** — add this project's local keys from Step 0c,
and derive each value *for this note*, not for the session. These are two separate
judgements made minutes apart: the same session produced a log tagged `zone: root`
(it crossed both zones) and a decision note tagged `zone: backend` (it was about
delivery). Re-deciding per entry is the whole point; carrying the value over from the
log defeats it silently.

```markdown
---
status: accepted
date: [TODAY]
supersedes:
# + any project-specific keys found in Step 0c (e.g. zone:), value derived for THIS note
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
only the last ~5 entries — delete the older ones from this list, don't archive
them elsewhere.

**Before deleting an entry, check that what makes deletion safe is actually there.**
Deleting is safe because the account survives in `sessions/*.md` — that is a claim
about the individual entry, not a property of the section, and it is false for every
entry written before the session-log link became routine. Open each entry you are
about to drop: it must carry a `[[sessions/...|session log]]` link *and* that file
must exist. If it does not, the entry is the only record there is — carry its durable
facts into `Current state` or `architecture-map.md` first, then delete. Measured
twice: 2026-07-26 in `goprofi-voronka`, where two of four entries had no log and the
links were written before compressing, and 2026-08-03 in `_mac/mac-setup`, where the
dropped 2026-07-15 entry had no log and none existed — its facts happened to survive
in `architecture-map.md`, which was luck, not a check.

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

The push should fast-forward, because Step 0 pulled before the session was written.
If it is still rejected, another machine pushed *during* this session — run
`git -C "$VAULT" pull --rebase` and resolve. In the append-only registries
(`00-system/index.md`, `00-system/connections.md`) the resolution is almost always
"keep both sides": merge the entries and preserve each file's existing order —
`index.md` is reverse-chronological, `connections.md` chronological. Do not
resurrect an entry the other side deliberately dropped: Step 6 trims `index.md` to
the last ~8-10, so an entry missing on one side may have been rotated out, not lost.
