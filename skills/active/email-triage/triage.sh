#!/usr/bin/env bash
# triage.sh — Email triage orchestrator for ArryBarry.
# Fetches new emails from MS365 and Gmail, classifies via LLM,
# saves raw emails and entity intelligence notes to Obsidian vault.
#
# Usage: triage.sh (no arguments — reads state from triage-state.json)
# Env: ANTHROPIC_API_KEY, MS365_*, GMAIL_*, OBSIDIAN_HOST, OBSIDIAN_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/active/obsidian-sync/sync.sh"
FETCH="$SCRIPT_DIR/email-fetch.sh"
STATE_FILE="$SCRIPT_DIR/triage-state.json"
PROCESSED_IDS="$SCRIPT_DIR/processed-ids.txt"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TODAY=$(date -u +"%Y-%m-%d")

# Counters
TOTAL_PROCESSED=0
TOTAL_FLAGGED=0
TOTAL_ERRORS=0
TOTAL_DUPES=0

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

# --- State Management ---
load_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    local default_ts
    default_ts=$(date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    echo "{\"ms365\":{\"last_processed\":\"$default_ts\",\"last_run\":\"\"},\"gmail\":{\"last_processed\":\"$default_ts\",\"last_run\":\"\"}}"
  fi
}

update_state_provider() {
  local provider="$1" timestamp="$2"
  local state
  state=$(cat "$STATE_FILE")
  local updated
  updated=$(echo "$state" | jq \
    --arg p "$provider" \
    --arg ts "$timestamp" \
    --arg now "$NOW" \
    '.[$p].last_processed = $ts | .[$p].last_run = $now')
  echo "$updated" > "$STATE_FILE"
}

# --- Dedup ---
is_processed() {
  local msg_id="$1"
  [ -f "$PROCESSED_IDS" ] && grep -qF "$msg_id" "$PROCESSED_IDS"
}

mark_processed() {
  local msg_id="$1"
  echo "$msg_id" >> "$PROCESSED_IDS"
}

# --- Slug Generation ---
make_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-60
}

# --- LLM Classification ---
classify_email() {
  local from="$1" to="$2" subject="$3" date="$4" body="$5"

  body=$(echo "$body" | head -c 2000)

  local prompt
  prompt=$(jq -n \
    --arg from "$from" \
    --arg to "$to" \
    --arg subject "$subject" \
    --arg date "$date" \
    --arg body "$body" \
    '{
      model: "claude-haiku-4-5-20251001",
      max_tokens: 500,
      temperature: 0,
      messages: [{
        role: "user",
        content: ("You are an email triage agent for ArryBarry Health & Beauty, a UK-based online health and beauty marketplace.\n\nClassify this email and extract key information. Respond with JSON only, no markdown formatting.\n\nEmail:\n- From: " + $from + "\n- To: " + $to + "\n- Subject: " + $subject + "\n- Date: " + $date + "\n- Body: " + $body + "\n\nRespond with this exact JSON structure:\n{\"category\": \"suppliers|customers|orders|products|marketing|partnerships|finance|internal\", \"confidence\": \"high|medium|low\", \"entity\": \"Name of the person, company, or product this is about\", \"entity_slug\": \"category-lowercase-hyphenated-slug\", \"summary\": \"One line summary\", \"key_facts\": [\"Fact 1\", \"Fact 2\"], \"action_items\": [\"Action 1\"], \"flag\": false, \"flag_reason\": \"\"}\n\nIMPORTANT for entity_slug:\n- Prefix with the category (e.g. suppliers-acme-packaging)\n- Use consistent naming for the same entity across emails\n- For companies, use the company name not the individual\n\nFlag (flag: true) if:\n- Confidence is low\n- Urgency or deadlines within 48 hours\n- Something unusual or unexpected\n- Cannot identify the entity\n\nDo NOT flag routine correspondence, order confirmations, or marketing updates.")
      }]
    }')

  local response
  response=$(curl -sf "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$prompt")

  if [ -z "$response" ]; then
    echo ""
    return 1
  fi

  echo "$response" | jq -r '.content[0].text // empty' | python3 -c "import sys,json;t=sys.stdin.read().strip();t=t.removeprefix(chr(96)*3+'json').removesuffix(chr(96)*3).strip();print(t)" | jq '.' 2>/dev/null
}

