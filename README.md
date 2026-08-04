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
        lib/brain.sh              ← deterministic code the prompts call
        lib/VERSION               ← what version is installed
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

Semver since v1.4.0 (`MAJOR.MINOR.PATCH`): `PATCH` — bug fixes with no new behaviour,
`MINOR` — backward-compatible features and rules (commands, checks, templates), `MAJOR` —
breaking changes shipped with a migration script. Tags `v1.0`–`v1.3` predate it, under a
coarser "v1.x = additive only" scheme, and are not retro-fitted.

```bash
# Update the installed system after pulling changes
bash update.sh

# Which version is actually installed
bash ~/.claude/skills/second-brain/lib/brain.sh version
```

**Upgrading from v1.1 → v1.2:**
```bash
# No vault migration needed — all changes are additive.
# Run update.sh to get the new command files:
bash update.sh

# For existing code/mixed projects, create architecture-map.md manually
# or let Claude generate it on your next session:
# > Create architecture-map.md for this project from the current codebase

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
| `ВТОРОЙ_МОЗГ_v1.7.0.md` | Russian | Architecture reference |
| `README.md` | English | GitHub |
| `chat-skills/brain-onboarding/SKILL.md` | English | Claude.ai Skills (machine) |

User guide and architecture doc in Russian:
- [WORKFLOW.md](WORKFLOW.md) — step-by-step guide
- [ВТОРОЙ_МОЗГ_v1.7.0.md](ВТОРОЙ_МОЗГ_v1.7.0.md) — full architecture


## Changelog

### v1.7.0 — 2026-08-04

- **Executable code moved out of the prompts into `lib/brain.sh`.** The measurement behind
  it: 575 lines of real bash (`install`/`update`/`preflight`) had produced no bug in the
  project's history, against 288 lines of code blocks inside prompts that held **all four**
  bugs of v1.4.3/v1.5.0 — code that looks like code but is never run, tested, or even
  syntax-checked. The guard is now one copy everyone calls, plus `vault-sync`,
  `stamp-field`, `version`, `archive` and `lint-diff`. `preflight` tests them by **running**
  them, which is what the extraction was for.
- **Every command syncs the vault before its first write — and reading syncs too.** Several
  vault files are append-only registries edited by every session on every machine, so a
  write on a stale checkout conflicts by construction. Reading needed it more: on a stale
  checkout `_PROJECT.md` and `taskboard.md` are present, readable and look current, so a
  session silently works from "as of my last visit to this machine". Unreachable remote
  warns and proceeds; a conflict stops the write.
- **The installed system knows its own version.** `install.sh`/`update.sh` write
  `lib/VERSION`, `brain.sh version` reads it, `/brain-init` stamps the real value instead
  of a hardcoded literal, and `/brain-save` re-stamps it on every save. Measured before the
  fix: 8 projects claimed `1.3`, two claimed `1.5.0`, none the version actually released.
- **Frontmatter templates declare themselves a minimum**, with a step that looks up the
  project's local keys *before* the first write. A project may require keys this package
  cannot know; an explicit template at hand beats a rule read two hundred messages ago.
  The key carries over and is checkable, the value is a judgement made per entry.
- **`/brain-lint` gained five steps.** Step 0c declares an incomplete checkout and refuses
  to seal a baseline from one. Step 4b sweeps the whole vault for bare `[[links]]` to
  non-unique names — a correct link goes bad on its own the moment another project reuses
  the basename, which is why this runs every time and not just for new projects. Step 4c
  measures links per note. Step 10b checks frontmatter key uniformity within a project.
  Step 12 reports the **delta** against the previous run: NEW first, then GONE, then the
  count of parked debt nobody needs to re-litigate.
- **The "minimum 2 wikilinks" rule is gone**, replaced by one that a template can satisfy:
  the `[[../_PROJECT|_PROJECT]]` backlink always, plus a sibling link when a genuinely
  related note exists. The old floor was unsatisfiable for a note that is first on its
  topic — it demanded either a permanent violation or an invented link.
- **Prompt code blocks must be portable**, because the session's shell is zsh on macOS,
  and a command name does not guarantee the tool it resolves to (`#!/bin/bash` fixes the
  shell, not `PATH`). Both classes failed silently green before the rule.
- **The vault is checked out whole on every machine.** `sparse-checkout` leaves tracked
  paths out of the working tree, and from inside any check "absent" and "not checked out"
  are the same observation — measured: 93 unresolved links of which 91 were phantoms, and
  three shared-baseline findings going GONE with nobody having fixed them.
- **`preflight.sh` grew 23 → 37 checks.** Each encodes a live incident; several are
  negative-tested by deliberately breaking a copy and requiring the check to go red.

**Upgrading from v1.6.0 → v1.7.0:** run `update.sh` — it now also installs `lib/`. Nothing
breaks: existing notes and formats are untouched. If your vault uses `sparse-checkout`, the
lint will say so and decline to seal its baseline rather than reporting a partial vault as
whole.

