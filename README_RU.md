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
~/Workspace/projects/dotfiles/              ← ваш код (обычный репозиторий)
    CLAUDE.md                     ← МОСТ: указывает на vault

~/Workspace/second-brain-vault/   ← Obsidian Vault (приватный репо)
    dotfiles/                     ← знания по проекту
        _PROJECT.md               ← что, зачем, текущий статус
        taskboard.md              ← задачи проекта
        architecture-map.md       ← карта кода (только code/mixed проекты)
        raw/                      ← сырые источники (конфиги, транскрипты)
        wiki/                     ← скомпилированные знания (пишет Claude)
            decision-*.md         ← записи решений (неизменяемые, ADR-lite)
        sessions/                 ← логи сессий
    00-system/                    ← карта vault и связи между проектами
    00-shared/                    ← кто вы: CRITICAL_FACTS.md + SOUL.md
```

При старте сессии Claude читает `CRITICAL_FACTS.md` + `_PROJECT.md` + `taskboard.md`
(~450 токенов) и сразу знает весь контекст. Для кодовых проектов также читает
`architecture-map.md` — карту маршрутов/модулей, которая заменяет сканирование репозитория.

## Быстрый старт

```bash
# 1. Клонируй репо
git clone https://github.com/[username]/second-brain-setup
cd second-brain-setup

# 2. Установка (создаёт vault + копирует команды в ~/.claude/)
bash install.sh

# 3. Заполни профиль — один раз
cd ~/Workspace/projects/any-folder && claude
> /brain-setup

# 4. Создай первый проект
mkdir ~/Workspace/projects/dotfiles && cd ~/Workspace/projects/dotfiles && claude
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

## Chat Skills

Скиллы для Claude.ai — дополняют slash-команды Claude Code.
Работают в любом чате, проектах Claude.ai и Cowork — без Claude Code.

| Скилл | Триггер | Когда |
|---|---|---|
| `brain-onboard` | `/brain-onboard` | Перенести проект из чата в Claude Code |

Установка: запакуй папку скилла в zip → Claude.ai → Customize → Skills.
Подробнее: [chat-skills/README_RU.md](chat-skills/README_RU.md)

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
cd ~/Workspace/second-brain-vault && git pull
# после /brain-save:
git add . && git commit -m "$(date +%Y-%m-%d)" && git push
```

Важно: используйте одинаковый путь к vault на всех устройствах (`~/Workspace/second-brain-vault/`).

## Совместимость

Команды написаны на английском и следуют стандарту [AGENTS.md](https://agentsfoundation.ai).

Работает с: Claude Code, Codex CLI, Gemini CLI, Cursor, Windsurf.
Для других агентов: переименуйте `CLAUDE.md` → `AGENTS.md`.

## Версионирование

С v1.4.0 — semver (`MAJOR.MINOR.PATCH`). `PATCH` — багфиксы без нового поведения,
`MINOR` — новые обратно-совместимые фичи/правила, `MAJOR` — breaking changes со
скриптом миграции. Теги `v1.0`–`v1.3` остались под прежней грубой схемой
("v1.x = всё аддитивное") и не переразмечены задним числом.

```bash
# Обновить команды после изменений
bash update.sh
```
**Обновление с v1.0 → v1.1** (путь к vault изменился):
```bash
mv ~/Documents/second-brain-vault ~/Workspace/second-brain-vault
# Затем обновите строку Vault: в CLAUDE.md каждого проекта
```

## Документация

- [WORKFLOW.md](WORKFLOW.md) — пошаговое руководство пользователя
- [ВТОРОЙ_МОЗГ_v1.5.0.md](ВТОРОЙ_МОЗГ_v1.5.0.md) — полная архитектурная справка
- [chat-skills/README_RU.md](chat-skills/README_RU.md) — скиллы для Claude.ai

## Changelog

### v1.5.0 — 2026-07-22

- **`_obsidian_available()` теперь проверяет, *какой* vault открыт** — сверяет
  `obsidian vault info=name` с `basename "$VAULT"`, а не только exit code. Все пути CLI
  относительны активному vault, поэтому переключённый в GUI другой vault молча уводил
  записи туда — exit 0, без предупреждения. Ожидаемое имя выводится из пути к vault,
  не хардкодится.
- **Step 0b в `/brain-save` больше не использует `obsidian property:set`** — правит поле
  `updated:` напрямую. `property:set` пересобирает *весь* frontmatter: снимает кавычки
  (`"1.4.3"` → `1.4.3`), разворачивает инлайн-списки в блочные (`tags: [session]`) и
  переинтерпретирует числоподобные значения (`007` → `7` — потеря данных). Guard в
  `/brain-save` больше не нужен вовсе; в `/brain-lint` он остаётся для read-only запросов.
- **Supersession decision-заметок — теперь два поля**: `status: superseded` и
  `superseded-by: <файл>`. Прежняя однострочная форма `status: superseded-by: <файл>`
  была невалидным YAML (двойное двоеточие), из-за чего Obsidian вообще не мог прочитать
  frontmatter такой заметки. `/brain-lint` Step 10 теперь помечает legacy-форму.

**Обновление с v1.4.x → v1.5.0:** запусти `update.sh`. Существующие заметки с
однострочной формой `status: superseded-by:` продолжают работать как текст, но невидимы
для property-запросов — раздели их на два поля (`/brain-lint` их покажет).

### v1.4.0 — 2026-07-20

- **`_PROJECT.md` больше не дублирует wiki** — `Current state` (только статус/блокеры),
  `Последняя сессия` (теперь обязательна, максимум ~5 однострочных записей) и собственная
  `For future Claude` файла (ограничена ~15-20 строками) — все три ссылаются на
  wiki/decision-заметки вместо пересказа их механизма. Устраняет реально найденный дрейф:
  `_PROJECT.md` одного проекта дорос до 519 строк, повторяя целиком пересказы сессий,
  которые уже были в wiki-заметках.
- **`/brain-lint`**: новые проверки размера/дублирования для всех трёх секций выше —
  срабатывают независимо от порога ~120 строк, ловят паттерн раньше.
- Принят semver (см. `CLAUDE.md` → Key rules) — этот релиз первый под новой схемой.

**Обновление с v1.3 → v1.4.0:**
```bash
# Миграция vault не нужна — все изменения аддитивны (новые правила + проверки линта).
bash update.sh
```

### v1.3 — 2026-06-23

- **Obsidian CLI интеграция** — опциональное усиление, когда запущен Obsidian 1.12.7+ с включённым CLI.
- **Guard `_obsidian_available()`** — каждый CLI-вызов обёрнут; система откатывается на файловую
  систему, если Obsidian не запущен или если открыт не тот vault, с которым работает команда.
- **`/brain-lint`**: Step 1 использует `obsidian orphans` когда доступен; новый Step 1b проверяет битые ссылки (`obsidian unresolved`, `obsidian deadends`); Step 11 добавляет проверку ссылок для architecture-map; Result-блок сообщает `Broken links (CLI)`.
- **`/brain-save`**: Step 0b правит поле `updated:` во frontmatter напрямую и не использует CLI вовсе
  (с v1.5.0 — `property:set` пересобирал весь frontmatter и терял данные).
- **`SKILL.md`**: новое правило в Principles — переименования через `obsidian move` сохраняют [[backlinks]]; никогда не переименовывать через файловую систему пока Obsidian запущен.
- **`/brain-init`**: шаблон CLAUDE.md включает секцию `### Obsidian CLI`.

