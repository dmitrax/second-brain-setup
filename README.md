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

~/Workspace/second-brain-vault/   ← Obsidian vault (private git repo)
    dotfiles/             ← project knowledge
        _PROJECT.md       ← what, why, current status
        taskboard.md      ← project tasks
        architecture-map.md  ← code orientation map (code/mixed projects)
        raw/              ← source files (configs, transcripts, docs)
        wiki/             ← compiled knowledge (Claude writes this)
            decision-*.md ← decision records (immutable, ADR-lite)
        sessions/         ← session logs
    00-system/            ← index.md, connections.md
    00-shared/            ← CRITICAL_FACTS.md, SOUL.md
```

At session start, Claude reads `CRITICAL_FACTS.md` + `_PROJECT.md` + `taskboard.md`
(~450 tokens) and immediately knows the full context. No re-explaining.
For code projects it also reads `architecture-map.md` — a route/module map that
replaces repository scanning.


## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/dmitrax/second-brain-setup
cd second-brain-setup

# 2. Install (creates vault + copies slash commands to ~/.claude/)
bash install.sh

# 3. Fill your profile (one time)
cd ~/Workspace/projects/any-folder && claude
> /brain-setup

# 4. Create your first project
mkdir ~/Workspace/projects/dotfiles && cd ~/Workspace/projects/dotfiles && claude
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

~/Workspace/projects/[project]/
    CLAUDE.md                     ← BRIDGE: points to vault + project rules

~/Workspace/second-brain-vault/   ← Obsidian vault (private)
    [project]/                    ← one folder per project
```

**AI-First note format** — every wiki note has a `## For future Claude` section
that tells Claude exactly when and how to use it. The Obsidian graph grows
as Claude adds `[[wikilinks]]` between notes.

**Rewrite, not append** — when processing a new source, Claude rewrites existing
notes instead of creating duplicates. Knowledge stays clean and current.

**Decision notes** — immutable `decision-<slug>-because-<reason>.md` records in `wiki/`.
When a decision changes, a new note supersedes the old one — nothing is deleted or rewritten.

## Chat Skills

Skills for Claude.ai that complement the Claude Code commands.
Work in any chat, Claude.ai Projects, and Cowork — no Claude Code needed.

| Skill | Trigger | When |
|---|---|---|
| `brain-onboard` | `/brain-onboard` | Onboard a project from chat to Claude Code |

Install: zip the skill folder → Claude.ai → Customize → Skills.
See [chat-skills/README.md](chat-skills/README.md) for details.

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

**Upgrading from v1.1 → v1.2:**
```bash
# No vault migration needed — all changes are additive.
# Run update.sh to get the new command files:
bash update.sh

# For existing code/mixed projects, create architecture-map.md manually
# or let Claude generate it on your next session:
# > Создай architecture-map.md для этого проекта на основе текущей кодовой базы

# Add updated: field to existing _PROJECT.md files (optional, enables stale detector):
# updated: 2026-06-09
```

**Upgrading from v1.0 → v1.1** (vault path changed):
```bash
mv ~/Documents/second-brain-vault ~/Workspace/second-brain-vault
# Then update Vault: line in each project's CLAUDE.md
```

## Language

| File | Language | Audience |
|---|---|---|
| `SKILL.md`, `commands/brain-*.md` | English | Claude Code (machine) |
| `WORKFLOW.md` | Russian | User guide (human) |
| `ВТОРОЙ_МОЗГ_v1.3.md` | Russian | Architecture reference |
| `README.md` | English | GitHub |
| `chat-skills/brain-onboarding/SKILL.md` | English | Claude.ai Skills (machine) |

User guide and architecture doc in Russian:
- [WORKFLOW.md](WORKFLOW.md) — step-by-step guide
- [ВТОРОЙ_МОЗГ_v1.3.md](ВТОРОЙ_МОЗГ_v1.3.md) — full architecture


## Changelog

### v1.4.0 — 2026-07-20

- **`_PROJECT.md` no longer duplicates wiki content** — `Current state` (status/blockers
  only), `Последняя сессия` (now mandatory, capped at ~5 one-line entries), and the
  file's own `For future Claude` (bounded ~15-20 lines) all link to wiki/decision notes
  instead of restating their mechanism. Fixes a real drift found live: one project's
  `_PROJECT.md` had grown to 519 lines by repeating full session recaps that already
  existed in wiki notes.
