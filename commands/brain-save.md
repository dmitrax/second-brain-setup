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
- A tool choice became a *constraint*: "pnpm, never npm", "python via pyenv, the system
  one breaks X". The inventory itself — which languages, frameworks and services the
  project uses — is **not** a trigger: it lives in `_PROJECT.md` and `architecture-map.md`,
  which Steps 3 and 5 of this command already keep current. Writing it here as well makes
  a third copy that nothing updates.
- New rule established: "we always do X", new convention, new agreement
- New constraint: "never do Y", something broke and should not repeat
- Workflow changed: new commands, new build/test/deploy steps

If triggered: open CLAUDE.md in current directory → update Block 2 → then proceed.
If nothing changed: skip the editing above. The audit below is **not** part of that —
it runs on every save, whether or not anything in Block 2 changed.

```bash
bash "$BRAIN" claude-md-audit "$PWD/CLAUDE.md"
```

Exit 0 clean · 2 findings · **1 the file could not be read**, which is an error and not a
pass. Report each finding in one line and offer to fix it; do not fix it silently — the
file has no history in a public repo, where `/brain-init` puts it in `.gitignore`.

Why this is a call and why it is unconditional. The rules it measures are old, and both
places that enforced them enforce them at *creation*: preflight checks the template
`/brain-init` writes, and the prose above only applies when a session already had a
reason to open the file. So a file that acquired a state section afterwards kept it for
as long as nobody happened to read it. Measured 2026-08-05 across the live projects: 2 of
7 carried `## Current state`, 3 carried a `Stack` inventory, and one of those state
sections claimed 30 tables against 45 on disk — found by a person reading the file, which
is precisely the reader this file is supposed to be saving time for.

**Whenever the file is open, check Block 2 does not restate the inventory.** A
`Stack` / `Стек` section listing languages, frameworks or scripts is the third copy of
what `_PROJECT.md` and `architecture-map.md` already carry: move any constraint out of it
into the rules list, then delete the section. Do not "update" it — an unowned copy drifts
again. Projects created before v1.7.0 almost all have one, because `/brain-init` wrote it
and the trigger above used to ask this step to keep it current. Measured 2026-08-04 in
`second-brain-setup`: three bash scripts listed for six weeks after `lib/brain.sh` became
the fourth, while the vault copy was correct throughout — nothing compares the two, which
is why the drift is silent and why the fix is deletion rather than a rewrite.

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
bash "$BRAIN" local-conventions "$VAULT" "$PROJECT" "$PWD/CLAUDE.md"
```

It reads three sources — this project's latest session log, its latest decision note,
and its `CLAUDE.md` — and prints `source<TAB>detail`. Read the output literally:

- keys listed for `session-log` / `decision-note` beyond `tags date project` (logs) or
  `status date supersedes` (decision notes) are this project's local convention;
- a `claude-md` line quoting a rule is the authority — it may require a key no existing
  entry carries yet;
- `none yet` means the project genuinely has none of that kind (a first session), while
  **`NOT READ` means the source could not be opened** — that is not the same fact, and
  the command exits non-zero when *every* source came back that way rather than letting
  you read silence as "no local conventions".

Take the **keys**; derive each **value** for the entry you are writing. Never copy a
value across — in the session that surfaced this, the session log needed `zone: root`
(it crossed both zones) while the decision note written minutes later needed
`zone: backend` (it was about delivery). Copying the key with its old value would have
been silently wrong, which is worse than omitting it.

If the command runs clean and reports no extra keys, the templates below are complete
as written.

Why this is a call and not a code block here: it was one, and both of its halves were
broken in ways nothing reported. The `CLAUDE.md` half referenced a variable this package
never assigns, so it grepped an empty filename and printed nothing, always. The
session-log half used a glob, and in the session's shell — zsh on macOS — an unmatched glob
aborts the command before `2>/dev/null` can apply, so on a project with no logs yet the
whole step produced a shell error and no result, exit 0. Both were invisible to
`preflight` 16, which checked that this step exists and sits above the templates, not
that it runs.

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

### Which of the two forms

Answer one question before writing: **were there alternatives worth recording?**

- **No** — the decision follows from a fact, and anyone who learns that fact would
  decide the same way ("clear `supersedes:`, it holds YAML null and not a note name").
  Use the **short form**. It is not a lesser note: it carries the same frontmatter, the
  same mandatory backlink, and is found by exactly the same queries.
- **Yes** — a real option was rejected, and a future session that does not know why
  would reasonably try it. Use the **full form**, and put the substance in
  `Alternatives rejected`.

Measured across the vault 2026-08-04: 286 decision notes, median **68 lines**, **not one
under 20** — there was no lighter setting, so a one-sentence decision either inflated to
fill the sections or invented content for them. 29 notes carry `Alternatives rejected`
empty or one line long, which is that inflation showing. Both failures cost the same
thing twice: the session's tokens now, and every future read of a section that says
nothing. The rule is *many decisions recorded slightly* over *few recorded exhaustively* —
a note that never got written because the template was heavy is the worst outcome of all.

**Short form:**

```markdown
---
status: accepted
date: [TODAY]
supersedes:
# + any project-specific keys found in Step 0c (e.g. zone:), value derived for THIS note
---

