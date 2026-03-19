#!/usr/bin/env python3
"""Email Offers Adapter — extract products from supplier offer emails.

Called by email-triage when it detects a 'supplier-offer' email.
Reads the raw email from vault, uses Claude to extract product data,
normalises to standard queue format.

Usage (called by triage.sh):
    ./email_offers.py --vault-path "10-Email-Raw/2026-03-19-suppliers-price-list.md"
    ./email_offers.py --body "EAN 4006000111827 Nivea Soft £3.50 MOQ 10"
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from config import QUEUE_PENDING
from vault import log, vault_read

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")

EXTRACT_PROMPT = """You are a product data extraction agent for ArryBarry Health & Beauty.

Extract ALL products from this supplier email/price list. For each product, extract:
- ean: EAN/GTIN barcode (13 digits). If not present, leave empty string.
- name: Product name/description
- brand: Brand name
- buy_price: Price per unit (numeric only, no currency symbols)
- currency: GBP or EUR (detect from context/symbols)
- moq: Minimum order quantity (default 1 if not stated)

Respond with JSON array only, no markdown:
[{"ean": "4006000111827", "name": "Nivea Soft 500ml", "brand": "Nivea", "buy_price": 3.50, "currency": "GBP", "moq": 10}]

If no products can be extracted, return: []

Email content:
"""


def extract_products(text: str) -> list[dict]:
    """Use Claude to extract products from email text."""
    if not ANTHROPIC_API_KEY:
        log("email_offers: ANTHROPIC_API_KEY not set")
        return []

    import anthropic
    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    try:
        response = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=4000,
            temperature=0,
            messages=[{"role": "user", "content": EXTRACT_PROMPT + text[:4000]}],
        )
        raw = response.content[0].text.strip()
        # Strip markdown fences if present (handles ```json etc.)
        raw = re.sub(r"^```[a-z]*\n?", "", raw, flags=re.MULTILINE)
        raw = re.sub(r"\n?```$", "", raw)
        products = json.loads(raw)
        if isinstance(products, list):
            log(f"email_offers: extracted {len(products)} products via Claude")
            return products
    except Exception as e:
        log(f"email_offers: extraction failed: {e}")
    return []


def process_email(vault_path: str = "", body: str = "", supplier: str = "Email Supplier",
                  dry_run: bool = False) -> int:
    """Process a supplier offer email. Returns count of products queued."""
    if vault_path:
        content = vault_read(vault_path)
        if not content:
            log(f"email_offers: cannot read vault path: {vault_path}")
            return 0
        # Extract supplier from frontmatter or filename
        if "from:" in content.lower():
            for line in content.split("\n"):
                if line.lower().startswith("from:"):
                    supplier = line.split(":", 1)[1].strip()
                    break
        body = content
    elif not body:
        log("email_offers: no input provided")
        return 0

    products = extract_products(body)
    if not products:
        return 0

    # Normalise
    normalised = []
    for p in products:
        if not p.get("ean") and not p.get("name"):
            continue
        normalised.append({
            "ean": str(p.get("ean", "")).strip(),
            "name": p.get("name", ""),
            "brand": p.get("brand", ""),
            "buy_price": float(p.get("buy_price", 0)),
            "currency": p.get("currency", "GBP"),
            "moq": int(p.get("moq", 1)),
            "volume_prices": [],
            "delivery_days": 0,
            "source_ref": f"email:{vault_path or 'direct'}",
        })

    if not normalised:
        return 0

    if dry_run:
        for p in normalised:
            log(f"  dry-run: {p['ean']} {p['name'][:40]} @ £{p['buy_price']:.2f}")
        return len(normalised)

    now = datetime.now(timezone.utc)
    opp_id = f"email-{now.strftime('%Y%m%d%H%M%S')}"
    opp = {
        "id": opp_id,
        "source": "email",
        "supplier": supplier,
        "received_at": now.isoformat(),
        "products": normalised,
    }
    os.makedirs(QUEUE_PENDING, exist_ok=True)
    with open(os.path.join(QUEUE_PENDING, f"{opp_id}.json"), "w") as f:
        json.dump(opp, f, indent=2)
    log(f"email_offers: queued {len(normalised)} products from {supplier}")
    return len(normalised)


def main():
    parser = argparse.ArgumentParser(description="Email Offers Adapter")
    parser.add_argument("--vault-path", help="Vault path to raw email")
    parser.add_argument("--body", help="Email body text directly")
    parser.add_argument("--supplier", default="Email Supplier")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    process_email(vault_path=args.vault_path, body=args.body,
                  supplier=args.supplier, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
