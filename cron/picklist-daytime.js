/**
 * Daytime auto-batch cron.
 * Runs every minute Mon-Sat 7am-5pm.
 * Fires when: >= 25 pending orders OR oldest pending order >= 25 seconds old.
 * Batches a soft-capped group (whole SKU groups, target ~25 orders).
 *
 * Working directory when invoked: cron/ — we change to project root first.
 */

import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';

// Change to project root so lib/paths.js resolves correctly
const __dirname = dirname(fileURLToPath(import.meta.url));
process.chdir(resolve(__dirname, '..'));

const { initDatabase } = await import('../lib/db/index.js');
initDatabase();

const { shouldAutoBatch, generateRealtimePicklist } = await import('../lib/picklist/generate.js');

if (!shouldAutoBatch()) {
  console.log('[picklist-daytime] Conditions not met — skipping.');
} else {
  const picklist = generateRealtimePicklist();
  if (!picklist) {
    console.log('[picklist-daytime] No picklist generated (no pending orders).');
  } else {
    console.log(`[picklist-daytime] Auto-batched picklist ${picklist.id.slice(0, 8)} — ${picklist.orderCount} orders.`);
  }
}
