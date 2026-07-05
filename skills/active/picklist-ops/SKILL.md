# picklist-ops

Warehouse picklist automation for ArryBarry order fulfilment.

## What This Skill Does

Automates the generation of SKU-grouped pick lists from BaseLinker orders in the "ready to pick" status:

- **Auto-batch trigger** — generates a picklist when 25 ready orders accumulate
- **Time-limit fallback** — if 25 orders are not reached within 1 hour, generates with whatever is available
- **Morning batch** — at 7am, prints ALL overnight orders grouped by SKU in one consolidated picklist (no 25-cap)
- **Manual triggers** — `Print next 25` and `Print selected orders` webhook endpoints
- **SKU-grouped layout** — same products from different orders appear together, sorted by warehouse location then SKU
- **Pack station QR** — each picklist includes a QR code; scanning it at the pack station fires shipping label creation in BaseLinker

## How It Runs

- **Auto-check cron:** `*/5 * * * *` — monitors ready-order count, triggers batch at 25 or after 1-hour timeout
- **Morning batch cron:** `0 7 * * *` — prints all overnight orders, resets daily batch state
- **Manual: Print next 25** — POST `/api/webhook/picklist-print-25` (with `x-api-key` header)
- **Manual: Print selected** — POST `/api/webhook/picklist-print-selected` with body `{"order_ids": [...]}`
- **Pack station scan** — POST `/api/webhook/picklist-scan` with body `{"picklist_id": "042"}`

## Configuration (Doppler: shared-services/prd)

| Variable | Description | Example |
|----------|-------------|---------|
| `PICKLIST_READY_STATUS_ID` | BaseLinker status_id for "ready to pick" | `121680` |
| `PICKLIST_PICKING_STATUS_ID` | Status set when picking starts | `121681` |
| `PICKLIST_PACKED_STATUS_ID` | Status set after labels created | `121682` |
| `PICKLIST_DEFAULT_COURIER` | Default courier code for label creation | `dpd` |
| `THEPOPEBOT_BASE_URL` | Base URL for QR code webhook links | `https://bot.arrybarry.com` |
| `BASELINKER_API_TOKEN` | BaseLinker API token | — |
| `OBSIDIAN_API_KEY` | Obsidian REST API key | — |
| `OBSIDIAN_HOST` | Obsidian host URL | — |

## State Files

All state in `/opt/bigman-engine/state/picklist-ops/`:

- `batch-start-time` — epoch timestamp when first ready order was seen in current cycle
- `morning-batch-YYYY-MM-DD` — marker for morning batch completion
- `picklist-counter` — sequential picklist ID counter
- `picklists/{ID}.json` — per-picklist state: order IDs, generation time, status

## Output

Vault notes at `07-Marketplace/Picklists/`:
- `YYYY-MM-DD-picklist-NNN.md` — the pick list itself
- `YYYY-MM-DD-labels-NNN.md` — label print report after pack station scan

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- obsidian-sync (vault write)
- qrencode (QR code generation — `apt install qrencode`)
- Doppler shared-services (PICKLIST_*, THEPOPEBOT_BASE_URL, BASELINKER_API_TOKEN, OBSIDIAN_*)
