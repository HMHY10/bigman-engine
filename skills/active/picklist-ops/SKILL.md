# picklist-ops

Warehouse picklist automation for ArryBarry fulfilment operations.

## What This Skill Does

Automates pick-list generation and shipping-label printing across the full warehouse pick–pack–ship cycle:

- **Overnight batch** — at warehouse open time, pulls all orders accumulated overnight, groups items by SKU (no per-batch cap when same-SKU volume is high), and auto-prints a single consolidated picklist
- **Daytime batching** — runs every 5 minutes during warehouse hours; batches ~25 orders at a time, with a configurable time-limit fallback so no orders wait more than N minutes
- **Manual triggers** — `print-next-25` and `print-selected <ids…>` subcommands let the warehouse team request ad-hoc picklists
- **Picklist format** — SKU-grouped (no images), QR code per batch for scan-on-return, bin/location references from BaseLinker inventory
- **Scan-on-return** — `scan-return <picklist_id>` retrieves BaseLinker shipping labels for every order in the batch and auto-prints them to the label printer

## How It Runs

| Mode | Schedule | Description |
|------|----------|-------------|
| overnight | `30 7 * * 1-6` | All orders since last warehouse close, no batch cap |
| daytime | `*/5 8-18 * * 1-6` | Rolling ~25-order batches with time fallback |
| manual | on-demand | Agent invocation for ad-hoc picklists |
| scan-return | on-demand | Called when picker scans QR on return |

## State Files

All state lives in `/opt/bigman-engine/state/picklist-ops/`:

| File | Purpose |
|------|---------|
| `queued-orders.json` | Orders fetched but not yet assigned to a batch |
| `batches/<id>.json` | Batch manifest (order IDs, SKU groups, status) |
| `batch-counter.txt` | Daily sequence counter for picklist IDs (`PL-YYYYMMDD-NNN`) |
| `last-fetch.txt` | Epoch of last order fetch (prevents re-queuing orders) |

Generated picklist HTML files are written to `/opt/bigman-engine/picklists/`.

## Configuration (Doppler: shared-services)

| Variable | Default | Description |
|----------|---------|-------------|
| `PICKLIST_ORDER_STATUS_ID` | — | BaseLinker status ID for orders ready to pick |
| `PICKLIST_MARKED_STATUS_ID` | — | Status to set when order is added to a picklist |
| `PICKLIST_PICKED_STATUS_ID` | — | Status to set when order is confirmed picked |
| `PICKLIST_PRINTER` | `picklist` | CUPS printer name for picklist documents |
| `SHIPPING_LABEL_PRINTER` | `label` | CUPS printer name for shipping labels |
| `WAREHOUSE_OPEN_HOUR` | `8` | Hour (24h) warehouse opens — daytime cron window start |
| `PICKLIST_BATCH_SIZE` | `25` | Target orders per daytime batch |
| `PICKLIST_BATCH_TIMEOUT_MINS` | `30` | Force-print a partial batch after this many minutes |
| `PICKLIST_LOCATION_FIELD` | `location` | BaseLinker extra field name holding bin/shelf location |
| `PICKLIST_OUTPUT_DIR` | `/opt/bigman-engine/picklists` | Where generated HTML files are saved |

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- qrencode (CLI QR code generator — `apt-get install qrencode`)
- wkhtmltopdf (HTML→PDF — `apt-get install wkhtmltopdf`)
- CUPS / lp (printing)
- Doppler shared-services (BASELINKER_API_TOKEN, OBSIDIAN_API_KEY, OBSIDIAN_HOST)

## Picklist ID Format

`PL-YYYYMMDD-NNN` — e.g. `PL-20260705-001`. The QR code on each printed picklist encodes this ID. Scanning it triggers `run.sh scan-return PL-20260705-001` to auto-print labels.

## Manual Invocation

```bash
# Print next 25 queued orders
doppler run -p shared-services -c prd -- ./run.sh print-next-25

# Print specific orders
doppler run -p shared-services -c prd -- ./run.sh print-selected 100001 100002 100003

# Handle scan-on-return
doppler run -p shared-services -c prd -- ./run.sh scan-return PL-20260705-001

# Run overnight batch
doppler run -p shared-services -c prd -- ./run.sh overnight

# Run daytime batch check
doppler run -p shared-services -c prd -- ./run.sh daytime
```
