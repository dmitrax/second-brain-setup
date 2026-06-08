# /brain-lint

Vault health check: find issues, update cross-project connections.

## Scope
Default: current project only (`$PROJECT` from CLAUDE.md).
With argument `--all`: entire vault.

Vault: `~/Workspace/second-brain-vault/`

## Step 1: Orphan notes

Find notes in `$PROJECT/wiki/` with no incoming [[wikilinks]] from other notes.

For each orphan note:
- Suggest: link it from an existing note OR add a reference from _PROJECT.md
- Do NOT delete automatically — suggest only

## Step 2: Contradictions

Find notes in `$PROJECT/wiki/` where statements contradict each other.

Contradiction signals:
- Same fact stated differently in two notes
- `## For future Claude` date older than 30 days + status stable → needs verification
- Decision in decisions/ contradicts practice described in wiki/

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

- Is `## Статус` block current?
- Is `## Последняя сессия` block up to date?
- If not — suggest updating

## Step 7: Check project taskboard

Read `$VAULT/$PROJECT/taskboard.md`.

Flag stale items:
- Task in `## На этой неделе` with no updates for 14+ days
  → suggest moving to `## Зависло` with reason
- Task in `## Зависло` with no update for 30+ days
  → ask user: still relevant? close / delete / keep with new date?

Note: especially useful with `--all` flag — catches stale tasks
in projects that haven't been opened recently.

## Result

```
✓ Lint complete: $PROJECT

Orphan notes:       [N] (list)
Contradictions:     [M] (list)
Stale notes:        [K] (list)
Taskboard:          [N] stale tasks flagged
Connections.md:     updated / no changes

Recommendations:
[list of specific actions]

Run /brain-save to persist any wiki changes made during lint.
```
