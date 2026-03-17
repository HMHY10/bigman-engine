#!/usr/bin/env python3
"""notebooklm-skill.py — Transform Obsidian vault content via Google NotebookLM.

Usage:
    notebooklm-skill.py <format> <vault_path> [vault_path ...] [--topic NAME] [--keep]

Formats: audio, slides, quiz, flashcards, mindmap, infographic
"""

import argparse
import asyncio
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# --- Configuration ---
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent.parent
SYNC = REPO_ROOT / "skills" / "active" / "obsidian-sync" / "sync.sh"
OUTPUT_BASE = REPO_ROOT / "outputs" / "notebooklm"
LOCK_FILE = pathlib.Path("/tmp/notebooklm-skill.lock")

FORMATS = {
    "audio":       {"ext": "mp3",  "generate": "generate_audio",      "download": "download_audio",      "dl_kwargs": {}},
    "slides":      {"ext": "pptx", "generate": "generate_slide_deck", "download": "download_slide_deck", "dl_kwargs": {}},
    "quiz":        {"ext": "json", "generate": "generate_quiz",       "download": "download_quiz",       "dl_kwargs": {"output_format": "json"}},
    "flashcards":  {"ext": "json", "generate": "generate_flashcards", "download": "download_flashcards", "dl_kwargs": {"output_format": "json"}},
    "mindmap":     {"ext": "json", "generate": "generate_mind_map",   "download": "download_mind_map",   "dl_kwargs": {}},
    "infographic": {"ext": "png",  "generate": "generate_infographic","download": "download_infographic","dl_kwargs": {}},
}

GENERATION_TIMEOUT = 600  # 10 minutes
API_DELAY = 2  # seconds between API calls
MAX_RETRIES = 3


def log(msg: str):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] {msg}", flush=True)


