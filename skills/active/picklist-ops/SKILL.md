---
name: picklist-ops
description: "Warehouse picklist automation for ArryBarry: auto-batches orders from BaseLinker when 25 reach ready status or after 1 hour, morning batch captures all overnight orders, SKU-grouped HTML picklists with QR scan-to-open-label support at the pack station."
---

# picklist-ops

Automated picklist generation and warehouse fulfilment coordination for ArryBarry.

## What This Skill Does

- **Auto-batch trigger**: Monitors BaseLinker every 5 minutes for orders in "ready to pick" status. When 25 orders accumulate, generates a picklist immediately.
- **Time-limit fallback**: If 25 orders haven't arrived within 1 hour, prints whatever is in the queue (minimum 1 order) so nothing stalls.
- **Morning batch**: At 07:30 daily, prints ALL orders in "ready" status in one go — no 25-order cap — so overnight orders are all covered before the day shift starts.
- **Manual triggers**: Webhook endpoints allow "Print next 25" or "Print selected orders" to be called on demand.
- **SKU-grouped layout**: Products are grouped by SKU across all orders in the batch so the picker collects every unit of a product in one trip, then moves on.
- **Scan-to-open labels**: Each order on the picklist carries a QR code that opens it directly in BaseLinker at the pack station for label printing.

## How It Runs

- **Auto-check cron:** Every 5 minutes (`*/5 * * * *`)
- **Morning batch cron:** Daily at 07:30 (`30 7 * * *`)
- **Manual triggers:** POST to `/webhook/picklist/next25` or `/webhook/picklist/selected`
- **Label scan:** Scan QR on picklist → opens BaseLinker order in browser → print label
- **Output:** HTML picklists in `/opt/bigman-engine/picklists/` + vault summary in `07-Marketplace/Picklists/`

## Configuration (via Doppler / environment)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PICKLIST_READY_STATUS_ID` | Yes | — | BaseLinker status_id for "ready to pick" |
| `PICKLIST_PICKING_STATUS_ID` | No | — | Status to set when an order enters a batch (prevents double-batching) |
| `PICKLIST_BATCH_SIZE` | No | 25 | Max orders per auto/manual-next batch |
| `PICKLIST_TIME_LIMIT_SECS` | No | 3600 | Seconds before time-limit fallback fires |
| `PICKLIST_HOST` | No | http://localhost:3000 | Public base URL (used in QR fallback text) |
| `PICKLIST_PRINT_CMD` | No | — | Shell command to send the HTML file to a printer, e.g. `lp -d OfficePrinter` |
| `BASELINKER_API_TOKEN` | Yes | — | Shared via marketplace-lib |
| `OBSIDIAN_API_KEY` | Yes | — | Vault write |
| `OBSIDIAN_HOST` | Yes | — | Vault URL |

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- obsidian-sync (vault write)
- Python 3 (for picklist generation)
- `qrencode` CLI (optional — for QR codes; falls back to plain text)
- Doppler shared-services

## State Files

Stored in `/opt/bigman-engine/state/picklist-ops/`:

| File | Contents |
|------|----------|
| `batch-counter` | Integer, increments per batch generated |
| `queue-first-seen` | Epoch timestamp when queue was first non-empty |
| `last-batch-time` | Epoch timestamp of last batch generation |
| `morning-batch-date` | YYYY-MM-DD of last successful morning batch |
