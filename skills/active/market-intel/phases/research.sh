#!/usr/bin/env bash
# research.sh — Phase 1: Data gathering for market intelligence.
# Gathers data from Brave Search, email intel, and vault entries.
# Structures results via Claude Haiku into JSON files.
#
# Usage:
#   research.sh competitor "Competitor Name"
#   research.sh supplier
#
# Reads from: Brave Search API, 09-Email/ entity notes, 03-Resources/Competitors/
# Writes to: /tmp/market-intel/research/{slug}.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/active/obsidian-sync/sync.sh"
PIPELINE_DIR="/tmp/market-intel"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

# --- Env checks ---
if [ -z "${BRAVE_API_KEY:-}" ]; then
  log "ERROR: BRAVE_API_KEY not set. Add it to Doppler shared-services."
  exit 1
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  log "ERROR: ANTHROPIC_API_KEY not set."
  exit 1
fi

# --- Slug helper ---
make_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-60
}

# --- Brave Search with rate limiting + 429 retry ---
brave_search() {
  local query="$1"
  local retries=0

  while [ $retries -le 1 ]; do
    local tmpfile="/tmp/brave-search-${RANDOM}.json"
    local http_code
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -G \
      "https://api.search.brave.com/res/v1/web/search" \
      --data-urlencode "q=${query}" \
      --data-urlencode "count=5" \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: ${BRAVE_API_KEY}")

    if [ "$http_code" = "200" ]; then
      cat "$tmpfile"
      rm -f "$tmpfile"
      return 0
    elif [ "$http_code" = "429" ] && [ $retries -eq 0 ]; then
      log "Brave Search rate limited for: $query — retrying in 5s"
      rm -f "$tmpfile"
      sleep 5
      retries=$((retries + 1))
    else
      log "Brave Search failed (HTTP $http_code) for: $query"
      rm -f "$tmpfile"
      return 1
    fi
  done
}

# --- Format Brave Search results for LLM ---
format_search_results() {
  local raw_json="$1"
  echo "$raw_json" | jq -r '
    .web.results[:5] // [] | .[] |
    "- [\(.title // "Untitled")](\(.url // "")): \(.description // "No description")"
  ' 2>/dev/null || echo "No results"
}

# --- Find email intel for a target across vault categories ---
find_email_intel() {
  local slug="$1"
  local intel=""

  for category in Marketing Partnerships Suppliers Customers Products; do
    local files
    files=$("$SYNC" list "09-Email/${category}/" 2>/dev/null | jq -r '.files[]' 2>/dev/null || echo "")
    [ -z "$files" ] && continue

    # Filter for files containing the slug in filename (case-insensitive)
    local matching
    matching=$(echo "$files" | grep -i "$slug" || echo "")
    [ -z "$matching" ] && continue

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      # Extract just the filename if it's a full path
      local fname
      fname=$(basename "$f" 2>/dev/null || echo "$f")
      local content
      content=$("$SYNC" get "09-Email/${category}/${fname}" 2>/dev/null || echo "")
      if [ -n "$content" ]; then
        intel="${intel}

--- From 09-Email/${category}/${fname} ---
${content}"
      fi
    done <<< "$matching"
  done

  echo "$intel"
}

# --- LLM call: structure research data via Haiku ---
structure_research() {
  local name="$1" slug="$2" target_type="$3"
  local search_text="$4" email_intel="$5" curated_data="$6"

  local prompt
  prompt=$(jq -n \
    --arg name "$name" \
    --arg slug "$slug" \
    --arg type "$target_type" \
    --arg search "$search_text" \
    --arg email "${email_intel:-None available}" \
    --arg curated "${curated_data:-No existing profile}" \
    '{
      model: "claude-haiku-4-5-20251001",
      max_tokens: 1500,
      temperature: 0,
      messages: [{
        role: "user",
        content: ("You are a market research data collector for ArryBarry Health & Beauty, a UK-based online health and beauty marketplace.\n\nGiven the following raw data about \"" + $name + "\" (" + $type + "), extract and structure the key facts.\n\n## Web Search Results\n" + $search + "\n\n## Internal Email Intelligence\n" + $email + "\n\n## Existing Profile Data\n" + $curated + "\n\nRespond with ONLY valid JSON (no markdown fencing, no explanation):\n{\n  \"name\": \"" + $name + "\",\n  \"slug\": \"" + $slug + "\",\n  \"type\": \"" + $type + "\",\n  \"web_data\": {\n    \"positioning\": \"Their market positioning in 1-2 sentences\",\n    \"products\": [\"category1\", \"category2\"],\n    \"hero_products\": [\"notable product or service 1\"],\n    \"price_range\": \"budget/mid/premium/luxury\",\n    \"channels\": [\"DTC website\", \"marketplace\", \"etc\"],\n    \"marketing_claims\": [\"key claim 1\"],\n    \"recent_news\": [\"recent development 1\"],\n    \"customer_sentiment\": {\"positive\": [\"point1\"], \"negative\": [\"point1\"]},\n    \"sources\": [{\"url\": \"source url\", \"title\": \"source title\"}]\n  },\n  \"email_intel\": {\n    \"mentions\": 0,\n    \"key_quotes\": [],\n    \"source_notes\": []\n  },\n  \"curated_data\": {\n    \"existing_profile\": false,\n    \"last_updated\": \"\",\n    \"notes\": \"\"\n  }\n}\n\nFill in real data from the search results and email intelligence. Use empty arrays/strings for missing data. Count actual email mentions.")
      }]
    }')

  local response
  response=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$prompt" 2>/dev/null)

  if [ -z "$response" ]; then
    log "ERROR: Haiku API call failed for $name"
    return 1
  fi

  # Extract text and validate JSON
  local text
  text=$(echo "$response" | jq -r '.content[0].text // empty')
  if [ -z "$text" ]; then
    log "ERROR: Empty response from Haiku for $name"
    return 1
  fi

  # Strip any markdown fencing if present
  text=$(echo "$text" | sed '/^```/d')

  # Validate it's valid JSON
  if ! echo "$text" | jq '.' >/dev/null 2>&1; then
    log "ERROR: Invalid JSON from Haiku for $name"
    return 1
  fi

  echo "$text"
}

