#!/usr/bin/env bash
# historical-import.sh — One-time bulk import of MS365 email history.
# Processes day-by-day with checkpoint state for restartability.
# Reuses email-fetch.sh for API calls. Duplicates classification from triage.sh.
#
# Usage:
#   historical-import.sh              # Default: 6 months
#   historical-import.sh --months 12  # Custom range
#   historical-import.sh --reset      # Clear checkpoint and re-run
#
# Env: ANTHROPIC_API_KEY, MS365_*, OBSIDIAN_HOST, OBSIDIAN_API_KEY (via Doppler)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SYNC="$REPO_ROOT/skills/active/obsidian-sync/sync.sh"
FETCH="$SCRIPT_DIR/email-fetch.sh"
STATE_FILE="$SCRIPT_DIR/historical-import-state.json"
TRIAGE_STATE_FILE="$SCRIPT_DIR/triage-state.json"
PROCESSED_IDS="$SCRIPT_DIR/processed-ids.txt"
PROCESSED_IDS_LOCK="$SCRIPT_DIR/processed-ids.txt.lock"
LOCK_FILE="/tmp/historical-import.lock"

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

# --- Lockfile ---
exec 200>"$LOCK_FILE"
flock -n 200 || { log "Another instance running. Exiting."; exit 0; }

# --- Parse arguments ---
MONTHS=6
RESET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --months) MONTHS="$2"; shift 2 ;;
    --reset) RESET=true; shift ;;
    *) log "Unknown argument: $1"; exit 1 ;;
  esac
done

# --- Calculate date range ---
END_DATE=$(date -u -d "yesterday" +"%Y-%m-%d" 2>/dev/null || date -u -v-1d +"%Y-%m-%d")
START_DATE=$(date -u -d "${MONTHS} months ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${MONTHS}m +"%Y-%m-%d")

# --- Handle --reset ---
if $RESET; then
  rm -f "$STATE_FILE"
  log "Checkpoint cleared (--reset). Dedup via processed-ids.txt still active."
fi

# --- State Management ---
if [ -f "$STATE_FILE" ]; then
  status=$(jq -r '.status // "in_progress"' "$STATE_FILE")
  if [ "$status" = "complete" ]; then
    log "Import already complete. Use --reset to re-run."
    exit 0
  fi
fi

init_state() {
  cat > "$STATE_FILE" << STATEEOF
{
  "start_date": "$START_DATE",
  "end_date": "$END_DATE",
  "last_completed_date": "",
  "total_processed": 0,
  "total_flagged": 0,
  "total_errors": 0,
  "status": "in_progress"
}
STATEEOF
}

if [ ! -f "$STATE_FILE" ]; then
  init_state
fi

LAST_COMPLETED=$(jq -r '.last_completed_date // ""' "$STATE_FILE")
TOTAL_PROCESSED=$(jq -r '.total_processed // 0' "$STATE_FILE")
TOTAL_FLAGGED=$(jq -r '.total_flagged // 0' "$STATE_FILE")
TOTAL_ERRORS=$(jq -r '.total_errors // 0' "$STATE_FILE")

# Override start/end from state file (in case of resume with different --months)
START_DATE=$(jq -r '.start_date' "$STATE_FILE")
END_DATE=$(jq -r '.end_date' "$STATE_FILE")

# If resuming, start from day after last completed
CURRENT_DATE="$START_DATE"
if [ -n "$LAST_COMPLETED" ]; then
  CURRENT_DATE=$(date -u -d "$LAST_COMPLETED + 1 day" +"%Y-%m-%d" 2>/dev/null || date -u -jf "%Y-%m-%d" -v+1d "$LAST_COMPLETED" +"%Y-%m-%d")
fi

log "START: importing MS365 email ($START_DATE to $END_DATE)"
if [ -n "$LAST_COMPLETED" ]; then
  log "Resuming from: $CURRENT_DATE (last completed: $LAST_COMPLETED)"
else
  log "Starting fresh from: $CURRENT_DATE"
fi

# --- Vault connectivity check ---
if ! "$SYNC" list "09-Email/" >/dev/null 2>&1; then
  log "ERROR: Obsidian vault unreachable. Exiting."
  exit 1
fi

# Touch processed IDs file and lock file
touch "$PROCESSED_IDS"
touch "$PROCESSED_IDS_LOCK"

# --- Slug helper ---
make_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -c1-60
}

# --- Fallback message ID ---
make_fallback_id() {
  local date="$1" from="$2" subject="$3"
  local hash
  hash=$(echo -n "$subject" | sha256sum | cut -c1-16)
  echo "${date}:${from}:${hash}"
}

# --- Dedup with flock ---
is_processed_locked() {
  local msg_id="$1"
  (
    flock 201
    grep -qF "$msg_id" "$PROCESSED_IDS" 2>/dev/null
  ) 201>"$PROCESSED_IDS_LOCK"
}

