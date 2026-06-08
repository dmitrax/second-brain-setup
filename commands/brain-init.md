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
4. "What is the stack / tools? (languages, frameworks, services, key commands)"
5. "What are the main rules for this project? (what to always do / never do)"
6. "Is the repository public or private? (public / private / no repo)"

Save answer to question 6 as $REPO_VISIBILITY.

## Step 2: Create vault structure

```
~/Workspace/second-brain-vault/$ARGUMENTS/
├── _PROJECT.md
├── taskboard.md
├── raw/
├── wiki/
│   └── decisions/
├── output/
└── sessions/
```

```bash
VAULT=~/Workspace/second-brain-vault
PROJECT=$ARGUMENTS
mkdir -p "$VAULT/$PROJECT/raw"
mkdir -p "$VAULT/$PROJECT/wiki/decisions"
mkdir -p "$VAULT/$PROJECT/output"
mkdir -p "$VAULT/$PROJECT/sessions"
# taskboard.md created in Step 3b
```

## Step 3: Create _PROJECT.md

Use the user's answers. Fill in all blocks.
Note: ## For future Claude section in English; content blocks in Russian.

```markdown
---
tags: [project-manifest]
created: [TODAY]
status: active
brain-version: "1.0"
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
[ANSWER TO QUESTION 4]

## Стиль работы
[ANSWER TO QUESTION 5 — preferences, not rules; rules go in CLAUDE.md]

## Ключевые решения
→ [[wiki/decisions/]]

## Последняя сессия
[TODAY] — project initialized
```

## Step 3b: Create project taskboard.md

File: `$VAULT/$PROJECT/taskboard.md`

```markdown
# Taskboard — [PROJECT]

## На этой неделе

## Зависло / откладываю

## Принятые решения
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
4. Tasks with no progress for 3+ days → flag explicitly:
   "🚨 [Task] stalled for N days. Reason: [reason]. Decompose now?"
5. Read: [PROJECT]/wiki/ — only files relevant to the current task

---

## Project: [PROJECT]

### Stack and tools
[ANSWER TO QUESTION 4]

### Rules
[ANSWER TO QUESTION 5 — what to always do, conventions, agreements]

### Do not
[ANSWER TO QUESTION 5 — prohibitions, constraints, things to avoid]
```

**Important:** Block "Rules" is filled from answers to questions 4 and 5.
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
- [[PROJECT]] — [short description from question 1], active
```

## Step 7: Report result

```
✓ Project [PROJECT] created

Vault:    ~/Workspace/second-brain-vault/[PROJECT]/
CLAUDE.md: ./CLAUDE.md
Repo:     [public → in .gitignore | private → ready to commit | none]

Next step: place first sources in raw/
and run /brain-ingest raw/[file]

Example: /brain-ingest raw/README.md
```
