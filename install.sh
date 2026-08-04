#!/usr/bin/env bash
# install.sh — install the "Second Brain" skill for Claude Code
set -e

# ─── Settings ────────────────────────────────────────────────────────────────
VAULT="${SECOND_BRAIN_VAULT:-$HOME/Workspace/second-brain-vault}"
mkdir -p ~/Workspace  # ensure ~/Workspace exists
SKILL_DIR="$HOME/.claude/skills/second-brain"
COMMANDS_DIR="$HOME/.claude/commands"

# Non-interactive mode: when stdin is not a terminal (CI, preflight.sh, a pipe) or
# SECOND_BRAIN_NONINTERACTIVE=1 is set, every question is skipped and defaults are used.
# Without this, `set -e` plus `read` aborted the script on the very first question at
# EOF, which made the install impossible to test except by hand at a keyboard.
if [ -t 0 ] && [ -z "$SECOND_BRAIN_NONINTERACTIVE" ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

# ask <prompt> <variable name> — asks only in interactive mode
ask() {
    if [ "$INTERACTIVE" = "1" ]; then
        read -r -p "$1" "$2" || true
    else
        printf -v "$2" '%s' ""
    fi
}

# ─── Output colours ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━ Установка skill: Второй Мозг ━━━${NC}"
echo ""

# ─── Ask for the vault path if not given ─────────────────────────────────────
echo -e "Путь к vault: ${YELLOW}$VAULT${NC}"
ask "Изменить? (Enter = оставить, или введи новый путь): " CUSTOM_VAULT
if [ -n "$CUSTOM_VAULT" ]; then
    VAULT="$CUSTOM_VAULT"
fi

# ─── Create directories ──────────────────────────────────────────────────────
echo ""
echo "Создаю директории..."

mkdir -p "$SKILL_DIR"
mkdir -p "$COMMANDS_DIR"

# Vault layout
mkdir -p "$VAULT/00-system" "$VAULT/00-shared"

# ─── Copy the skill files ────────────────────────────────────────────────────
echo "Устанавливаю skill файлы..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"

# lib/ holds the deterministic helpers the prompts call. Installed before the commands:
# a command referring to a missing brain.sh degrades silently into "CLI unavailable".
if [ -f "$SCRIPT_DIR/lib/brain.sh" ]; then
    mkdir -p "$SKILL_DIR/lib"
    cp "$SCRIPT_DIR/lib/brain.sh" "$SKILL_DIR/lib/brain.sh"
    chmod +x "$SKILL_DIR/lib/brain.sh"
    # The version is written next to the script: otherwise the installed system does
    # not know its own version and cannot report that it lags behind what the vault
    # already records.
    # --dirty: the normal working order is edit -> update.sh (try it) -> commit, so
    # without the suffix VERSION records `describe` from BEFORE the commit and silently
    # trails the installed code. Measured 2026-08-03: _PROJECT.md received -10-g34f5287
    # against the actual -12-g9a657fe. The -dirty suffix makes the lag visible in the
    # stamp itself.
    INSTALLED_VERSION=$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo "v1.0-dev")
    printf '%s\n' "$INSTALLED_VERSION" > "$SKILL_DIR/lib/VERSION"
    echo -e "  ${GREEN}✓${NC} lib/brain.sh + VERSION ($INSTALLED_VERSION) → $SKILL_DIR/lib/"
else
    echo -e "  ${YELLOW}!${NC} lib/brain.sh не найден — команды будут работать без CLI"
fi

for cmd in brain-setup brain-init brain-save brain-ingest brain-lint; do
    if [ -f "$SCRIPT_DIR/commands/$cmd.md" ]; then
        cp "$SCRIPT_DIR/commands/$cmd.md" "$COMMANDS_DIR/$cmd.md"
        echo -e "  ${GREEN}✓${NC} /commands/$cmd.md → ~/.claude/commands/"
    else
        echo -e "  ${YELLOW}!${NC} $cmd.md не найден — пропускаю"
    fi
done

# ─── Create the vault system files (only if absent) ──────────────────────────
echo ""
echo "Инициализирую vault системные файлы..."

# index.md
if [ ! -f "$VAULT/00-system/index.md" ]; then
    cat > "$VAULT/00-system/index.md" << 'EOF'
# Index

## Проекты
(проекты появятся после /brain-init)

