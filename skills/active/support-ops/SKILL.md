# support-ops

Marketplace support operations skill for ArryBarry Health & Beauty.

## Purpose
Track returns, disputes, and support cases across all marketplace channels via BaseLinker. Detect stale returns, repeat offenders, and problematic products before they escalate.

## Schedule
Every 4 hours via cron.

## What It Does

### Phase 1 — Fetch
- Pull returns from BaseLinker (72h window — wider than other skills since returns move slower)
- Pull orders from BaseLinker (72h window — for context and pattern matching)

### Phase 2 — Analyse

**2a: Stale Return Detection**
- For each open return (not completed/resolved/closed), check its age
- Flag returns older than SUPPORT_STALE_DAYS (5 days) without resolution
- Alert includes BaseLinker return_id and order_id for cross-referencing

**2b: Repeat Customer Detection**
- Group returns by customer email
- Flag customers with 3+ returns in the 72h window

**2c: Product Return Rate Analysis**
- Group returns by product
- For products with 3+ returns, calculate return rate against order volume
- Flag products with >10% return rate

## Cross-Skill Boundary
- **support-ops** tracks case lifecycle: is the return progressing?
- **finance-ops** tracks money: refunds and reimbursements
- Both write alerts independently — duplicates across skills are expected and acceptable for different audiences
- Every alert includes BaseLinker order_id and/or return_id for cross-referencing

## Alerts
Written to Obsidian vault under `07-Marketplace/Support/Alerts/`.
Severity routing: high and critical alerts are also copied to `09-Email/Flagged/`.

## Dependencies
- Shared library: marketplace-lib (config.sh, cache.sh, baselinker.sh, alerts.sh)
- Secrets: Doppler `shared-services/prd` (BASELINKER_API_TOKEN, OBSIDIAN_HOST, OBSIDIAN_API_KEY)
- Tools: jq, bc, curl
