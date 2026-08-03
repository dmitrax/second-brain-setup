# /brain-lint

Vault health check: find issues, update cross-project connections.

## Scope
Default: current project only. Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
With argument `--all`: entire vault.

Vault: `~/Workspace/second-brain-vault/`

## Step 0: Sync the vault before auditing it

```bash
VAULT="$HOME/Workspace/second-brain-vault"
BRAIN="$HOME/.claude/skills/second-brain/lib/brain.sh"
bash "$BRAIN" vault-sync "$VAULT"; rc=$?
```

- **0** → synced, or skipped on purpose (local-only vault is supported). Proceed.
- **2** → remote unreachable. Say so in one line, and label the report as covering a
  possibly stale checkout — the findings are still worth having, the claim of
  completeness is not.
- **3** → rebase conflict, vault is mid-rebase. **Stop.** Fix nothing: this command
  edits what it finds, and edits on top of a half-finished rebase are unreviewable.

Unlike the other commands, `/brain-lint` needs this for **reading**, not only for its
own writes. It reports what the vault does *not* contain — orphans, unresolved links,
stale projects — and every one of those verdicts is a claim about the whole vault. Run
on a checkout that is a week behind, it reports a clean bill of health for a state that
no longer exists, and does it silently: the files are all there, they read fine, nothing
looks wrong. A false green here is worse than a missed finding, because it is trusted.

## Guard

```bash
bash "$BRAIN" obsidian-available "$VAULT"   # exit 0 = GUI up AND this vault active
```

Use it as the condition of every CLI branch below: `if bash "$BRAIN" obsidian-available
"$VAULT"; then … else <filesystem fallback> fi`. If it exits non-zero, fall back — do not
retry, do not wait longer, and never call `obsidian` outside the branch.

The guard is **code in `lib/brain.sh`**, not a snippet to re-enact here. It lived as a
fenced block in this file for four versions, while `SKILL.md` and `/brain-init` referred
to it as if it were a library function they had — so `/brain-init` prescribed a mutating
`obsidian move` under a guard that did not exist in its context. One copy, called by
everyone, is the fix; `preflight` runs it in both states rather than grepping for its
shape.

Never diagnose this guard by splitting its conditions into separate commands: they are
chained on `&&` precisely so the CLI is never touched until the cheap checks pass. Run
apart, the third condition executes unconditionally and cold-starts the GUI — that
happened on 2026-07-22 while debugging by hand. The logic was innocent; the diagnosis
was not.

## Step 1: Orphan notes

```bash
if bash "$BRAIN" obsidian-available "$VAULT"; then
  obsidian orphans  # returns notes with no incoming [[wikilinks]]
else
  # filesystem fallback, per note: grep -rlF "[[<basename>]]" "$VAULT" — no hits = orphan.
  # -F is mandatory. Without it the brackets read as a character class, almost every
  # file "matches", and the step reports zero orphans — a false green, not an error.
fi
```

For each orphan note:
- Suggest: link it from an existing note OR add a reference from _PROJECT.md
- Do NOT delete automatically — suggest only

## Step 1b: Broken links (CLI only)

```bash
if bash "$BRAIN" obsidian-available "$VAULT"; then
  obsidian unresolved  # [[wikilinks]] pointing to non-existent files
  obsidian deadends    # notes with no outgoing links at all
fi
# Fallback: skip this step — no reliable filesystem equivalent
```

## Step 2: Contradictions

Find notes in `$PROJECT/wiki/` where statements contradict each other.

Contradiction signals:
- Same fact stated differently in two notes
- `## For future Claude` date older than 30 days + status stable → needs verification
- A decision note contradicts practice described in a synthesis note

For each contradiction — report to user and suggest resolution.

## Step 3: Stale notes

Find notes where:
- `status: draft` and date older than 14 days → suggest promote to stable or delete
- `date:` older than 60 days with no updates → flag for review

## Step 4: Missing pages

Find [[wikilinks]] in note bodies pointing to non-existent files.
For each — suggest creating the page or fixing the link.

## Step 4b: Ambiguous links (bare [[name]] where the name is not unique)

A `[[wikilink]]` that names a file whose basename exists more than once in the vault
resolves to the first shortest-path match — silently, and to a file in whatever project
Obsidian picked. Every such link needs an explicit path instead
(`[[project/wiki/note|note]]`, `[[../_PROJECT|_PROJECT]]`).

Run over the whole vault regardless of scope. A link is broken by the *existence of a
duplicate name anywhere*, so a project-scoped run cannot see its own breakage:

```bash
cd "$VAULT" || exit 1
find . -name '*.md' -not -path './.git/*' | sed 's|.*/||; s|\.md$||' | sort | uniq -d |
while read -r name; do
  grep -rnF --include='*.md' "[[$name]]" . |
    grep -v '/sessions/' | grep -v '/archive-'
done
```

`-F` is mandatory — the pattern is full of brackets. `sessions/` and `archive-*` are
history and are not rewritten. Report every hit; do not auto-fix.

