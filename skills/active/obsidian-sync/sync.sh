#!/usr/bin/env bash
set -euo pipefail

HOST="${OBSIDIAN_HOST:?OBSIDIAN_HOST not set}"
KEY="${OBSIDIAN_API_KEY:?OBSIDIAN_API_KEY not set}"
AUTH="Authorization: Bearer $KEY"

cmd="${1:?Usage: sync.sh <get|put|put-file|list> ...}"
shift

case "$cmd" in
  get)
    path="${1:?Missing vault path}"
    curl -sf "$HOST/vault/$path" -H "$AUTH"
    ;;
  put)
    path="${1:?Missing vault path}"
    content="${2:?Missing content}"
    curl -sf -X PUT "$HOST/vault/$path" \
      -H "$AUTH" -H "Content-Type: text/markdown" \
      -d "$content" && echo "OK: $path"
    ;;
  put-file)
    path="${1:?Missing vault path}"
    file="${2:?Missing local file}"
    curl -sf -X PUT "$HOST/vault/$path" \
      -H "$AUTH" -H "Content-Type: text/markdown" \
      --data-binary "@$file" && echo "OK: $path"
    ;;
  list)
    path="${1:-}"
    curl -sf "$HOST/vault/$path" -H "$AUTH"
    ;;
  *)
    echo "Unknown: $cmd. Use get|put|put-file|list" >&2; exit 1
    ;;
esac
