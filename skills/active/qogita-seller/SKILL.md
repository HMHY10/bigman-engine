# qogita-seller

Manages ArryBarry's sell-side presence on Qogita wholesale marketplace: order tracking, SLA enforcement, stock feed generation, and performance reporting.

## What This Skill Does

- **Order tracking:** Fetches seller orders, caches state, detects status changes
- **SLA enforcement:** Alerts when pending orders approach fulfilment deadlines (24h high, 36h critical)
- **Stock feed generation:** Pulls BaseLinker inventory, produces CSV stock feed (EAN, SKU, quantity, price)
- **Performance reporting:** Daily vault summaries with order counts, fulfilment rates, revenue

## How It Runs

Dual cron schedule:

- **Orders mode** (default): Every 2 hours (`0 */2 * * *`)
  - Authenticates as Qogita seller
  - Fetches and caches seller orders
  - Checks SLA deadlines on pending orders
  - Writes daily performance summary to vault

- **Stock feed mode** (`--stock-feed`): Daily at 5am (`0 5 * * *`)
  - Pulls product stock and pricing from BaseLinker inventory
  - Generates CSV feed: `ean,sku,quantity,price`
  - Outputs to `/opt/bigman-engine/outputs/qogita-stock-feed.csv`

## Qogita Seller Context

- Account: info@arrybarry.com
- Status: ACTIVE, selling in GB only
- Submitted price is not the final buyer price (Qogita adds undisclosed margin)
- Auth returns `accessToken` field (not `access`), no refresh token needed

## Vault Output

- Performance: `07-Marketplace/Qogita/Seller/YYYY-MM-DD-performance.md`
- SLA alerts: `07-Marketplace/Qogita/Seller/Alerts/` (via alerts.sh)

## Dependencies

- marketplace-lib (config.sh, cache.sh, alerts.sh, qogita-auth.sh, baselinker.sh)
- obsidian-sync (vault write)
- Doppler shared-services (QOGITA_SELLER_EMAIL, QOGITA_SELLER_PASSWORD, BASELINKER_API_TOKEN, OBSIDIAN_API_KEY, OBSIDIAN_HOST)
