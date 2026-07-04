---
name: picklist-ops
description: Warehouse picklist automation — auto-batches when 25 orders reach ready status, falls back to time-limit print, and runs a morning batch for all overnight orders. Generates SKU-grouped pick lists with QR codes for pack station shipping label printing.
---

# picklist-ops

Automated warehouse picklist generation for ArryBarry fulfilment operations.

## What This Skill Does

- **Auto-batch**: monitors BaseLinker for orders in "ready to pick" status; prints when 25 orders accumulate
- **Time-limit fallback**: if 25 orders don't accumulate within 1 hour, prints whatever is ready
- **Morning batch**: cron at 8 AM prints ALL overnight ready orders grouped by SKU with no 25-order cap
- **SKU grouping**: same product appears as one consolidated row across multiple orders
- **QR code**: each picklist includes a QR code for the pack station to scan and trigger shipping label printing

## Modes

- `--mode=auto` (default): check threshold → print at 25, or fall back to time-limit
- `--mode=morning`: fetch all orders since last batch, no size cap
- `--mode=manual`: used internally by web UI override buttons

## Web UI

Manual override buttons live at `/picklist` in the thepopebot web interface:
- **Print next 25**: immediately generate a picklist for the next 25 ready orders
- **Print selected orders**: select specific orders from the list and generate a picklist

## Pack Station QR Flow

1. Picklist HTML contains a QR code encoding `{APP_URL}/picklist/batch/{batchId}`
2. Pack station operator scans the QR → browser opens the batch page
3. Batch page shows all orders in the batch and a "Get Shipping Labels" button
4. Clicking triggers BaseLinker to create packages and returns label PDFs

## Configuration

Set in Doppler (`shared-services`):
- `BL_PICKLIST_STATUS_ID` — BaseLinker status ID for orders ready to pick (required)
- `APP_URL` — Full URL of the thepopebot instance (for QR code links)

Optional env overrides:
- `PICKLIST_BATCH_SIZE` — orders per batch (default: 25)
- `PICKLIST_TIME_LIMIT_HOURS` — time-limit fallback in hours (default: 1)

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, config.sh, alerts.sh)
- Doppler shared-services (BASELINKER_API_TOKEN, BL_PICKLIST_STATUS_ID, APP_URL)
- obsidian-sync optional (vault write for records)

## State

State and batch files are stored in `/app/data/picklist-ops/`:
- `state.json` — batch timer, last batch epoch, last batch ID
- `batches/{batchId}.json` — batch manifest (order IDs, mode, timestamp)
- `batches/{batchId}.html` — generated picklist HTML
