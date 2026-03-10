[![ThePopeBot](docs/hero.png)](https://www.skool.com/ai-architects)

[Get priority support HERE](https://www.skool.com/ai-architects)

# ThePopeBot

Build autonomous AI agents that work for you 24/7, individually or in teams.

### What You Get

- **Runs 24/7** — set up tasks and your agent handles them around the clock, no babysitting
- **Does real work** — writes code, opens pull requests, completes multi-step tasks end to end
- **Agent clusters** — build teams of agents that coordinate and work together on bigger jobs
- **Full visibility** — every action is a commit you can review, approve, or undo

### Why It Works

**The repository IS the agent** — Every action your agent takes is a git commit. You can see exactly what it did, when, and why. If it screws up, revert it. Want to clone your agent? Fork the repo — code, personality, scheduled jobs, full history, all of it goes with your fork.

**Free compute, built in** — Every GitHub account comes with free cloud computing time. thepopebot uses that to run your agent. One task or a hundred in parallel — the compute is already included.

**Self-evolving** — The agent modifies its own code through pull requests. Every change is auditable, every change is reversible. You stay in control.

---

## How It Works

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  ┌─────────────────┐         ┌─────────────────┐                     │
│  │  Event Handler  │ ──1──►  │     GitHub      │                     │
│  │  (creates job)  │         │ (job/* branch)  │                     │
│  └────────▲────────┘         └────────┬────────┘                     │
│           │                           │                              │
│           │                           2 (triggers run-job.yml)       │
│           │                           │                              │
│           │                           ▼                              │
│           │                  ┌─────────────────┐                     │
│           │                  │  Docker Agent   │                     │
│           │                  │(Pi/Claude Code) │                     │
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
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

You interact with your bot via the web chat interface or Telegram (optional). The Event Handler creates a job branch. GitHub Actions spins up a Docker container with the Pi coding agent. The agent does the work, commits the results, and opens a PR. Auto-merge handles the rest. You get a notification when it's done.

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=stephengpope/thepopebot&type=date&legend=top-left)](https://www.star-history.com/#stephengpope/thepopebot&type=date&legend=top-left)

---

## Get Started

### Prerequisites

| Requirement | Install |
|-------------|---------|
| **Node.js 18+** | [nodejs.org](https://nodejs.org) |
| **npm** | Included with Node.js |
| **Git** | [git-scm.com](https://git-scm.com) |
| **GitHub CLI** | [cli.github.com](https://cli.github.com) |
| **Docker + Docker Compose** | [docker.com](https://docs.docker.com/get-docker/) (installer requires admin password) |
| **ngrok*** | [ngrok.com](https://ngrok.com/download) (free account + authtoken required) |

*\*ngrok is only required for local installs without port forwarding. VPS/cloud deployments don't need it. [Sign up](https://dashboard.ngrok.com/signup) for a free ngrok account, then run `ngrok config add-authtoken <YOUR_TOKEN>` before starting setup.*

### Two steps

**Step 1** — Scaffold a new project:

```bash
mkdir my-agent && cd my-agent
npx thepopebot@latest init
```

This creates a Next.js project with configuration files, GitHub Actions workflows, and agent templates. You don't need to create a GitHub repo first — the setup wizard handles that.

**Step 2** — Run the setup wizard:

```bash
npm run setup
```

The wizard walks you through everything:
- Checks prerequisites (Node.js, Git, GitHub CLI)
- Creates a GitHub repository and pushes your initial commit
- Creates a GitHub Personal Access Token (scoped to your repo)
- Collects API keys (Anthropic required; OpenAI, Brave optional)
- Sets GitHub repository secrets and variables
- Generates `.env`
- Builds the project and starts Docker for you

**That's it.** Visit your APP_URL when the wizard finishes.

- **Web Chat**: Visit your APP_URL to chat with your agent, create jobs, upload files
- **Telegram** (optional): Run `npm run setup-telegram` to connect a Telegram bot
- **Webhook**: Send a POST to `/api/create-job` with your API key to create jobs programmatically
- **Cron**: Edit `config/CRONS.json` to schedule recurring jobs

### Chat vs Agent LLM

Your bot has two sides — a **chat** side and an **agent** side.

**Chat** is the conversational part. When you talk to your bot in the web UI or Telegram, it uses the chat LLM. This runs on your server and responds in real time.

**Agent** is the worker. When your bot needs to write code, modify files, or do a bigger task, it spins up a separate job that runs in a Docker container on GitHub. That job uses the agent LLM.

By default, both use the same model. But during setup, you can choose different models for each — for example, a faster model for chat and a more capable one for agent jobs. The wizard asks "Would you like agent jobs to use different LLM settings?" and lets you pick.

### Using a Claude Subscription (OAuth Token)

If you have a Claude Pro ($20/mo) or Max ($100+/mo) subscription, you can use it to power your agent jobs instead of paying per API call. During setup, choose Anthropic as your agent provider and say yes when asked about a subscription.

You'll need to generate a token:

```bash
# Install Claude Code CLI (if you don't have it)
npm install -g @anthropic-ai/claude-code

# Generate your token (opens browser to log in)
claude setup-token
```

Paste the token (starts with `sk-ant-oat01-`) into the setup wizard. Your agent jobs will now run through your subscription. Note that usage counts toward your Claude.ai limits, and you still need an API key for the chat side.

See [Claude Code vs Pi](docs/CLAUDE_CODE_VS_PI.md) for more details on the two agent backends.

> **Local installs**: Your server needs to be reachable from the internet for GitHub webhooks and Telegram. On a VPS/cloud server, your APP_URL is just your domain. For local development, use [ngrok](https://ngrok.com) (`ngrok http 80`) or port forwarding to expose your machine.
>
> **If your ngrok URL changes** (it changes every time you restart ngrok on the free plan), you must update APP_URL everywhere:
>
> ```bash
> # Update .env and GitHub variable in one command:
> npx thepopebot set-var APP_URL https://your-new-url.ngrok.io
> # If Telegram is configured, re-register the webhook:
> npm run setup-telegram
> ```

---

## Updating

```bash
npx thepopebot upgrade          # latest stable
npx thepopebot upgrade @beta    # latest beta
npx thepopebot upgrade 1.2.72   # specific version
```

Saves your local changes, syncs with GitHub, installs the new version, rebuilds, pushes, and restarts Docker.

**What it does:**

1. Saves any local changes you've made
2. Pulls the latest from GitHub (stops if there are conflicts)
3. Installs the new version and updates project files
4. Rebuilds your project
5. Pushes everything to GitHub
6. Restarts Docker containers (if running)

Pushing to `main` triggers the `rebuild-event-handler.yml` workflow on your server. It detects the version change, runs `thepopebot init`, updates `THEPOPEBOT_VERSION` in the server's `.env`, pulls the new Docker image, restarts the container, rebuilds `.next`, and reloads PM2 — no manual `docker compose` needed.

> **Upgrade failed?** See [Recovering from a Failed Upgrade](docs/UPGRADE.md#recovering-from-a-failed-upgrade).

### Understanding `init`

#### How your project is structured

When you ran `thepopebot init` the first time, it scaffolded a project folder with two kinds of files:

**Your files** — These are yours to customize. `init` will never overwrite them:

| Files | What they do |
|-------|-------------|
| `config/SOUL.md`, `JOB_PLANNING.md`, `JOB_AGENT.md`, etc. | Your agent's personality, behavior, and prompts |
| `config/CRONS.json`, `TRIGGERS.json` | Your scheduled jobs and webhook triggers |
| `docker/pi-coding-agent-job/` | The Dockerfile for the Pi coding agent job container |
| `docker/claude-code-job/` | The Dockerfile for the Claude Code agent job container |

**Managed files** — These are infrastructure files that need to stay in sync with the package version. `init` auto-updates them for you:

| Files | What they do |
|-------|-------------|
| `.github/workflows/` | GitHub Actions that run jobs, auto-merge PRs, rebuild on deploy |
| `docker-compose.yml` | Defines how your containers run together (Traefik, event handler, runner) |
| `docker/event-handler/` | The Dockerfile for the event handler container |
| `.dockerignore` | Keeps unnecessary files out of Docker builds |
| `app/` | Next.js pages, layouts, and routes |
| `CLAUDE.md` | AI assistant context for your project |

#### What happens when you run `init`

1. **Managed files** are updated automatically to match the new package version
2. **Your files** are left alone — but if the package ships new defaults (e.g., a new field in `CRONS.json`), `init` lets you know:

```
Updated templates available:
These files differ from the current package templates.

  config/CRONS.json

To view differences:  npx thepopebot diff <file>
To reset to default:  npx thepopebot reset <file>
```

You can review at your own pace:

```bash
npx thepopebot diff config/CRONS.json    # see what changed
npx thepopebot reset config/CRONS.json   # accept the new template
```

#### If you've modified managed files

If you've made custom changes to managed files (e.g., added extra steps to a GitHub Actions workflow), use `--no-managed` so `init` doesn't overwrite your changes:

```bash
npx thepopebot init --no-managed
```

#### Template file conventions

The `templates/` directory contains files scaffolded into user projects by `thepopebot init`. Two naming conventions handle files that npm or AI tools would otherwise misinterpret:

**`.template` suffix** — Files ending in `.template` are scaffolded with the suffix stripped. This is used for files that npm mangles (`.gitignore`) or that AI tools would pick up as real project docs (`CLAUDE.md`).

| In `templates/` | Scaffolded as |
|-----------------|---------------|
| `.gitignore.template` | `.gitignore` |
| `CLAUDE.md.template` | `CLAUDE.md` |
| `api/CLAUDE.md.template` | `api/CLAUDE.md` |

**`CLAUDE.md` exclusion** — The scaffolding walker skips any file named `CLAUDE.md` (without the `.template` suffix). This is a safety net so a bare `CLAUDE.md` accidentally added to `templates/` never gets copied into user projects where AI tools would confuse it with real project instructions.

---

## CLI Commands

All commands are run via `npx thepopebot <command>` (or the `npm run` shortcuts where noted).

**Project setup:**

| Command | Description |
|---------|-------------|
| `init` | Scaffold a new project, or update templates in an existing one |
| `setup` | Run the full interactive setup wizard (`npm run setup`) |
| `setup-telegram` | Reconfigure the Telegram webhook (`npm run setup-telegram`) |
| `reset-auth` | Regenerate AUTH_SECRET, invalidating all sessions |

**Templates:**

| Command | Description |
|---------|-------------|
| `diff [file]` | List files that differ from package templates, or diff a specific file |
| `reset [file]` | List all template files, or restore a specific one to package default |
| `upgrade` / `update` | Upgrade thepopebot (install, init, build, commit, push, restart Docker) |
| `sync <path>` | Sync local package to a test install (build, pack, Docker) |
| `user:password <email>` | Change a user's password |

**Secrets & variables:**

These commands set individual GitHub repository secrets/variables using the `gh` CLI. They read `GH_OWNER` and `GH_REPO` from your `.env`. If VALUE is omitted, you'll be prompted with masked input (keeps secrets out of shell history).

| Command | Description |
|---------|-------------|
| `set-agent-secret KEY [VALUE]` | Set `AGENT_<KEY>` GitHub secret and update `.env` |
| `set-agent-llm-secret KEY [VALUE]` | Set `AGENT_LLM_<KEY>` GitHub secret |
| `set-var KEY [VALUE]` | Set a GitHub repository variable |

GitHub secrets use a prefix convention so the workflow can route them correctly:

- **`AGENT_`** — Protected secrets passed to the Docker container (filtered from LLM). Example: `AGENT_GH_TOKEN`, `AGENT_ANTHROPIC_API_KEY`
- **`AGENT_LLM_`** — LLM-accessible secrets (not filtered). Example: `AGENT_LLM_BRAVE_API_KEY`
- **No prefix** — Workflow-only secrets, never passed to container. Example: `GH_WEBHOOK_SECRET`

---

## Security

thepopebot includes API key authentication, webhook secret validation (fail-closed), session encryption, secret filtering in the Docker agent, and auto-merge path restrictions. However, all software carries risk — thepopebot is provided as-is, and you are responsible for securing your own infrastructure. If you're running locally with a tunnel (ngrok, Cloudflare Tunnel, port forwarding), be aware that your dev server endpoints are publicly accessible with no rate limiting and no TLS on the local hop.

See [Security](docs/SECURITY.md) for full details on what's exposed, the risks, and recommendations.

---

## Running Different Models

The Event Handler (chat, Telegram, webhooks) and Jobs (Docker agent) are two independent layers — each can run a different LLM. Use Claude for interactive chat and a cheaper or local model for long-running jobs, mix providers per cron entry, or run everything on a single model.

See [Running Different Models](docs/RUNNING_DIFFERENT_MODELS.md) for the full guide: Event Handler config, job defaults, per-job overrides, provider table, and custom provider setup.

---

## Docs

| Document | Description |
|----------|-------------|
| [Architecture](docs/ARCHITECTURE.md) | Two-layer design, file structure, API endpoints, GitHub Actions, Docker agent |
| [Configuration](docs/CONFIGURATION.md) | Environment variables, GitHub secrets, repo variables, ngrok, Telegram setup |
| [Customization](docs/CUSTOMIZATION.md) | Personality, skills, operating system files, using your bot, security details |
| [Chat Integrations](docs/CHAT_INTEGRATIONS.md) | Web chat, Telegram, adding new channels |
| [Running Different Models](docs/RUNNING_DIFFERENT_MODELS.md) | Event Handler vs job model config, per-job overrides, providers, custom provider |
| [Auto-Merge](docs/AUTO_MERGE.md) | Auto-merge controls, ALLOWED_PATHS configuration |
| [Deployment](docs/DEPLOYMENT.md) | VPS setup, Docker Compose, HTTPS with Let's Encrypt |
| [Claude Code vs Pi](docs/CLAUDE_CODE_VS_PI.md) | Comparing the two agent backends (subscription vs API credits) |
| [How to Build Skills](docs/HOW_TO_BUILD_SKILLS.md) | Guide to building and activating agent skills |
| [Pre-Release](docs/PRE_RELEASE.md) | Installing beta/alpha builds |
| [Code Workspaces](docs/CODE_WORKSPACES.md) | Interactive Docker containers with in-browser terminal |
| [Clusters](docs/CLUSTERS.md) | Agent clusters — groups of Docker containers spawned from role definitions |
| [Hacks](docs/HACKS.md) | Tips, tricks, and workarounds |
| [Mobile Testing](docs/MOBILE_TESTING.md) | Testing on mobile devices |
| [Security](docs/SECURITY.md) | Security disclaimer, local development risks |
| [Upgrading](docs/UPGRADE.md) | Automated upgrades, recovering from failed upgrades |

### Maintainer

| Document | Description |
|----------|-------------|
| [NPM](docs/NPM.md) | Updating skills, versioning, and publishing releases |
