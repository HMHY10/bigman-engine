import { createHash, timingSafeEqual } from 'crypto';
import { createJob } from '../lib/tools/create-job.js';
import { setWebhook } from '../lib/tools/telegram.js';
import { githubApi, getJobStatus, fetchJobLog } from '../lib/tools/github.js';
import { getTelegramAdapter } from '../lib/channels/index.js';
import { chat, summarizeJob } from '../lib/ai/index.js';
import { createNotification } from '../lib/db/notifications.js';
import { loadTriggers } from '../lib/triggers.js';
import { verifyApiKey } from '../lib/db/api-keys.js';
import { getConfig } from '../lib/config.js';

// Bot token — resolved from DB/env, can be overridden by /telegram/register
let telegramBotToken = null;

// Cached trigger firing function (initialized on first request)
let _fireTriggers = null;

function getTelegramBotToken() {
  if (!telegramBotToken) {
    telegramBotToken = getConfig('TELEGRAM_BOT_TOKEN') || null;
  }
  return telegramBotToken;
}

function getFireTriggers() {
  if (!_fireTriggers) {
    const result = loadTriggers();
    _fireTriggers = result.fireTriggers;
  }
  return _fireTriggers;
}

// Routes that have their own authentication
const PUBLIC_ROUTES = ['/telegram/webhook', '/github/webhook', '/vault-sync', '/ping'];

/**
 * Timing-safe string comparison.
 * @param {string} a
 * @param {string} b
 * @returns {boolean}
 */
function safeCompare(a, b) {
  if (!a || !b) return false;
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return timingSafeEqual(bufA, bufB);
}

/**
 * Centralized auth gate for all API routes.
 * Public routes pass through; everything else requires a valid API key from the database.
 * @param {string} routePath - The route path
 * @param {Request} request - The incoming request
 * @returns {Response|null} - Error response or null if authorized
 */
function checkAuth(routePath, request) {
  if (PUBLIC_ROUTES.includes(routePath)) return null;

  const apiKey = request.headers.get('x-api-key');
  if (!apiKey) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const record = verifyApiKey(apiKey);
  if (!record) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 });
  }

  return null;
}

/**
 * Extract job ID from branch name (e.g., "job/abc123" -> "abc123")
 */
function extractJobId(branchName) {
  if (!branchName || !branchName.startsWith('job/')) return null;
  return branchName.slice(4);
}

// ─────────────────────────────────────────────────────────────────────────────
// Route handlers
// ─────────────────────────────────────────────────────────────────────────────

async function handleWebhook(request) {
  const body = await request.json();
  const { job } = body;
  if (!job) return Response.json({ error: 'Missing job field' }, { status: 400 });

  try {
    const result = await createJob(job);
    return Response.json(result);
  } catch (err) {
    console.error(err);
    return Response.json({ error: 'Failed to create job' }, { status: 500 });
  }
}

async function handleTelegramRegister(request) {
  const body = await request.json();
  const { bot_token, webhook_url } = body;
  if (!bot_token || !webhook_url) {
    return Response.json({ error: 'Missing bot_token or webhook_url' }, { status: 400 });
  }

  try {
    const result = await setWebhook(bot_token, webhook_url, getConfig('TELEGRAM_WEBHOOK_SECRET'));
    telegramBotToken = bot_token;
    return Response.json({ success: true, result });
  } catch (err) {
    console.error(err);
    return Response.json({ error: 'Failed to register webhook' }, { status: 500 });
  }
}

async function handleTelegramWebhook(request) {
  const botToken = getTelegramBotToken();
  if (!botToken) return Response.json({ ok: true });

  const adapter = getTelegramAdapter(botToken);
  const normalized = await adapter.receive(request);
  if (!normalized) return Response.json({ ok: true });

  // Process message asynchronously (don't block the webhook response)
  processChannelMessage(adapter, normalized).catch((err) => {
    console.error('Failed to process message:', err);
  });

  return Response.json({ ok: true });
}

