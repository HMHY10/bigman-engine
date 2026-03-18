---
name: compliance-ops
description: Monitor account health and compliance across marketplaces. Tracks defect rates, cancellation rates, return rates, and policy violations. Runs twice daily via cron. Use when asked about marketplace compliance, account health, or defect rates.
---

# Compliance Ops

Monitors account health and compliance across all connected marketplaces (Amazon, eBay, TikTok Shop, etc.) via BaseLinker. Calculates defect rates per marketplace, tracks return rates, and generates alerts when thresholds are breached.

## How It Works

Two-phase pipeline that fetches recent order and return data from BaseLinker, analyses compliance metrics per marketplace, and writes alerts to the Obsidian vault.

1. **Fetch** — Pull journal entries, orders, returns, and order sources from BaseLinker (48-hour window)
2. **Analyse** — Calculate defect rates per marketplace, return rates, and generate alerts for threshold breaches

### Automatic (Twice-Daily Cron)
Runs at 08:00 and 20:00 UTC daily. On Sundays, the evening run also generates a weekly health snapshot.

### Manual Trigger

```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- ./skills/active/compliance-ops/run.sh
```

## Metrics Tracked

### Defect Rate (per marketplace)
- Orders with `status_id < 0` are counted as defects (cancellations/failures)
- **Warning threshold:** `COMPLIANCE_WARN_PERCENT` (80% of 2.5% = 2.0% defect rate)
- **Critical threshold:** `COMPLIANCE_CRITICAL_PERCENT` (90% of 2.5% = 2.25% defect rate)

### Return Rate (overall)
- Returns as a percentage of total orders
- Flagged if exceeding 10%

### Weekly Health Snapshot (Sundays only)
- Comprehensive report covering all marketplaces
- Written to `07-Marketplace/Compliance/Health/YYYY-MM-DD-weekly-health.md`

## Vault Output

- **Defect alerts:** `07-Marketplace/Compliance/Alerts/` — individual alert notes per threshold breach
- **Weekly health:** `07-Marketplace/Compliance/Health/YYYY-MM-DD-weekly-health.md` — Sunday snapshots

## Dependencies

### Shared Libraries (marketplace-lib)
- `config.sh` — constants, thresholds, logging
- `cache.sh` — local cache read/write
- `baselinker.sh` — BaseLinker API client with pagination and rate limiting
- `alerts.sh` — vault alert creation with severity routing

### Secrets (Doppler shared-services)
BASELINKER_API_TOKEN, OBSIDIAN_HOST, OBSIDIAN_API_KEY

### Cron Entry
```cron
0 8,20 * * * doppler run -p shared-services -c prd -- /opt/bigman-engine/skills/active/compliance-ops/run.sh >> /var/log/bigman/compliance-ops.log 2>&1
```

## Important Rules

- All alerts use the shared `alert_create` function for consistent formatting and email routing
- Defect thresholds are percentages of the marketplace's maximum allowed defect rate (2.5%)
- Weekly health reports include YAML frontmatter for vault indexing
- Cache is used for order data to avoid redundant API calls across skills
- Float arithmetic uses `bc -l` (not bash integer math)