- **`/brain-lint`**: new size/duplication checks for all three sections above — flags
  fire independent of the ~120-line threshold, catching the pattern earlier.
- Adopted semver (see `CLAUDE.md` Key rules) — this release is the first tagged under it.

**Upgrading from v1.3 → v1.4.0:**
```bash
# No vault migration needed — all changes are additive (new rules + lint checks).
bash update.sh
```

### v1.3 — 2026-06-23

- **Obsidian CLI integration** — optional enhancement when Obsidian 1.12.7+ is running with CLI enabled.
- **`_obsidian_available()` guard** — every CLI call is wrapped; system falls back to filesystem if Obsidian is not running.
- **`/brain-lint`**: Step 1 uses `obsidian orphans` when available; new Step 1b checks broken links (`obsidian unresolved`, `obsidian deadends`); Step 11 adds link validation for architecture-map; Result block reports `Broken links (CLI)`.
- **`/brain-save`**: Step 0b uses `obsidian property:set` to update `updated:` frontmatter when CLI is available.
- **`SKILL.md`**: new Principles rule — use `obsidian move` for renames to preserve [[backlinks]]; never rename via filesystem while Obsidian is running.
- **`/brain-init`**: CLAUDE.md template includes `### Obsidian CLI` section.

**Upgrading from v1.2 → v1.3:**
```bash
# No vault migration needed — all changes are additive.
bash update.sh
# To enable CLI: Obsidian → Settings → General → Command line interface
```

### v1.2 — 2026-06-09

- **architecture-map.md** — new file for code/mixed projects: route/module → file → data source → components. Read at session start; never scan the repo. `/brain-save` keeps it current. `/brain-lint` checks freshness.
- **Decision notes (ADR-lite)** — `wiki/decision-<slug>-because-<reason>.md`. Immutable records with Y-statement, alternatives, consequences. Superseded not rewritten. `/brain-save` creates them on trigger.
- **Critical thinking & warn clause** in all CLAUDE.md templates: no auto-flattery; one-line warning before destructive actions.
- **Tier navigation** in session start: no full vault or repository scan — index + grep.
- **`updated:` field** in `_PROJECT.md` frontmatter. Bumped by `/brain-save`. Used by `/brain-lint` stale detector (14-day threshold).
- **`/brain-lint` additions**: stale project detector, size check, decision consistency, architecture-map freshness.
- **`/brain-save` session log** sharpened: adds "What worked" and "Tech debt found, not fixed" sections.
- Decision notes flat in `wiki/` (removed `wiki/decisions/` subfolder convention).
- `brain-init` now asks for project type (code / content / config / mixed).

### v1.1 — 2026-06-08

**Vault path moved to `~/Workspace/` — fixes iCloud Drive conflict on macOS.**

- Default path: `~/Documents/second-brain-vault/` → `~/Workspace/second-brain-vault/`
- `install.sh` now creates `~/Workspace/` if absent
- Recommended code projects location: `~/Workspace/projects/` (not required)
- Cross-device path consistency: same on macOS and Linux

**Chat Skills:**
- `brain-onboard` — new Claude.ai skill: onboards any project from chat context
  into the Second Brain vault (generates CLAUDE.md, _PROJECT.md, taskboard.md)

### v1.0 — 2026-06-01

Initial release.

- 5 slash commands: `/brain-setup`, `/brain-init`, `/brain-save`, `/brain-ingest`, `/brain-lint`
- One vault, autonomous projects (each project is a self-contained root-level folder)
- AI-First note format: YAML frontmatter + `## For future Claude`
- Wikilinks rule: minimum 2 `[[links]]` per note for Obsidian graph
- `raw/` files treated as untrusted source material (prompt injection protection)
- Git-based sync across devices (no paid Obsidian Sync needed)

---

## Credits

- [Andrej Karpathy](https://x.com/karpathy) — LLM Knowledge Bases pattern
- [@alex_magnier](https://t.me/alex_magnier) — Claude Code + Obsidian guide
- [Eugeniu Ghelbur](https://github.com/eugeniughelbur/obsidian-second-brain) — AI-First vault, `## For future Claude` pattern

## License

MIT
