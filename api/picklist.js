import { execFile } from 'child_process';
import { promisify } from 'util';
import { existsSync } from 'fs';
import { getConfig } from '../lib/config.js';

const execFileAsync = promisify(execFile);

// Path to picklist trigger script (resolved from SKILLS_PATH or default)
function getTriggerScript() {
  const base = getConfig('SKILLS_PATH') || '/app/skills/active';
  return `${base}/picklist-ops/trigger.sh`;
}

// Doppler run prefix if DOPPLER_PROJECT is set
function getDopplerPrefix() {
  const project = getConfig('DOPPLER_PROJECT') || 'shared-services';
  const config = getConfig('DOPPLER_CONFIG') || 'prd';
  // Only use doppler if it's available and project is configured
  if (!project || project === 'shared-services') {
    try {
      // Check if doppler binary exists by trying which
      return ['doppler', 'run', `-p`, project, `-c`, config, '--'];
    } catch {
      return [];
    }
  }
  return [];
}

/**
 * Run the picklist trigger.sh script with given arguments.
 * Returns { success, stdout, stderr }.
 */
async function runTrigger(args = []) {
  const script = getTriggerScript();

  if (!existsSync(script)) {
    return { success: false, error: `Trigger script not found: ${script}` };
  }

  const prefix = getDopplerPrefix();
  const cmd = prefix.length > 0 ? prefix[0] : '/usr/bin/env';
  const cmdArgs = prefix.length > 0
    ? [...prefix.slice(1), script, ...args]
    : ['bash', script, ...args];

  try {
    const { stdout, stderr } = await execFileAsync(cmd, cmdArgs, {
      timeout: 120_000, // 2 minutes
      maxBuffer: 4 * 1024 * 1024,
    });
    return { success: true, stdout, stderr };
  } catch (err) {
    return {
      success: false,
      error: err.message,
      stdout: err.stdout || '',
      stderr: err.stderr || '',
    };
  }
}

/**
 * POST /api/picklist/print-next-25
 * Prints the next batch of up to 25 ready orders.
 * Body: {} (no payload required)
 */
export async function handlePrintNext25(_request) {
  const result = await runTrigger(['next-25']);

  if (!result.success) {
    console.error('[picklist] print-next-25 failed:', result.error, result.stderr);
    return Response.json(
      { error: 'Picklist trigger failed', detail: result.error },
      { status: 500 }
    );
  }

  return Response.json({
    ok: true,
    message: 'Print next 25 triggered',
    log: result.stdout,
  });
}

/**
 * POST /api/picklist/print-selected
 * Prints a specific set of orders.
 * Body: { order_ids: ["12345", "12346", ...] }
 */
export async function handlePrintSelected(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: 'Invalid JSON body' }, { status: 400 });
  }

  const { order_ids } = body;
  if (!Array.isArray(order_ids) || order_ids.length === 0) {
    return Response.json(
      { error: 'Missing or empty order_ids array' },
      { status: 400 }
    );
  }

  const idsJson = JSON.stringify(order_ids.map(String));
  const result = await runTrigger(['selected', idsJson]);

  if (!result.success) {
    console.error('[picklist] print-selected failed:', result.error, result.stderr);
    return Response.json(
      { error: 'Picklist trigger failed', detail: result.error },
      { status: 500 }
    );
  }

  return Response.json({
    ok: true,
    message: `Print triggered for ${order_ids.length} selected orders`,
    order_ids,
    log: result.stdout,
  });
}

/**
 * GET /api/picklist/print-label?order_id=12345
 * Pack-station endpoint: scan QR code on picklist → print shipping label.
 * Fires BaseLinker label generation via the trigger script.
 */
export async function handlePrintLabel(request) {
  const url = new URL(request.url);
  const orderId = url.searchParams.get('order_id');

  if (!orderId || !/^\d+$/.test(orderId)) {
    return Response.json({ error: 'Missing or invalid order_id' }, { status: 400 });
  }

  // Run via trigger script which has doppler env available
  const result = await runTrigger(['print-label', orderId]);

  if (!result.success) {
    console.error('[picklist] print-label failed:', result.error, result.stderr);
    return Response.json(
      { error: 'Label print failed', detail: result.error },
      { status: 500 }
    );
  }

  // Return a simple success page suitable for a browser redirect after QR scan
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Label Printed</title>
<style>
  body { font-family: sans-serif; text-align: center; padding: 40px; background: #f0faf0; color: #1a4a1a; }
  .icon { font-size: 72px; margin-bottom: 16px; }
  h1 { font-size: 28px; }
  p { font-size: 16px; color: #555; margin-top: 8px; }
  .order { font-size: 32px; font-weight: bold; font-family: monospace; margin: 16px 0; }
</style>
</head>
<body>
  <div class="icon">&#10003;</div>
  <h1>Label Sent to Printer</h1>
  <div class="order">Order #${orderId}</div>
  <p>Shipping label printing&hellip;</p>
  <p style="margin-top:24px;font-size:13px;color:#999">ArryBarry Health &amp; Beauty &mdash; Pack Station</p>
</body>
</html>`;

  return new Response(html, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}