In context of <X>, facing <Y>, we chose <Z> to achieve <W>, accepting <V>.

[one line: the fact or measurement that forced it — with the number, if there is one]

## Links
[[../_PROJECT|_PROJECT]] · related: [[wiki/...]]
```

**Full form** — same header, plus the sections that carry the alternatives:

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

The `_PROJECT` backlink is mandatory. `related:` takes every note this decision is
actually related to — and is **deleted entirely, placeholder and label, when the decision
is first on its topic**. Do not keep the placeholder and do not link something adjacent to
avoid an empty line: the graph is read as evidence that a relation holds, so a fabricated
one costs more than an absent one. Measured 2026-08-04: 6 decision notes across 4 projects
carried the `_PROJECT` link alone, which was correct authoring against a rule that then
demanded two — the rule was the defect, not the notes. Their siblings arrive later and
link back; `/brain-lint` Step 4c reports the state without asking anyone to fake it.

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

## Step 4b: Measure what you just wrote

```bash
bash "$BRAIN" prose-budget "$VAULT/$PROJECT/_PROJECT.md" "$VAULT/$PROJECT/taskboard.md"
```

Exit **0** within budget · **2** over · **1** a counter did not run (that is an error,
not a pass — say so and do not claim the sizes are fine).

On **2**, name the overrun in the result block and act on it now, in this session:

- `_PROJECT.md` prose → the paragraph to collapse is almost always one restating a wiki
  note written this same session. Replace it with one line plus the `[[wikilink]]`.
- `For future Claude` → drop what has aged into a fact no longer surprising; it stays
  findable by grep in `wiki/`.
- taskboard Done → `brain.sh archive <taskboard> <archive-note> --before <YYYY-MM-DD>
  --apply`, never retype entries by hand. **Both flags, spelled out, are the call** —
  `--before` is mandatory and refuses anything that is not a date (so the prompt cannot
  quietly archive the entries this very session just closed: pass today's date and they
  stay), and without `--apply` it is a dry run that prints what it *would* move and exits
  **0**. Reporting "archived" off that exit code moves nothing and looks like success;
  read the line, not the code. Until 2026-08-04 this step named the bare command, which
  exits 1 as written. **A top-level task
  gets `YYYY-MM-DD` at the moment you close it** — `- [x] 2026-08-04 …`. `archive` moves
  dated entries and cannot move undated ones, so an entry closed without a date is one no
  tool will ever file, and the Done threshold it then trips is unsatisfiable by any amount
  of running `archive`. Measured 2026-08-04 in this project: 35 closed entries, 2 dated.
  A closed **sub-item** under a parent needs no date — it is not an archivable entry and
  is not counted as one. Where the date usually goes missing: it sat in a section heading
  (`### ✅ ЗАКРЫТО 03.08`), and headings are not moved, so the sweep separates the item
  from the only date it ever had. Date the items before sweeping, not after.
