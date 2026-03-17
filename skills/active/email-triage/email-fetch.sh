#!/usr/bin/env bash
# email-fetch.sh — Fetches emails from MS365 or Gmail since a given timestamp.
# Outputs a JSON array of emails in a common format to stdout.
# EXIT CODE: 0 on success (even if 0 emails), 1 on auth failure.
#
# Usage: email-fetch.sh <ms365|gmail> <iso8601-timestamp>

PROVIDER="${1:?Usage: email-fetch.sh <ms365|gmail> <iso8601-timestamp>}"
SINCE="${2:?Missing timestamp argument}"

# --- MS365 ---
fetch_ms365() {
  local token_response
  token_response=$(curl -sf -X POST \
    "https://login.microsoftonline.com/${MS365_TENANT_ID}/oauth2/v2.0/token" \
    -d "client_id=${MS365_CLIENT_ID}" \
    -d "client_secret=${MS365_CLIENT_SECRET}" \
    -d "refresh_token=${MS365_REFRESH_TOKEN}" \
    -d "grant_type=refresh_token" \
    -d "scope=https://graph.microsoft.com/.default")

  local access_token
  access_token=$(echo "$token_response" | jq -r '.access_token // empty')
  if [ -z "$access_token" ]; then
    echo "[email-fetch] ERROR: MS365 token refresh failed" >&2
    return 1
  fi

  local filter="receivedDateTime gt ${SINCE}"
  local select="subject,from,toRecipients,ccRecipients,body,receivedDateTime,internetMessageId,conversationId,hasAttachments"
  local all_emails="[]"

  # First request uses --data-urlencode for proper encoding
  local response
  response=$(curl -s -G "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages" \
    --data-urlencode "\$filter=$filter" \
    --data-urlencode "\$select=$select" \
    --data-urlencode "\$top=50" \
    --data-urlencode "\$orderby=receivedDateTime asc" \
    -H "Authorization: Bearer $access_token")

  if [ -z "$response" ]; then
    echo "[email-fetch] ERROR: MS365 API call failed" >&2
    return 1
  fi

  # Check for API error
  local api_error
  api_error=$(echo "$response" | jq -r '.error.message // empty')
  if [ -n "$api_error" ]; then
    echo "[email-fetch] ERROR: MS365 API: $api_error" >&2
    return 1
  fi

  # Transform and collect
  local page_emails
  page_emails=$(echo "$response" | jq '[(.value // [])[] | {
    subject: .subject,
    from: .from.emailAddress.address,
    to: ([.toRecipients[]?.emailAddress.address] | join(", ")),
    cc: ([.ccRecipients[]?.emailAddress.address] | join(", ")),
    body: (.body.content // "" | .[0:2000]),
    date: .receivedDateTime,
    message_id: .internetMessageId,
    thread_id: .conversationId,
    provider: "ms365",
    has_attachments: .hasAttachments
  }]')

  all_emails=$(echo "$all_emails" "$page_emails" | jq -s '.[0] + .[1]')

  # Handle pagination
  local next_url
  next_url=$(echo "$response" | jq -r '."@odata.nextLink" // empty')
  while [ -n "$next_url" ]; do
    response=$(curl -s "$next_url" -H "Authorization: Bearer $access_token")
    page_emails=$(echo "$response" | jq '[(.value // [])[] | {
      subject: .subject,
      from: .from.emailAddress.address,
      to: ([.toRecipients[]?.emailAddress.address] | join(", ")),
      cc: ([.ccRecipients[]?.emailAddress.address] | join(", ")),
      body: (.body.content // "" | .[0:2000]),
      date: .receivedDateTime,
      message_id: .internetMessageId,
      thread_id: .conversationId,
      provider: "ms365",
      has_attachments: .hasAttachments
    }]')
    all_emails=$(echo "$all_emails" "$page_emails" | jq -s '.[0] + .[1]')
    next_url=$(echo "$response" | jq -r '."@odata.nextLink" // empty')
  done

  echo "$all_emails"
}

