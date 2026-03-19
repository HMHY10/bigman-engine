#!/usr/bin/env python3
"""vault-intel adapter — extract competitor pricing from classified vault notes.

Reads notes from:
  - 07-Marketplace/Buying/Competitor/
  - 04-Operations/Email-Intelligence/
Extracts structured pricing signals via Claude Haiku.
Outputs enrichment JSON to data/product-intel/competitor/ keyed by EAN.

Cron: daily at 7am.
"""
import json
import subprocess
from datetime import datetime

import anthropic

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from vault import log, strip_json_fences

SKILL = "opportunity-analyser"
VAULT_FOLDERS = [
    "07-Marketplace/Buying/Competitor/",
    "04-Operations/Email-Intelligence/",
]

EXTRACT_PROMPT = """Extract ALL competitor/supplier pricing signals from this vault note.
Return a JSON array of objects with these fields:
- ean: product EAN/GTIN (string, or null if not found)
- product: product name
- competitor: company/seller name
- price: price as a number (GBP)
- marketplace: where seen (amazon, ebay, wholesale, qogita, etc.)
- date: date the pricing was observed (YYYY-MM-DD)

If no pricing signals found, return an empty array [].
Only return the JSON array, no other text."""




def call_haiku(text, note_path):
    """Extract pricing signals from note text using Claude Haiku."""
    client = anthropic.Anthropic()
    try:
        resp = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=2000,
            messages=[{"role": "user", "content": f"Note: {note_path}\n\n{text}\n\n{EXTRACT_PROMPT}"}],
        )
        raw = resp.content[0].text.strip()
        raw = strip_json_fences(raw)
        return json.loads(raw)
    except Exception as e:
        log(f"haiku extraction failed for {note_path}: {e}")
        return []


def extract_pricing_signals(text, note_path):
    """Extract pricing signals from a vault note."""
    return call_haiku(text, note_path)


# ── Dedup ─────────────────────────────────────────────

def _processed_file(data_dir):
    return os.path.join(data_dir, "competitor", "processed-notes.json")


def _load_processed(data_dir):
    path = _processed_file(data_dir)
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def _save_processed(index, data_dir):
    path = _processed_file(data_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(index, f, indent=2)


def is_processed(note_path, last_modified, data_dir=None):
    data_dir = data_dir or config.INTEL_ROOT
    index = _load_processed(data_dir)
    return index.get(note_path) == last_modified


def mark_processed(note_path, last_modified, data_dir=None):
    data_dir = data_dir or config.INTEL_ROOT
    index = _load_processed(data_dir)
    index[note_path] = last_modified
    _save_processed(index, data_dir)


# ── Vault I/O ─────────────────────────────────────────

def vault_list_notes(folder):
    """List notes in a vault folder via obsidian-sync."""
    try:
        result = subprocess.run(
            ["bash", "/opt/bigman-engine/skills/active/obsidian-sync/sync.sh", "list", folder],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            log(f"vault list failed for {folder}: {result.stderr[:200]}")
            return []
        lines = [l.strip() for l in result.stdout.strip().split("\n") if l.strip()]
        return lines
    except Exception as e:
        log(f"vault list error: {e}")
        return []


def vault_read_note(path):
    """Read a vault note via obsidian-sync."""
    try:
        result = subprocess.run(
            ["bash", "/opt/bigman-engine/skills/active/obsidian-sync/sync.sh", "get", path],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            log(f"vault read failed for {path}: {result.stderr[:200]}")
            return None
        return result.stdout
    except Exception as e:
        log(f"vault read error: {e}")
        return None


# ── Enrichment Output ─────────────────────────────────

def save_competitor_data(signals, data_dir=None):
    """Save extracted signals to product-intel/competitor/ keyed by EAN."""
    data_dir = data_dir or config.INTEL_ROOT
    comp_dir = os.path.join(data_dir, "competitor")
    os.makedirs(comp_dir, exist_ok=True)

    # Group signals by EAN to avoid N+1 file reads/writes
    by_ean = {}
    for signal in signals:
        ean = signal.get("ean")
        if ean:
            by_ean.setdefault(ean, []).append(signal)

    for ean, ean_signals in by_ean.items():
        path = os.path.join(comp_dir, f"{ean}.json")
        existing = []
        if os.path.exists(path):
            with open(path) as f:
                existing = json.load(f)
        existing_keys = {f"{s.get('competitor')}:{s.get('date')}:{s.get('price')}" for s in existing}
        changed = False
        for signal in ean_signals:
            key = f"{signal.get('competitor')}:{signal.get('date')}:{signal.get('price')}"
            if key not in existing_keys:
                existing.append(signal)
                existing_keys.add(key)
                changed = True
        if changed:
            with open(path, "w") as f:
                json.dump(existing, f, indent=2)


# ── Main ──────────────────────────────────────────────

def run(dry_run=False, data_dir=None):
    """Main entry point — scan vault folders, extract pricing, save."""
    data_dir = data_dir or config.INTEL_ROOT
    total_signals = 0
    total_notes = 0

    for folder in VAULT_FOLDERS:
        notes = vault_list_notes(folder)
        log(f"{folder}: {len(notes)} notes found")

        for note_path in notes:
            modified = datetime.now().isoformat()
            if is_processed(note_path, modified, data_dir):
                continue

            text = vault_read_note(note_path)
            if not text or len(text.strip()) < 50:
                mark_processed(note_path, modified, data_dir)
                continue

            total_notes += 1
            if dry_run:
                log(f"[dry-run] would extract from: {note_path}")
                continue

            signals = extract_pricing_signals(text, note_path)
            if signals:
                save_competitor_data(signals, data_dir)
                total_signals += len(signals)
                log(f"{note_path}: extracted {len(signals)} pricing signals")

            mark_processed(note_path, modified, data_dir)

    log(f"done: {total_notes} notes scanned, {total_signals} pricing signals extracted")


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    run(dry_run=dry)
