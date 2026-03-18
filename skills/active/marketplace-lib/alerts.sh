#!/usr/bin/env bash
# marketplace-lib/alerts.sh — Vault alerting with severity routing
# Requires: config.sh sourced first

# ── alert_create <severity> <marketplace> <category> <title> <body> ───
# severity: info | high | critical
# category: vault subfolder under 07-Marketplace (e.g. "Finance/Alerts")
# Creates a vault note with YAML frontmatter. Routes high/critical to email.
alert_create() {
  local severity="$1" marketplace="$2" category="$3" title="$4" body="$5"
  local date_now
  date_now=$(date -u '+%Y-%m-%d')
  local ts
  ts=$(date -u '+%Y%m%d-%H%M%S')
  local safe_title
  safe_title=$(printf '%s' "$title" | tr ' /' '-' | tr -cd '[:alnum:]-_')
  local filename="${ts}-${safe_title}.md"
  local vault_path="07-Marketplace/${category}/${filename}"

  # Build note content with YAML frontmatter
  local content
  content=$(cat <<NOTEEOF
---
source: marketplace-ops
marketplace: ${marketplace}
severity: ${severity}
date: ${date_now}
status: open
created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
---

# ${title}

${body}
NOTEEOF
)

  # Write to vault via Obsidian REST API
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$content")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "alert_create: [${severity}] ${vault_path} — OK"
  else
    log "alert_create: [${severity}] ${vault_path} — HTTP ${http_code}"
    return 1
  fi

  # Route high/critical to email flagged folder
  if [[ "$severity" == "high" || "$severity" == "critical" ]]; then
    _alert_send_email "$severity" "$marketplace" "$title" "$body"
  fi

  return 0
}

# ── alert_resolve <note_path> ─────────────────────────────────────────
# Update an existing alert note's status from open to resolved.
alert_resolve() {
  local note_path="$1"

  # Fetch current content
  local current
  current=$(curl -sS \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Accept: text/markdown" \
    "${VAULT_URL}/vault/${note_path}")

  if [[ -z "$current" ]]; then
    log "alert_resolve: could not fetch ${note_path}"
    return 1
  fi

  # Replace status in frontmatter
  local updated
  updated=$(printf '%s' "$current" | sed 's/^status: open$/status: resolved/')

  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${note_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$updated")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "alert_resolve: ${note_path} — resolved"
  else
    log "alert_resolve: ${note_path} — HTTP ${http_code}"
    return 1
  fi
}

# ── vault_write <vault_path> <content> ────────────────────────────────
# Write arbitrary content to the vault. Returns 0 on success, 1 on failure.
vault_write() {
  local vault_path="$1" content="$2"
  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$content")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "vault_write: ${vault_path} — OK"
    return 0
  else
    log "vault_write: ${vault_path} — HTTP ${http_code}"
    return 1
  fi
}

# ── _alert_send_email <severity> <marketplace> <title> <body> ─────────
# Write alert to 09-Email/Flagged/ for email visibility.
_alert_send_email() {
  local severity="$1" marketplace="$2" title="$3" body="$4"
  local ts
  ts=$(date -u '+%Y%m%d-%H%M%S')
  local safe_title
  safe_title=$(printf '%s' "$title" | tr ' /' '-' | tr -cd '[:alnum:]-_')
  local filename="${ts}-${safe_title}.md"
  local vault_path="09-Email/Flagged/${filename}"

  local content
  content=$(cat <<EMAILEOF
---
source: marketplace-ops
marketplace: ${marketplace}
severity: ${severity}
date: $(date -u '+%Y-%m-%d')
type: alert-email
---

# [${severity^^}] ${title}

**Marketplace:** ${marketplace}
**Severity:** ${severity}
**Time:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

${body}
EMAILEOF
)

  local http_code
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${VAULT_URL}/vault/${vault_path}" \
    -H "Authorization: Bearer ${OBSIDIAN_API_KEY}" \
    -H "Content-Type: text/markdown" \
    -d "$content")

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    log "alert_email: [${severity}] ${vault_path} — sent"
  else
    log "alert_email: [${severity}] ${vault_path} — HTTP ${http_code}"
  fi
}