/**
 * Process a normalized message through the AI layer with channel UX.
 * Message persistence is handled centrally by the AI layer.
 */
async function processChannelMessage(adapter, normalized) {
  await adapter.acknowledge(normalized.metadata);
  const stopIndicator = adapter.startProcessingIndicator(normalized.metadata);

  try {
    const response = await chat(
      normalized.threadId,
      normalized.text,
      normalized.attachments,
      { userId: 'telegram', chatTitle: 'Telegram' }
    );
    await adapter.sendResponse(normalized.threadId, response, normalized.metadata);
  } catch (err) {
    console.error('Failed to process message with AI:', err);
    await adapter
      .sendResponse(
        normalized.threadId,
        'Sorry, I encountered an error processing your message.',
        normalized.metadata
      )
      .catch(() => {});
  } finally {
    stopIndicator();
  }
}

async function handleGithubWebhook(request) {
  const GH_WEBHOOK_SECRET = getConfig('GH_WEBHOOK_SECRET');

  // Validate webhook secret (timing-safe, required)
  if (!GH_WEBHOOK_SECRET || !safeCompare(request.headers.get('x-github-webhook-secret-token'), GH_WEBHOOK_SECRET)) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const payload = await request.json();
  const jobId = payload.job_id || extractJobId(payload.branch);
  if (!jobId) return Response.json({ ok: true, skipped: true, reason: 'not a job' });

  try {
    // Fetch log from repo via API (no longer sent in payload)
    let log = payload.log || '';
    if (!log) {
      log = await fetchJobLog(jobId, payload.commit_sha);
    }

    const results = {
      job: payload.job || '',
      pr_url: payload.pr_url || payload.run_url || '',
      run_url: payload.run_url || '',
      status: payload.status || '',
      merge_result: payload.merge_result || '',
      log,
      changed_files: payload.changed_files || [],
      commit_message: payload.commit_message || '',
    };

    const message = await summarizeJob(results);
    await createNotification(message, payload);

    console.log(`Notification saved for job ${jobId.slice(0, 8)}`);

    return Response.json({ ok: true, notified: true });
  } catch (err) {
    console.error('Failed to process GitHub webhook:', err);
    return Response.json({ error: 'Failed to process webhook' }, { status: 500 });
  }
}

// System files in job logs — NOT synced to vault
const VAULT_SKIP_FILES = new Set([
  'claude-session.jsonl', 'claude-stderr.log', 'system-prompt.md', 'job.config.json',
]);

/**
 * Sync job output files from GitHub to Obsidian vault.
 * Reads .md outputs from the job log directory and writes to vault via REST API.
 * Vault path: checks for `vault-path:` in YAML frontmatter, else `05-Agent-Outputs/{filename}`.
 */
