# /brain-save

Save the current session to the vault. Execute steps in strict order.

## Step 0: Check if CLAUDE.md needs updating

Before saving, quickly check — did this session change anything that belongs in CLAUDE.md Block 2?

Triggers (if any apply → update CLAUDE.md Block 2 first):
- Stack changed: new language, framework, tool added or removed
- New rule established: "we always do X", new convention, new agreement
- New constraint: "never do Y", something broke and should not repeat
- Workflow changed: new commands, new build/test/deploy steps

If triggered: open CLAUDE.md in current directory → update Block 2 → then proceed with steps below.
If nothing changed: skip this step.

---

## Identify current project

Read CLAUDE.md in current directory → find line `Project:` → that is `$PROJECT`.
Vault: `~/Workspace/second-brain-vault/`

## Step 1: Create session log

File: `$VAULT/$PROJECT/sessions/[YYYY-MM-DD_HHMM]_session.md`
(Use timestamp to avoid collision if multiple sessions per day)

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
[list of decisions or "none"]

## New knowledge
[what was learned or "none"]

## Next step
[concrete next action]

## Affected wiki files
[list of updated notes]
```

## Step 2: Update wiki

For each piece of new knowledge or decision made:
- Find existing note — REWRITE it (do not create a duplicate)
- If no note exists — create one with AI-First format (YAML + ## For future Claude)
- Ensure `## For future Claude` is current and in English

When rewriting a note:
- Update `date:` in frontmatter
- Update `## For future Claude` if the note's use case changed
- Remove outdated facts
- Add new facts and [[wikilinks]]

## Step 3: Update _PROJECT.md

In `## Последняя сессия` block:
```
[DATE] — [one line summary of what was done]
```

Update `## Статус` block if project status changed.

## Step 4: Update project taskboard

File: `$VAULT/$PROJECT/taskboard.md`

- Completed tasks → move to `## Принятые решения` with date
- New tasks → add to `## На этой неделе`
- Stalled tasks — do NOT delete, only add date and reason

## Step 5: Update index.md

File: `$VAULT/00-system/index.md`

If new notes were created — add them to the project section.
Update `## Последние изменения` (keep last 3-5 lines).

## Step 6: Check for cross-project connections

If session produced knowledge applicable to OTHER projects:
- Add entry to `$VAULT/00-system/connections.md`
- Format: `[DATE] | [[$PROJECT/wiki/note]] → applicable in [other-project]`

## Result

```
✓ Session saved

Log:        sessions/[YYYY-MM-DD_HHMM]_session.md
Wiki:       [N] notes updated
Taskboard:  updated

Don't forget: git add . && git commit -m "[DATE]" && git push
```
