---
name: picklist-ops
description: Warehouse picklist automation — auto-batches orders from BaseLinker into SKU-grouped picklists with QR codes and bin locations, handles overnight bulk runs and daytime incremental batching, and auto-prints shipping labels when a picker scans a completed picklist on return
---

# picklist-ops

Warehouse picking automation for ArryBarry. Fetches orders from BaseLinker, groups them by SKU, and generates printer-ready HTML picklists with QR codes and bin/location references.

## Modes

| Mode | When | Trigger |
|------|------|---------|
| `overnight` | Pre-warehouse-open | Cron 06:45 Mon–Sat |
| `daytime` | Hourly during ops | Cron every 10 min, 08:00–17:50 |
| `next25` | On demand | Webhook `POST /webhook/picklist` `{"action":"next25"}` |
| `selected` | On demand | Webhook `POST /webhook/picklist` `{"action":"selected","orders":"12345,12346"}` |
| `scan-return` | Picker returns | Webhook `POST /webhook/picklist` `{"action":"scan-return","picklist_id":"PL-20260705-001"}` |

## Overnight Logic

- Fetches all orders with ready-to-pick status created since yesterday 18:00
- Groups by SKU — all orders sharing a SKU stay in the same picklist batch (no cap mid-SKU)
- Produces one or more picklists depending on SKU spread
- Sends to print via `PICKLIST_PRINT_CMD`

## Daytime Logic

- Polls for new ready-to-pick orders every 10 minutes
- Prints immediately when ≥ `PICKLIST_BATCH_SIZE` (default 25) orders are queued
- Prints whatever is pending if `PICKLIST_MAX_WAIT_MINS` (default 15) have elapsed since last batch with no print

## SKU Grouping

Picklist rows show: SKU | Product Name | Bin Location | Total Qty | Order breakdown

## Shipping Label Auto-Print

When a picker scans the QR code on a completed picklist and the `scan-return` webhook fires, the skill calls BaseLinker's `printCourierLabel` for every order in that picklist.

## Dependencies

- marketplace-lib (baselinker.sh, config.sh, cache.sh, alerts.sh)
- Doppler shared-services: `BASELINKER_API_TOKEN`, `OBSIDIAN_API_KEY`, `OBSIDIAN_HOST`
- Doppler shared-services: `PICKLIST_READY_STATUS_IDS` (comma-separated BaseLinker status IDs for orders ready to pick)
- Optional: `PICKLIST_BATCH_SIZE` (default 25), `PICKLIST_MAX_WAIT_MINS` (default 15)
- Optional: `PICKLIST_PRINT_CMD` (default: saves HTML to spool dir and logs path)
- Optional: `PICKLIST_LABEL_PRINTER_ID` (BaseLinker printer ID for label auto-print)
- Optional: `WAREHOUSE_OPEN_HOUR` (default 8), `WAREHOUSE_CLOSE_HOUR` (default 18)
- System: `qrencode` for QR code generation (falls back to text if missing)