**Обновление с v1.2 → v1.3:**
```bash
# Миграция vault не нужна — все изменения аддитивны.
bash update.sh
# Чтобы включить CLI: Obsidian → Settings → General → Command line interface
```

### v1.2 — 2026-06-09

- **architecture-map.md** — новый файл для code/mixed проектов: маршрут/модуль → файл → источник данных → компоненты. Читается на старте каждой code-сессии; не сканируй репозиторий. `/brain-save` обновляет, `/brain-lint` проверяет свежесть.
- **Decision notes (ADR-lite)** — `wiki/decision-<slug>-because-<reason>.md`. Неизменяемые записи с Y-statement, альтернативами и последствиями. Замещаются, а не редактируются. `/brain-save` создаёт по триггеру.
- **Critical thinking & warn clause** во всех CLAUDE.md шаблонах: нет автолести; одна строка предупреждения перед деструктивными действиями.
- **Tier navigation**: нет полного сканирования vault или репозитория — индекс и grep.
- **Поле `updated:`** в frontmatter `_PROJECT.md`. Обновляется `/brain-save`. Используется stale-детектором `/brain-lint` (порог 14 дней).
- **`/brain-lint` дополнения**: stale-детектор проектов, проверка размера, консистентность decision-заметок, свежесть architecture-map.
- **`/brain-save` лог сессии** улучшен: добавлены секции "What worked" и "Tech debt found, not fixed".
- Decision-заметки теперь flat в `wiki/` (удалена конвенция подпапки `wiki/decisions/`).
- `brain-init` добавил вопрос о типе проекта (code/content/config/mixed).

### v1.1 — 2026-06-08

**Путь к vault перенесён в `~/Workspace/` — устраняет конфликт с iCloud Drive на macOS.**

- Путь по умолчанию: `~/Documents/second-brain-vault/` → `~/Workspace/second-brain-vault/`
- `install.sh` создаёт `~/Workspace/` при установке автоматически
- Рекомендуемое расположение кода: `~/Workspace/projects/` (не обязательно)
- Единый путь на macOS и Linux

**Chat Skills:**
- `brain-onboard` — новый скилл для Claude.ai: переносит проект из контекста чата
  в vault Второго Мозга (генерирует CLAUDE.md, _PROJECT.md, taskboard.md)

---

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