- taskboard `In progress` / total → `brain.sh sweep-closed <taskboard>` (dry-run by
  default) moves closed top-level items with their bodies into Done; a closed *sub-item*
  stays, because its text explains the open parent above it — add `--apply` to write.
  Then `archive` what landed in Done, with both flags as above. Whatever remains over budget after that is genuinely open work or `Backlog` —
  say so plainly and leave it as a task rather than trimming live content.

**Never finish the save silently on exit 2.** The budgets used to be measured only by
`/brain-lint`, hours or days later, by whoever happened to run it — so an overrun was
attributed to no session in particular and fixed by nobody. Measured 2026-08-03:
`_mac/mac-setup` grew 51→62 and 28→35 in a save at 22:03 and surfaced an hour later on
another machine; and in one session this project's own `_PROJECT.md` crossed its budget
four times through ordinary status edits, each time announced only by a hand-run lint.
The numbers are the same numbers `/brain-lint` prints — one implementation, in
`lib/brain.sh`, so the two can never disagree.

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

## Step 8: Report what the save actually did

Run this **after every write above and before the commit** — it reads the vault's
working tree, so a commit first makes it see nothing:

```bash
bash "$BRAIN" save-report "$VAULT" "$PROJECT"
```

Exit **0** every owed step left a trace · **2** at least one did not · **1** could not
measure (an error, not a pass — say so; do not report a clean save off it).

The output is the Result block's raw material, and it is not optional prose:

- **`ok`** — the step wrote something. Carry its numbers into the block as they are.
- **`MISSING`** — a step that is owed unconditionally left no trace on disk. Either go
  back and do it now, or write the line **"step skipped: <step> — <reason>"** in the
  Result. Never both silent and finished.
- **`ANSWER`** — a conditional step wrote nothing. That is often correct, but the
  session has to *say* which: "no decision was made this session", "the structure did
  not move", "nothing crossed into another project". An unstated answer is
  indistinguishable from a forgotten step, which is the whole defect this step exists
  for.
- **`n/a`** — the step does not apply here (a content project has no architecture map).
  Nothing to say.

**Why this replaced a template.** Measured 2026-08-16 in `goprofi-voronka`, twice in one
session: a save ran **eight steps of twelve** and reported success. The four that
vanished were exactly the ones leaving no visible trace — `brain-version` (0b),
`local-conventions` (0c), the decision note (2b), the architecture map (5) — and the miss
was caught by the user noticing the save felt fast, not by anything printed. The old
Result block listed those lines but asked for no numbers, so it was filled from the
memory of what the session *meant* to do. A count has to be counted: the shell reports
the facts, this step judges them, and the split is the same one `archive` uses — the
model picks the boundary, the shell moves the bytes.

## Result

Write the block from the `save-report` output — the numbers are its numbers, not a
recollection. Shape:

```
✓ Session saved

Log:        sessions/[the file save-report named]
Wiki:       [N] created, [M] updated
Decisions:  [K] created — or the stated reason there were none
Version:    [the stamp save-report read]
Taskboard:  updated / [stated reason it was not]
Arch map:   updated / n/a / [stated reason it was not]
Index:      updated / n/a
step skipped: [step] — [reason]        ← one line per MISSING, or no such line at all

Don't forget: git add -A && git commit -m "[DATE]" && git push
```
The labels above are written in English here because this file is; **print them in the
vault's working language** (`brain.sh vault-language`), and leave every identifier —
finding keys, paths, section and command names — exactly as it is. See `SKILL.md`,
"Language of everything you say to the user".


The push should fast-forward, because Step 0 pulled before the session was written.
If it is still rejected, another machine pushed *during* this session — run
`git -C "$VAULT" pull --rebase` and resolve. In the append-only registries
(`00-system/index.md`, `00-system/connections.md`) the resolution is almost always
"keep both sides": merge the entries and preserve each file's existing order —
`index.md` is reverse-chronological, `connections.md` chronological. Do not
resurrect an entry the other side deliberately dropped: Step 6 trims `index.md` to
the last ~8-10, so an entry missing on one side may have been rotated out, not lost.
