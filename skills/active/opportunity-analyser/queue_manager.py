"""File-based opportunity queue with dedup and staleness recovery."""
import json
import os
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path

from config import (
    QUEUE_INBOX, QUEUE_PENDING, QUEUE_PROCESSING, QUEUE_PROCESSED,
    QUEUE_FAILED, QUEUE_ARCHIVE,
    DEDUP_INDEX, DEDUP_WINDOW_DAYS, DEDUP_PRUNE_DAYS,
    MAX_RETRIES, PROCESSING_STALE_HOURS,
)
from models import Opportunity, Product, VolumePrice


def _ensure_dirs():
    for d in [QUEUE_INBOX, QUEUE_PENDING, QUEUE_PROCESSING, QUEUE_PROCESSED,
              QUEUE_FAILED, QUEUE_ARCHIVE, os.path.dirname(DEDUP_INDEX)]:
        os.makedirs(d, exist_ok=True)


def _load_dedup_index() -> dict:
    if os.path.exists(DEDUP_INDEX):
        with open(DEDUP_INDEX) as f:
            return json.load(f)
    return {}


def _save_dedup_index(index: dict):
    with open(DEDUP_INDEX, "w") as f:
        json.dump(index, f)


def _dedup_key(source: str, ean: str, buy_price: float) -> str:
    return f"{source}:{ean}:{buy_price:.2f}"


def is_duplicate(source: str, ean: str, buy_price: float) -> bool:
    index = _load_dedup_index()
    key = _dedup_key(source, ean, buy_price)
    if key not in index:
        return False
    last_seen = index[key]
    age_days = (time.time() - last_seen) / 86400
    return age_days < DEDUP_WINDOW_DAYS


def record_processed(source: str, ean: str, buy_price: float):
    index = _load_dedup_index()
    key = _dedup_key(source, ean, buy_price)
    index[key] = time.time()
    _save_dedup_index(index)


def prune_dedup_index():
    index = _load_dedup_index()
    cutoff = time.time() - (DEDUP_PRUNE_DAYS * 86400)
    pruned = {k: v for k, v in index.items() if v > cutoff}
    _save_dedup_index(pruned)


def recover_stale_processing():
    """Move files stuck in processing/ back to pending/."""
    _ensure_dirs()
    cutoff = time.time() - (PROCESSING_STALE_HOURS * 3600)
    for f in Path(QUEUE_PROCESSING).glob("*.json"):
        if f.stat().st_mtime < cutoff:
            shutil.move(str(f), os.path.join(QUEUE_PENDING, f.name))


def get_pending() -> list[tuple[str, Opportunity]]:
    """Return list of (filepath, Opportunity) from pending queue.
    Priority: price-changed (filename starts with 'p-') first, then by age."""
    _ensure_dirs()
    results = []
    files = list(Path(QUEUE_PENDING).glob("*.json"))
    # Priority ordering: 'p-' prefix = price change, sort those first, then by mtime
    files.sort(key=lambda f: (0 if f.name.startswith("p-") else 1, f.stat().st_mtime))
    for f in files:
        with open(f) as fh:
            data = json.load(fh)
        products = [
            Product(
                ean=p["ean"],
                name=p.get("name", ""),
                brand=p.get("brand", ""),
                buy_price=p.get("buy_price", 0),
                currency=p.get("currency", "GBP"),
                moq=p.get("moq", 1),
                volume_prices=[VolumePrice(**vp) for vp in p.get("volume_prices", [])],
                delivery_days=p.get("delivery_days", 0),
                source_ref=p.get("source_ref", ""),
            )
            for p in data.get("products", [])
        ]
        opp = Opportunity(
            id=data["id"],
            source=data["source"],
            supplier=data["supplier"],
            received_at=data["received_at"],
            products=products,
            retry_count=data.get("retry_count", 0),
        )
        results.append((str(f), opp))
    return results


def move_to_processing(filepath: str) -> str:
    dest = os.path.join(QUEUE_PROCESSING, os.path.basename(filepath))
    shutil.move(filepath, dest)
    return dest


def move_to_processed(filepath: str):
    shutil.move(filepath, os.path.join(QUEUE_PROCESSED, os.path.basename(filepath)))


def move_to_failed(filepath: str, reason: str):
    dest = os.path.join(QUEUE_FAILED, os.path.basename(filepath))
    shutil.move(filepath, dest)
    # Write failure reason alongside
    reason_file = dest.replace(".json", ".reason.txt")
    with open(reason_file, "w") as f:
        f.write(f"{datetime.now(timezone.utc).isoformat()}: {reason}\n")


def move_to_pending_retry(filepath: str):
    """Move back to pending with incremented retry count."""
    with open(filepath) as f:
        data = json.load(f)
    data["retry_count"] = data.get("retry_count", 0) + 1
    if data["retry_count"] >= MAX_RETRIES:
        move_to_failed(filepath, f"Max retries ({MAX_RETRIES}) exceeded")
        return
    dest = os.path.join(QUEUE_PENDING, os.path.basename(filepath))
    with open(dest, "w") as f:
        json.dump(data, f)
    os.remove(filepath)
