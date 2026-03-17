# triggers/ — Trigger Action Scripts

This directory holds scripts referenced by `command`-type entries in `config/TRIGGERS.json`.

When a `command`-type trigger fires, the working directory is `triggers/`.

## Example

In `config/TRIGGERS.json`:
```json
{
  "name": "Deploy Hook",
  "watch_path": "/webhook/deploy",
  "enabled": true,
  "actions": [
    {
      "type": "command",
      "command": "node on-deploy.js {{body.environment}}"
    }
  ]
}
```

This runs `triggers/on-deploy.js` when a POST hits `/webhook/deploy`.

## Template Tokens

`command` (and `job`) strings support template tokens resolved from the incoming request:

| Token | Resolves to |
|-------|-------------|
| `{{body}}` | Entire request body as JSON |
| `{{body.field}}` | Nested field from request body |
| `{{query}}` | All query parameters as JSON |
| `{{query.field}}` | Specific query parameter |
| `{{headers}}` | All request headers as JSON |
| `{{headers.field}}` | Specific request header |

## Action Types

Most trigger entries use `type: "agent"` (the default) which spins up a Docker agent. Only `command`-type entries reference scripts in this directory. See `config/TRIGGERS.json` for the full trigger configuration and the root `CLAUDE.md` for all action type details.
