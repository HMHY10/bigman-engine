---
name: picklist-ops
description: Warehouse picklist automation — auto-batches ready orders, generates SKU-grouped pick lists, and triggers shipping label printing at the pack station via QR scan.
---

# picklist-ops

Automated pick list generation for ArryBarry warehouse operations.

## Features

- **Auto-batch**: triggers when 25 orders accumulate in the "ready to pick" status
- **Time-limit fallback**: prints whatever is available after 1 hour if 25 orders not reached
- **Morning batch**: at 7 AM prints ALL overnight orders (no 25-order cap), grouped by SKU
- **SKU grouping**: same products from multiple orders appear together for efficient picking
- **QR scan trigger**: each order line has a QR code; scanning at the pack station fires shipping label print

## Scripts

| Script | Purpose |
|--------|---------|
| `run.sh` | Auto-batch daemon — check order count and time limit (run every 5 min via cron) |
| `morning-batch.sh` | Morning full-batch — fetch all overnight orders and generate one big picklist |
| `picklist-lib.sh` | Shared library — HTML generation, SKU grouping, state management |

## State Files (`/app/data/picklist/`)

| File | Purpose |
|------|---------|
| `timer.json` | When the 25-order batch timer started |
| `printed-orders.json` | Order IDs already included in a printed picklist |
| `batch-{id}.json` | Picklist batch data (used by web print view) |

## Configuration (marketplace-lib/config.sh)

| Variable | Default | Description |
|----------|---------|-------------|
| `PICKLIST_READY_STATUS_ID` | (must be set) | BaseLinker order_status_id for "Ready to Pick" |
| `PICKLIST_BATCH_SIZE` | 25 | Orders per auto-batch |
| `PICKLIST_TIME_LIMIT_SECONDS` | 3600 | Max wait time before printing partial batch |
| `PICKLIST_OVERNIGHT_HOURS` | 13 | Hours to look back for morning batch (covers overnight) |
| `PICKLIST_STATE_DIR` | /app/data/picklist | State file directory |
| `PICKLIST_SCAN_BASE_URL` | (must be set) | Base URL for QR scan endpoint (e.g. https://bot.arrybarry.com) |

## Dependencies

- marketplace-lib (baselinker.sh, config.sh, alerts.sh)
- Doppler shared-services: BASELINKER_API_TOKEN, OBSIDIAN_API_KEY, OBSIDIAN_HOST, PICKLIST_READY_STATUS_ID, PICKLIST_SCAN_BASE_URL