# --- Vault Operations ---
save_raw_email() {
  local category="$1" subject="$2" from="$3" to="$4" cc="$5"
  local date="$6" message_id="$7" thread_id="$8" provider="$9"
  local has_attach="${10}" body="${11}" priority="${12}"

  local slug
  slug=$(make_slug "$subject")
  local filename="${TODAY}-${category}-${slug}.md"
  local vault_path="10-Email-Raw/${filename}"

  local tmpfile="/tmp/email-raw-$$.md"
  cat > "$tmpfile" << RAWEOF
---
date: ${TODAY}
from: ${from}
to: ${to}
cc: ${cc}
subject: ${subject}
message-id: ${message_id}
thread-id: ${thread_id}
provider: ${provider}
category: ${category}
priority: ${priority}
has-attachments: ${has_attach}
tags: []
---

# ${subject}

**From:** ${from}
**Date:** ${date}

---

${body}
RAWEOF

  "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
  local result=$?
  rm -f "$tmpfile"

  if [ $result -eq 0 ]; then
    echo "$filename"
  else
    echo ""
  fi
}

append_entity_note() {
  local category="$1" entity="$2" entity_slug="$3"
  local summary="$4" key_facts="$5" action_items="$6" raw_filename="$7"

  # Capitalize first letter of category for folder name
  local cap_category="${category^}"
  local vault_path="09-Email/${cap_category}/${entity_slug}.md"

  # Read existing note
  local existing
  existing=$("$SYNC" get "$vault_path" 2>/dev/null || echo "")

  # Create header if note doesn't exist
  if [ -z "$existing" ]; then
    existing="# ${entity}

**Category:** ${category}
**First seen:** ${TODAY}
**Last updated:** ${TODAY}

---"
  else
    # Update Last updated date
    existing=$(echo "$existing" | sed "s/\*\*Last updated:\*\* .*/\*\*Last updated:\*\* ${TODAY}/")
  fi

  # Check size for rollover (50KB)
  local size=${#existing}
  if [ "$size" -gt 50000 ]; then
    local n=2
    while "$SYNC" get "09-Email/${cap_category}/${entity_slug}-${n}.md" >/dev/null 2>&1; do
      n=$((n + 1))
    done

    existing="${existing}

Continued in [[${entity_slug}-${n}]]"
    local tmpfile="/tmp/entity-rollover-$$.md"
    echo "$existing" > "$tmpfile"
    "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
    rm -f "$tmpfile"

    vault_path="09-Email/${cap_category}/${entity_slug}-${n}.md"
    existing="# ${entity} (continued)

**Category:** ${category}
**Continued from:** [[${entity_slug}]]
**Last updated:** ${TODAY}

---"
  fi

  # Format key facts
  local facts_str=""
  if [ -n "$key_facts" ] && [ "$key_facts" != "[]" ]; then
    facts_str=$(echo "$key_facts" | jq -r '.[]' 2>/dev/null | head -5 | sed 's/^/- /' | paste -sd ' ' -)
  fi

  # Format action items (up to 3)
  local actions_str=""
  if [ -n "$action_items" ] && [ "$action_items" != "[]" ]; then
    actions_str=$(echo "$action_items" | jq -r '.[]' 2>/dev/null | head -3 | sed 's/^/- /' | paste -sd ' ' -)
  fi

  # Build append block
  local append_block="

### ${TODAY} — ${summary}
${summary}. ${facts_str}
${actions_str:+**Action:** ${actions_str} → }[[10-Email-Raw/${raw_filename}]]"

  # Write back
  local updated="${existing}${append_block}"
  local tmpfile="/tmp/entity-note-$$.md"
  echo "$updated" > "$tmpfile"
  "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
  rm -f "$tmpfile"
}

append_flagged() {
  local category="$1" entity="$2" flag_reason="$3" raw_filename="$4"

  local vault_path="09-Email/Flagged/Action-Required.md"

  local existing
  existing=$("$SYNC" get "$vault_path" 2>/dev/null || echo "# Action Required

Emails flagged for human review.

---")

  local flag_line="- **${TODAY}** [${category}] ${entity}: ${flag_reason} → [[10-Email-Raw/${raw_filename}]]"

  local updated="${existing}
${flag_line}"
  local tmpfile="/tmp/flagged-$$.md"
  echo "$updated" > "$tmpfile"
  "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
  rm -f "$tmpfile"
}

# --- Process a single email ---
process_email() {
  local email_json="$1" provider="$2"

  local subject from to cc body date message_id thread_id has_attach
  subject=$(echo "$email_json" | jq -r '.subject // "(no subject)"')
  from=$(echo "$email_json" | jq -r '.from // "unknown"')
  to=$(echo "$email_json" | jq -r '.to // ""')
  cc=$(echo "$email_json" | jq -r '.cc // ""')
  body=$(echo "$email_json" | jq -r '.body // ""')
  date=$(echo "$email_json" | jq -r '.date // ""')
  message_id=$(echo "$email_json" | jq -r '.message_id // ""')
  thread_id=$(echo "$email_json" | jq -r '.thread_id // ""')
  has_attach=$(echo "$email_json" | jq -r '.has_attachments // false')

  # Dedup check
  if [ -n "$message_id" ] && is_processed "$message_id"; then
    TOTAL_DUPES=$((TOTAL_DUPES + 1))
    return 0
  fi

  # Classify via LLM
  local classification
  classification=$(classify_email "$from" "$to" "$subject" "$date" "$body")

  if [ -z "$classification" ]; then
    log "ERROR: Classification failed for: $subject"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    append_flagged "unknown" "unknown" "classification failed" "unclassified-${TODAY}.md"
    return 1
  fi

  local category confidence entity entity_slug summary key_facts action_items flag flag_reason
  category=$(echo "$classification" | jq -r '.category // "internal"')
  confidence=$(echo "$classification" | jq -r '.confidence // "low"')
  entity=$(echo "$classification" | jq -r '.entity // "Unknown"')
  entity_slug=$(echo "$classification" | jq -r '.entity_slug // "unknown"')
  summary=$(echo "$classification" | jq -r '.summary // ""')
  key_facts=$(echo "$classification" | jq -c '.key_facts // []')
  action_items=$(echo "$classification" | jq -c '.action_items // []')
  flag=$(echo "$classification" | jq -r '.flag // false')
  flag_reason=$(echo "$classification" | jq -r '.flag_reason // ""')

  # Derive priority
  local priority="normal"
  if [ "$flag" = "true" ]; then priority="high"; fi
  if [ "$category" = "marketing" ]; then priority="low"; fi

  # Save raw email
  local raw_filename
  raw_filename=$(save_raw_email "$category" "$subject" "$from" "$to" "$cc" "$date" "$message_id" "$thread_id" "$provider" "$has_attach" "$body" "$priority")

  if [ -z "$raw_filename" ]; then
    log "ERROR: Failed to save raw email: $subject"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    return 1
  fi

  # Append to entity note
  append_entity_note "$category" "$entity" "$entity_slug" "$summary" "$key_facts" "$action_items" "$raw_filename"

  # Flag if needed
  if [ "$flag" = "true" ]; then
    append_flagged "$category" "$entity" "$flag_reason" "$raw_filename"
    TOTAL_FLAGGED=$((TOTAL_FLAGGED + 1))
    log "Classified: ${category}/${entity_slug} (${confidence}) → FLAGGED: ${flag_reason}"
  else
    log "Classified: ${category}/${entity_slug} (${confidence}) → saved"
  fi

  # Mark as processed and update state
  [ -n "$message_id" ] && mark_processed "$message_id"
  [ -n "$date" ] && update_state_provider "$provider" "$date"

  TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))
}