async function handleVaultSync(request) {
  // Auth: validate WEBHOOK_SECRET (same pattern as GitHub webhook)
  const WEBHOOK_SECRET = getConfig('WEBHOOK_SECRET');
  if (!WEBHOOK_SECRET || !safeCompare(request.headers.get('x-webhook-secret'), WEBHOOK_SECRET)) {
    return Response.json({ error: 'Unauthorized' }, { status: 401 });
  }

  const body = await request.json();
  const { job_id, commit_sha } = body;

  if (!job_id || !commit_sha) {
    return Response.json({ error: 'Missing job_id or commit_sha' }, { status: 400 });
  }

  const { GH_OWNER, GH_REPO } = process.env;
  const OBSIDIAN_HOST = getConfig('OBSIDIAN_HOST');
  const OBSIDIAN_API_KEY = getConfig('OBSIDIAN_API_KEY');

  if (!OBSIDIAN_HOST || !OBSIDIAN_API_KEY) {
    return Response.json({ error: 'Obsidian not configured' }, { status: 500 });
  }

  try {
    const files = await githubApi(
      `/repos/${GH_OWNER}/${GH_REPO}/contents/logs/${job_id}?ref=${encodeURIComponent(commit_sha)}`
    );

    if (!Array.isArray(files)) {
      return Response.json({ ok: true, synced: 0, reason: 'no log directory' });
    }

    const outputFiles = files.filter(f => f.name.endsWith('.md') && !VAULT_SKIP_FILES.has(f.name));
    if (outputFiles.length === 0) {
      return Response.json({ ok: true, synced: 0, reason: 'no output files' });
    }

    const synced = [];
    for (const file of outputFiles) {
      const fileData = await githubApi(
        `/repos/${GH_OWNER}/${GH_REPO}/contents/logs/${job_id}/${file.name}?ref=${encodeURIComponent(commit_sha)}`
      );
      const content = Buffer.from(fileData.content, 'base64').toString('utf-8');

      // Check frontmatter for explicit vault path
      let vaultPath = `05-Agent-Outputs/${file.name}`;
      const match = content.match(/^---\n[\s\S]*?vault-path:\s*(.+)\n[\s\S]*?---/);
      if (match) vaultPath = match[1].trim();

      const res = await fetch(`${OBSIDIAN_HOST}/vault/${vaultPath}`, {
        method: 'PUT',
        headers: { 'Authorization': `Bearer ${OBSIDIAN_API_KEY}`, 'Content-Type': 'text/markdown' },
        body: content,
      });

      if (res.ok || res.status === 204) {
        synced.push({ file: file.name, vault_path: vaultPath });
        console.log(`[vault-sync] ${file.name} → ${vaultPath}`);
      } else {
        console.error(`[vault-sync] Failed: ${vaultPath} HTTP ${res.status}`);
      }
    }

    console.log(`[vault-sync] Job ${job_id.slice(0, 8)}: ${synced.length}/${outputFiles.length} files`);
    return Response.json({ ok: true, synced: synced.length, files: synced });
  } catch (err) {
    console.error('[vault-sync] Error:', err.message);
    return Response.json({ error: 'Vault sync failed' }, { status: 500 });
  }
}

async function handleJobStatus(request) {
  try {
    const url = new URL(request.url);
    const jobId = url.searchParams.get('job_id');
    const result = await getJobStatus(jobId);
    return Response.json(result);
  } catch (err) {
    console.error('Failed to get job status:', err);
    return Response.json({ error: 'Failed to get job status' }, { status: 500 });
  }
}

/**
 * POST /api/orders/ingest
 * Receive one or more orders from an external system (Shopify, WooCommerce, etc.).
 * Body: { orders: [{externalId, source, customerName, customerAddress, lineItems, notes, receivedAt}] }
 * OR a single order object (for simple webhook integrations).
 * After ingesting, triggers auto-batch check if >= 25 pending orders.
 */
async function handleOrderIngest(request) {
  const body = await request.json().catch(() => null);
  if (!body) return Response.json({ error: 'Invalid JSON' }, { status: 400 });

  const { createOrder, countPendingOrders } = await import('../lib/db/orders.js');
  const { runAutoBatch } = await import('../lib/picklist/batcher.js');

  // Support both single order and array
  const incoming = Array.isArray(body.orders) ? body.orders : [body];
  const created = [];

  for (const orderData of incoming) {
    if (!orderData || typeof orderData !== 'object') continue;
    // Dedup by externalId if provided
    if (orderData.externalId) {
      const { getOrderByExternalId } = await import('../lib/db/orders.js');
      const existing = getOrderByExternalId(orderData.externalId);
      if (existing) {
        created.push({ id: existing.id, externalId: existing.externalId, skipped: true });
        continue;
      }
    }
    const order = createOrder(orderData);
    created.push({ id: order.id, externalId: order.externalId });
  }

  // Check if we should auto-batch (daytime: >= 25 pending)
  const pendingCount = countPendingOrders();
  let autoBatched = null;
  if (pendingCount >= 25) {
    autoBatched = await runAutoBatch();
  }

  return Response.json({
    ok: true,
    created: created.length,
    orders: created,
    autoBatched: autoBatched ? { picklistId: autoBatched.id, orderCount: autoBatched.orderCount } : null,
  });
}

