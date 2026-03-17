# skills/ — Agent Skills

Skills are lightweight plugins that extend agent abilities. Each skill lives in `skills/<skill-name>/` and is activated by symlinking into `skills/active/`.

## How Skills Work

1. **Discovery** — The system scans `skills/active/` for directories containing `SKILL.md`.
2. **Frontmatter loaded** — The `description` from YAML frontmatter is included in the system prompt under "Active skills" (via the `{{skills}}` template variable).
3. **Full SKILL.md read on demand** — When the agent decides to use a skill, it reads the full `SKILL.md` for detailed usage instructions.

Both Pi and Claude Code discover skills from the same `skills/active/` directory (via `.pi/skills` and `.claude/skills` symlink bridges).

## SKILL.md Format

Every skill must have a `SKILL.md` with YAML frontmatter:

```markdown
---
name: skill-name-in-kebab-case
description: One sentence describing what the skill does and when to use it.
---

# Skill Name

## Usage

```bash
skills/skill-name/script.sh <args>
```
```

- The `description` field appears in the system prompt — keep it concise and action-oriented.
- Use project-root-relative paths in documentation (e.g., `skills/skill-name/script.sh`).

## Skill Structure

- **`SKILL.md`** (required) — YAML frontmatter + markdown documentation
- **Scripts** (optional) — prefer bash (`.sh`) for simplicity
- **`package.json`** (optional) — only if Node.js dependencies are truly needed

## Creating a Skill

### Simple bash skill (most common)

```bash
mkdir skills/my-skill
```

**skills/my-skill/SKILL.md:**
```markdown
---
name: my-skill
description: Does X when the agent needs to Y.
---

# My Skill

## Setup
Requires MY_API_KEY environment variable.

## Usage
```bash
skills/my-skill/run.sh <args>
```
```

**skills/my-skill/run.sh:**
```bash
#!/bin/bash
if [ -z "$1" ]; then echo "Usage: run.sh <args>"; exit 1; fi
if [ -z "$MY_API_KEY" ]; then echo "Error: MY_API_KEY not set"; exit 1; fi
# ... skill logic
```

Then make it executable and activate:
```bash
chmod +x skills/my-skill/run.sh
ln -s ../my-skill skills/active/my-skill
```

### Node.js skill

Use this pattern only when bash + curl isn't sufficient (e.g., HTML parsing, complex data processing). Add a `package.json` with dependencies — they're installed automatically in Docker.

## Activation & Deactivation

```bash
# Activate
ln -s ../skill-name skills/active/skill-name

# Deactivate
rm skills/active/skill-name
```

The `skills/active/` directory is shared by both agent backends via symlink bridges:
- `.claude/skills → skills/active`
- `.pi/skills → skills/active`

## Credential Setup

If a skill needs an API key, set it up before the job runs:

```bash
npx thepopebot set-agent-llm-secret KEY_NAME value
```

This creates a GitHub secret with `AGENT_LLM_` prefix, exposed as an env var in the Docker container. Also add to `.env` for local development.

**Multi-line secrets** (e.g., JSON service account files):
```bash
npx thepopebot set-agent-llm-secret GOOGLE_CREDENTIALS < credentials.json
```

## Testing

Always build AND test a skill in the same job. Tell the agent to test with real input after creating the skill and fix any issues before committing.

## Default Skills

Check `skills/` for available built-in skills. Activate any you need by symlinking into `skills/active/`.
