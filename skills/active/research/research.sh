#!/usr/bin/env bash
set -euo pipefail

# Research convenience wrapper — runs Brave Search with ArryBarry defaults
# Usage: research.sh "query" [-n num] [--freshness period] [--country code]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SEARCH_CMD="$SKILLS_DIR/brave-search/search.js"

if [ ! -f "$SEARCH_CMD" ]; then
  echo "Error: brave-search skill not found at $SEARCH_CMD" >&2
  exit 1
fi

if [ -z "${BRAVE_API_KEY:-}" ]; then
  echo "Error: BRAVE_API_KEY not set" >&2
  exit 1
fi

# Default: 8 results, GB country, with content extraction
query="${1:?Usage: research.sh \"query\" [-n num] [--freshness period]}"
shift

# Check if custom flags were passed, otherwise use defaults
has_n=false
has_country=false
has_content=false
for arg in "$@"; do
  case "$arg" in
    -n) has_n=true ;;
    --country) has_country=true ;;
    --content) has_content=true ;;
  esac
done

args=()
$has_n || args+=(-n 8)
$has_country || args+=(--country GB)
$has_content || args+=(--content)

exec node "$SEARCH_CMD" "$query" "${args[@]}" "$@"
