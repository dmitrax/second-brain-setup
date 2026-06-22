#!/usr/bin/env bash
# update.sh — apply Second Brain skill changes to local Claude Code
# Run after editing SKILL.md or any commands/brain-*.md

set -e

SKILL_DIR="$HOME/.claude/skills/second-brain"
COMMANDS_DIR="$HOME/.claude/commands"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || echo "v1.0-dev")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━ Second Brain — applying $VERSION ━━━${NC}"
echo ""

mkdir -p "$SKILL_DIR" "$COMMANDS_DIR"

# SKILL.md
if [ -f "$SCRIPT_DIR/SKILL.md" ]; then
    cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
    echo -e "  ${GREEN}✓${NC} SKILL.md → $SKILL_DIR/"
else
    echo -e "  ${YELLOW}!${NC} SKILL.md not found — skipping"
fi

# Commands
UPDATED=0
for cmd in brain-setup brain-init brain-save brain-ingest brain-lint; do
    src="$SCRIPT_DIR/commands/$cmd.md"
    if [ -f "$src" ]; then
        cp "$src" "$COMMANDS_DIR/$cmd.md"
        echo -e "  ${GREEN}✓${NC} /brain-${cmd#brain-} → $COMMANDS_DIR/"
        UPDATED=$((UPDATED + 1))
    else
        echo -e "  ${YELLOW}!${NC} $cmd.md not found — skipping"
    fi
done

echo ""
echo -e "${GREEN}━━━ Done: $UPDATED commands + SKILL.md applied ━━━${NC}"
echo ""
echo "  Version: $VERSION"
echo "  Restart active Claude Code sessions to pick up changes."
echo ""

# Напомнить про vault если это был breaking change
if git -C "$SCRIPT_DIR" describe --tags --exact-match 2>/dev/null | grep -q "^v[0-9]*\.0"; then
    echo -e "${YELLOW}⚠️  Major version detected.${NC}"
    echo "   Check migration guide before using on existing vaults."
    echo ""
fi
