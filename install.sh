#!/usr/bin/env bash
# install.sh — установка skill "Второй Мозг" для Claude Code
set -e

# ─── Настройки ───────────────────────────────────────────────────────────────
VAULT="${SECOND_BRAIN_VAULT:-$HOME/Documents/second-brain-vault}"
SKILL_DIR="$HOME/.claude/skills/second-brain"
COMMANDS_DIR="$HOME/.claude/commands"

# ─── Цвета для вывода ────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━ Установка skill: Второй Мозг ━━━${NC}"
echo ""

# ─── Спросить vault path если не задан ───────────────────────────────────────
echo -e "Путь к vault: ${YELLOW}$VAULT${NC}"
read -p "Изменить? (Enter = оставить, или введи новый путь): " CUSTOM_VAULT
if [ -n "$CUSTOM_VAULT" ]; then
    VAULT="$CUSTOM_VAULT"
fi

# ─── Создать директории ───────────────────────────────────────────────────────
echo ""
echo "Создаю директории..."

mkdir -p "$SKILL_DIR"
mkdir -p "$COMMANDS_DIR"

# Vault структура
mkdir -p "$VAULT/00-system" "$VAULT/00-shared"

# ─── Копировать файлы skill ──────────────────────────────────────────────────
echo "Устанавливаю skill файлы..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"

for cmd in brain-setup brain-init brain-save brain-ingest brain-lint; do
    if [ -f "$SCRIPT_DIR/commands/$cmd.md" ]; then
        cp "$SCRIPT_DIR/commands/$cmd.md" "$COMMANDS_DIR/$cmd.md"
        echo -e "  ${GREEN}✓${NC} /commands/$cmd.md → ~/.claude/commands/"
    else
        echo -e "  ${YELLOW}!${NC} $cmd.md не найден — пропускаю"
    fi
done

# ─── Создать системные файлы vault (если не существуют) ──────────────────────
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

# ─── Git инициализация ────────────────────────────────────────────────────────
echo ""
if [ ! -d "$VAULT/.git" ]; then
    read -p "Инициализировать Git в vault? (y/n): " INIT_GIT
    if [ "$INIT_GIT" = "y" ]; then
        cd "$VAULT"
        git init
        git add .
        git commit -m "init: Second Brain vault"
        echo -e "  ${GREEN}✓${NC} Git инициализирован"
        echo ""
        read -p "Добавить remote репозиторий? (Enter = пропустить, или вставь URL): " REMOTE_URL
        if [ -n "$REMOTE_URL" ]; then
            git remote add origin "$REMOTE_URL"
            echo -e "  ${GREEN}✓${NC} Remote добавлен: $REMOTE_URL"
        fi
    fi
fi

# ─── Итог ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━ Установка завершена ━━━${NC}"
echo ""
echo -e "Vault:    ${YELLOW}$VAULT${NC}"
echo -e "Skill:    ${YELLOW}$SKILL_DIR/SKILL.md${NC}"
echo -e "Команды:  ${YELLOW}$COMMANDS_DIR/brain-*.md${NC}"
echo ""
echo "Следующие шаги:"
echo "  1. Запусти guided setup — заполни профиль:"
echo "     cd ~/projects-code && claude"
echo "     /brain-setup"
echo ""
echo "  2. Создай первый проект:"
echo "     mkdir ~/projects-code/[название] && cd ~/projects-code/[название]"
echo "     claude"
echo "     /brain-init [название]"
echo ""
