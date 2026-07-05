---
name: picklist-ops
description: Picklist automation — auto-batch, morning run, SKU grouping, and QR-code label trigger for ArryBarry warehouse operations
---

# picklist-ops

Automates pick list generation for ArryBarry warehouse fulfilment. Monitors BaseLinker "ready to ship" orders and produces SKU-grouped HTML pick lists, with QR codes that fire shipping-label printing at the pack station.

## What This Skill Does

- **Auto-batch trigger** — watches the ready-to-ship queue; prints a picklist when 25 orders accumulate *or* when the oldest queued order is more than 60 minutes old (whichever comes first)
- **Morning batch** — at 08:00 prints ALL overnight ready orders in one consolidated picklist (no 25-order cap)
- **Manual print-next-25** — on-demand trigger for the next 25 queued orders
- **Manual print-selected** — on-demand trigger for a specific set of order IDs (comma-separated)
- **Label-print trigger** — a QR code on each picklist row links to a webhook; scanning it at the pack station calls BaseLinker to print the shipping label on the thermal printer

## How It Runs

| Mode | Trigger | Schedule / Source |
|------|---------|------------------|
| Auto-batch check | System cron command | Every 5 min: `*/5 * * * *` |
| Morning batch | System cron command | 08:00 daily: `0 8 * * *` |
| Print next 25 | Webhook `POST /webhook/picklist-next-25` | Manual (Telegram / browser) |
| Print selected | Webhook `POST /webhook/picklist-selected` with `?order_ids=1,2,3` | Manual |
| Label print | Webhook `GET /webhook/picklist-label?order_id=N` | QR code scan at pack station |

## Picklist Format

HTML file written to `08-Operations/Picklists/YYYY-MM-DD-HHMMSS-batch-N.html` in the Obsidian vault. Staff open it on the warehouse PC and print via browser.

Layout:
```
ARRYBARRY PICK LIST — 2026-07-05 08:00 — Batch #7 — 18 orders

SKU: AB-SERUM-30ML  (4 units across 3 orders)
  ┌ Order 123456  Jane Doe      Qty 2  [QR]
  ├ Order 123789  John Smith    Qty 1  [QR]
  └ Order 124001  Alice Brown   Qty 1  [QR]

SKU: AB-MOISTURISER-50ML  (6 units across 2 orders)
  ┌ Order 123456  Jane Doe      Qty 3  [QR]
  └ Order 124099  Bob Taylor    Qty 3  [QR]
```

Each row's QR code encodes a thepopebot webhook URL that prints the label for that order when scanned.

## State Files

Stored at `/opt/bigman-engine/state/picklist-ops/`:
- `queue.json` — array of queued order objects with IDs and arrival timestamps
- `batch-counter.txt` — incrementing batch number
- `last-batch.json` — metadata from the last batch run

## Configuration (Doppler: shared-services)

| Variable | Description |
|----------|-------------|
| `BASELINKER_API_TOKEN` | BaseLinker API token |
| `OBSIDIAN_API_KEY` | Obsidian REST API key |
| `OBSIDIAN_HOST` | Obsidian REST API URL |
| `PICKLIST_READY_STATUS_ID` | BaseLinker `order_status_id` for "Ready to Ship" |
| `PICKLIST_WEBHOOK_HOST` | thepopebot host URL (e.g. `https://bot.arrybarry.com`) |
| `PICKLIST_LABEL_PRINTER` | BaseLinker printer ID for thermal label printer (default: `0`) |

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- obsidian-sync (vault write via alerts.sh `vault_write`)
- `jq` for JSON processing
- `qrencode` or online QR API (falls back gracefully if offline)
- Doppler shared-services env vars
