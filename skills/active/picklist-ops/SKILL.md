---
name: picklist-ops
description: Warehouse picklist automation for ArryBarry. Auto-generates SKU-grouped pick lists when 25 ready orders accumulate (or after 60 minutes), runs a morning batch for all overnight orders, and handles QR-code-triggered shipping label printing at the pack station. Use when asked about picklists, picking, packing, shipping labels, or warehouse operations.
---

# Picklist Ops

Automates the full pick-pack-dispatch cycle for ArryBarry warehouse operations via BaseLinker.

## What This Skill Does

### Auto-batch (every 5 minutes)
`picklist-check.sh` runs on cron and:
- Fetches all orders with `PICKLIST_READY_STATUS_ID` status
- **Fires immediately** when 25+ unprinted orders are waiting
- **Starts a 60-minute countdown** when orders first arrive (under 25)
- **Prints whatever is available** if 60 minutes elapse without reaching 25
- Tracks which orders have been on a picklist (avoids double-printing)

### Morning batch (07:00 daily)
`picklist-morning.sh` runs at 07:00 and:
- Fetches **all** overnight ready orders (14-hour window, since ~5pm previous day)
- Generates a single large picklist with **no order cap**
- Resets the auto-batch window

### SKU-grouped picklist HTML
Each picklist is a two-section A4-printable HTML document:

**Section 1 — Picking Guide**: Products grouped by SKU so the picker walks the warehouse once per SKU and collects all quantities across all orders simultaneously.

**Section 2 — Dispatch Cards**: One card per order with full details and a **QR code** that, when scanned at the pack station, fires the label print trigger for that order.

### QR code label printing
`label-trigger.sh` is fired by scanning the QR code on a dispatch card:
- Checks for an existing shipping package in BaseLinker
- Creates one via `PICKLIST_DEFAULT_COURIER` if none exists
- Fetches the label PDF from BaseLinker
- Prints to `PICKLIST_LABEL_PRINTER` (CUPS) if configured
- Advances the order to `PICKLIST_DISPATCHED_STATUS_ID`

### Manual buttons
Two scripts for on-demand picklist generation:

| Button | Script | What it does |
|--------|--------|--------------|
| **Print next 25** | `picklist-next.sh` | Next 25 unprinted ready orders |
| **Print selected orders** | `picklist-selected.sh ID1 ID2 ...` | Specific order IDs |

---

## Required Secrets (Doppler: shared-services/prd)

| Secret | Description |
|--------|-------------|
| `PICKLIST_READY_STATUS_ID` | BaseLinker status ID for "Ready to Pick" orders |
| `PICKLIST_PICKING_STATUS_ID` | *(optional)* Status to set when picklist is generated |
| `PICKLIST_DISPATCHED_STATUS_ID` | *(optional)* Status to set after label is scanned |
| `PICKLIST_DEFAULT_COURIER` | *(optional)* BaseLinker courier code for auto-creating packages |
| `PICKLIST_PRINTER` | *(optional)* CUPS printer name for picklist pages |
| `PICKLIST_LABEL_PRINTER` | *(optional)* CUPS printer name for shipping labels |
| `BIGMAN_HOST` | Full URL of the bigman-engine instance (e.g. `https://bot.arrybarry.co.uk`) |

To find your BaseLinker status IDs: **BaseLinker → Orders → Status management** — hover each status to see its ID.

---

## Tunable Constants (Doppler or env)

| Variable | Default | Description |
|----------|---------|-------------|
| `PICKLIST_BATCH_SIZE` | `25` | Orders per auto-batch |
| `PICKLIST_BATCH_WINDOW_MINUTES` | `60` | Minutes before time-limit fallback fires |
| `PICKLIST_SINCE_HOURS` | `72` | Look-back window for ready orders |
| `PICKLIST_MORNING_SINCE_HOURS` | `14` | Overnight window for morning batch |

---

## Cron Schedule

```
*/5 * * * *   picklist-check.sh    — auto-batch threshold + time-limit check
0 7   * * *   picklist-morning.sh  — morning all-orders batch
```

---

## Webhook Triggers

| Action | URL path | Calls |
|--------|----------|-------|
| QR scan → print label | `/webhook?action=print-label&order_id=ID` | `label-trigger.sh` |
| Print next 25 button | `/webhook?action=picklist-next` | `picklist-next.sh` |
| Print selected button | `/webhook?action=picklist-selected&orders=ID1,ID2,...` | `picklist-selected.sh` |

---

## Output

- **HTML file**: `/opt/bigman-engine/picklists/YYYYMMDD-HHMMSS.html`
- **Vault metadata**: `07-Marketplace/Warehouse/Picklists/YYYYMMDD-HHMMSS.md`
- **Vault HTML**: `07-Marketplace/Warehouse/Picklists/YYYYMMDD-HHMMSS.html`
- **Printed orders state**: `/opt/bigman-engine/state/picklist-ops/printed-orders.json`

---

## Manual Run

```bash
cd /opt/bigman-engine

# Morning batch (all ready orders)
doppler run -p shared-services -c prd -- ./skills/active/picklist-ops/picklist-morning.sh

# Next 25 orders
doppler run -p shared-services -c prd -- ./skills/active/picklist-ops/picklist-next.sh

# Specific orders
doppler run -p shared-services -c prd -- ./skills/active/picklist-ops/picklist-selected.sh 12345 67890

# Trigger label print for one order
doppler run -p shared-services -c prd -- ./skills/active/picklist-ops/label-trigger.sh 12345
```

---

## Dependencies

- `marketplace-lib` (config.sh, cache.sh, baselinker.sh, alerts.sh)
- `obsidian-sync` (vault write)
- Doppler `shared-services/prd`
- `jq`, `curl`, `python3` (for URL encoding)
- `lp` / CUPS (optional, for physical printing)
- `wkhtmltopdf` (optional, for HTML→PDF conversion before printing)
