# /brain-lint

Vault health check: find issues, update cross-project connections.

## Scope
Default: current project only. Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
With argument `--all`: entire vault.

Vault: `~/Workspace/second-brain-vault/`

## Guard function

```bash
VAULT="$HOME/Workspace/second-brain-vault"

_obsidian_available() {
  command -v obsidian >/dev/null 2>&1 && \
  { [ -L "$HOME/Library/Application Support/obsidian/SingletonLock" ] || \
    [ -L "$HOME/.config/obsidian/SingletonLock" ]; } && \
  [ "$(timeout 2 obsidian vault info=name 2>/dev/null)" = "$(basename "$VAULT")" ]
}
```

Electron writes a `SingletonLock` symlink into its userData dir for as long as the app is
running (same mechanism on every OS) — checking it tells us the GUI is actually up before
touching the `obsidian` binary. This must be a symlink test (`-L`), not `-e`: the link
deliberately points at a target that doesn't exist as a real file, so `-e` always reads
false even while Obsidian is running. Do not switch this to `pgrep -f "obsidian"` — that
matches on the full command line of every process, including the very shell process
running this guard (its own invocation text contains the word "obsidian"), which is a
guaranteed false positive that then cold-starts the GUI via the call below. `timeout` is
a second safety net in case the socket call itself stalls. If either check fails, fall
back to filesystem logic — do not retry, do not wait longer.

The guard compares `vault info=name` against the vault we actually mean, instead of
just checking its exit code. Exit code alone confirms only that *some* vault is open.
Every CLI path is relative to the **active** vault, so `path=` does not protect against
this: with another vault switched on in the GUI, a write lands there — silently, exit 0,
the same failure class as the `file=`/`path=` bug one level up. The expected name is
derived from `$VAULT` via `basename`, never hardcoded — the path is already known to
every command, and a hardcoded name would break for anyone whose vault directory is
named differently.

## Step 1: Orphan notes

```bash
if _obsidian_available; then
  obsidian orphans  # returns notes with no incoming [[wikilinks]]
else
  # filesystem fallback: grep -rL for notes with no incoming links
fi
```

For each orphan note:
- Suggest: link it from an existing note OR add a reference from _PROJECT.md
- Do NOT delete automatically — suggest only

## Step 1b: Broken links (CLI only)

```bash
if _obsidian_available; then
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

## Step 11: Architecture map freshness (code / mixed projects only)

If `architecture-map.md` exists in the project root:
- Read its `updated:` frontmatter field
- Read the date of the most recent session log in `sessions/`
- If the session log is newer than `architecture-map.md` updated date AND that session
  touched code (check session log "What we did" for code-related activity) →
  flag: "architecture-map.md may be stale — last session was [date], map was updated [date]"

```bash
if _obsidian_available; then
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
