"""Vault I/O via obsidian-sync subprocess (follows notebooklm pattern)."""
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from config import SYNC_SCRIPT, REPO_ROOT

SYNC = Path(SYNC_SCRIPT)


def log(msg: str):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] opportunity-analyser: {msg}", flush=True)


def vault_write(vault_path: str, content: str) -> bool:
    """Write content to vault via obsidian-sync. Returns True on success."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
        f.write(content)
        tmppath = f.name
    try:
        result = subprocess.run(
            [str(SYNC), "put-file", vault_path, tmppath],
            capture_output=True, text=True, timeout=30,
            cwd=REPO_ROOT,
        )
        if result.returncode != 0:
            log(f"vault_write failed: {vault_path} — {result.stderr.strip()}")
            return False
        log(f"vault_write: {vault_path} — OK")
        return True
    except subprocess.TimeoutExpired:
        log(f"vault_write timeout: {vault_path}")
        return False
    finally:
        os.unlink(tmppath)


def vault_read(vault_path: str) -> str | None:
    """Read content from vault. Returns None on failure."""
    try:
        result = subprocess.run(
            [str(SYNC), "get", vault_path],
            capture_output=True, text=True, timeout=30,
            cwd=REPO_ROOT,
        )
        if result.returncode != 0:
            return None
        return result.stdout
    except subprocess.TimeoutExpired:
        return None
