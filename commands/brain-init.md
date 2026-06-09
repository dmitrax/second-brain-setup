# /brain-init

Create a new project in the Second Brain system.

## Arguments
`$ARGUMENTS` = project name (e.g.: dotfiles, tg-bot, content-kit)

If no name provided — ask for it as the first question.

## Step 1: Ask 6 questions one by one

Ask questions sequentially, wait for each answer before proceeding:

1. "What is this project? (one or two sentences)"
2. "What is the concrete end goal? What does done look like?"
3. "Current status: starting from scratch or already in progress?"
4. "What is the project type? (code / content / config / mixed)"
5. "What is the stack / tools? (languages, frameworks, services, key commands)"
6. "What are the main rules for this project? (what to always do / never do)"
7. "Is the repository public or private? (public / private / no repo)"

Save answer to question 4 as $PROJECT_TYPE.
Save answer to question 7 as $REPO_VISIBILITY.

## Step 2: Create vault structure

```bash
VAULT=~/Workspace/second-brain-vault
PROJECT=$ARGUMENTS
mkdir -p "$VAULT/$PROJECT/raw"
mkdir -p "$VAULT/$PROJECT/wiki"
mkdir -p "$VAULT/$PROJECT/output"
mkdir -p "$VAULT/$PROJECT/sessions"
# taskboard.md and _PROJECT.md created in Step 3
```

If $PROJECT_TYPE is `code` or `mixed` — also create `architecture-map.md` (Step 3c).

**Note:** no `wiki/decisions/` subfolder. Decision notes are flat in `wiki/` with
filename `decision-<slug>-because-<reason>.md`.

## Step 3: Create _PROJECT.md

Use the user's answers. Fill in all blocks.
Note: `## For future Claude` section in English; content blocks in Russian.

```markdown
---
tags: [project-manifest]
created: [TODAY]
updated: [TODAY]
status: active
type: [PROJECT_TYPE]
brain-version: "1.2"
---

## For future Claude
Read this file at the start of EVERY session for project [NAME].
Full context here: what we are building, current status, how to work.

# _PROJECT.md — [NAME]

## Что это
[ANSWER TO QUESTION 1]

## Цель
[ANSWER TO QUESTION 2]

## Статус
[ANSWER TO QUESTION 3]

## Стек / инструменты
[ANSWER TO QUESTION 5]

## Стиль работы
[ANSWER TO QUESTION 6 — preferences, not rules; rules go in CLAUDE.md]

## Ключевые решения
[Significant decisions live as immutable decision-*.md notes in wiki/.
List active ones here as [[wikilinks]]. If none yet — write "No major decisions made yet."]

## Последняя сессия
[TODAY] — project initialized
```

`updated:` is bumped by `/brain-save` on every session that changes project state.
`/brain-lint` flags the project as stale when `updated` is more than 14 days old.

## Step 3b: Create project taskboard.md

File: `$VAULT/$PROJECT/taskboard.md`

```markdown
# Taskboard — [PROJECT]

## In progress

## Backlog

## Done
```

## Step 3c: Create architecture-map.md (code / mixed projects only)

Skip this step for content and config projects.

File: `$VAULT/$PROJECT/architecture-map.md`

Fill from the user's answers (stack, current status). Leave clearly-marked gaps
for Claude to complete on the first code session.

```markdown
---
project: [PROJECT]
updated: [TODAY]
---

# Architecture map — [PROJECT]

The orientation file for code work. Read before editing code — do not scan the
repository to rediscover structure. Rewritten in place after structural changes.

## Stack
[ANSWER TO QUESTION 5 — one line]

## Routes / modules

| Path or module | File | Data source | Components / deps |
|---|---|---|---|
| [fill on first session] | | | |

## Key components / units
- [fill on first session]

## External integrations
- [fill on first session]

## Current focus
- [ANSWER TO QUESTION 2 — what we are building toward]
```

