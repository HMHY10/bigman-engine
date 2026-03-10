# Architecture

thepopebot uses a two-layer architecture:

1. **Event Handler** - Next.js application for webhooks, Telegram chat, and cron scheduling
2. **Docker Agent** - Coding agent container (Pi or Claude Code) for autonomous task execution

```
┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│  ┌─────────────────┐         ┌─────────────────┐                     │
│  │  Event Handler  │ ──1──►  │     GitHub      │                     │
│  │  (creates job)  │         │ (job/* branch)  │                     │
│  └────────▲────────┘         └────────┬────────┘                     │
│           │                           │                              │
│           │                           2 (triggers run-job.yml)    │
│           │                           │                              │
│           │                           ▼                              │
│           │                  ┌─────────────────┐                     │
│           │                  │  Docker Agent   │                     │
│           │                  │ (Pi/Claude,PRs) │                     │
│           │                  └────────┬────────┘                     │
│           │                           │                              │
│           │                           3 (creates PR)                 │
│           │                           │                              │
│           │                           ▼                              │
│           │                  ┌─────────────────┐                     │
│           │                  │     GitHub      │                     │
│           │                  │   (PR opened)   │                     │
│           │                  └────────┬────────┘                     │
│           │                           │                              │
│           │                           4a (auto-merge.yml)            │
│           │                           4b (rebuild-event-handler.yml) │
│           │                           │                              │
│           5 (notify-pr-complete.yml / │                              │
│           │  notify-job-failed.yml)   │                              │
│           └───────────────────────────┘                              │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘
```

---

## File Structure

This is the user project structure after running `npx thepopebot init`:

```
/
├── .github/workflows/
│   ├── auto-merge.yml             # Auto-merges job PRs (checks AUTO_MERGE + ALLOWED_PATHS)
│   ├── notify-job-failed.yml      # Sends notification when a job fails
│   ├── notify-pr-complete.yml     # Gathers job data and sends notification after merge
│   ├── rebuild-event-handler.yml  # Rebuilds event handler after push to main
│   ├── run-job.yml                # Runs Docker agent on job/* branch creation
│   └── upgrade-event-handler.yml  # Upgrades thepopebot package in event handler
├── .claude/                       # Claude Code settings
├── .pi/
│   ├── extensions/                # Pi extensions (env-sanitizer for secret filtering)
│   └── skills/                    # Custom skills for the agent
├── config/
│   ├── SOUL.md                    # Agent identity and personality
│   ├── JOB_PLANNING.md            # Event handler system prompt
│   ├── JOB_SUMMARY.md             # Job summary prompt
│   ├── JOB_AGENT.md               # Agent runtime environment
│   ├── CODE_PLANNING.md           # Code workspace planning prompt
│   ├── HEARTBEAT.md               # Self-monitoring
│   ├── CLUSTER_SYSTEM_PROMPT.md   # Cluster system prompt
│   ├── CLUSTER_ROLE_PROMPT.md     # Cluster role prompt
│   ├── SKILL_BUILDING_GUIDE.md    # Guide for building skills
│   ├── CRONS.json                 # Scheduled jobs
│   └── TRIGGERS.json              # Webhook trigger definitions
├── app/
│   ├── layout.js
│   ├── page.js
│   ├── api/[...thepopebot]/       # Catch-all API route
│   └── stream/chat/               # Chat streaming route
├── docker/
│   ├── pi-coding-agent-job/
│   │   ├── Dockerfile             # Pi coding agent container
│   │   └── entrypoint.sh          # Container startup script
│   ├── claude-code-job/
│   │   ├── Dockerfile             # Claude Code CLI job container
│   │   └── entrypoint.sh          # Container startup script
│   ├── claude-code-headless/
│   │   ├── Dockerfile             # Claude Code headless task container
│   │   └── entrypoint.sh          # Container startup script
│   ├── claude-code-workspace/
│   │   ├── Dockerfile             # Interactive code workspace container
│   │   └── entrypoint.sh          # Container startup script
│   ├── claude-code-cluster-worker/
│   │   ├── Dockerfile             # Cluster worker container
│   │   └── entrypoint.sh          # Container startup script
│   └── event-handler/
│       └── Dockerfile             # Event handler container
├── docker-compose.yml             # Production deployment (Traefik + event handler + runner)
├── middleware.js                   # Auth middleware (re-exports from thepopebot)
├── cron/                          # Working dir for command-type cron jobs
├── triggers/                      # Working dir for command-type trigger scripts
├── skills/                        # Plugin directories (activate via skills/active/ symlinks)
├── logs/                          # Per-job directories (job.md + session logs)
├── next.config.mjs                # Next.js config (wraps withThepopebot)
├── instrumentation.js             # Server startup hook (re-exports register)
├── .env                           # Environment config (generated by setup)
└── package.json
```

All core logic lives in the `thepopebot` NPM package. The user's project contains only configuration files and thin Next.js wiring.

---

## Event Handler

The Event Handler is a Next.js API route handler that provides orchestration capabilities. All routes are served through a catch-all route (`app/api/[...thepopebot]/route.js`) that re-exports `GET` and `POST` from the `thepopebot/api` package entry point.

### API Endpoints

| Endpoint | Method | x-api-key | Purpose |
|----------|--------|-----------|---------|
| `/api/ping` | GET | N | Health check, returns `{"message": "Pong!"}` |
| `/api/create-job` | POST | Y | Generic webhook for job creation |
| `/api/telegram/webhook` | POST | N | Telegram bot webhook (uses its own secret) |
| `/api/telegram/register` | POST | Y | Register Telegram webhook URL |
| `/api/github/webhook` | POST | N | Receives notifications from GitHub Actions (uses its own secret) |
| `/api/jobs/status` | GET | Y | Check status of a running job |
| `/api/cluster/:id/role/:id/webhook` | POST | Y | Trigger cluster role execution |

