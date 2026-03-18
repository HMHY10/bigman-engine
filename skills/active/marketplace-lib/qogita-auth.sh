#!/usr/bin/env bash
# marketplace-lib/qogita-auth.sh — Qogita JWT authentication
# Requires: config.sh sourced first

# ── qogita_login <role> ──────────────────────────────────────────────
# role: "seller" or "buyer" — determines which env vars to use
# Caches token at /tmp/qogita-<role>-token.json
# Re-logins if token is older than 50 minutes (tokens expire at 60 min)
qogita_login() {
  local role="$1"
  local token_file="/tmp/qogita-${role}-token.json"
  local max_age_secs=3000  # 50 minutes

  # Check existing token freshness
  if [[ -f "$token_file" ]]; then
    local mtime now age
    mtime=$(stat -c '%Y' "$token_file" 2>/dev/null || stat -f '%m' "$token_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))

    if (( age < max_age_secs )); then
      local cached_token
      cached_token=$(jq -r '.accessToken // empty' "$token_file" 2>/dev/null)
      if [[ -n "$cached_token" ]]; then
        log "qogita_login: ${role} token still fresh (${age}s old)"
        printf '%s' "$cached_token"
        return 0
      fi
    fi
    log "qogita_login: ${role} token expired (${age}s), re-authenticating"
  fi

  # Determine credentials from env
  local email password
  case "$role" in
    seller)
      email="${QOGITA_SELLER_EMAIL}"
      password="${QOGITA_SELLER_PASSWORD}"
      ;;
    buyer)
      email="${QOGITA_BUYER_EMAIL}"
      password="${QOGITA_BUYER_PASSWORD}"
      ;;
    *)
      log "qogita_login: unknown role '${role}'"
      return 1
      ;;
  esac

  if [[ -z "$email" || -z "$password" ]]; then
    log "qogita_login: missing credentials for role '${role}'"
    return 1
  fi

  # POST to login endpoint
  local payload response http_code body
  payload=$(jq -n --arg e "$email" --arg p "$password" '{email: $e, password: $p}')

  response=$(curl -sS -w '\n%{http_code}' \
    -X POST "${QOGITA_API_URL}/auth/login/" \
    -H "Content-Type: application/json" \
    -d "$payload")

  http_code=$(printf '%s' "$response" | tail -1)
  body=$(printf '%s' "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    log "qogita_login: ${role} login failed — HTTP ${http_code}"
    log "qogita_login: response: ${body}"
    return 1
  fi

  # Extract accessToken (NOT "access")
  local token
  token=$(printf '%s' "$body" | jq -r '.accessToken // empty')

  if [[ -z "$token" ]]; then
    log "qogita_login: ${role} — no accessToken in response"
    log "qogita_login: keys present: $(printf '%s' "$body" | jq -r 'keys | join(", ")')"
    return 1
  fi

  # Cache the full response
  printf '%s' "$body" > "$token_file"
  log "qogita_login: ${role} authenticated (token length: ${#token})"
  printf '%s' "$token"
  return 0
}

# ── qogita_request <role> <method> <path> [body] ────────────────────
# Make authenticated request to Qogita API.
# On 401: re-login once and retry.
# On 429: sleep and retry.
qogita_request() {
  local role="$1" method="$2" path="$3" body="${4:-}"
  local max_retries=2
  local attempt=0

  while (( attempt < max_retries )); do
    local token
    token=$(qogita_login "$role")
    if [[ -z "$token" ]]; then
      log "qogita_request: could not obtain token for ${role}"
      return 1
    fi

    local curl_args=(
      -sS -w '\n%{http_code}'
      -X "$method"
      "${QOGITA_API_URL}${path}"
      -H "Authorization: Bearer ${token}"
      -H "Content-Type: application/json"
    )

    if [[ -n "$body" ]]; then
      curl_args+=(-d "$body")
    fi

    local response http_code resp_body
    response=$(curl "${curl_args[@]}")
    http_code=$(printf '%s' "$response" | tail -1)
    resp_body=$(printf '%s' "$response" | sed '$d')

    # 401 Unauthorized — force re-login
    if [[ "$http_code" == "401" ]]; then
      attempt=$((attempt + 1))
      if (( attempt >= max_retries )); then
        log "qogita_request: ${method} ${path} — 401 after re-login, giving up"
        return 1
      fi
      log "qogita_request: ${method} ${path} — 401, forcing re-login"
      rm -f "/tmp/qogita-${role}-token.json"
      continue
    fi

    # 429 Too Many Requests — back off
    if [[ "$http_code" == "429" ]]; then
      attempt=$((attempt + 1))
      if (( attempt >= max_retries )); then
        log "qogita_request: ${method} ${path} — 429 after retry, giving up"
        return 1
      fi
      log "qogita_request: ${method} ${path} — 429, sleeping 30s"
      sleep 30
      continue
    fi

    # Any other error
    if [[ "$http_code" =~ ^[45][0-9]{2}$ ]]; then
      log "qogita_request: ${method} ${path} — HTTP ${http_code}"
      printf '%s' "$resp_body"
      return 1
    fi

    # Success
    printf '%s' "$resp_body"
    return 0
  done

  return 1
}