**This check exists because the class recurs without anyone writing a bad link.** A name
is unique when the link is written and stops being unique later, the moment a second
project creates a file with the same basename — at which point already-correct links in
the *older* project become ambiguous, with no edit to them and no signal anywhere.
Measured 2026-08-03: five `puzzlebot-voronka` notes written 2026-06-28…07-04 carried 33
correct bare links until `goprofi-voronka` was created 2026-07-29 reusing those five
filenames. The vault had been linted clean of this class three days earlier. So the
trigger is not authoring discipline and cannot be caught at write time by review — only a
vault-wide sweep that re-asks "is this name still unique" finds it. Run it on every lint,
not only when a project is new.

False positives are notes that *document* this bug and quote the bare form as an example,
inside backticks or a fenced block. Exclude those by filename; never relax the grep to
skip lines containing a backtick — a real bare link and an unrelated backtick share a line
often enough (confirmed live in `goprofi-voronka/_PROJECT.md`).

## Step 5: Cross-project connections (update connections.md)

Read wiki/ of all projects (if `--all`) or current project.

Find:
- Notes in current project that reference concepts from other projects
- Decisions that may be applicable in other projects

Update `$VAULT/00-system/connections.md`:
- Add new connections
- Remove connections that are no longer relevant
- Update timestamp: `## Last updated: [TODAY] lint`

## Step 6: Check _PROJECT.md

- Is the status block current?
- Is the last-session block up to date?
- Does the `updated:` frontmatter field exist? If missing — add it, set to today.
- If not current — suggest updating

## Step 7: Check project taskboard

Read `$VAULT/$PROJECT/taskboard.md`.

Flag stale items:
- Task in active/in-progress with no updates for 14+ days
  → suggest moving to stalled with reason
- Task in stalled with no update for 30+ days
  → ask user: still relevant? close / delete / keep with new date?

Note: especially useful with `--all` flag — catches stale tasks
in projects that haven't been opened recently.

## Step 8: Stale project detector

Read `updated:` from frontmatter of `_PROJECT.md` for each project in scope.

If `updated:` is more than 14 days old:
- Flag: "Project [name] — no vault update in N days. Still active, on pause, or close?"

If `updated:` field is missing from frontmatter — flag: "Project [name] — missing
`updated:` field in _PROJECT.md. Add it and set to the date of the last session."

## Step 9: Size check

Read `$VAULT/$PROJECT/_PROJECT.md` and `$VAULT/$PROJECT/taskboard.md`.

Flag if:
- `_PROJECT.md`'s **prose sections** together exceed ~60 lines → suggest moving stale
  detail into wiki/ notes. Count only `## Current state` (or `## Статус`),
  `## Последняя сессия` and `## For future Claude`; skip blank lines. Do **not** count
  link-list sections (`## Key decisions` / `## Ключевые решения`, `## Source projects`,
  `## Рабочие файлы`) — those grow linearly with the project's decision count and
  violate no rule, so folding them into a total-size threshold makes a well-kept large
  project look like a violator. Measured 2026-07-22: `dimarch` carries 36 lines of
  legitimate decision links against 65 wiki notes, while its actual defect sits in
  `## Current state` (141 lines of prose). Total file size is not the signal — prose is
- Taskboard Done / completed section is unbounded (more than ~20 closed items) →
  suggest archiving old entries to a `wiki/archive-YYYY.md` note
- `## Current state` (or `## Статус` in older projects — same section) contains
  multi-sentence paragraphs that restate facts a linked (or linkable) wiki/decision
  note already covers → flag as duplication, suggest collapsing the paragraph to
  one line + `[[wikilink]]`
- `## Последняя сессия` entries run longer than 1-2 lines, or the section is
  missing while `## Current state` reads like a session-by-session log (several
  dated paragraphs) → flag: session recaps are accumulating in the wrong
  section; suggest adding a proper `## Последняя сессия` and moving narrative
  out to wiki/ or the session log. This check catches the disease independent
  of size — it triggers well before the ~60-line prose budget does.
- `_PROJECT.md`'s own `## For future Claude` exceeds ~20 lines, or contains
  multi-sentence entries that restate a linked (or linkable) wiki/decision
  note's mechanism/investigation rather than just its one-line consequence →
  flag as duplication, same fix as "Current state". This section has no
  template default and no size guard elsewhere, so it tends to drift furthest
  unnoticed — confirmed live in `dimarch` (149 lines before a fix was applied).

## Step 10: Decision consistency

Find all notes in `wiki/` whose filename starts with `decision-`.

Check:
- Any decision note with `status: superseded` still referenced as active in
  `_PROJECT.md` "Key decisions" section → flag the stale link, suggest updating
- Any decision note with `status: deprecated` still referenced anywhere → same
- `supersedes:` / `superseded-by:` points to a note that does not exist → flag
  broken reference
- Any note still carrying the legacy one-line `status: superseded-by: x` form →
  flag it: that is invalid YAML (double colon = nested mapping in compact form),
  so Obsidian cannot parse the frontmatter at all and the note silently drops out
  of every property query. Fix by splitting into `status: superseded` +
  `superseded-by: x`
