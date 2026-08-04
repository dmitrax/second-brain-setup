# /brain-init

Create a new project in the Second Brain system.

## Arguments
`$ARGUMENTS` = project name (e.g.: dotfiles, tg-bot, content-kit)

If no name provided — ask for it as the first question.

## Step 0: Sync the vault before writing anything

```bash
VAULT="$HOME/Workspace/second-brain-vault"
BRAIN="$HOME/.claude/skills/second-brain/lib/brain.sh"
bash "$BRAIN" vault-sync "$VAULT"; rc=$?
```

- **0** → synced, or skipped on purpose (local-only vault is supported). Proceed.
- **2** → remote unreachable. Say so in one line and proceed; never let it block the work.
- **3** → rebase conflict, vault is mid-rebase. **Stop, create nothing**, hand the listed
  files to the user.

This runs *before* the questions, not just before the writes. `/brain-init` appends to
`00-system/index.md` — one of the registries every machine edits — so a stale checkout
conflicts at push by construction. And asking the user seven questions only to fail on
the first write afterwards is the worse order: find out the vault is unusable while it
still costs nothing.

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
Note: `## For future Claude` is always English — it is read by Claude, not by a human.
The other blocks follow the vault's working language; see "Which language the headings
are written in" below before writing anything.

`[BRAIN_VERSION]` is the **actual installed version**, never a literal typed here:

```bash
bash "$HOME/.claude/skills/second-brain/lib/brain.sh" version
```

Until v1.7.0 this template carried a hardcoded `brain-version: "1.5.0"`, which had to be
edited by hand at every release and of course was not — so every project created after
v1.6.0 would have been stamped with a version it never ran. Measured 2026-08-03: 8
projects claim `1.3`, two claim `1.5.0`, none claim 1.6.0, and no command reads or
updates the field. It is stamped by `/brain-save` from now on, which is what makes it
mean something.

### Which language the headings are written in

Run this **before** writing the template:

```bash
bash "$HOME/.claude/skills/second-brain/lib/brain.sh" vault-language "$VAULT"
```

