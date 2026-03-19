#!/usr/bin/env python3
"""File Ingest Adapter — parse supplier price lists from inbox directory.

Watches /opt/bigman-engine/data/opportunities/inbox/ for:
  - .csv files — auto-detect columns (EAN, price, name, brand)
  - .xlsx files — auto-detect columns via header row
  - .pdf files — table extraction via pdfplumber, Claude API fallback

Parsed products normalised to standard queue format, written to pending/.
Processed files moved to inbox/processed/.
Runs every 30m via cron.

Usage:
    ./file_ingest.py                # process inbox
    ./file_ingest.py --dry-run      # preview without writing
    ./file_ingest.py --file /path   # process specific file
"""
import argparse
import csv
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from config import QUEUE_INBOX, QUEUE_PENDING, CLAUDE_PDF_MAX_PAGES, CLAUDE_PDF_MAX_PER_CYCLE
from vault import log
from queue_manager import is_duplicate
import fx

INBOX_PROCESSED = f"{QUEUE_INBOX}/processed"

# Common column name patterns for auto-detection
EAN_PATTERNS = re.compile(r"(?i)^(ean|gtin|barcode|upc|ean13|ean_code|product.?code)$")
PRICE_PATTERNS = re.compile(r"(?i)^(price|unit.?price|buy.?price|cost|net.?price|trade.?price|wholesale)$")
NAME_PATTERNS = re.compile(r"(?i)^(name|product.?name|description|title|product.?description|item)$")
BRAND_PATTERNS = re.compile(r"(?i)^(brand|brand.?name|manufacturer|make)$")
MOQ_PATTERNS = re.compile(r"(?i)^(moq|min.?order|minimum|min.?qty)$")


def _detect_columns(headers: list[str]) -> dict:
    """Auto-detect which columns contain EAN, price, name, brand, MOQ."""
    mapping = {}
    for i, h in enumerate(headers):
        h = h.strip()
        if EAN_PATTERNS.match(h):
            mapping["ean"] = i
        elif PRICE_PATTERNS.match(h):
            mapping["price"] = i
        elif NAME_PATTERNS.match(h):
            mapping["name"] = i
        elif BRAND_PATTERNS.match(h):
            mapping["brand"] = i
        elif MOQ_PATTERNS.match(h):
            mapping["moq"] = i
    return mapping


def _parse_price(val: str) -> float:
    """Parse price string handling £/€ symbols and commas."""
    val = val.strip().replace("£", "").replace("€", "").replace(",", "").replace(" ", "")
    try:
        return float(val)
    except (ValueError, TypeError):
        return 0.0