## Последние изменения
EOF
    echo -e "  ${GREEN}✓${NC} 00-system/index.md"
fi

# connections.md
if [ ! -f "$VAULT/00-system/connections.md" ]; then
    cat > "$VAULT/00-system/connections.md" << 'EOF'
# Connections — связи между проектами

## Общие знания

## Перетоки знаний

## Последнее обновление
(обновляется автоматически при /brain-lint)
EOF
    echo -e "  ${GREEN}✓${NC} 00-system/connections.md"
fi

# CRITICAL_FACTS.md
if [ ! -f "$VAULT/00-shared/CRITICAL_FACTS.md" ]; then
    cat > "$VAULT/00-shared/CRITICAL_FACTS.md" << EOF
# Critical Facts

Имя: (заполни)
Часовой пояс: (заполни, например: Europe/Berlin UTC+2)
Устройства: (заполни)
Vault: $VAULT
Язык работы: русский
(добавь другие ключевые факты о себе — максимум ~120 токенов)
EOF
    echo -e "  ${GREEN}✓${NC} 00-shared/CRITICAL_FACTS.md"
    echo -e "  ${YELLOW}→ Заполни CRITICAL_FACTS.md своими данными!${NC}"
fi

# SOUL.md
if [ ! -f "$VAULT/00-shared/SOUL.md" ]; then
    cat > "$VAULT/00-shared/SOUL.md" << 'EOF'
# Soul

## Кто я
(2-3 предложения: ценности, чем занимаюсь, что важно)

## Как я думаю
(стиль мышления, как принимаю решения)

## Как мне нравится работать с ИИ
(предпочтения: тон, формат, скорость vs качество)

## Чего не терплю
(что раздражает в работе с ИИ)
EOF
    echo -e "  ${GREEN}✓${NC} 00-shared/SOUL.md"
    echo -e "  ${YELLOW}→ Заполни SOUL.md своими данными!${NC}"
fi

# .gitignore
if [ ! -f "$VAULT/.gitignore" ]; then
    cat > "$VAULT/.gitignore" << 'EOF'
# Obsidian workspace
.obsidian/workspace*
.obsidian/cache

# Бинарные файлы — обрабатывай через Whisper, в vault клади только транскрипты
raw/**/*.mp3
raw/**/*.mp4
raw/**/*.m4a
raw/**/*.wav
raw/**/*.pdf

# Системное
.DS_Store
*.swp

# Секреты и ключи
.env
.env.*
*.key
*.pem
*.p12
id_rsa
id_ed25519
credentials.json
token.json
secrets.*

# Базы данных
*.sqlite
*.sqlite3
*.db

# Claude Code локальный контекст
.claude/
CLAUDE.local.md
EOF
    echo -e "  ${GREEN}✓${NC} .gitignore"
fi

# ─── Git initialisation ──────────────────────────────────────────────────────
echo ""
if [ ! -d "$VAULT/.git" ]; then
    ask "Инициализировать Git в vault? (y/n): " INIT_GIT
    if [ "$INIT_GIT" = "y" ]; then
        cd "$VAULT"
        git init
        git add .
        git commit -m "init: Second Brain vault"
        echo -e "  ${GREEN}✓${NC} Git инициализирован"
        echo ""
        ask "Добавить remote репозиторий? (Enter = пропустить, или вставь URL): " REMOTE_URL
        if [ -n "$REMOTE_URL" ]; then
            git remote add origin "$REMOTE_URL"
            echo -e "  ${GREEN}✓${NC} Remote добавлен: $REMOTE_URL"
        fi
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━ Установка завершена ━━━${NC}"
echo ""
echo -e "Vault:    ${YELLOW}$VAULT${NC}"
echo -e "Skill:    ${YELLOW}$SKILL_DIR/SKILL.md${NC}"
echo -e "Команды:  ${YELLOW}$COMMANDS_DIR/brain-*.md${NC}"
echo ""
echo "Следующие шаги:"
echo "  1. Запусти guided setup — заполни профиль:"
echo "     cd ~/Workspace/projects && claude"
echo "     /brain-setup"
echo ""
echo "  2. Создай первый проект:"
echo "     mkdir ~/Workspace/projects/[название] && cd ~/Workspace/projects/[название]"
echo "     claude"
echo "     /brain-init [название]"
echo ""
