# finance-ops

Financial intelligence and reconciliation for ArryBarry marketplace operations.

## What This Skill Does

Monitors financial health across all marketplaces connected via BaseLinker:
- Refund reconciliation (returns vs refund payments)
- Reimbursement detection (returned but not restocked)
- PO-to-delivery matching (purchase orders vs goods-in documents)
- Courier fulfilment claims (lost/damaged parcels)
- Claim lifecycle tracking with stale escalation
- Daily P&L snapshots per marketplace

## How It Runs

- **Cron:** Every 2 hours (`0 */2 * * *`)
- **Two phases:** Fetch (pull last 48h from BaseLinker) -> Analyse (rule-based checks)
- **Output:** Vault notes in `07-Marketplace/Finance/` + email alerts for high/critical

## Thresholds

- Discrepancy flagged at >£25 (high), >£100 (critical)
- Stale claims escalated after 7 days without status change
- Courier claims flagged if not filed within 14 days

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- obsidian-sync (vault write)
- Doppler shared-services (BASELINKER_API_TOKEN, OBSIDIAN_API_KEY, OBSIDIAN_HOST)
