# /brain-setup

First-time setup: fill CRITICAL_FACTS.md and SOUL.md.
Run once after installation, or to refresh your profile.

## Step 1: Check current state

Read `~/Documents/second-brain-vault/00-shared/CRITICAL_FACTS.md`
and `~/Documents/second-brain-vault/00-shared/SOUL.md`.

If files contain placeholder text (e.g. "(заполни)") → proceed with setup.
If already filled → ask: "Эти файлы уже заполнены. Обновить? (да / нет)"
If answer is "нет" → stop.

## Step 2: Fill CRITICAL_FACTS.md

Ask questions one by one, wait for each answer:

1. "Как тебя зовут?"
2. "Часовой пояс? (например: Europe/Berlin UTC+2)"
3. "На каких устройствах работаешь?"
4. "Путь к vault? (по умолчанию: ~/Documents/second-brain-vault/)"
5. "Язык работы? (по умолчанию: русский)"
6. "Твои основные роли? (например: лидер FieldForce, вайб-кодер)"

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

1. "Опиши себя в 2-3 предложениях: ценности, чем занимаешься, что важно"
2. "Как ты думаешь и принимаешь решения?"
3. "Как тебе нравится работать с ИИ? (тон, формат, скорость vs качество)"
4. "Что раздражает в работе с ИИ?"

Write to `00-shared/SOUL.md` in Russian.

```markdown
# Soul

## Кто я
[ANSWER 1]

## Как я думаю
[ANSWER 2]

## Как мне нравится работать с ИИ
[ANSWER 3]

## Чего не терплю
[ANSWER 4]
```

## Step 4: Confirm

Show the filled content of both files.
Ask: "Всё верно? (да / исправить)"
If "исправить" → ask which file and what to change, then redo.

## Result

```
✓ Setup complete

00-shared/CRITICAL_FACTS.md — filled
00-shared/SOUL.md — filled

Next: create your first project with /brain-init [project-name]
```
