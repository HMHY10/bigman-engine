---
name: picklist-ops
description: Warehouse picklist automation for ArryBarry. Auto-batches ready orders from BaseLinker — prints when 25 orders accumulate, or after a 1-hour timeout, or all overnight orders on first morning run. Picklists are SKU-grouped so the same product appears together across orders. Each order line carries a QR code that, when scanned at the pack station, fires the shipping label printer via the API. Manual triggers available via API endpoints (Print next 25, Print selected orders).
---

# picklist-ops

Warehouse pick-and-pack automation skill for ArryBarry Health & Beauty.

## What It Does

1. **Auto-batch (25 orders)** — polls BaseLinker every 5 minutes for orders in the "ready to pick" status. When 25 ready orders accumulate, a picklist is generated and printed immediately.

2. **Time-limit fallback** — if 25 orders have not accumulated within 60 minutes of the first queued order, whatever is available is printed. Prevents indefinite waiting on slow days.

3. **Morning batch** — on the first run after midnight, all overnight orders are printed in a single batch with no 25-order cap. Ensures the team starts each day with a complete list.

4. **SKU-grouped layout** — the picklist groups identical products together across all orders. Instead of picking order-by-order, the picker collects all units of SKU-X in one trip, then all of SKU-Y, etc.

5. **QR code per order line** — each order row on the picklist has a QR code. Scanning it at the pack station fires `GET /api/picklist/print-label?order_id=X` which triggers BaseLinker shipping label generation and sends it to the label printer.

6. **Manual triggers** (API):
   - `POST /api/picklist/print-next-25` — print the next batch of up to 25 ready orders
   - `POST /api/picklist/print-selected` — print a specific list of order IDs

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `BASELINKER_API_TOKEN` | Yes | BaseLinker API token (from Doppler shared-services) |
| `BL_PICK_STATUS_ID` | Yes | BaseLinker status_id representing "ready to pick" |
| `PICKLIST_PRINTER` | Yes | CUPS printer name for the picklist printer |
| `LABEL_PRINTER` | No | CUPS printer name for pack-station label printer (defaults to `PICKLIST_PRINTER`) |
| `THEPOPEBOT_URL` | Yes | Public base URL of thepopebot server (e.g. `https://ops.arrybarry.com`) |
| `THEPOPEBOT_API_KEY` | Yes | API key for authenticating picklist API calls |
| `PICKLIST_BATCH_SIZE` | No | Orders per auto-batch (default: 25) |
| `PICKLIST_TIMEOUT_MINS` | No | Minutes before time-limit fallback fires (default: 60) |
| `OBSIDIAN_API_KEY` | No | For vault logging (optional) |
| `OBSIDIAN_HOST` | No | Vault URL (optional) |

## Cron

Runs via `picklist-poll` cron every 5 minutes (`*/5 * * * *`).

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, config.sh)
- qrencode (apt: qrencode) — for QR code generation
- wkhtmltopdf or chromium-browser — for HTML-to-print conversion
- CUPS — for network printing
