---
name: picklist-ops
description: Warehouse picklist automation — auto-batches orders by SKU, generates printable picklists with QR codes and bin references, and auto-prints shipping labels on scan-return.
---

# picklist-ops

Warehouse picking automation for ArryBarry. Generates consolidated SKU-grouped picklists from BaseLinker orders, handles overnight and daytime batching strategies, and triggers shipping label printing when pickers return from the warehouse.

## What This Skill Does

- **Morning batch** — before the warehouse opens, pulls all overnight ready-to-pick orders and generates one or more SKU-grouped picklists. No hard 25-order cap; same-SKU groups are never split across batches.
- **Daytime batch** — every 30 minutes during business hours, batches ~25 orders (extended to include all same-SKU orders). Falls back to printing whatever is queued if the time limit is reached and volume is low.
- **Manual batch** — "Print next 25" or "Print selected orders" triggered via webhook from the scanning station or Telegram bot.
- **Scan return** — when a picker returns and scans the picklist QR code, automatically fetches and prints shipping labels for all orders in the batch, then updates order status in BaseLinker.
- **SKU grouping** — picklists sorted by bin/location so pickers walk the warehouse efficiently. Quantities consolidated per SKU across all orders in the batch.
- **QR codes** — each picklist carries a unique batch ID encoded as a QR code for scan-return triggering.

## How It Runs

- **Morning cron:** `0 7 * * 1-5` — runs before the 8 AM warehouse open (adjust schedule to match site hours)
- **Daytime cron:** `*/30 8-17 * * 1-5` — every 30 minutes during warehouse hours
- **Scan-return webhook:** POST to `/webhook` with `{"action": "scan-return", "batch_id": "PL-YYYYMMDD-NNN"}`
- **Manual webhook:** POST to `/webhook` with `{"action": "manual-batch"}` or `{"action": "manual-batch", "order_ids": "12345,12346"}`

## Required Environment Variables (via Doppler shared-services)

| Variable | Description |
|----------|-------------|
| `BASELINKER_API_TOKEN` | BaseLinker API key |
| `PICKLIST_READY_STATUS_ID` | BaseLinker order status ID meaning "ready to pick" (e.g. `123456`) |
| `PICKLIST_PACKED_STATUS_ID` | BaseLinker order status ID to set after picking (e.g. `123457`) |
| `PICKLIST_INVENTORY_ID` | BaseLinker inventory ID for location lookups |
| `OBSIDIAN_HOST` | Obsidian REST API base URL (for vault picklist archive) |
| `OBSIDIAN_API_KEY` | Obsidian REST API token |

## Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PICKLIST_BATCH_SIZE` | `25` | Target orders per daytime batch |
| `PICKLIST_TIME_FALLBACK_MINS` | `30` | Minutes before forcing a batch even if below target |
| `PICKLIST_PRINTER_NAME` | (none) | CUPS printer name for picklist auto-print |
| `LABEL_PRINTER_NAME` | (none) | CUPS printer name for shipping label auto-print |

## State

Persisted at `/opt/bigman-engine/state/picklist/`:

- `batched-order-ids.txt` — one order ID per line; prevents double-batching
- `last-batch-time` — unix timestamp of last daytime batch (for time fallback)
- `batches/PL-YYYYMMDD-NNN.json` — batch metadata (order IDs, SKU groups, status)
- `prints/PL-YYYYMMDD-NNN.html` — generated picklist HTML

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- obsidian-sync (vault write for picklist archive)
- Doppler shared-services
- Optional: CUPS (`lp`) for physical printing
- Optional: `wkhtmltopdf` or Chromium for PDF conversion
