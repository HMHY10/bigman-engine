---
name: email-triage
description: Classify and triage incoming emails from MS365 and Gmail into categorised intelligence notes in the Obsidian vault. Runs on a 15-minute cron schedule on the VPS. Use when asked to check emails, triage inbox, or process new messages.
---

# Email Triage

Polls MS365 and Gmail for new emails, classifies them using LLM, saves raw emails to the vault archive, and maintains living intelligence notes per entity (supplier, customer, product, etc.).

## How It Works

This skill runs automatically via cron every 15 minutes. It can also be triggered manually.

### Automatic (Cron)
Every 15 minutes, triage.sh runs on the VPS:
1. Fetches new emails from MS365 and Gmail since last run
2. Classifies each email (category, entity, summary, key facts, action items)
3. Saves raw email to 10-Email-Raw/
4. Appends intelligence summary to entity note in 09-Email/{Category}/
5. Flags uncertain/urgent emails to 09-Email/Flagged/Action-Required.md

### Manual Trigger
```bash
cd /opt/bigman-engine && doppler run --project shared-services --config prd -- ./skills/active/email-triage/triage.sh
```

Safe to run anytime — idempotent (won't reprocess already-triaged emails).

## Vault Output Structure

### Raw Emails — 10-Email-Raw/
Full email content with YAML frontmatter (date, from, to, subject, message-id, category, etc.).
Filename: YYYY-MM-DD-{category}-{subject-slug}.md

### Entity Intelligence — 09-Email/{Category}/
Living notes per entity (company, person, product). Each new email appends a dated summary block with key facts, action items, and a link to the raw email.

Categories: Suppliers, Customers, Orders, Products, Marketing, Partnerships, Finance, Internal

### Flagged — 09-Email/Flagged/Action-Required.md
Emails needing human attention: low-confidence classification, urgent deadlines, anomalies.

## Configuration

### Email Providers
- MS365: Microsoft Graph API (Inbox only)
- Gmail: Gmail API (excludes spam, trash, promotions, social)

### Secrets (Doppler shared-services)
MS365_CLIENT_ID, MS365_CLIENT_SECRET, MS365_TENANT_ID, MS365_REFRESH_TOKEN,
GMAIL_CLIENT_ID, GMAIL_CLIENT_SECRET, GMAIL_REFRESH_TOKEN, ANTHROPIC_API_KEY

### State Files (on VPS, not in vault)
- triage-state.json — last-processed timestamps per provider
- processed-ids.txt — message-id index for deduplication

## Important Rules

- All entity notes use Obsidian wiki-links [[path/to/note]] for cross-references
- Raw emails are write-once — never modified after creation
- Entity notes are append-only — never delete existing entries
- Entity notes roll over at 50KB with continuation links
- Classification uses Claude Haiku (fast, cheap, deterministic)
- Body is truncated to 2000 chars for classification (full body in raw email)
