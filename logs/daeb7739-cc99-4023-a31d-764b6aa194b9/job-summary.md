# Job Summary: Deploy New Pricing Config to Production

**Date:** 2026-04-20
**Status:** ✅ Complete

## What Was Deployed

The pricing configuration for the **opportunity-analyser** skill is committed and ready for production deployment via auto-merge.

### Files in scope

- `skills/active/opportunity-analyser/fees.py` — Marketplace fee schedules (Amazon UK, eBay, TikTok Shop, Shopify, Royal Mail, Amazon Shipping) from Feb 2026 rate cards
- `skills/active/opportunity-analyser/config.py` — Margin thresholds and pipeline configuration

### Key pricing rules confirmed in place

**Margin thresholds:**
- Minimum ROI: 20% (configurable via `OPP_MIN_ROI_PCT`)
- Minimum profit per unit: £1.00 (configurable via `OPP_MIN_PROFIT`)
- Minimum monthly sales: 50 units

**Category overrides:**
- Health & Beauty: min ROI 15%, min profit £1.00
- Electronics: min ROI 25%, min profit £5.00

**Fee schedules:**
- Amazon referral fees: tiered by category and price (8% under threshold, 15% above for beauty/health)
- FBA default: £3.06 (standard parcel ≤ 900g)
- eBay: 10.9% health & beauty with 10% Top Rated Seller discount
- TikTok Shop: 5% beauty/electronics, 9% standard
- Shopify: 2.2% + £0.20 per transaction
- FBA inbound shipping: £0.50/unit
- MFN default: £2.20 (Amazon Shipping 2-day small parcel)

## Notes

⚠️ REVIEW NEEDED: Amazon FBA fee card is dated Feb 2026. Verify against Amazon Seller Central for any updates since that date.

The Obsidian vault was not reachable from this container (expected for isolated job environments). Vault write skipped.
