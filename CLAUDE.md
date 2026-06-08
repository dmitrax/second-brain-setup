# CLAUDE.md — second-brain-setup

# Note: safe to commit to a public repo.
# This file contains no personal data.
# The vault (personal knowledge) is a separate private repo.

## Vault (Second Brain)
~/Workspace/second-brain-vault/
Project: second-brain-system/

### At session start
1. Read: 00-shared/CRITICAL_FACTS.md
2. Read: second-brain-system/_PROJECT.md
3. Read: second-brain-system/taskboard.md
4. Tasks with no progress for 3+ days → flag explicitly
5. Read: second-brain-system/wiki/ — only relevant files

---

## Project: second-brain-setup

### What this is
The Second Brain skill system for Claude Code.
All .md files in commands/ are slash command definitions Claude executes.
SKILL.md is the passive skill loaded automatically.
install.sh sets up the system. update.sh applies changes.

### Stack
- Markdown files (.md) — slash command definitions and skill rules
- Bash scripts (.sh) — install and update automation
- No external dependencies

### Language rule
- SKILL.md and commands/brain-*.md → English (Claude reads as instructions)
- WORKFLOW.md and ВТОРОЙ_МОЗГ_v3_ФИНАЛ.md → Russian (human-facing docs)

### Rules
- After editing SKILL.md or any brain-*.md → run update.sh to apply
- Versioning: v1.x = additive only, v2.0 = breaking change + migration script
- Test install.sh in a clean temp $HOME before tagging a release
- Every architectural decision goes to second-brain-system/wiki/decisions/
- brain-version in _PROJECT.md must match the git tag

### Do not
- Do not add personal data to any file in this repo (vault is separate and private)
- Do not rename existing folders in vault structure (breaks wikilinks in active vaults)
- Do not reduce backward compatibility within v1.x
- Do not commit API keys, secrets, or vault content