- `status:` holding any value other than `accepted` / `superseded` / `deprecated` →
  flag it, whatever the value — most likely a hedge like `partially-superseded-by
  <note>` invented to avoid picking `superseded`. `status` is invisible to every
  property query once it holds an off-schema value, same failure shape as the legacy
  form above. Fix: `status: superseded` + `superseded-by:` on the old note, and move
  the nuance of what changed into the *new* note's body — restating the parts of the
  old scope that still hold, not just the delta, so the new note alone is enough for
  current policy. Found live 2026-07-22 in `puzzlebot-voronka`
  (`decision-replace-o-biznese-videos-with-faceless-formats-because-no-production-resource-yet`
  carried `status: partially-superseded-by decision-restore-video-...`); fixed on sight
- `corrected-by:` points to a note that does not exist → flag broken reference
- A note that declares itself a correction of record for another note (its body says
  so, or it is the target of a `corrected-by:`) while the corrected note carries no
  `corrected-by:` field → flag the missing marker. The correction is then visible
  only from the new note, which leaves the stale fact unmarked for anyone reading
  the old one — the exact failure the field exists to prevent
- `corrected-by:` on a note whose `status:` is `superseded` → flag as redundant:
  a superseded note is already retired wholesale, the finer-grained marker adds
  nothing and suggests one of the two fields was set by mistake

## Step 10b: Frontmatter key consistency within a project

A project may require keys this package knows nothing about — `goprofi-voronka` puts
`zone:` on session logs and decision notes because that repo is split into zones. Nothing
enforces such a local convention, so it erodes silently: the `/brain-save` template shows
its own keys and reads as exhaustive at the moment of writing.

The set of frontmatter keys must be uniform inside a project. A key carried by most
earlier entries but absent from a newer one is a finding:

```bash
cd "$VAULT/$PROJECT/sessions" 2>/dev/null || exit 0
keys() { awk '/^---$/ {c++; next} c==1 && /^[A-Za-z_-]+:/ {sub(/:.*/,""); print}' "$1" | sort -u; }
n=$(ls -1 *.md 2>/dev/null | wc -l)
[ "$n" -lt 3 ] && exit 0          # too few entries to call anything a convention
conv=$(mktemp)                    # not $TMPDIR — unset on most Linux setups
for f in *.md; do keys "$f"; done | sort | uniq -c |
  awk -v n="$n" '$1 > n * 0.6 {print $2}' > "$conv"
for f in *.md; do
  have=$(keys "$f")
  while read -r k; do
    printf '%s\n' "$have" | grep -qxF "$k" || echo "$f: missing '$k'"
  done < "$conv"
done
rm -f "$conv"
```

Run the same over `wiki/decision-*.md`, which carry their own convention separately.

Report; do not auto-fill. The **key** is mechanical, the **value** is a judgement that
has to be made per entry — the session that surfaced this wrote a log tagged
`zone: root` (it crossed both zones) and, minutes later, a decision note tagged
`zone: backend` (it was about delivery). Copying a value from the previous entry would
be silently wrong, which is worse than the missing field.

The 60% threshold treats a key as a convention only when most entries carry it, so a
one-off experimental key never becomes a rule. Measured 2026-08-03: `goprofi-voronka`
had 4 logs of 55 and 2 decision notes of 100 missing `zone:`, the most recent two on
2026-08-01 — the same day, twice. Every other project came back uniform on
`date/project/tags`.

## Step 11: Architecture map freshness (code / mixed projects only)

If `architecture-map.md` exists in the project root:
- Read its `updated:` frontmatter field
- Read the date of the most recent session log in `sessions/`
- If the session log is newer than `architecture-map.md` updated date AND that session
  touched code (check session log "What we did" for code-related activity) →
  flag: "architecture-map.md may be stale — last session was [date], map was updated [date]"

```bash
if bash "$BRAIN" obsidian-available "$VAULT"; then
  # path= (exact), not file= — file= resolves by name like a wikilink and would
  # hit the first architecture-map.md in the vault, i.e. another project's
  obsidian links path=$PROJECT/architecture-map.md   # list all [[wikilinks]] in the map
  obsidian unresolved                     # which of those are broken
fi
```

If this is a code or mixed project and `architecture-map.md` does NOT exist:
- Suggest creating it: "No architecture-map.md found. Create one to improve
  code-session continuity."

Skip Steps 11 for content and config projects.

## Result

```
✓ Lint complete: $PROJECT

Orphan notes:          [N] (list)
Contradictions:        [M] (list)
Stale notes:           [K] (list)
Missing link targets:  [L] (list)
Stale projects:        [N] (list with days since update)
Size warnings:         [N] (list)
Decision issues:       [N] (list)
Architecture map:      ok / stale / missing / not applicable
Broken links (CLI):    [N] (list) / n/a (Obsidian не запущен)
Taskboard:             [N] stale tasks flagged
Connections.md:        updated / no changes

Recommendations:
[list of specific actions]

Run /brain-save to persist any wiki changes made during lint.
```
