# Cluster Workspaces

Clusters are multi-role agent teams. You define a set of roles, each with its own prompt and trigger configuration, and the system launches ephemeral Docker containers to execute them. Roles within a cluster share a workspace directory, allowing agents to collaborate by reading and writing to shared folders.

---

## Creating a Cluster

Create a cluster from the web UI. Each cluster has:

- **Name** — Display label for the cluster.
- **System Prompt** — Shared context appended to every role's system prompt. Use this for mission, goals, and shared instructions. Defaults to the template in `config/CLUSTER_SYSTEM_PROMPT.md`.
- **Shared Folders** — Named subdirectories under `shared/` that all roles can access (e.g., `docs`, `output`).
- **Enabled/Disabled** — Toggle the cluster on or off. Disabling stops all running containers and prevents new triggers from firing.

---

## Defining Roles

Each role within a cluster represents one agent type. A role has:

| Field | Description |
|-------|-------------|
| **Role Name** | Display name (e.g., "Researcher", "Writer") |
| **Role Instructions** | Markdown prompt describing what this role does. Defaults to `config/CLUSTER_ROLE_PROMPT.md`. |
| **Prompt** | The user-facing task prompt passed to the agent (default: "Execute your role.") |
| **Max Concurrency** | Maximum number of simultaneous containers for this role (default: 1) |
| **Trigger Config** | How this role gets activated (see Triggers below) |
| **Folders** | Role-specific subdirectories within its own directory |
| **Cleanup Worker Dir** | If enabled, the ephemeral worker directory is deleted after the container exits |

### Template Variables

Both the system prompt and role prompt support `{{PLACEHOLDER}}` template variables that are resolved at container launch time:

| Variable | Value |
|----------|-------|
| `{{CLUSTER_HOME}}` | Container workspace root (`/home/claude-code/workspace`) |
| `{{CLUSTER_SHARED_DIR}}` | Path to cluster shared directory |
| `{{CLUSTER_SHARED_FOLDERS}}` | JSON array of shared folder paths |
| `{{SELF_ROLE_NAME}}` | This role's name |
| `{{SELF_WORKER_ID}}` | Unique ID for this worker instance |
| `{{SELF_WORK_DIR}}` | This worker's ephemeral working directory |
| `{{SELF_TMP_DIR}}` | This worker's temp directory |
| `{{WORKSPACE}}` | JSON manifest of the full workspace layout |
| `{{DATETIME}}` | ISO timestamp at launch time |
| `{{WEBHOOK_PAYLOAD}}` | JSON payload from a webhook trigger (only present for webhook-triggered runs) |

---

## Trigger Types

Each role can have multiple triggers configured simultaneously. All triggers respect the role's concurrency limit — if the maximum number of containers is already running, the trigger is skipped.

### Manual

Always available. Click the run button in the UI to launch a role container on demand.

### Webhook

Always-on once the role exists. Send a POST request to trigger execution:

```
POST /api/cluster/{clusterId}/role/{roleId}/webhook
Header: x-api-key: YOUR_API_KEY
Body: { "key": "value" }
```

The request body is passed to the role as `{{WEBHOOK_PAYLOAD}}`. You can also include a `prompt` field in the body to override the role's default prompt for that run.

**Responses:**

| Status | Meaning |
|--------|---------|
| 200 | Container launched successfully |
| 403 | Cluster is disabled |
| 404 | Role or cluster not found |
| 429 | Max concurrency reached |

### Cron

Schedule a role to run on a recurring basis using a cron expression.

Configure in the role's trigger settings:

```json
{
  "cron": {
    "enabled": true,
    "schedule": "0 */6 * * *"
  }
}
```

Uses standard cron syntax (powered by `node-cron`). The schedule is registered at server boot and reloaded whenever trigger config changes.

### File Watch

Trigger a role when files change in the cluster's data directory.

```json
{
  "file_watch": {
    "enabled": true,
    "paths": "shared/input,shared/data"
  }
}
```

Paths are comma-separated, relative to the cluster's data directory. Changes are debounced (5-second window) so rapid edits produce a single trigger. The `logs/` directory is always excluded from watching. Requires `chokidar` to be installed.

---

## Directory Structure

Each cluster gets a data directory on disk under `data/clusters/`:

```
data/clusters/
  cluster-{shortId}/
    shared/                       # Cluster-wide shared directory
      docs/                       # Example shared folder
      output/                     # Example shared folder
    role-{roleShortId}/
      shared/                     # Role-specific shared directory
      worker-{uuid}/              # Ephemeral per-container directory
        tmp/                      # Worker temp directory
    logs/
      role-{roleShortId}/
        2025-01-15_14-30-00_{uuid}/
          system-prompt.md        # Resolved system prompt for this run
          user-prompt.md          # Resolved user prompt for this run
          meta.json               # Run metadata (role name, timestamps)
          trigger.json            # Trigger info (type, payload)
          stdout.jsonl            # Container stdout
          stderr.txt              # Container stderr
```

Short IDs are the first 8 characters of the UUID with dashes removed.

---

## Concurrency

Each role has a `maxConcurrency` setting (default: 1). Before any trigger launches a container, the system counts running containers for that role. If the count meets or exceeds the limit, the trigger is rejected.

This applies uniformly across all trigger types — manual, webhook, cron, and file watch all go through the same `canRunRole()` gate.

Set higher concurrency for roles that handle parallel workloads (e.g., a webhook-triggered role that processes independent requests). Keep it at 1 for roles that should run sequentially.

---

## Console and Logs

### Live Console

The cluster console page provides real-time visibility into running containers via Server-Sent Events. It shows:

- **Container status** per role — which workers are running, idle, or stopped
- **Resource usage** — CPU, memory, and network stats per container
- **Live logs** — Streaming stdout and stderr from each running container
- **Prompts** — View the resolved system and user prompts for any worker

The console polls every 3 seconds, automatically discovers new containers, and cleans up tailing when containers stop.

### Session Logs

Every container run creates a log session under `logs/` in the cluster data directory. The logs page in the UI shows historical runs grouped by role, with access to:

- `stdout.jsonl` — Structured stdout output
- `stderr.txt` — Raw stderr output
- `system-prompt.md` — The full system prompt as sent to the agent
- `user-prompt.md` — The user prompt as sent to the agent
- `trigger.json` — What triggered the run and any payload

---

## Prompt Architecture

Each worker container receives two prompts:

1. **System Prompt** (`--append-system-prompt`) — Composed from the cluster's system prompt plus the role's instructions, with all template variables resolved. This provides shared context about the cluster mission and the role's responsibilities.

2. **User Prompt** (`-p`) — The role's `prompt` field (or a webhook-provided override). This is the actual task instruction.

The default role template (`config/CLUSTER_ROLE_PROMPT.md`) introduces the agent to the cluster concept and provides the workspace layout via `{{WORKSPACE}}`. The default system prompt template (`config/CLUSTER_SYSTEM_PROMPT.md`) has placeholders for mission, vision, goals, and values.

Customize these templates in your project's `config/` directory to set defaults for new clusters and roles.