API keys are database-backed and managed via the web UI Settings page. Use the `x-api-key` header for authentication.

**Examples:**

Create a job via webhook:

```bash
curl -X POST https://your-app-url/api/create-job \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{"job": "Update the README with installation instructions"}'
```

Check job status:

```bash
curl "https://your-app-url/api/jobs/status?job_id=abc123" \
  -H "x-api-key: YOUR_API_KEY"
```

Register Telegram webhook:

```bash
curl -X POST https://your-app-url/api/telegram/register \
  -H "Content-Type: application/json" \
  -H "x-api-key: YOUR_API_KEY" \
  -d '{
    "bot_token": "YOUR_BOT_TOKEN",
    "webhook_url": "https://your-domain.com/api/telegram/webhook"
  }'
```

### Components

- **`api/index.js`** - Next.js route handlers (GET/POST) for all `/api/*` endpoints
- **`lib/cron.js`** - Loads CRONS.json and schedules jobs using node-cron
- **`lib/triggers.js`** - Loads TRIGGERS.json and fires actions when watched paths are hit
- **`lib/ai/`** - LLM integration (multi-provider chat, streaming, agent, tools)
- **`lib/channels/`** - Channel adapter pattern for Telegram (and future channels)
- **`lib/tools/`** - Job creation, GitHub API, Telegram, Docker, and OpenAI utilities
- **`lib/code/`** - Code workspaces (server actions, terminal view, WebSocket proxy)
- **`lib/cluster/`** - Worker clusters (roles, triggers, Docker containers)

---

## GitHub Actions Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `run-job.yml` | `job/*` branch created | Runs Docker agent container |
| `auto-merge.yml` | PR opened from `job/*` branch | Checks `AUTO_MERGE` + `ALLOWED_PATHS`, merges if allowed |
| `rebuild-event-handler.yml` | Push to `main` | Rebuilds Next.js inside the event handler container |
| `upgrade-event-handler.yml` | Manual / scheduled | Upgrades thepopebot package in the event handler |
| `notify-pr-complete.yml` | After `auto-merge.yml` completes | Gathers job data, sends to event handler for notification |
| `notify-job-failed.yml` | When `run-job.yml` fails | Sends failure notification to event handler |

**Flow:**

1. Event handler creates a `job/uuid` branch via GitHub API
2. GitHub Actions detects branch creation → runs `run-job.yml`
3. Docker agent executes task, commits results, creates PR
4. `auto-merge.yml` runs → checks merge policy → squash merges (or leaves open)
5. `notify-pr-complete.yml` runs → gathers job data → sends to event handler → notification
6. If `run-job.yml` fails, `notify-job-failed.yml` sends a failure alert

---

## Docker Agent

The container executes tasks autonomously using either the Pi coding agent or Claude Code CLI. The agent backend is selected via the `run-job.yml` workflow configuration.

**Agent backends:**
- **Pi coding agent** (`docker/pi-coding-agent-job/`) — Original agent with Puppeteer + Chromium
- **Claude Code** (`docker/claude-code-job/`) — Anthropic's Claude Code CLI

**Container includes:**
- Node.js 22
- Selected coding agent (Pi or Claude Code)
- Puppeteer + Chromium (headless browser, CDP on port 9222) — Pi agent only
- Git + GitHub CLI

**Environment Variables:**

| Variable | Description | Required |
|----------|-------------|----------|
| `REPO_URL` | Your repository URL | Yes |
| `BRANCH` | Branch to work on (e.g., job/uuid) | Yes |
| `SECRETS` | Protected credentials collected from `AGENT_*` GitHub secrets by `run-job.yml` | Yes |
| `LLM_SECRETS` | LLM-accessible credentials collected from `AGENT_LLM_*` GitHub secrets by `run-job.yml` | No |

**Runtime Flow:**

1. Extract Job ID from branch name
2. Start Chrome in headless mode (Pi agent)
3. Decode and export secrets (filtered from LLM's bash)
4. Decode and export LLM secrets (accessible to LLM)
5. Configure Git credentials
6. Clone repository branch
7. Run agent with SOUL.md + job.md
8. Commit all changes
9. Create PR (auto-merge handled by `auto-merge.yml` workflow)

---

## Code Workspaces

Interactive Docker containers (`docker/claude-code-workspace/`) with an in-browser terminal. Users can launch workspaces from the web UI to get a live shell into a development environment. Managed by `lib/code/` — includes server actions, WebSocket proxy for terminal I/O, and React UI components.

---

## Clusters

Groups of Docker containers spawned from role definitions with webhook triggers. Each cluster has roles, and each role runs in a `docker/claude-code-cluster-worker/` container. Roles can be triggered via the `/api/cluster/:id/role/:id/webhook` endpoint. Managed by `lib/cluster/` — includes runtime orchestration, streaming, server actions, and React UI.

---

## Headless Mode

For tasks that don't require a full job branch workflow, a headless container (`docker/claude-code-headless/`) can execute Claude Code tasks directly without creating a GitHub branch or PR. Useful for one-off tasks triggered from the event handler.

---

## Session Logs

Each job gets its own directory at `logs/{JOB_ID}/` containing both the job description (`job.md`) and session logs (`.jsonl`). These can be used to resume sessions or review agent actions.