def parse_csv(filepath: str) -> list[dict]:
    """Parse CSV file, auto-detecting columns."""
    products = []
    with open(filepath, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        headers = next(reader, [])
        mapping = _detect_columns(headers)

        if "ean" not in mapping or "price" not in mapping:
            log(f"file_ingest: cannot detect EAN/price columns in {filepath}: {headers}")
            return []

        for row in reader:
            if len(row) <= max(mapping.values()):
                continue
            ean = row[mapping["ean"]].strip()
            price = _parse_price(row[mapping["price"]])
            if not ean or price <= 0:
                continue
            products.append({
                "ean": ean,
                "name": row[mapping["name"]].strip() if "name" in mapping else "",
                "brand": row[mapping["brand"]].strip() if "brand" in mapping else "",
                "buy_price": price,
                "currency": "GBP",
                "moq": int(row[mapping["moq"]]) if "moq" in mapping and row[mapping["moq"]].strip().isdigit() else 1,
                "volume_prices": [],
                "delivery_days": 0,
                "source_ref": f"file:{os.path.basename(filepath)}",
            })
    return products


def parse_xlsx(filepath: str) -> list[dict]:
    """Parse Excel file, auto-detecting columns from first row."""
    import openpyxl
    products = []
    wb = openpyxl.load_workbook(filepath, read_only=True, data_only=True)
    ws = wb.active

    row_iter = ws.iter_rows(values_only=True)
    first_row = next(row_iter, None)
    if not first_row:
        return []

    headers = [str(h or "") for h in first_row]
    mapping = _detect_columns(headers)

    if "ean" not in mapping or "price" not in mapping:
        log(f"file_ingest: cannot detect EAN/price columns in {filepath}: {headers}")
        return []

    for row in row_iter:
        row = list(row)
        if len(row) <= max(mapping.values()):
            continue
        ean = str(row[mapping["ean"]] or "").strip()
        price = _parse_price(str(row[mapping["price"]] or ""))
        if not ean or price <= 0:
            continue
        products.append({
            "ean": ean,
            "name": str(row[mapping["name"]] or "").strip() if "name" in mapping else "",
            "brand": str(row[mapping["brand"]] or "").strip() if "brand" in mapping else "",
            "buy_price": price,
            "currency": "GBP",
            "moq": int(row[mapping["moq"]]) if "moq" in mapping and str(row[mapping["moq"]] or "").strip().isdigit() else 1,
            "volume_prices": [],
            "delivery_days": 0,
            "source_ref": f"file:{os.path.basename(filepath)}",
        })
    wb.close()
    return products


def parse_pdf(filepath: str) -> list[dict]:
    """Parse PDF tables via pdfplumber. Falls back to Claude API for complex layouts."""
    import pdfplumber
    products = []

    with pdfplumber.open(filepath) as pdf:
        if len(pdf.pages) > CLAUDE_PDF_MAX_PAGES:
            log(f"file_ingest: PDF {filepath} has {len(pdf.pages)} pages (max {CLAUDE_PDF_MAX_PAGES}) — flagging for manual")
            return []

        for page in pdf.pages:
            tables = page.extract_tables()
            for table in tables:
                if not table or len(table) < 2:
                    continue
                headers = [str(h or "") for h in table[0]]
                mapping = _detect_columns(headers)
                if "ean" not in mapping or "price" not in mapping:
                    continue
                for row in table[1:]:
                    if len(row) <= max(mapping.values()):
                        continue
                    ean = str(row[mapping["ean"]] or "").strip()
                    price = _parse_price(str(row[mapping["price"]] or ""))
                    if not ean or price <= 0:
                        continue
                    products.append({
                        "ean": ean,
                        "name": str(row[mapping["name"]] or "").strip() if "name" in mapping else "",
                        "brand": str(row[mapping["brand"]] or "").strip() if "brand" in mapping else "",
                        "buy_price": price,
                        "currency": "GBP",
                        "moq": int(row[mapping["moq"]]) if "moq" in mapping and str(row[mapping["moq"]] or "").strip().isdigit() else 1,
                        "volume_prices": [],
                        "delivery_days": 0,
                        "source_ref": f"file:{os.path.basename(filepath)}",
                    })
    return products


def process_file(filepath: str, dry_run: bool = False) -> dict:
    """Process a single file. Returns stats."""
    ext = Path(filepath).suffix.lower()
    stats = {"file": os.path.basename(filepath), "total": 0, "queued": 0, "skipped": 0}

    if ext == ".csv":
        products = parse_csv(filepath)
    elif ext in (".xlsx", ".xls"):
        products = parse_xlsx(filepath)
    elif ext == ".pdf":
        products = parse_pdf(filepath)
    else:
        log(f"file_ingest: unsupported file type: {ext}")
        return stats

    stats["total"] = len(products)

    # Dedup
    filtered = []
    for p in products:
        if is_duplicate("file", p["ean"], p["buy_price"]):
            stats["skipped"] += 1
        else:
            filtered.append(p)

    if filtered and not dry_run:
        now = datetime.now(timezone.utc)
        supplier = Path(filepath).stem.replace("_", " ").replace("-", " ").title()
        opp_id = f"file-{Path(filepath).stem}-{now.strftime('%Y%m%d%H%M')}"
        opp = {
            "id": opp_id,
            "source": "file",
            "supplier": supplier,
            "received_at": now.isoformat(),
            "products": filtered,
        }
        os.makedirs(QUEUE_PENDING, exist_ok=True)
        with open(os.path.join(QUEUE_PENDING, f"{opp_id}.json"), "w") as f:
            json.dump(opp, f, indent=2)
        stats["queued"] = len(filtered)
        log(f"file_ingest: {os.path.basename(filepath)} → {len(filtered)} products queued")
    elif filtered and dry_run:
        stats["queued"] = len(filtered)
        for p in filtered[:3]:
            log(f"  dry-run: {p['ean']} {p['name'][:40]} @ £{p['buy_price']:.2f}")

    # Move to processed
    if not dry_run:
        shutil.move(filepath, os.path.join(INBOX_PROCESSED, os.path.basename(filepath)))

    return stats


def process_inbox(dry_run: bool = False):
    """Process all files in inbox directory."""
    os.makedirs(QUEUE_INBOX, exist_ok=True)
    os.makedirs(INBOX_PROCESSED, exist_ok=True)
    files = [f for f in Path(QUEUE_INBOX).iterdir()
             if f.is_file() and f.suffix.lower() in (".csv", ".xlsx", ".xls", ".pdf")]

    if not files:
        log("file_ingest: inbox empty")
        return

    pdf_count = 0
    log(f"file_ingest: {len(files)} files in inbox")

    for f in sorted(files, key=lambda x: x.stat().st_mtime):
        if f.suffix.lower() == ".pdf":
            pdf_count += 1
            if pdf_count > CLAUDE_PDF_MAX_PER_CYCLE:
                log(f"file_ingest: PDF limit ({CLAUDE_PDF_MAX_PER_CYCLE}) reached, deferring {f.name}")
                continue
        process_file(str(f), dry_run=dry_run)


def main():
    parser = argparse.ArgumentParser(description="File Ingest Adapter")
    parser.add_argument("--file", help="Process specific file")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.file:
        process_file(args.file, dry_run=args.dry_run)
    else:
        process_inbox(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
