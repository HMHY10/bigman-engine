#!/usr/bin/env python3
"""Execution Layer — act on approved opportunity recommendations.

For Qogita opportunities: add to cart → optimize → confirm (human approves checkout)
For other suppliers: generate draft purchase order in vault.

ALWAYS human-gated — no autonomous spending.

Usage:
    ./execute.py --approve <opportunity-id>                    # approve for execution
    ./execute.py --approve <opportunity-id> --confirm          # confirm Qogita checkout
    ./execute.py --list                                        # list pending approvals
    ./execute.py --approve <opportunity-id> --qty 50           # override quantity
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from config import QUEUE_PROCESSED, QUEUE_PENDING, QUEUE_PROCESSING, DATA_ROOT
from clients import qogita
from vault import log, vault_write
import config

APPROVALS_DIR = f"{DATA_ROOT}/approvals"



# ── Approved Products Tracking ────────────────────────
APPROVED_FILE = os.path.join(config.INTEL_ROOT, 'price-alerts', 'approved-products.json')


def load_approved_products():
    """Load list of previously approved products."""
    if os.path.exists(APPROVED_FILE):
        with open(APPROVED_FILE) as f:
            return json.load(f)
    return []


def record_approval(ean, product_name, qty, supplier):
    """Record a product approval for future auto-execution."""
    approved = load_approved_products()
    for entry in approved:
        if entry['ean'] == ean:
            entry['max_approved_quantity'] = max(entry.get('max_approved_quantity', 0), qty)
            entry['last_approved_date'] = datetime.now(timezone.utc).strftime('%Y-%m-%d')
            entry['approved_supplier'] = supplier
            with open(APPROVED_FILE, 'w') as f:
                json.dump(approved, f, indent=2)
            return
    approved.append({
        'ean': ean,
        'product_name': product_name,
        'max_approved_quantity': qty,
        'last_approved_date': datetime.now(timezone.utc).strftime('%Y-%m-%d'),
        'approved_supplier': supplier,
    })
    os.makedirs(os.path.dirname(APPROVED_FILE), exist_ok=True)
    with open(APPROVED_FILE, 'w') as f:
        json.dump(approved, f, indent=2)


def has_prior_approval(ean):
    """Check if a product has been previously approved."""
    approved = load_approved_products()
    return any(entry['ean'] == ean for entry in approved)


def find_recommendation(opportunity_id: str) -> dict | None:
    """Find a processed opportunity by ID."""
    for d in [QUEUE_PROCESSED, QUEUE_PENDING, QUEUE_PROCESSING]:
        if not os.path.isdir(d):
            continue
        for f in Path(d).glob("*.json"):
            with open(f) as fh:
                data = json.load(fh)
            if data.get("id") == opportunity_id:
                return data
    return None


def approve_qogita(opportunity: dict, qty_override: int = 0) -> dict:
    """Add Qogita products to cart. Returns cart summary."""
    results = []
    for product in opportunity.get("products", []):
        ean = product.get("ean", "")
        qty = qty_override or product.get("recommended_qty", product.get("moq", 1))
        if not ean:
            continue

        log(f"execute: adding {ean} x{qty} to Qogita cart")
        result = qogita.add_to_cart(ean, qty)
        if result:
            results.append({"ean": ean, "qty": qty, "status": "added", "detail": result})
        else:
            results.append({"ean": ean, "qty": qty, "status": "failed"})

    # Get cart summary
    cart = qogita.get_cart()
    return {"items_added": results, "cart": cart}


def confirm_qogita_checkout() -> dict | None:
    """Optimize cart and create checkout. Returns checkout details."""
    log("execute: optimizing Qogita cart...")
    checkout = qogita.optimize_cart()
    if checkout:
        log(f"execute: checkout created — review at qogita.com before confirming payment")
        return checkout
    else:
        log("execute: checkout optimization failed")
        return None


def generate_draft_po(opportunity: dict, qty_override: int = 0) -> str:
    """Generate a draft purchase order in vault."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    supplier = opportunity.get("supplier", "Unknown")
    opp_id = opportunity.get("id", "unknown")

    lines = []
    total = 0
    for p in opportunity.get("products", []):
        qty = qty_override or p.get("moq", 1)
        price = p.get("buy_price", 0)
        line_total = qty * price
        total += line_total
        lines.append(f"| {p.get('ean', '')} | {p.get('name', '')[:40]} | {qty} | £{price:.2f} | £{line_total:.2f} |")

    content = f"""---
source: opportunity-analyser
type: purchase-order-draft
date: {today}
supplier: {supplier}
opportunity_id: {opp_id}
status: draft
---

# Draft Purchase Order — {supplier}

**Date:** {today}
**Opportunity:** {opp_id}
**Status:** DRAFT — requires manual approval and sending to supplier

## Order Lines

| EAN | Product | Qty | Unit Price | Line Total |
|-----|---------|-----|------------|------------|
{chr(10).join(lines)}

**Total: £{total:.2f}** (ex-VAT)

## Next Steps
1. Review quantities and pricing
2. Send to supplier via email/portal
3. Update status to "sent" once ordered
4. Track delivery in finance-ops

---
*Draft generated by opportunity-analyser at {datetime.now(timezone.utc).isoformat()}*
"""
    vault_path = f"07-Marketplace/Buying/Orders/{today}-{opp_id}-draft-po.md"
    vault_write(vault_path, content)
    log(f"execute: draft PO written to vault — {vault_path}")
    return vault_path


def list_approvals():
    """List pending approvals."""
    os.makedirs(APPROVALS_DIR, exist_ok=True)
    files = list(Path(APPROVALS_DIR).glob("*.json"))
    if not files:
        print("No pending approvals.")
        return
    for f in files:
        with open(f) as fh:
            data = json.load(fh)
        print(f"  {data.get('id', f.stem)} — {data.get('supplier', '?')} — {len(data.get('products', []))} products")


def main():
    parser = argparse.ArgumentParser(description="Opportunity Execution Layer")
    parser.add_argument("--approve", help="Approve opportunity by ID")
    parser.add_argument("--confirm", action="store_true", help="Confirm Qogita checkout")
    parser.add_argument("--qty", type=int, default=0, help="Override quantity")
    parser.add_argument("--list", action="store_true", help="List pending approvals")
    args = parser.parse_args()

    if args.list:
        list_approvals()
    elif args.approve:
        opp = find_recommendation(args.approve)
        if not opp:
            print(f"Opportunity '{args.approve}' not found in processed queue.")
            sys.exit(1)

        source = opp.get("source", "")
        if source == "qogita":
            if args.confirm:
                result = confirm_qogita_checkout()
                if result:
                    print(f"\nCheckout created. Review and pay at qogita.com")
                    print(json.dumps(result, indent=2))
            else:
                result = approve_qogita(opp, qty_override=args.qty)
                print(f"\n{len(result['items_added'])} items added to Qogita cart.")
                print("Run with --confirm to optimize and create checkout.")
        else:
            path = generate_draft_po(opp, qty_override=args.qty)
            print(f"\nDraft PO generated: {path}")
            print("Review in Obsidian vault, then send to supplier manually.")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
