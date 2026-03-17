# cron/ — Cron Action Scripts

This directory holds scripts referenced by `command`-type entries in `config/CRONS.json`.

When a `command`-type cron fires, the working directory is `cron/`.

## Example

In `config/CRONS.json`:
```json
{
  "name": "Daily Cleanup",
  "schedule": "0 3 * * *",
  "type": "command",
  "command": "node cleanup.js --older-than 7d",
  "enabled": true
}
```

This runs `cron/cleanup.js` daily at 3am.

## Action Types

Most cron entries use `type: "agent"` (the default) which spins up a Docker agent — those don't need scripts here. Only `command`-type entries reference scripts in this directory. See `config/CRONS.json` for the full cron configuration and the root `CLAUDE.md` for all action type details.
