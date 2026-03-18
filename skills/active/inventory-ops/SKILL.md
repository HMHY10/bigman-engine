# inventory-ops

Inventory intelligence and stock management for ArryBarry marketplace operations.

## What This Skill Does

Provides inventory insights that BaseLinker's native automations cannot:
- **Booking-in reconciliation** — matches purchase orders against goods-in documents; flags short deliveries, late deliveries, and unmatched receipts
- **Cross-channel pricing report** — snapshots product stock levels and pricing across all inventories and external storages
- **Listing health** — compares active BaseLinker products against external storage listings; flags products missing from any storefront

## How It Runs

- **Cron:** Twice daily (`0 7,19 * * *`)
- **Two phases:** Fetch (pull inventories, stock, prices, POs, goods-in docs) -> Analyse (rule-based checks + vault reports)
- **Output:** Vault notes in `07-Marketplace/Inventory/` + alerts for issues

## Overlap with finance-ops

Booking-in reconciliation is also analysed by finance-ops from a financial perspective (payment implications). This skill focuses on the stock accuracy and availability angle — different audience, complementary analysis.

## Dependencies

- marketplace-lib (baselinker.sh, cache.sh, alerts.sh, config.sh)
- obsidian-sync (vault write)
- Doppler shared-services (BASELINKER_API_TOKEN, OBSIDIAN_API_KEY, OBSIDIAN_HOST)