mark_processed_locked() {
  local msg_id="$1"
  (
    flock 201
    echo "$msg_id" >> "$PROCESSED_IDS"
  ) 201>"$PROCESSED_IDS_LOCK"
}

# --- LLM Classification (duplicated from triage.sh) ---
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
    -d "$prompt" 2>/dev/null)

  if [ -z "$response" ]; then
    echo ""
    return 1
  fi

  echo "$response" | jq -r '.content[0].text // empty' | python3 -c "import sys,json;t=sys.stdin.read().strip();t=t.removeprefix(chr(96)*3+'json').removesuffix(chr(96)*3).strip();print(t)" | jq '.' 2>/dev/null
}

# --- Vault: Save raw email ---
save_raw_email() {
  local category="$1" subject="$2" from="$3" to="$4" cc="$5"
  local email_date="$6" message_id="$7" thread_id="$8" provider="$9"
  local has_attach="${10}" body="${11}" priority="${12}"

  local day_str
  day_str=$(echo "$email_date" | cut -c1-10)
  local slug
  slug=$(make_slug "$subject")
  local filename="${day_str}-${category}-${slug}.md"
  local vault_path="10-Email-Raw/${filename}"

  local tmpfile="/tmp/email-raw-$$.md"
  cat > "$tmpfile" << RAWEOF
---
date: ${day_str}
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
**Date:** ${email_date}

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

# --- Vault: Append entity note ---
append_entity_note() {
  local category="$1" entity="$2" entity_slug="$3"
  local summary="$4" key_facts="$5" action_items="$6" raw_filename="$7"

  local day_str
  day_str=$(echo "$raw_filename" | cut -c1-10)
  local cap_category="${category^}"
  local vault_path="09-Email/${cap_category}/${entity_slug}.md"

  local existing
  existing=$("$SYNC" get "$vault_path" 2>/dev/null || echo "")

  if [ -z "$existing" ]; then
    existing="# ${entity}

**Category:** ${category}
**First seen:** ${day_str}
**Last updated:** ${day_str}

---"
  else
    existing=$(echo "$existing" | sed "s/\*\*Last updated:\*\* .*/\*\*Last updated:\*\* ${day_str}/")
  fi

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
**Last updated:** ${day_str}

---"
  fi

  local facts_str=""
  if [ -n "$key_facts" ] && [ "$key_facts" != "[]" ]; then
    facts_str=$(echo "$key_facts" | jq -r '.[]' 2>/dev/null | head -5 | sed 's/^/- /' | paste -sd ' ' -)
  fi

  local actions_str=""
  if [ -n "$action_items" ] && [ "$action_items" != "[]" ]; then
    actions_str=$(echo "$action_items" | jq -r '.[]' 2>/dev/null | head -3 | sed 's/^/- /' | paste -sd ' ' -)
  fi

  local append_block="

### ${day_str} — ${summary}
${summary}. ${facts_str}
${actions_str:+**Action:** ${actions_str} → }[[10-Email-Raw/${raw_filename}]]"

  local updated="${existing}${append_block}"
  local tmpfile="/tmp/entity-note-$$.md"
  echo "$updated" > "$tmpfile"
  "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
  rm -f "$tmpfile"
}

# --- Vault: Append flagged ---
append_flagged() {
  local category="$1" entity="$2" flag_reason="$3" raw_filename="$4"

  local day_str
  day_str=$(echo "$raw_filename" | cut -c1-10)
  local vault_path="09-Email/Flagged/Action-Required.md"

  local existing
  existing=$("$SYNC" get "$vault_path" 2>/dev/null || echo "# Action Required

Emails flagged for human review.

---")

  local flag_line="- **${day_str}** [${category}] ${entity}: ${flag_reason} → [[10-Email-Raw/${raw_filename}]]"
  local updated="${existing}
${flag_line}"
  local tmpfile="/tmp/flagged-$$.md"
  echo "$updated" > "$tmpfile"
  "$SYNC" put-file "$vault_path" "$tmpfile" 2>/dev/null
  rm -f "$tmpfile"
}

# --- Process a single email ---
process_email() {
  local email_json="$1"

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

  # Fallback message ID if empty
  if [ -z "$message_id" ]; then
    message_id=$(make_fallback_id "$date" "$from" "$subject")
  fi

  # Dedup check (with flock)
  if is_processed_locked "$message_id"; then
    return 1  # signal dupe
  fi

  # Classify via LLM
  local classification
  classification=$(classify_email "$from" "$to" "$subject" "$date" "$body")

  if [ -z "$classification" ]; then
    log "  ERROR: Classification failed for: $subject"
    return 2  # signal error
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

  local priority="normal"
  if [ "$flag" = "true" ]; then priority="high"; fi
  if [ "$category" = "marketing" ]; then priority="low"; fi

  # Save raw email
  local raw_filename
  raw_filename=$(save_raw_email "$category" "$subject" "$from" "$to" "$cc" "$date" "$message_id" "$thread_id" "ms365" "$has_attach" "$body" "$priority")

  if [ -z "$raw_filename" ]; then
    log "  ERROR: Failed to save raw email: $subject"
    return 2
  fi

  # Append entity note
  append_entity_note "$category" "$entity" "$entity_slug" "$summary" "$key_facts" "$action_items" "$raw_filename"

  # Flag if needed
  if [ "$flag" = "true" ]; then
    append_flagged "$category" "$entity" "$flag_reason" "$raw_filename"
    log "  ${entity_slug} (${confidence}) → FLAGGED: ${flag_reason}"
    mark_processed_locked "$message_id"
    return 3  # signal flagged
  fi

  mark_processed_locked "$message_id"
  return 0  # signal success
}

# --- Update checkpoint ---
update_checkpoint() {
  local completed_date="$1"
  jq \
    --arg d "$completed_date" \
    --argjson p "$TOTAL_PROCESSED" \
    --argjson f "$TOTAL_FLAGGED" \
    --argjson e "$TOTAL_ERRORS" \
    '.last_completed_date = $d | .total_processed = $p | .total_flagged = $f | .total_errors = $e' \
    "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# --- Main loop: day by day ---
TOTAL_DUPES=0
DAYS_PROCESSED=0

while [ "$CURRENT_DATE" \< "$END_DATE" ] || [ "$CURRENT_DATE" = "$END_DATE" ]; do
  NEXT_DATE=$(date -u -d "$CURRENT_DATE + 1 day" +"%Y-%m-%d" 2>/dev/null || date -u -jf "%Y-%m-%d" -v+1d "$CURRENT_DATE" +"%Y-%m-%d")

  # Fetch emails for this day (using day start as since timestamp)
  day_emails=$("$FETCH" ms365 "${CURRENT_DATE}T00:00:00Z" 2>/dev/null || echo "[]")

  if [ "$day_emails" = "null" ] || [ -z "$day_emails" ]; then
    log "Day ${CURRENT_DATE}: fetch failed, skipping (will retry on re-run)"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    CURRENT_DATE="$NEXT_DATE"
    continue
  fi

  # Client-side date filter: keep only emails where date >= CURRENT_DATE and date < NEXT_DATE
  day_emails=$(echo "$day_emails" | jq --arg start "${CURRENT_DATE}T00:00:00Z" --arg end "${NEXT_DATE}T00:00:00Z" \
    '[.[] | select(.date >= $start and .date < $end)]')

  count=$(echo "$day_emails" | jq 'length')

  if [ "$count" -eq 0 ]; then
    update_checkpoint "$CURRENT_DATE"
    DAYS_PROCESSED=$((DAYS_PROCESSED + 1))
    CURRENT_DATE="$NEXT_DATE"
    continue
  fi

  day_processed=0
  day_flagged=0
  day_errors=0
  day_dupes=0

  for i in $(seq 0 $((count - 1))); do
    email_json=$(echo "$day_emails" | jq -c ".[$i]")

    set +e
    process_email "$email_json"
    result=$?
    set -e

    case $result in
      0) day_processed=$((day_processed + 1)); TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1)) ;;
      1) day_dupes=$((day_dupes + 1)); TOTAL_DUPES=$((TOTAL_DUPES + 1)) ;;
      2) day_errors=$((day_errors + 1)); TOTAL_ERRORS=$((TOTAL_ERRORS + 1)) ;;
      3) day_flagged=$((day_flagged + 1)); day_processed=$((day_processed + 1)); TOTAL_FLAGGED=$((TOTAL_FLAGGED + 1)); TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1)) ;;
    esac

    sleep 1  # Rate limit between LLM calls
  done

  log "Day ${CURRENT_DATE}: ${day_processed} processed, ${day_flagged} flagged, ${day_dupes} dupes, ${day_errors} errors"

  update_checkpoint "$CURRENT_DATE"
  DAYS_PROCESSED=$((DAYS_PROCESSED + 1))
  CURRENT_DATE="$NEXT_DATE"
done

# --- Seed triage-state.json if it doesn't exist yet ---
if [ ! -f "$TRIAGE_STATE_FILE" ]; then
  seed_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$TRIAGE_STATE_FILE" << TSEOF
{
  "ms365": { "last_processed": "${END_DATE}T23:59:59Z", "last_run": "${seed_ts}" },
  "gmail": { "last_processed": "${END_DATE}T23:59:59Z", "last_run": "" }
}
TSEOF
  log "Seeded triage-state.json (first deployment — live triage not yet run)"
fi

# --- Mark complete ---
jq '.status = "complete"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

log "COMPLETE: ${DAYS_PROCESSED} days, ${TOTAL_PROCESSED} processed, ${TOTAL_FLAGGED} flagged, ${TOTAL_DUPES} dupes, ${TOTAL_ERRORS} errors"