### v1.6.0 — 2026-08-03

- **`/brain-save` syncs the vault before its first write** — `git pull --rebase
  --autostash` under `timeout`, skipped silently when the vault has no remote. Several
  vault files are append-only registries that every session on every machine edits, so
  writing on top of a stale checkout conflicted at push time by construction. An
  unreachable remote warns and proceeds; a conflict mid-rebase stops the write entirely,
  so markers can never land inside notes.
- **Vault searches must declare literal or pattern** — `grep -F` for note names and
  `[[wikilinks]]`, `grep -E` for alternation. A bare `grep -r` treats the pattern as a
  *basic* regex, which is wrong in both directions and silent in both: on a live vault,
  literal `[[architecture-map]]` matched 304 files without `-F` against 17 with it, and
  `docker|colima` matched 1 file without `-E` against 37 with it. The near-empty result
  is the expensive one — it reads as "the vault knows nothing about this".
- **`corrected-by:` marks a partially stale decision note** — when the decision still
  holds but a supporting fact in its body has been disproved. `status` and body stay
  untouched; `superseded` would falsely retire a rule still in force. The marker lives
  in the note being corrected, not only as a backlink from the new one.
- **`status:` on a decision note is binary** — exactly `accepted` / `superseded` /
  `deprecated`, never a hedge like `partially-superseded-by`. Degree of change belongs
  in the new note's body, which must restate the parts of the old scope that still hold.
  Off-schema values are invisible to every property query; `/brain-lint` flags them.
- **`/brain-lint`'s `_PROJECT.md` size check counts prose only** (~60 lines across
  `Current state`, `Последняя сессия`, `For future Claude`), not total file length.
  Link-list sections grow legitimately with a project's decision count, and folding
  them into a total made a well-kept large project look like the worse violator.
- **`preflight.sh` — an executable release gate**, 23 checks over the repo's own rules
  plus an install into a clean `$HOME`. Every check encodes a past incident; three of
  the four bugs in v1.4.3/v1.5.0 were catchable by a one-line grep that did not exist.
  Needs a Python with PyYAML (`python3 -m venv .venv && .venv/bin/pip install pyyaml`);
  `install.sh` never ships it, so the package keeps its no-dependencies promise.
- **Repo scripts hold a bash 3.2 floor** — macOS ships it as `/bin/bash`. No `mapfile`,
  `declare -A`, or `${var^^}`. This is not style: `preflight.sh` used `mapfile`, so two
  checks received empty input and **printed a pass without ever running** for ten days.
  Hence the general rule now enforced across the gate — a check must fail hard when its
  input is empty, or when the tool it needs is absent. Green means "ran and found
  nothing", never "did not run".

**Upgrading from v1.5.0 → v1.6.0:** run `update.sh`. Nothing breaks — the new rules add
checks and steps, no existing note format changes. If your vault has no git remote, the
new sync step skips itself silently.

### v1.5.0 — 2026-07-22

- **`_obsidian_available()` now verifies *which* vault is open**, comparing
  `obsidian vault info=name` against `basename "$VAULT"` instead of only checking the
  exit code. Every CLI path is relative to the active vault, so a different vault
  switched on in the GUI silently redirected writes — exit 0, no warning. The expected
  name is derived from the vault path, never hardcoded.
- **`/brain-save` Step 0b no longer uses `obsidian property:set`** — it edits the
  `updated:` frontmatter field directly. `property:set` re-serializes the *entire*
  frontmatter: it strips quotes (`"1.4.3"` → `1.4.3`), expands inline lists to block
  form (`tags: [session]`), and reinterprets numeric-looking values (`007` → `7`, real
  data loss). `/brain-save` no longer needs the guard at all; `/brain-lint` keeps it
  for read-only queries.
- **Decision-note supersession is now two fields** — `status: superseded` plus
  `superseded-by: <file>`. The previous one-line `status: superseded-by: <file>` was
  invalid YAML (double colon = compact nested mapping), which made Obsidian unable to
  parse that note's frontmatter at all. `/brain-lint` Step 10 now flags the legacy form.

**Upgrading from v1.4.x → v1.5.0:** run `update.sh`. Existing notes using the one-line
`status: superseded-by:` form keep working as text but stay invisible to property
queries — split them into two fields (`/brain-lint` will point them out).

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
- **`_obsidian_available()` guard** — every CLI call is wrapped; system falls back to filesystem
  if Obsidian is not running, or if the open vault is not the one the command means.
- **`/brain-lint`**: Step 1 uses `obsidian orphans` when available; new Step 1b checks broken links (`obsidian unresolved`, `obsidian deadends`); Step 11 adds link validation for architecture-map; Result block reports `Broken links (CLI)`.
- **`/brain-save`**: Step 0b edits the `updated:` frontmatter field directly and uses no CLI at all
  (since v1.5.0 — `property:set` re-serialized the whole frontmatter and lost data).
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