# --- Research a single competitor ---
research_competitor() {
  local name="$1"
  local slug
  slug=$(make_slug "$name")

  log "Research: $name (slug: $slug)"

  # --- Brave Search queries (4 per competitor, 1s delay between) ---
  local all_search_text=""

  local queries=(
    "\"${name}\" UK health beauty"
    "\"${name}\" pricing products"
    "\"${name}\" reviews complaints"
    "\"${name}\" news 2026"
  )

  local search_count=0
  for query in "${queries[@]}"; do
    local result
    result=$(brave_search "$query" || echo "{}")
    if [ "$result" != "{}" ] && [ -n "$result" ]; then
      local formatted
      formatted=$(format_search_results "$result")
      all_search_text="${all_search_text}

### Query: ${query}
${formatted}"
      search_count=$((search_count + 1))
    fi
    sleep 1  # Rate limit: 1 query/second
  done

  log "Research: $name — $search_count searches completed"

  # --- Email intel ---
  local email_intel
  email_intel=$(find_email_intel "$slug")
  local email_refs=0
  if [ -n "$email_intel" ]; then
    email_refs=$(echo "$email_intel" | grep -c "^--- From" || echo "0")
  fi

  log "Research: $name — $email_refs email references found"

  # --- Existing curated profile ---
  local curated_data=""
  curated_data=$("$SYNC" get "03-Resources/Competitors/${name}.md" 2>/dev/null || echo "")
  if [ -z "$curated_data" ]; then
    # Try slug-based filename
    curated_data=$("$SYNC" get "03-Resources/Competitors/${slug}.md" 2>/dev/null || echo "")
  fi

  # --- Structure via Haiku ---
  local structured_json
  structured_json=$(structure_research "$name" "$slug" "competitor" "$all_search_text" "$email_intel" "$curated_data")

  if [ -z "$structured_json" ]; then
    log "WARNING: Failed to structure research for $name — skipping"
    return 1
  fi

  # --- Write to pipeline ---
  echo "$structured_json" > "$PIPELINE_DIR/research/${slug}.json"
  log "Research: $name — $search_count searches, $email_refs email refs → ${slug}.json"
}

# --- Research all suppliers ---
research_suppliers() {
  log "Research: enumerating suppliers from 09-Email/Suppliers/..."

  local supplier_files
  supplier_files=$("$SYNC" list "09-Email/Suppliers/" 2>/dev/null | jq -r '.files[]' 2>/dev/null || echo "")

  if [ -z "$supplier_files" ]; then
    log "WARNING: No supplier entity notes found in 09-Email/Suppliers/"
    return 0
  fi

  # Extract supplier names from entity note filenames
  # Pattern: suppliers-{name-slug}.md → "Name Slug" (title-cased)
  local supplier_count=0

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local fname
    fname=$(basename "$f" .md 2>/dev/null || echo "$f")
    fname=$(echo "$fname" | sed 's/\.md$//')

    # Strip "suppliers-" prefix if present
    local name_slug
    name_slug=$(echo "$fname" | sed 's/^suppliers-//')
    [ -z "$name_slug" ] && continue

    # Convert slug to readable name (hyphens → spaces, title case)
    local name
    name=$(echo "$name_slug" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
    local slug
    slug=$(make_slug "$name")

    log "Research: supplier '$name' (from entity note: $fname)"

    # --- Read existing entity note for this supplier ---
    local entity_content
    entity_content=$("$SYNC" get "09-Email/Suppliers/${fname}.md" 2>/dev/null || \
                     "$SYNC" get "09-Email/Suppliers/${fname}" 2>/dev/null || echo "")

    # --- Brave Search queries for supplier (3 per supplier) ---
    local all_search_text=""
    local queries=(
      "\"${name}\" packaging pricing UK"
      "\"${name}\" products range wholesale"
      "\"${name}\" reviews lead time delivery"
    )

    local search_count=0
    for query in "${queries[@]}"; do
      local result
      result=$(brave_search "$query" || echo "{}")
      if [ "$result" != "{}" ] && [ -n "$result" ]; then
        local formatted
        formatted=$(format_search_results "$result")
        all_search_text="${all_search_text}

### Query: ${query}
${formatted}"
        search_count=$((search_count + 1))
      fi
      sleep 1  # Rate limit
    done

    # --- Structure via Haiku ---
    local structured_json
    structured_json=$(structure_research "$name" "$slug" "supplier" "$all_search_text" "$entity_content" "")

    if [ -n "$structured_json" ]; then
      echo "$structured_json" > "$PIPELINE_DIR/research/${slug}.json"
      supplier_count=$((supplier_count + 1))
      log "Research: supplier $name — $search_count searches → ${slug}.json"
    else
      log "WARNING: Failed to structure research for supplier $name — skipping"
    fi
  done <<< "$supplier_files"

  log "Research: $supplier_count suppliers researched"
}

# --- Main ---
TARGET_TYPE="${1:?Usage: research.sh <competitor|supplier> [name]}"
shift

case "$TARGET_TYPE" in
  competitor)
    NAME="${1:?Missing competitor name}"
    research_competitor "$NAME"
    ;;
  supplier)
    research_suppliers
    ;;
  *)
    log "ERROR: Unknown target type: $TARGET_TYPE"
    exit 1
    ;;
esac
