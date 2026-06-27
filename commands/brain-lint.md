# /brain-lint

Vault health check: find issues, update cross-project connections.

## Scope
Default: current project only. Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
With argument `--all`: entire vault.

Vault: `~/Workspace/second-brain-vault/`

## Guard function

```bash
_obsidian_available() {
  command -v obsidian >/dev/null 2>&1 && \
  obsidian vault info=name >/dev/null 2>&1
}
```

Use this guard for every CLI block below. If Obsidian is not running — fall back to filesystem logic.

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
- `_PROJECT.md` exceeds ~120 lines → suggest moving stale detail into wiki/ notes
- Taskboard Done / completed section is unbounded (more than ~20 closed items) →
  suggest archiving old entries to a `wiki/archive-YYYY.md` note

## Step 10: Decision consistency

Find all notes in `wiki/` whose filename starts with `decision-`.

Check:
- Any decision note with `status: superseded-by:` still referenced as active in
  `_PROJECT.md` "Key decisions" section → flag the stale link, suggest updating
- Any decision note with `status: deprecated` still referenced anywhere → same
- `supersedes:` field points to a note that does not exist → flag broken reference

## Step 11: Architecture map freshness (code / mixed projects only)

If `architecture-map.md` exists in the project root:
- Read its `updated:` frontmatter field
- Read the date of the most recent session log in `sessions/`
- If the session log is newer than `architecture-map.md` updated date AND that session
  touched code (check session log "What we did" for code-related activity) →
  flag: "architecture-map.md may be stale — last session was [date], map was updated [date]"

```bash
if _obsidian_available; then
  obsidian links file=architecture-map    # list all [[wikilinks]] in the map
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
