# /api — External API Routes

This directory contains the route handlers for all `/api/*` endpoints. These routes are for **external callers only** — GitHub Actions, Telegram, cURL, third-party webhooks.

## Auth

All routes (except `/telegram/webhook` and `/github/webhook`, which use their own webhook secrets) require a valid API key passed via the `x-api-key` header. API keys are stored in the SQLite database and managed through the admin UI — they are NOT environment variables.

Auth flow: `x-api-key` header -> `verifyApiKey()` -> database lookup (hashed, timing-safe comparison).

## Do NOT use these routes for browser UI

Browser-facing features must use **Server Actions** (`'use server'` functions) with `requireAuth()` session checks — never `/api` fetch calls. The only exception is chat streaming, which has its own dedicated route at `/stream/chat` with session auth.

| Caller | Mechanism | Auth |
|--------|-----------|------|
| External (cURL, GitHub Actions, Telegram) | `/api` route | `x-api-key` header |
| Browser UI (data/mutations) | Server Action | `requireAuth()` session |
| Browser UI (chat streaming) | `/stream/chat` | `auth()` session |

## Routes

| Method | Path | Auth | Handler |
|--------|------|------|---------|
| GET | `/api/ping` | None | Health check |
| POST | `/api/create-job` | `x-api-key` | Create agent job |
| GET | `/api/jobs/status` | `x-api-key` | Job status (query: `?job_id=`) |
| POST | `/api/telegram/webhook` | Telegram webhook secret | Telegram message handler |
| POST | `/api/telegram/register` | `x-api-key` | Register bot token + webhook URL |
| POST | `/api/github/webhook` | GitHub webhook secret | GitHub event handler |
| POST | `/api/cluster/:clusterId/role/:roleId/webhook` | `x-api-key` | Trigger cluster role execution |
| POST | `/api/orders` | `x-api-key` | Import orders (single object or array); required fields: `orderNumber`, `sku`, `productName` |
| GET | `/api/picklist/scan` | None (public, ID-secured) | Scanner endpoint — marks picklist completed and fires `picklist-scan-shipping-label` trigger |
