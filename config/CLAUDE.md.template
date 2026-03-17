# config/ — Agent Configuration

This directory contains all user-editable configuration files. These files are **not managed** — your changes are preserved across upgrades.

## File Reference

### System Prompts

| File | Used By | Purpose |
|------|---------|---------|
| `SOUL.md` | Chat + Jobs | Agent personality, identity, and values. Included in all LLM interactions. |
| `JOB_PLANNING.md` | Event handler | System prompt for the event handler LLM when planning jobs from chat. |
| `JOB_AGENT.md` | Docker agent | Runtime environment documentation injected into the agent's context. |
| `JOB_SUMMARY.md` | Docker agent | Prompt template for summarizing completed job results. |
| `CODE_PLANNING.md` | Code workspaces | System prompt for the planning chat in interactive code workspaces. |
| `HEARTBEAT.md` | Heartbeat cron | Self-monitoring prompt for the agent's periodic heartbeat job. |
| `CLUSTER_SYSTEM_PROMPT.md` | Cluster workers | Shared system prompt for all cluster worker agents. |
| `CLUSTER_ROLE_PROMPT.md` | Cluster workers | Per-role prompt template (receives role-specific variables). |
| `WEB_SEARCH_AVAILABLE.md` | Chat | Injected into chat context when web search tools are available. |
| `WEB_SEARCH_UNAVAILABLE.md` | Chat | Injected into chat context when web search is disabled. |
| `SKILL_BUILDING_GUIDE.md` | Docker agent | Guide for building and managing agent skills. |

### Scheduling & Triggers

| File | Purpose |
|------|---------|
| `CRONS.json` | Scheduled job definitions — loaded at server startup by `node-cron`. |
| `TRIGGERS.json` | Webhook trigger definitions — loaded at server startup. |

## Template Variables

Config markdown files support includes and built-in variables (processed by `render-md.js` at runtime):

| Syntax | Description |
|--------|-------------|
| `{{ filepath.md }}` | Include another file (path relative to project root, recursive with circular detection) |
| `{{datetime}}` | Current ISO timestamp |
| `{{skills}}` | Dynamic bullet list of active skill descriptions from `skills/active/*/SKILL.md` frontmatter |
| `{{web_search}}` | Injects web search availability context |

## When Changes Take Effect

- **Prompt files** (`.md`) — Changes take effect immediately on the next LLM call. No restart needed.
- **CRONS.json / TRIGGERS.json** — Require a server restart to reload schedules and trigger watchers.