/**
 * POST /api/picklists/scan
 * Called when a picker scans the QR code on a picklist after returning to packing.
 * Body: { picklistId }
 * Marks the picklist as completed, updates order statuses to 'picked',
 * and returns shipping label data for each order.
 */
async function handlePicklistScan(request) {
  const body = await request.json().catch(() => null);
  if (!body?.picklistId) {
    return Response.json({ error: 'Missing picklistId' }, { status: 400 });
  }

  const { getPicklistById, updatePicklistStatus } = await import('../lib/db/picklists.js');
  const { updateOrdersStatus, getOrderById } = await import('../lib/db/orders.js');

  const pl = getPicklistById(body.picklistId);
  if (!pl) {
    return Response.json({ error: 'Picklist not found' }, { status: 404 });
  }
  if (pl.status === 'completed') {
    return Response.json({ ok: true, alreadyCompleted: true });
  }

  // Mark orders as picked
  updateOrdersStatus(pl.orderIds, 'picked');
  updatePicklistStatus(pl.id, 'completed', { completedAt: Date.now() });

  // Return order details for shipping label printing
  const orders = pl.orderIds.map((id) => getOrderById(id)).filter(Boolean);
  const shippingLabels = orders.map((o) => ({
    orderId: o.id,
    externalId: o.externalId,
    customerName: o.customerName,
    customerAddress: o.customerAddress,
    lineItems: o.lineItems,
  }));

  console.log(`[picklist] Scan complete: ${pl.id.slice(0, 8)} → ${orders.length} labels`);

  return Response.json({
    ok: true,
    picklistId: pl.id,
    orderCount: orders.length,
    shippingLabels,
    // The caller (warehouse scanner app / label printer) should use this data
    // to print shipping labels via their own label printing integration.
    printLabelsUrl: `/warehouse/picklists/${pl.id}/labels`,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Next.js Route Handlers (catch-all)
// ─────────────────────────────────────────────────────────────────────────────

async function POST(request) {
  const url = new URL(request.url);
  const routePath = url.pathname.replace(/^\/api/, '');

  // Auth check
  const authError = checkAuth(routePath, request);
  if (authError) return authError;

  // Fire triggers (non-blocking)
  try {
    const fireTriggers = getFireTriggers();
    // Clone request to read body for triggers without consuming it for the handler
    const clonedRequest = request.clone();
    const body = await clonedRequest.json().catch(() => ({}));
    const query = Object.fromEntries(url.searchParams);
    const headers = Object.fromEntries(request.headers);
    fireTriggers(routePath, body, query, headers);
  } catch (e) {
    // Trigger errors are non-fatal
  }

  // Cluster role webhooks
  const clusterMatch = routePath.match(/^\/cluster\/([a-f0-9-]+)\/role\/([a-f0-9-]+)\/webhook$/);
  if (clusterMatch) {
    const { handleClusterWebhook } = await import('../lib/cluster/runtime.js');
    return handleClusterWebhook(clusterMatch[1], clusterMatch[2], request);
  }

  // Route to handler
  switch (routePath) {
    case '/create-job':          return handleWebhook(request);
    case '/vault-sync':          return handleVaultSync(request);
    case '/telegram/webhook':   return handleTelegramWebhook(request);
    case '/telegram/register':  return handleTelegramRegister(request);
    case '/github/webhook':     return handleGithubWebhook(request);
    case '/orders/ingest':      return handleOrderIngest(request);
    case '/picklists/scan':     return handlePicklistScan(request);
    default:                    return Response.json({ error: 'Not found' }, { status: 404 });
  }
}

async function GET(request) {
  const url = new URL(request.url);
  const routePath = url.pathname.replace(/^\/api/, '');

  // Auth check
  const authError = checkAuth(routePath, request);
  if (authError) return authError;

  switch (routePath) {
    case '/ping':           return Response.json({ message: 'Pong!' });
    case '/jobs/status':    return handleJobStatus(request);
    default:                return Response.json({ error: 'Not found' }, { status: 404 });
  }
}

export { GET, POST };
