---
name: picklist-ops
description: Warehouse picklist automation — generates pick batches from BaseLinker orders, groups by SKU with bin locations and QR codes, and auto-prints shipping labels on scan return
---

# picklist-ops

Automated picklist generation for the ArryBarry warehouse. Batches pending orders from
BaseLinker into printer-ready HTML picklists grouped by SKU, with bin/location references
and a QR code that triggers shipping label printing when scanned on return.

## How It Runs

### Overnight batch (cron: `0 6 * * 1-6`)
Runs at 06:00 Mon–Sat before the warehouse opens. Fetches all orders placed since warehouse
close the previous day and generates one or more picklists — no hard order cap; same-SKU
orders are kept together regardless of volume.

### Daytime batch (cron: `*/5 8-18 * * 1-6`)
Runs every 5 minutes during warehouse hours. Accumulates new orders and fires when either:
- **~25 orders** are waiting (configurable via `PICKLIST_BATCH_SIZE`), or
- **15 minutes** have elapsed since the first new order arrived (configurable via
  `PICKLIST_BATCH_MAX_WAIT`)

### Manual print (via agent job or API)
- **Print next N orders:** `manual-print.sh [--count N]`
- **Print specific orders:** `manual-print.sh --orders 12345,12346,12347`

### Scan return (webhook trigger)
When a picker scans the QR code on a completed picklist, a POST fires to `/webhook/picklist-scan`.
The trigger calls `scan-return.sh` which:
1. Loads the picklist state to retrieve order IDs
2. Fetches/generates shipping labels from BaseLinker for each order
3. Sends labels to the label printer (via CUPS if `LABEL_PRINTER_NAME` is set)
4. Marks orders as shipped in BaseLinker

## Configuration

All settings are read from environment (injected by Doppler `shared-services`):

| Variable | Default | Description |
|---|---|---|
| `BASELINKER_API_TOKEN` | required | BaseLinker API token |
| `BL_STATUS_NEW` | _(empty)_ | Status ID for "ready to pick" orders; leave empty to fetch all unconfirmed |
| `BL_STATUS_PICKING` | _(empty)_ | Status ID to set when order is assigned to a picklist |
| `BL_STATUS_PICKED` | _(empty)_ | Status ID to set when picklist is returned |
| `BL_BIN_FIELD` | `extra_field_1` | Product field used as bin/location reference |
| `PICKLIST_BATCH_SIZE` | `25` | Target daytime batch size |
| `PICKLIST_BATCH_MAX_WAIT` | `15` | Minutes before a partial batch is forced |
| `PICKLIST_OUTPUT_DIR` | `/opt/bigman-engine/picklists` | Directory for HTML picklist files |
| `PRINTER_NAME` | _(empty)_ | CUPS printer name for picklist sheets (A4) |
| `LABEL_PRINTER_NAME` | _(empty)_ | CUPS printer name for shipping labels |
| `PICKLIST_WEBHOOK_URL` | _(empty)_ | Base URL of thepopebot instance (for QR codes) |
| `OBSIDIAN_HOST` | required | Vault REST API URL |
| `OBSIDIAN_API_KEY` | required | Vault bearer token |

## State

State is written to `${STATE_BASE}/picklist-ops/`:

```
picklist-ops/
├── daytime-timer.json          # Daytime batch timer (start time + waiting order IDs)
└── picklists/
    └── PL-20260704-060012.json # Per-picklist state (order IDs, SKU groups, status)
```

## Dependencies

- marketplace-lib (`baselinker.sh`, `cache.sh`, `alerts.sh`, `config.sh`)
- obsidian-sync (vault write)
- Doppler `shared-services` (see configuration table above)
- `jq` (JSON processing)
- `curl` (API calls + QR code images)
- `lpr` / CUPS (optional, for direct printer output)