# --- Main ---
log "START"

# Check vault connectivity
if ! "$SYNC" list "09-Email/" >/dev/null 2>&1; then
  log "ERROR: Obsidian vault unreachable. Exiting."
  exit 1
fi

# Load state
STATE=$(load_state)
echo "$STATE" > "$STATE_FILE"

# Touch processed IDs file
touch "$PROCESSED_IDS"

# Process each provider
for provider in ms365 gmail; do
  last_ts=$(echo "$STATE" | jq -r ".${provider}.last_processed // empty")
  if [ -z "$last_ts" ]; then
    log "WARNING: No state for $provider, skipping"
    continue
  fi

  log "${provider}: fetching since ${last_ts}..."

  emails=$("$FETCH" "$provider" "$last_ts")
  if [ -z "$emails" ] || [ "$emails" = "null" ]; then
    log "${provider}: fetch failed or returned null, skipping"
    continue
  fi

  count=$(echo "$emails" | jq 'length')
  log "${provider}: fetched ${count} emails since ${last_ts}"

  if [ "$count" -eq 0 ]; then
    tmp_state=$(cat "$STATE_FILE")
    echo "$tmp_state" | jq --arg p "$provider" --arg now "$NOW" '.[$p].last_run = $now' > "$STATE_FILE"
    continue
  fi

  # Process each email
  for i in $(seq 0 $((count - 1))); do
    email_json=$(echo "$emails" | jq ".[$i]")
    process_email "$email_json" "$provider"
  done
done

log "END: ${TOTAL_PROCESSED} processed, ${TOTAL_FLAGGED} flagged, ${TOTAL_ERRORS} errors, ${TOTAL_DUPES} dupes"
