# /brain-setup

First-time setup: fill CRITICAL_FACTS.md and SOUL.md.
Run once after installation, or to refresh your profile.

## Step 1: Check current state

Read `~/Workspace/second-brain-vault/00-shared/CRITICAL_FACTS.md`
and `~/Workspace/second-brain-vault/00-shared/SOUL.md`.

If files contain placeholder text (e.g. "(fill in)") → proceed with setup.
If already filled → ask: "These files are already filled in. Update them? (yes / no)"
If answer is "no" → stop.

## Step 2: Fill CRITICAL_FACTS.md

Ask questions one by one, wait for each answer:

1. "What is your name?"
2. "Time zone? (e.g. Europe/Berlin UTC+2)"
3. "Which devices do you work on?"
4. "Path to the vault? (default: ~/Workspace/second-brain-vault/)"
5. "Working language? Claude will answer in it, and templates will use it for free-prose headings."
6. "Your main roles? (e.g. team lead, hobby coder)"

Write to `00-shared/CRITICAL_FACTS.md`. Keep under 120 tokens.

```markdown
# Critical Facts

Name: [ANSWER 1]
Timezone: [ANSWER 2]
Devices: [ANSWER 3]
Vault: [ANSWER 4]
Working language: [ANSWER 5]
Roles: [ANSWER 6]
```

## Step 3: Fill SOUL.md

Ask questions one by one:

1. "Describe yourself in 2-3 sentences: values, what you do, what matters"
2. "How do you think and make decisions?"
3. "How do you like working with AI? (tone, format, speed vs quality)"
4. "What irritates you when working with AI?"

Write to `00-shared/SOUL.md` in Russian.

```markdown
# Soul

## Who I am
[ANSWER 1]

## How I think
[ANSWER 2]

## How I like working with AI
[ANSWER 3]

## What I cannot stand
[ANSWER 4]
```

## Step 4: Confirm

Show the filled content of both files.
Ask: "Is this all correct? (yes / fix)"
If "fix" → ask which file and what to change, then redo.

## Result

```
✓ Setup complete

00-shared/CRITICAL_FACTS.md — filled
00-shared/SOUL.md — filled

Next: create your first project with /brain-init [project-name]
```
The labels above are written in English here because this file is; **print them in the
vault's working language** (`brain.sh vault-language`), and leave every identifier —
finding keys, paths, section and command names — exactly as it is. See `SKILL.md`,
"Language of everything you say to the user".