Exit **0** prints the vault owner's answer · **2** the key is there but unanswered ·
**1** there is no profile file at all. On 1 or 2, say so in one line and use English.
The value is raw and may name two languages for two purposes ("Russian in chat, English
in code and commits") — that is a judgement to read, not a token to switch on.

Then, and this is the part that is not free choice:

- **A section the tooling matches is written in English, always, in every new file** —
  `## Current state`, `## Last session`, `## For future Claude`, and in the taskboard
  `## In progress`, `## Backlog`, `## Done`. A matched name is an identifier: it is what
  `prose-budget`, `sweep-closed`, `archive` and `/brain-lint` search for literally, and
  identifiers are never translated (see `SKILL.md`, "Language of everything you say to
  the user"). **Never invent a third spelling** — `## Текущее состояние` is invisible to
  every one of those, and invisible silently, because a section that is not found and a
  section that is empty look the same from outside.
- **Every other heading is free prose** (`Что это` / `What this is`, `Цель` / `Goal`,
  the stack and working-style sections) and follows the vault's language with no
  constraint at all. This is where the vault-language answer above is spent.
- **The Russian spellings stay matched forever** — `Статус`, `Последняя сессия`,
  `В работе`, `Завершено` remain in every alternation in `lib/brain.sh` and are not going
  away. They are how existing files keep working, not a choice offered to a new one.
- **Never rename a heading in an existing file.** Renaming breaks nothing mechanically —
  both spellings are matched — but it rewrites history for no gain, and `/brain-save`
  already forbids it.

Why English rather than "pick what fits the vault's language", which is what this file
said until 2026-08-04: that instruction had no way to converge. Measured the same day on
this vault — all 9 taskboards were English while `_PROJECT.md` was split 6 projects to 4,
and a `/brain-init` run following the instruction literally produced a Russian taskboard
unlike any of the nine. The split does not come from carelessness; it comes from asking a
question that has two right answers. Making the matched vocabulary an identifier removes
the question. Existing files are left exactly as they are.

```markdown
---
tags: [project-manifest]
created: [TODAY]
updated: [TODAY]
status: active
type: [PROJECT_TYPE]
brain-version: "[BRAIN_VERSION]"
---

## For future Claude
Read this file at the start of EVERY session for project [NAME].
Full context here: what we are building, current status, how to work.

# _PROJECT.md — [NAME]

## What this is
[ANSWER TO QUESTION 1 — in the vault's working language]

## Goal
[ANSWER TO QUESTION 2 — in the vault's working language]

## Current state
[ANSWER TO QUESTION 3]

## Stack / tools
[ANSWER TO QUESTION 5]

## Working style
[ANSWER TO QUESTION 6 — preferences, not rules; rules go in CLAUDE.md]

## Key decisions
[Significant decisions live as immutable decision-*.md notes in wiki/.
List active ones here as [[wikilinks]]. If none yet — write "No major decisions made yet."]

## Last session
(matched section — English in every new file, see the language rule above)
[TODAY] — project initialized
```

`updated:` is bumped by `/brain-save` on every session that changes project state.
`/brain-lint` flags the project as stale when `updated` is more than 14 days old.

## Step 3b: Create project taskboard.md

File: `$VAULT/$PROJECT/taskboard.md`

Every heading here is a matched section — `sweep-closed` moves items between the first
and the third, `archive` empties the third, `prose-budget` measures both. So they are
written in English exactly as below, whatever the vault's working language; the rule and
its reasoning are in Step 3 above. The task *text* follows the vault's language.

```markdown
# Taskboard — [PROJECT]

## In progress

## Backlog

## Done
```

A closed task at the top level carries the date it was closed — `- [x] YYYY-MM-DD …`.
This is not decoration: `archive` moves dated entries and cannot move undated ones, so an
entry written without a date is one no tool will ever be able to file. Measured
2026-08-04 in this project — 35 closed entries, 2 of them dated, and a threshold that no
amount of running `archive` could satisfy. `sweep-closed` warns about undated items, but
it warns *after* the item has already lost its date, which is too late to be the only
place this is said. A closed **sub-item** under an open task needs no date; it is not an
archivable entry and is not counted as one.

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
0. Sync the vault BEFORE reading anything from it — the vault is shared across machines,
   and a stale checkout reads as current:
   `bash "$HOME/.claude/skills/second-brain/lib/brain.sh" vault-sync "$HOME/Workspace/second-brain-vault"`
   Exit 0 → proceed. 2 → say so in one line and proceed. 3 → conflict, stop and report.
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

### Obsidian CLI
Requires Obsidian 1.12.7+ with CLI enabled (Settings → General → Command line interface).
Obsidian must be running. The system works without CLI — it's optional enhancement.
**The CLI is read-only here.** Queries only — `orphans`, `unresolved`, `deadends`,
`vault info` — and each behind the guard `bash
"$HOME/.claude/skills/second-brain/lib/brain.sh" obsidian-available "$VAULT"`, one copy of
code that everyone calls: a zero exit from the CLI proves only that *some* vault is open,
and every path is relative to that one. Call the guard, never reconstruct it inline —
every clause in it encodes a separate incident.

Nothing writes to the vault through the CLI. `property:set` re-serializes the whole
frontmatter block and loses data. `obsidian move` set a vault setting nobody asked for and
then corrupted 8 places in 6 files from a stale cache, minutes after the call returned 0
(measured 2026-08-04). Renames go through `bash "$BRAIN" rename "$VAULT" <old> <new>
--apply`, which repoints links itself; edit frontmatter directly with a normal file edit.
Address any query with `path=<project>/<name>.md` (exact), never `file=<name>` — `file=`
resolves by name like a wikilink and silently targets another project's file.

---

## Project: [PROJECT]

### Rules
[ANSWER TO QUESTION 6 — what to always do, conventions, agreements]

### Do not
[ANSWER TO QUESTION 6 — prohibitions, constraints, things to avoid]
```

**Important:** Block "Rules" is filled from answers to questions 5 and 6.
If the user gave explicit technical rules — copy them here verbatim.
If no rules were stated — write sensible defaults based on the stack.

**From answer 5, only the constraints reach this file** — "pnpm, never npm", "python via
pyenv, the system one breaks X", a build command that cannot be guessed. They go into
`Rules`, not into a section of their own. The inventory — which languages, frameworks and
services the project uses — is already written by Step 3 into `_PROJECT.md` and by Step 3c
into `architecture-map.md`, and `/brain-save` keeps both current. A third copy here would
be the only one no command ever updates, and for a public repo Step 5 also puts this file
in `.gitignore`, so it is the one copy nobody sees changing. Until v1.7.0 the template did
carry a `### Stack and tools` section: measured 2026-08-04 in `second-brain-setup`, its
copy still named three bash scripts six weeks after `lib/brain.sh` became the fourth,
while the vault copy was right the whole time. Checked by preflight 10b.

**The template has no status section on purpose.** This file loads in full at every
session start, before the topic is known, so it holds only what cannot expire — rules,
prohibitions, hardware limits, resolved gotchas. Project status lives in `_PROJECT.md`
and `taskboard.md`. Do not add `## Current state` / `## Статус` here later either;
see `SKILL.md`, "What belongs where".

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

**Consequence to state out loud, not just record:** an ignored `CLAUDE.md` has no git
history, no diff at commit time, and no review — so anything wrong in it drifts
invisibly and indefinitely. That is a second, independent reason nothing expiring may
be written there (see `SKILL.md`, "What belongs where"): the vault is versioned and
this file is not. Confirmed live on `dimarch` 2026-07-25 — six stale facts, none of
which any commit would ever have shown.

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

**00-system/index.md** — add a line under the registry's projects heading. That heading
is vault content, not a matched section, so it carries whatever the vault already uses —
here `## Проекты`. Find it, do not assume its spelling:
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
