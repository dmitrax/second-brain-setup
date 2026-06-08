# Chat Skills

Skills for Claude.ai — complement the Claude Code slash commands
from the main second-brain-setup system.

Unlike `commands/brain-*.md` (which run inside Claude Code),
these skills work in any Claude chat, Claude.ai Projects, and Cowork.

## Available skills

### brain-onboard

Onboards any project into the Second Brain system without opening Claude Code.

Invoke in any chat that has project context — the skill scans the conversation,
asks only for missing info, and generates a complete ready-to-use file package:
`CLAUDE.md`, `_PROJECT.md`, `taskboard.md`, and a setup script.

**Install:** upload `brain-onboarding/` as a zip to Claude.ai → Customize → Skills  
**Trigger:** Slash command — `/brain-onboard`  
**Works in:** regular chats, Claude.ai Projects, Cowork

**When to use:**
- You have been working on a project in chat and want to move to Claude Code
- You have an existing project on disk and want to connect it to the vault
- You want a fully filled CLAUDE.md instead of the generic `/brain-init` template

**Relation to brain-init:**  
`/brain-init` creates a generic project structure from inside Claude Code.  
`/brain-onboard` creates the same structure but with real content extracted
from the conversation — use it when you have project context in a chat.

## Adding more skills

Each skill lives in its own subfolder with a `SKILL.md` (required) and `LICENSE.txt`.
Zip the folder and upload to Claude.ai → Customize → Skills.

```
chat-skills/
    [skill-name]/
        SKILL.md      ← must start with YAML frontmatter (name + description)
        LICENSE.txt
```
