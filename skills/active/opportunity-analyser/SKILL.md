---
name: opportunity-analyser
description: Analyse wholesale product opportunities against Amazon marketplace data. Checks compliance, calculates margins, estimates volumes, scores Buy/Review/Skip. Use when evaluating products to purchase for resale.
---

# Opportunity Analyser

Source-agnostic product opportunity analysis pipeline. Takes products from any source (Qogita, supplier emails, pricing files) and analyses them against Amazon for compliance, margins, demand, and purchase recommendations.

## Usage

### Manual single-product analysis
```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- \
  venvs/opportunity-analyser/bin/python3 \
  skills/active/opportunity-analyser/analyse.py \
  --ean 4006000111827 --price 3.50 --supplier "Qogita" --brand "Nivea" --name "Nivea Soft 500ml"
```

### Process pending queue
```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- \
  venvs/opportunity-analyser/bin/python3 \
  skills/active/opportunity-analyser/analyse.py --queue
```

### Dry run (no vault writes, no file moves)
```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- \
  venvs/opportunity-analyser/bin/python3 \
  skills/active/opportunity-analyser/analyse.py --queue --dry-run
```

## Cron
```cron
0 */2 * * * cd /opt/bigman-engine && doppler run -p shared-services -c prd -- venvs/opportunity-analyser/bin/python3 skills/active/opportunity-analyser/analyse.py --queue >> /var/log/opportunity-analyser.log 2>&1
```

## Output
- Recommendations: `07-Marketplace/Buying/Recommendations/`
- Daily summary: `07-Marketplace/Buying/Reports/`
- Raw predictors: `/opt/bigman-engine/data/product-intel/predictors/`

## Secrets (Doppler shared-services)
- `SP_API_REFRESH_TOKEN`, `SP_API_CLIENT_ID`, `SP_API_CLIENT_SECRET`, `SP_API_SELLER_ID`, `SP_API_AWS_ACCESS_KEY`, `SP_API_AWS_SECRET_KEY`
- `QOGITA_BUYER_EMAIL`, `QOGITA_BUYER_PASSWORD`
- `RAINFOREST_API_KEY`
- `ANTHROPIC_API_KEY` (existing)

## Source Adapters

### Qogita Scan — daily wholesale catalog scan
```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- \
  venvs/opportunity-analyser/bin/python3 \
  skills/active/opportunity-analyser/adapters/qogita_scan.py --dry-run
```
Cron: `0 6 * * *` — scans all Qogita offers, converts EUR→GBP, dedup, writes to pending queue.

### File Ingest — CSV/Excel/PDF price lists
```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- \
  venvs/opportunity-analyser/bin/python3 \
  skills/active/opportunity-analyser/adapters/file_ingest.py --dry-run
```
Cron: `*/30 * * * *` — watches `data/opportunities/inbox/` for .csv/.xlsx/.pdf files.
Single file: `--file /path/to/pricelist.csv`

### Email Offers — supplier email extraction
Triggered automatically by email-triage when a `suppliers` email contains pricing keywords.
Manual: `--vault-path "10-Email-Raw/2026-03-19-suppliers-price-list.md"`

## Execution Layer

### Approve opportunity for purchase
```bash
cd /opt/bigman-engine && doppler run -p shared-services -c prd -- \
  venvs/opportunity-analyser/bin/python3 \
  skills/active/opportunity-analyser/execute.py --approve <opportunity-id>
```
- Qogita source: adds to cart. Run with `--confirm` to create checkout.
- Other sources: generates draft PO in vault (`07-Marketplace/Buying/Orders/`).
- `--qty 50` to override quantity. `--list` to see pending approvals.

## 6-Stage Pipeline
1. **Amazon Match** — EAN→ASIN, fuzzy fallback, brand mismatch filtering
2. **Compliance** — SP-API restrictions, hazmat, IP, regulatory flags
3. **Market Analysis** — BSR, sellers, sales estimates, pricing (SP-API + Rainforest backup)
4. **Margin Calc** — Amazon fees, ROI, profit per unit
5. **Volume Estimate** — purchase quantity (sales velocity → BSR estimate → MOQ fallback)
6. **Scoring** — configurable thresholds → Buy/Review/Skip
