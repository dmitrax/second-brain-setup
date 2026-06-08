# Chat Skills

📖 [Read in English](README.md)

Скиллы для Claude.ai — дополняют slash-команды Claude Code
из основной системы second-brain-setup.

В отличие от `commands/brain-*.md` (которые работают внутри Claude Code),
эти скиллы работают в любом чате Claude, в проектах Claude.ai и в Cowork.

## Доступные скиллы

### brain-onboard

Переносит любой проект в систему Второго Мозга без открытия Claude Code.

Вызывается в любом чате где обсуждается проект — скилл читает контекст разговора,
задаёт только недостающие вопросы и генерирует готовый пакет файлов:
`CLAUDE.md`, `_PROJECT.md`, `taskboard.md` и setup-скрипт.

**Установка:** загрузи папку `brain-onboarding/` zip-архивом в Claude.ai → Customize → Skills  
**Триггер:** Slash command — `/brain-onboard`  
**Работает в:** обычных чатах, проектах Claude.ai, Cowork

**Когда использовать:**
- Работал над проектом в чате и хочешь перейти в Claude Code
- Есть существующий проект на диске — нужно подключить к vault
- Хочешь заполненный CLAUDE.md вместо пустого шаблона от `/brain-init`

**Отличие от brain-init:**  
`/brain-init` создаёт типовую структуру проекта прямо из Claude Code.  
`/brain-onboard` создаёт ту же структуру с реальным содержимым из контекста чата —
используй его когда контекст проекта уже есть в разговоре.

## Добавление новых скиллов

Каждый скилл живёт в отдельной папке с `SKILL.md` (обязателен) и `LICENSE.txt`.
Запакуй папку в zip и загрузи в Claude.ai → Customize → Skills.

```
chat-skills/
    [название-скилла]/
        SKILL.md      ← должен начинаться с YAML frontmatter (name + description)
        LICENSE.txt
```
