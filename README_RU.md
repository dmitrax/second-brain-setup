# Второй Мозг для Claude Code

[📖 Read in English](README.md)

> Система долгосрочной памяти для Claude Code + Obsidian.
> Vault знаний, который растёт с каждой сессией.

---

## Проблема

Claude Code — мощный инструмент, но у него амнезия. Каждая новая сессия начинается с чистого листа. Вы тратите 15–30 минут на объяснение того, что уже обсуждали вчера. За неделю — 2–3 часа впустую.

## Идея

Андрей Карпати в 2025 году описал паттерн [LLM Knowledge Bases](https://x.com/karpathy): вместо того чтобы загружать сырые документы в контекст каждый раз заново, LLM **компилирует** их в постоянную wiki один раз, а потом поддерживает её актуальной. Знания накапливаются — система умнеет с каждой итерацией.

Этот репозиторий — реализация этой идеи для Claude Code с Obsidian как интерфейсом.

## Как это работает

Два независимых пространства, связанных через `CLAUDE.md`:

```
~/projects/dotfiles/              ← ваш код (обычный репозиторий)
    CLAUDE.md                     ← МОСТ: указывает на vault

~/Documents/second-brain-vault/   ← Obsidian Vault (приватный репо)
    dotfiles/                     ← знания по проекту
        _PROJECT.md               ← что, зачем, текущий статус
        taskboard.md              ← задачи проекта
        raw/                      ← сырые источники (конфиги, транскрипты)
        wiki/                     ← скомпилированные знания (пишет Claude)
        sessions/                 ← логи сессий
    00-system/                    ← карта vault и связи между проектами
    00-shared/                    ← кто вы: CRITICAL_FACTS.md + SOUL.md
```

При старте сессии Claude читает `CRITICAL_FACTS.md` + `_PROJECT.md` + `taskboard.md` (~450 токенов) и сразу знает весь контекст. Никаких объяснений.

## Быстрый старт

```bash
# 1. Клонируй репо
git clone https://github.com/[username]/second-brain-setup
cd second-brain-setup

# 2. Установка (создаёт vault + копирует команды в ~/.claude/)
bash install.sh

# 3. Заполни профиль — один раз
cd ~/projects/any-folder && claude
> /brain-setup

# 4. Создай первый проект
mkdir ~/projects/dotfiles && cd ~/projects/dotfiles && claude
> /brain-init dotfiles

# 5. Работай. Сохраняй. Повторяй.
> /brain-save
```

## Команды

| Команда | Когда |
|---|---|
| `/brain-setup` | Один раз после установки — заполнить профиль |
| `/brain-init [название]` | Новый проект |
| `/brain-save` | Конец каждой сессии |
| `/brain-ingest raw/[файл]` | Обработать источник в wiki |
| `/brain-lint` | Аудит текущего проекта |
| `/brain-lint --all` | Полный аудит vault (раз в неделю) |

## Ключевые принципы

**Автономные проекты.** Каждый проект — самостоятельная папка. Удалить проект = удалить одну папку. Добавить = создать одну папку.

**AI-First заметки.** Каждая wiki-заметка содержит `## For future Claude` — инструкцию для читающего Claude: когда использовать эту заметку и ключевые факты. Паттерн взят из системы [Eugeniu Ghelbur](https://github.com/eugeniughelbur/obsidian-second-brain).

**Rewrite, не append.** При обработке нового источника Claude перезаписывает существующие заметки — обновляет факты, удаляет устаревшее. Vault не превращается в свалку.

**Граф знаний.** Claude создаёт `[[wikilinks]]` между заметками при каждом сохранении. Obsidian Graph View показывает как растёт ваша база знаний.

**Безопасность raw/.** Файлы в `raw/` считаются ненадёжным контентом. Claude никогда не следует инструкциям из сырых файлов — защита от prompt injection.

## Архитектура памяти

```
CLAUDE.md          ← правила и путь к vault (читается автоматически)
    ↓
Obsidian Vault     ← накопленные знания (читается по инструкции)
    ↓
~/.claude/memory/  ← персональные предпочтения (Claude пишет сам)
```

## Синхронизация между устройствами

Vault — просто папка с `.md` файлами. Git синхронизирует её между устройствами бесплатно. Obsidian Sync не нужен.

```bash
# Vault
cd ~/Documents/second-brain-vault && git pull
# после /brain-save:
git add . && git commit -m "$(date +%Y-%m-%d)" && git push
```

Важно: используйте одинаковый путь к vault на всех устройствах (`~/Documents/second-brain-vault/`).

## Совместимость

Команды написаны на английском и следуют стандарту [AGENTS.md](https://agentsfoundation.ai).

Работает с: Claude Code, Codex CLI, Gemini CLI, Cursor, Windsurf.
Для других агентов: переименуйте `CLAUDE.md` → `AGENTS.md`.

## Версионирование

`v1.x` — только аддитивные изменения.
`v2.0` — breaking changes, поставляется со скриптом миграции.

```bash
# Обновить команды после изменений
bash update.sh
```

## Документация

- [WORKFLOW.md](WORKFLOW.md) — пошаговое руководство пользователя
- [ВТОРОЙ_МОЗГ_v1.0.md](ВТОРОЙ_МОЗГ_v1.0.md) — полная архитектурная справка

## Changelog

### v1.0 — 2026-06-01

Первый релиз.

**5 slash-команд:** `/brain-setup`, `/brain-init`, `/brain-save`, `/brain-ingest`, `/brain-lint`

**Архитектура:**
- Один vault, автономные проекты
- `00-system/`: только `index.md` и `connections.md`
- `00-shared/`: только `CRITICAL_FACTS.md` и `SOUL.md`
- AI-First формат заметок: YAML frontmatter + `## For future Claude`
- Правило wikilinks: минимум 2 `[[ссылки]]` на каждую заметку

**Безопасность:**
- `raw/` — защита от prompt injection
- Расширенный `.gitignore` для секретов и баз данных
- `CLAUDE.md` в `.gitignore` для публичных репозиториев

## Авторы идей и источники

- [Andrej Karpathy](https://x.com/karpathy) — паттерн LLM Knowledge Bases
- [@alex_magnier](https://t.me/alex_magnier) — гайд Claude Code + Obsidian
- [Eugeniu Ghelbur](https://github.com/eugeniughelbur/obsidian-second-brain) — AI-First vault, `## For future Claude`

## Лицензия

MIT