def vault_read(vault_path: str) -> str:
    """Read a note from the Obsidian vault via obsidian-sync."""
    result = subprocess.run(
        [str(SYNC), "get", vault_path],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to read vault path: {vault_path}")
    return result.stdout


def vault_write(vault_path: str, content: str):
    """Write a note to the Obsidian vault via obsidian-sync."""
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
        f.write(content)
        tmppath = f.name
    try:
        result = subprocess.run(
            [str(SYNC), "put-file", vault_path, tmppath],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            raise RuntimeError(f"Failed to write vault path: {vault_path}")
    finally:
        os.unlink(tmppath)


def derive_topic(vault_paths: list[str]) -> str:
    """Derive topic from first vault path filename, stripping date prefix."""
    name = pathlib.Path(vault_paths[0]).stem
    # Strip leading YYYY-MM-DD- if present
    name = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", name)
    return name


def setup_auth():
    """Write NOTEBOOKLM_AUTH_JSON env var to storage file for the client."""
    auth_json = os.environ.get("NOTEBOOKLM_AUTH_JSON", "")
    if not auth_json:
        log("ERROR: NOTEBOOKLM_AUTH_JSON not set.")
        log("Setup: run 'notebooklm login' on Mac, then:")
        log("  doppler secrets set NOTEBOOKLM_AUTH_JSON=\"$(cat ~/.notebooklm/storage_state.json)\" -p shared-services -c prd")
        raise RuntimeError("NOTEBOOKLM_AUTH_JSON not set")

    storage_dir = pathlib.Path.home() / ".notebooklm"
    storage_dir.mkdir(exist_ok=True)
    (storage_dir / "storage_state.json").write_text(auth_json)


def format_duration(seconds: float) -> str:
    """Format seconds into human-readable Xm Xs."""
    m, s = divmod(int(seconds), 60)
    if m > 0:
        return f"{m}m {s}s"
    return f"{s}s"


async def run_with_retry(coro_func, *args, **kwargs):
    """Run an async function with exponential backoff on failure."""
    delay = API_DELAY
    for attempt in range(MAX_RETRIES):
        try:
            return await coro_func(*args, **kwargs)
        except Exception as e:
            if attempt == MAX_RETRIES - 1:
                raise
            log(f"  Retry {attempt + 1}/{MAX_RETRIES} after error: {e} (waiting {delay}s)")
            await asyncio.sleep(delay)
            delay *= 2


async def main():
    parser = argparse.ArgumentParser(description="Transform vault content via NotebookLM")
    parser.add_argument("format", choices=FORMATS.keys(), help="Output format")
    parser.add_argument("vault_paths", nargs="+", help="Vault note paths")
    parser.add_argument("--topic", default=None, help="Override topic name")
    parser.add_argument("--keep", action="store_true", help="Keep notebook after generation")
    args = parser.parse_args()

    fmt = FORMATS[args.format]
    topic = args.topic or derive_topic(args.vault_paths)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M")
    start_time = time.time()

    log(f"START format={args.format} sources={len(args.vault_paths)}")

    # --- Lockfile ---
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("ERROR: Another instance is running. Exiting.")
        lock_fd.close()
        sys.exit(1)

    # Everything from here is in try/finally so lock is always released
    from notebooklm import NotebookLMClient

    nb = None
    nb_name = None
    client_ctx = None
    client = None

    try:
        # --- Auth ---
        setup_auth()
        log("Auth check: storage file written")

        # --- Read vault content ---
        sources = []
        for vp in args.vault_paths:
            content = vault_read(vp)
            size_kb = len(content) / 1024
            log(f"Reading vault: {vp} ({size_kb:.1f}KB)")
            sources.append({"path": vp, "content": content})

        # --- NotebookLM operations ---
        client_ctx = await NotebookLMClient.from_storage()
        client = await client_ctx.__aenter__()

        # Create notebook
        nb_name = f"{today}-{topic}"
        nb = await run_with_retry(client.notebooks.create, nb_name)
        log(f"Created notebook: {nb_name}")
        await asyncio.sleep(API_DELAY)

        # Add sources
        for src in sources:
            name = pathlib.Path(src["path"]).stem
            await run_with_retry(client.sources.add_text, nb.id, name, src["content"])
            log(f"Added source: {name} ({len(src['content']) / 1024:.1f}KB text)")
            await asyncio.sleep(API_DELAY)

        # Generate
        generate_method = getattr(client.artifacts, fmt["generate"])
        log(f"Generating {args.format}... (polling, timeout {GENERATION_TIMEOUT // 60}m)")

        status = await run_with_retry(generate_method, nb.id)
        await client.artifacts.wait_for_completion(nb.id, status.task_id, timeout=GENERATION_TIMEOUT)

        gen_duration = time.time() - start_time
        log(f"Generation complete ({format_duration(gen_duration)})")
        await asyncio.sleep(API_DELAY)

        # Download
        output_dir = OUTPUT_BASE / args.format
        output_dir.mkdir(parents=True, exist_ok=True)
        filename = f"{timestamp}-{topic}.{fmt['ext']}"
        filepath = output_dir / filename

        download_method = getattr(client.artifacts, fmt["download"])
        dl_kwargs = fmt["dl_kwargs"].copy()
        await run_with_retry(download_method, nb.id, str(filepath), **dl_kwargs)

        file_size_mb = filepath.stat().st_size / (1024 * 1024)
        log(f"Downloaded: {filepath} ({file_size_mb:.1f}MB)")

        # Write vault index note
        source_links = "\n".join(f"- [[{s['path']}]]" for s in sources)
        format_title = args.format.replace("mindmap", "Mind Map").replace("flashcards", "Flashcards").title()
        now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        index_content = f"""---
vault-path: 05-Agent-Outputs/NotebookLM/{today}-{topic}-{args.format}.md
type: notebooklm-output
format: {args.format}
generated: {now_iso}
---

# {format_title}: {topic}

**Date:** {today}
**Agent:** bigman-notebooklm
**Format:** {args.format}
**Status:** Generated

## Source Notes
{source_links}

## Output File
**Path:** `{filepath}`
**Size:** {file_size_mb:.1f}MB

## Notes
Generated via notebooklm-py from {len(sources)} source note(s).
"""

        index_path = f"05-Agent-Outputs/NotebookLM/{today}-{topic}-{args.format}.md"
        try:
            vault_write(index_path, index_content)
            log(f"Vault index: {index_path}")
        except Exception as e:
            log(f"WARNING: Failed to write vault index: {e} (artifact still saved at {filepath})")

    except Exception as e:
        log(f"ERROR: {e}")
        sys.exit(1)

    finally:
        # Cleanup notebook
        if nb and client and not args.keep:
            try:
                await client.notebooks.delete(nb.id)
                log("Cleaned up notebook")
            except Exception as e:
                log(f"WARNING: Notebook cleanup failed: {e}")
        elif nb and args.keep:
            log(f"Kept notebook: {nb_name} (--keep)")

        if client_ctx:
            await client_ctx.__aexit__(None, None, None)

        lock_fd.close()

    total_duration = time.time() - start_time
    log(f"END: {args.format} generated in {format_duration(total_duration)}")


if __name__ == "__main__":
    asyncio.run(main())