# --- Gmail ---
fetch_gmail() {
  local token_response
  token_response=$(curl -sf -X POST "https://oauth2.googleapis.com/token" \
    -d "client_id=${GMAIL_CLIENT_ID}" \
    -d "client_secret=${GMAIL_CLIENT_SECRET}" \
    -d "refresh_token=${GMAIL_REFRESH_TOKEN}" \
    -d "grant_type=refresh_token")

  local access_token
  access_token=$(echo "$token_response" | jq -r '.access_token // empty')
  if [ -z "$access_token" ]; then
    echo "[email-fetch] ERROR: Gmail token refresh failed" >&2
    return 1
  fi

  # Check for new refresh token (Gmail sometimes rotates)
  local new_refresh
  new_refresh=$(echo "$token_response" | jq -r '.refresh_token // empty')
  if [ -n "$new_refresh" ] && [ "$new_refresh" != "$GMAIL_REFRESH_TOKEN" ]; then
    echo "[email-fetch] Gmail issued new refresh token, updating Doppler..." >&2
    doppler secrets set "GMAIL_REFRESH_TOKEN=${new_refresh}" --project shared-services --config prd 2>/dev/null
  fi

  # Convert ISO 8601 to epoch seconds for Gmail query
  local epoch_since
  epoch_since=$(date -d "$SINCE" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$SINCE" +%s 2>/dev/null)
  if [ -z "$epoch_since" ]; then
    echo "[email-fetch] ERROR: Could not convert timestamp: $SINCE" >&2
    return 1
  fi

  # List message IDs matching query
  local query="after:${epoch_since} -in:spam -in:trash -category:promotions -category:social"
  local list_response
  list_response=$(curl -sf -G "https://gmail.googleapis.com/gmail/v1/users/me/messages" \
    --data-urlencode "q=${query}" \
    -H "Authorization: Bearer $access_token")

  local message_ids
  message_ids=$(echo "$list_response" | jq -r '.messages[]?.id // empty')

  if [ -z "$message_ids" ]; then
    echo "[]"
    return 0
  fi

  # Fetch each message
  local all_emails="[]"
  while IFS= read -r msg_id; do
    [ -z "$msg_id" ] && continue

    local msg
    msg=$(curl -sf "https://gmail.googleapis.com/gmail/v1/users/me/messages/${msg_id}?format=full" \
      -H "Authorization: Bearer $access_token")

    local subject from_addr to_addr cc_addr date_val msg_id_header thread_id has_attach
    subject=$(echo "$msg" | jq -r '[.payload.headers[] | select(.name=="Subject")] | .[0].value // "(no subject)"')
    from_addr=$(echo "$msg" | jq -r '[.payload.headers[] | select(.name=="From")] | .[0].value // "unknown"')
    to_addr=$(echo "$msg" | jq -r '[.payload.headers[] | select(.name=="To")] | .[0].value // ""')
    cc_addr=$(echo "$msg" | jq -r '[.payload.headers[] | select(.name=="Cc")] | .[0].value // ""')
    date_val=$(echo "$msg" | jq -r '[.payload.headers[] | select(.name=="Date")] | .[0].value // ""')
    msg_id_header=$(echo "$msg" | jq -r '[.payload.headers[] | select(.name=="Message-ID" or .name=="Message-Id")] | .[0].value // ""')
    thread_id=$(echo "$msg" | jq -r '.threadId // ""')
    has_attach=$(echo "$msg" | jq '[.payload.parts[]? | select(.filename != "" and .filename != null)] | length > 0')

    # Extract body (prefer plain text, fall back to snippet)
    local body
    body=$(echo "$msg" | jq -r '
      def decode_body: .data // "" | gsub("-";"+") | gsub("_";"/") | @base64d;
      if .payload.parts then
        [.payload.parts[] | select(.mimeType=="text/plain")] | .[0].body | decode_body
      elif .payload.body.data then
        .payload.body | decode_body
      else
        .snippet // ""
      end' 2>/dev/null | head -c 2000)

    if [ -z "$body" ]; then
      body=$(echo "$msg" | jq -r '.snippet // ""')
    fi

    # Convert date to ISO 8601
    local iso_date
    iso_date=$(date -d "$date_val" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$date_val")

    # Clean from address (extract email from "Name <email>" format)
    local clean_from
    clean_from=$(echo "$from_addr" | grep -o '<[^>]*>' | tr -d '<>' 2>/dev/null)
    [ -z "$clean_from" ] && clean_from="$from_addr"

    local email_json
    email_json=$(jq -n \
      --arg subject "$subject" \
      --arg from "$clean_from" \
      --arg to "$to_addr" \
      --arg cc "$cc_addr" \
      --arg body "$body" \
      --arg date "$iso_date" \
      --arg message_id "$msg_id_header" \
      --arg thread_id "$thread_id" \
      --argjson has_attachments "$has_attach" \
      '{subject:$subject,from:$from,to:$to,cc:$cc,body:$body,date:$date,message_id:$message_id,thread_id:$thread_id,provider:"gmail",has_attachments:$has_attachments}')

    all_emails=$(echo "$all_emails" | jq --argjson e "$email_json" '. + [$e]')
  done <<< "$message_ids"

  echo "$all_emails"
}

# --- Main ---
case "$PROVIDER" in
  ms365) fetch_ms365 ;;
  gmail) fetch_gmail ;;
  *) echo "[email-fetch] Unknown provider: $PROVIDER. Use ms365 or gmail." >&2; exit 1 ;;
esac
