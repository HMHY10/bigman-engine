#!/usr/bin/env python3
"""Daily NotebookLM auth health check."""
import asyncio, os, pathlib, sys

auth_json = os.environ.get("NOTEBOOKLM_AUTH_JSON", "")
if not auth_json:
    print("[WARN] NOTEBOOKLM_AUTH_JSON not set")
    sys.exit(1)

p = pathlib.Path.home() / ".notebooklm"
p.mkdir(exist_ok=True)
(p / "storage_state.json").write_text(auth_json)

try:
    from notebooklm import NotebookLMClient
    async def check():
        async with await NotebookLMClient.from_storage() as client:
            await client.notebooks.list()
            print("[OK] NotebookLM auth valid")
    asyncio.run(check())
except Exception as e:
    print(f"[WARN] NotebookLM auth check failed: {e}")
    sys.exit(1)
