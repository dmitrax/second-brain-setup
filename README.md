# Second Brain for Claude Code

[📖 Читать на русском](README_RU.md)

> Personal knowledge management system for Claude Code + Obsidian.
> Persistent memory that grows with every session.

Based on Andrej Karpathy's [LLM Knowledge Bases](https://x.com/karpathy) pattern
and the [implementation guide](https://t.me/alex_magnier) by @alex_magnier.

---

## The problem

Claude Code has no memory between sessions. Every time you start a new session,
you re-explain the project context. Over a week, that's hours of wasted time.

## The solution

An Obsidian vault as external memory, connected to Claude Code via `CLAUDE.md`.
Five slash commands to manage it. The vault grows with every session.

```
projects/dotfiles/        ← your code (existing repo)
    CLAUDE.md             ← the bridge to vault

~/Documents/second-brain-vault/   ← Obsidian vault (private git repo)
    dotfiles/             ← project knowledge
        _PROJECT.md       ← what, why, current status
        taskboard.md      ← project tasks
        raw/              ← source files (configs, transcripts, docs)
        wiki/             ← compiled knowledge (Claude writes this)
        sessions/         ← session logs
    00-system/            ← index.md, connections.md
    00-shared/            ← CRITICAL_FACTS.md, SOUL.md
```

At session start, Claude reads `CRITICAL_FACTS.md` + `_PROJECT.md` + `taskboard.md`
(~450 tokens) and immediately knows the full context. No re-explaining.

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/[username]/second-brain-setup
cd second-brain-setup

# 2. Install (creates vault + copies slash commands to ~/.claude/)
bash install.sh

# 3. Fill your profile (one time)
cd ~/projects/any-folder && claude
> /brain-setup

# 4. Create your first project
mkdir ~/projects/dotfiles && cd ~/projects/dotfiles && claude
> /brain-init dotfiles

# 5. Work. Save. Repeat.
> /brain-save
```

## Commands

| Command | When |
|---|---|
| `/brain-setup` | One time after install — fill your profile |
| `/brain-init [name]` | Create a new project |
| `/brain-save` | End of every session |
| `/brain-ingest raw/[file]` | Process a source file into wiki |
| `/brain-lint` | Audit current project |
| `/brain-lint --all` | Weekly full vault audit |

## How it works

**Two separate spaces, one bridge:**

```
~/.claude/                        Claude Code global config
    skills/second-brain/
        SKILL.md                  ← passive skill, auto-loaded
    commands/
        brain-*.md                ← slash commands

~/projects/[project]/
    CLAUDE.md                     ← BRIDGE: points to vault + project rules

~/Documents/second-brain-vault/   ← Obsidian vault (private)
    [project]/                    ← one folder per project
```

**AI-First note format** — every wiki note has a `## For future Claude` section
that tells Claude exactly when and how to use it. The Obsidian graph grows
as Claude adds `[[wikilinks]]` between notes.

**Rewrite, not append** — when processing a new source, Claude rewrites existing
notes instead of creating duplicates. Knowledge stays clean and current.

## Compatibility

The skill files (`SKILL.md`, `brain-*.md`) are written in English and follow
the [AGENTS.md open standard](https://agentsfoundation.ai).

Works with: Claude Code, Codex CLI, Gemini CLI, Cursor, Windsurf.
For non-Claude agents: rename `CLAUDE.md` → `AGENTS.md`.

## Versioning

`v1.x` — additive changes only (new commands, new fields).
`v2.0` — breaking changes, shipped with a migration script.

```bash
# Update slash commands after pulling changes
bash update.sh
```

## Language

| File | Language | Audience |
|---|---|---|
| `SKILL.md`, `commands/brain-*.md` | English | Claude Code (machine) |
| `WORKFLOW.md` | Russian | User guide (human) |
| `ВТОРОЙ_МОЗГ_v1.0.md` | Russian | Architecture reference |
| `README.md` | English | GitHub |

User guide and architecture doc in Russian:
- [WORKFLOW.md](WORKFLOW.md) — step-by-step guide
- [ВТОРОЙ_МОЗГ_v1.0.md](ВТОРОЙ_МОЗГ_v1.0.md) — full architecture

## Changelog

### v1.0 — 2026-06-01

Initial release.

**5 slash commands:**
- `/brain-setup` — guided profile setup (CRITICAL_FACTS.md + SOUL.md)
- `/brain-init` — create new project with full vault structure
- `/brain-save` — save session: wiki rewrite, taskboard, session log
- `/brain-ingest` — process source files into wiki (project-relative paths)
- `/brain-lint` — vault health check: orphans, contradictions, stale notes, taskboard

**Architecture:**
- One vault, autonomous projects (each project is a self-contained folder)
- `00-system/` contains only `index.md` and `connections.md`
- `00-shared/` contains only `CRITICAL_FACTS.md` and `SOUL.md`
- AI-First note format: YAML frontmatter + `## For future Claude`
- Wikilinks rule: minimum 2 `[[links]]` per note for Obsidian graph

**Security:**
- `raw/` files treated as untrusted source material (prompt injection protection)
- Extended `.gitignore` for secrets and databases
- `CLAUDE.md` added to `.gitignore` for public code repos

**Sync:**
- Git-based sync across devices (no paid Obsidian Sync needed)
- Vault path: `~/Documents/second-brain-vault/` (consistent across devices)

## Credits

- [Andrej Karpathy](https://x.com/karpathy) — LLM Knowledge Bases pattern
- [@alex_magnier](https://t.me/alex_magnier) — Claude Code + Obsidian guide
- [Eugeniu Ghelbur](https://github.com/eugeniughelbur/obsidian-second-brain) — AI-First vault, `## For future Claude` pattern

## License

MIT
