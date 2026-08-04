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

echo -e "${BLUE}━━━ Installing skill: Second Brain ━━━${NC}"
echo ""

# ─── Ask for the vault path if not given ─────────────────────────────────────
echo -e "Vault path: ${YELLOW}$VAULT${NC}"
ask "Change it? (Enter = keep, or type a new path): " CUSTOM_VAULT
if [ -n "$CUSTOM_VAULT" ]; then
    VAULT="$CUSTOM_VAULT"
fi

# ─── Create directories ──────────────────────────────────────────────────────
echo ""
echo "Creating directories..."

mkdir -p "$SKILL_DIR"
mkdir -p "$COMMANDS_DIR"

# Vault layout
mkdir -p "$VAULT/00-system" "$VAULT/00-shared"

# ─── Copy the skill files ────────────────────────────────────────────────────
echo "Installing skill files..."

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
    echo -e "  ${YELLOW}!${NC} lib/brain.sh not found — commands will run without the CLI"
fi

for cmd in brain-setup brain-init brain-save brain-ingest brain-lint; do
    if [ -f "$SCRIPT_DIR/commands/$cmd.md" ]; then
        cp "$SCRIPT_DIR/commands/$cmd.md" "$COMMANDS_DIR/$cmd.md"
        echo -e "  ${GREEN}✓${NC} /commands/$cmd.md → ~/.claude/commands/"
    else
        echo -e "  ${YELLOW}!${NC} $cmd.md not found — skipping"
    fi
done

# ─── Create the vault system files (only if absent) ──────────────────────────
echo ""
echo "Initialising the vault system files..."

# index.md
if [ ! -f "$VAULT/00-system/index.md" ]; then
    cat > "$VAULT/00-system/index.md" << 'EOF'
# Index

## Projects
(projects appear here after /brain-init)

## Recent changes
EOF
    echo -e "  ${GREEN}✓${NC} 00-system/index.md"
fi

# connections.md
if [ ! -f "$VAULT/00-system/connections.md" ]; then
    cat > "$VAULT/00-system/connections.md" << 'EOF'
# Connections — links between projects

## Shared knowledge

## Knowledge transfers

## Last updated
(refreshed automatically by /brain-lint)
EOF
    echo -e "  ${GREEN}✓${NC} 00-system/connections.md"
fi

# CRITICAL_FACTS.md
if [ ! -f "$VAULT/00-shared/CRITICAL_FACTS.md" ]; then
    cat > "$VAULT/00-shared/CRITICAL_FACTS.md" << EOF
# Critical Facts

Name: (fill in)
Time zone: (fill in, e.g. Europe/Berlin UTC+2)
Devices: (fill in)
Vault: $VAULT
Working language: (fill in — Claude will answer in this language)
(add any other key facts about yourself — ~120 tokens maximum)
EOF
    echo -e "  ${GREEN}✓${NC} 00-shared/CRITICAL_FACTS.md"
    echo -e "  ${YELLOW}→ Fill CRITICAL_FACTS.md with your own details!${NC}"
fi

# SOUL.md
if [ ! -f "$VAULT/00-shared/SOUL.md" ]; then
    cat > "$VAULT/00-shared/SOUL.md" << 'EOF'
# Soul

## Who I am
(2-3 sentences: values, what I do, what matters)

## How I think
(thinking style, how I make decisions)

## How I like working with AI
(preferences: tone, format, speed vs quality)

## What I cannot stand
(what irritates me when working with AI)
EOF
    echo -e "  ${GREEN}✓${NC} 00-shared/SOUL.md"
    echo -e "  ${YELLOW}→ Fill SOUL.md with your own details!${NC}"
fi

# .gitignore
if [ ! -f "$VAULT/.gitignore" ]; then
    cat > "$VAULT/.gitignore" << 'EOF'
# Obsidian workspace
.obsidian/workspace*
.obsidian/cache

# Binary media — transcribe with Whisper; keep only the transcripts in the vault
raw/**/*.mp3
raw/**/*.mp4
raw/**/*.m4a
raw/**/*.wav
raw/**/*.pdf

# System
.DS_Store
*.swp

# Secrets and keys
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

# Databases
*.sqlite
*.sqlite3
*.db

# Claude Code local context
.claude/
CLAUDE.local.md
EOF
    echo -e "  ${GREEN}✓${NC} .gitignore"
fi

# ─── Git initialisation ──────────────────────────────────────────────────────
echo ""
if [ ! -d "$VAULT/.git" ]; then
    ask "Initialise Git in the vault? (y/n): " INIT_GIT
    if [ "$INIT_GIT" = "y" ]; then
        cd "$VAULT"
        git init
        git add .
        git commit -m "init: Second Brain vault"
        echo -e "  ${GREEN}✓${NC} Git initialised"
        echo ""
        ask "Add a remote repository? (Enter = skip, or paste a URL): " REMOTE_URL
        if [ -n "$REMOTE_URL" ]; then
            git remote add origin "$REMOTE_URL"
            echo -e "  ${GREEN}✓${NC} Remote added: $REMOTE_URL"
        fi
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━ Installation complete ━━━${NC}"
echo ""
echo -e "Vault:    ${YELLOW}$VAULT${NC}"
echo -e "Skill:    ${YELLOW}$SKILL_DIR/SKILL.md${NC}"
echo -e "Commands: ${YELLOW}$COMMANDS_DIR/brain-*.md${NC}"
echo ""
echo "Next steps:"
echo "  1. Run the guided setup — fill in your profile:"
echo "     cd ~/Workspace/projects && claude"
echo "     /brain-setup"
echo ""
echo "  2. Create your first project:"
echo "     mkdir ~/Workspace/projects/[name] && cd ~/Workspace/projects/[name]"
echo "     claude"
echo "     /brain-init [name]"
echo ""