## Step 4: Create CLAUDE.md in current directory

Create `CLAUDE.md` in the directory where Claude Code is running.
CLAUDE.md contains TWO blocks: vault bridge + project rules.

```markdown
# CLAUDE.md — [PROJECT]

## Vault (Second Brain)
~/Workspace/second-brain-vault/
Project: [PROJECT]

### At session start
1. Read: 00-shared/CRITICAL_FACTS.md
2. Read: [PROJECT]/_PROJECT.md
3. Read: [PROJECT]/taskboard.md
4. If code or mixed project: read [PROJECT]/architecture-map.md before any code work
5. Do not full-scan the vault or repository. Use _PROJECT.md, architecture-map.md,
   and grep to find specific notes — never load whole folders or scan all code.
6. Tasks with no progress for 3+ days → flag explicitly:
   "🚨 [Task] stalled for N days. Reason: [reason]. Decompose now?"
7. If raw/ contains unprocessed files — notify user before ingesting

### Critical thinking & safety
- Do not flatter or auto-agree. If an approach is weak, unrealistic, or suboptimal,
  say so plainly: what is wrong and what would be better. Praise only when earned.
- Before an action that can break production or destroy work (DB migration, changing
  public URLs, deleting components, force-push, bulk deletes), warn in ONE line:
  "Before I do this — note: [risk]. Proceed?" If confirmed, execute without further
  hedging. One warning, not repeated. Skip the warning for mechanical tasks
  (refactor, formatting, adding comments).

---

## Project: [PROJECT]

### Stack and tools
[ANSWER TO QUESTION 5]

### Rules
[ANSWER TO QUESTION 6 — what to always do, conventions, agreements]

### Do not
[ANSWER TO QUESTION 6 — prohibitions, constraints, things to avoid]
```

**Important:** Block "Rules" is filled from answers to questions 5 and 6.
If the user gave explicit technical rules — copy them here verbatim.
If no rules were stated — write sensible defaults based on the stack.

Stack-specific rule examples:
- Arch Linux: "backup before editing any config", "AUR only via [manager]"
- Python: "virtual environment mandatory", "type hints for public functions"
- Node.js: "use npm ci, not npm install", "never commit node_modules"
- Telegram bot: "log all errors", "no hardcoded tokens"

## Step 5: Handle .gitignore based on $REPO_VISIBILITY

**If $REPO_VISIBILITY = "public":**

Add `CLAUDE.md` to the project's `.gitignore`.
Create `.gitignore` if it does not exist.

```
# .gitignore
# Claude Code — personal context, not for public repos
CLAUDE.md
CLAUDE.local.md
```

Inform the user:
```
⚠️  Public repo: CLAUDE.md added to .gitignore
    File stored locally only — will not be pushed to GitHub.
    On other devices, recreate it with /brain-init.
```

**If $REPO_VISIBILITY = "private":**

Do not add CLAUDE.md to .gitignore.
Inform the user:
```
✓ Private repo: CLAUDE.md can be committed.
  git add CLAUDE.md && git commit -m "add: Second Brain config"
  It will sync across devices automatically.
```

**If $REPO_VISIBILITY = "no repo":**

Do nothing with .gitignore.
Inform the user:
```
ℹ️  No repo: CLAUDE.md stored locally in current directory.
```

## Step 6: Update vault system files

**00-system/index.md** — add line in "Projects" section:
```
- [[PROJECT]] — [short description from question 1], [PROJECT_TYPE], active
```

## Step 7: Report result

```
✓ Project [PROJECT] created

Vault:     ~/Workspace/second-brain-vault/[PROJECT]/
CLAUDE.md: ./CLAUDE.md
Type:      [PROJECT_TYPE]
Arch map:  created / not applicable
Repo:      [public → in .gitignore | private → ready to commit | none]

Next step: place first sources in raw/
and run /brain-ingest raw/[file]

Example: /brain-ingest raw/README.md
```
