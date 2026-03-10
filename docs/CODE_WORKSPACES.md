# Code Workspaces

Code workspaces are browser-based interactive coding sessions that run inside Docker containers. They give you a full terminal environment with Claude Code pre-installed, connected to a Git repository of your choice. Think of them as on-demand cloud development environments you can launch directly from chat.

---

## Creating a Workspace

Start a code workspace from any chat conversation. When you ask the AI to help with code, it can launch a workspace using the `start_coding` tool. The AI will:

1. Spin up a Docker container with Claude Code and your repository cloned
2. Create a feature branch for your changes
3. Open the workspace in your browser at `/code/{id}`

The chat conversation is linked to the workspace, so the AI has context about what you were discussing.

---

## What You Can Do

### Claude Code Tab

The primary tab is a full Claude Code session running in your browser via xterm.js. You can interact with Claude Code exactly as you would locally — ask it to write code, debug issues, run tests, or explore the codebase.

### Shell Tabs

Click **+ Shell** in the tab bar to open additional terminal sessions inside the same container. These are plain bash shells in your workspace directory. Use them to run commands, check logs, or do anything you would in a normal terminal — without interrupting your Claude Code session.

### Toolbar Actions

The toolbar at the bottom of the Claude Code tab provides quick actions:

| Button | What it does |
|--------|-------------|
| **Commit** | Sends the `/commit-changes` command to Claude Code |
| **Merge** | Sends the `/ai-merge-back` command to merge your feature branch |
| **Reconnect** | Reconnects to the container if the WebSocket drops |
| **Close Session** | Ends the workspace (see Closing a Session below) |
| **Theme** | Cycles between dark, light, and system terminal themes |

---

## Container Lifecycle

### Startup

When a workspace is created, a Docker container is launched from the `claude-code-workspace` image. The container:

- Clones your repository and checks out the specified branch
- Creates a feature branch if one was requested
- Starts `ttyd` (a terminal-over-WebSocket server) so your browser can connect
- Receives chat context from the linked conversation so Claude Code understands your goals

### Persistence

Workspace data is stored in a Docker named volume. If the container stops or crashes, the system automatically recovers it:

- **Stopped or paused containers** are restarted
- **Dead or missing containers** are recreated with the same volume, preserving your work
- The browser client automatically attempts to reconnect and will trigger container recovery if needed

### Closing a Session

When you close a workspace session (via the toolbar or tab close button), the system:

1. Checks for uncommitted or unpushed changes and warns you if any exist
2. Injects a summary of your commits into the linked chat conversation, so the AI knows what was done
3. Removes the container and its volume
4. Redirects you back to the linked chat

If you have unsaved work, commit and push your changes before closing. Changes in the container that are not pushed to the remote will be lost when the session ends.

---

## Headless Mode

Headless mode runs a coding task without an interactive terminal. Instead of opening a browser-based workspace, the AI launches an ephemeral container that executes the task autonomously — Claude Code runs with `-p` (prompt mode), commits changes, and merges back automatically.

### When to Use It

- **Interactive mode** — You want to watch, guide, or collaborate with Claude Code in real-time. Best for exploratory work, debugging sessions, or tasks where you want direct control.
- **Headless mode** — You have a clear task description and want it done hands-off. Best for well-defined implementation tasks, refactors, or automated workflows.

The chat UI provides a toggle to switch between interactive and headless mode after selecting a repository and branch.

### How It Works

1. The AI calls the `start_headless_coding` tool with your task description
2. An ephemeral container launches, clones your repo, and creates a feature branch
3. Claude Code runs the task in prompt mode (`claude -p`)
4. Output streams live back to your chat — you can watch progress in real-time
5. When complete, the container commits changes and creates a PR
6. The container is automatically cleaned up

Headless containers share the same workspace volume system as interactive sessions, so the AI can close an interactive session and continue the work headlessly (or vice versa).

---

## Configuration

Code workspaces require:

- **Docker** — The event handler needs access to the Docker socket (`/var/run/docker.sock`)
- **`GH_TOKEN`** — A GitHub token for cloning repositories
- **`CLAUDE_CODE_OAUTH_TOKEN`** — Authentication token for Claude Code inside the container

These are configured during initial setup. No additional workspace-specific configuration is needed.
