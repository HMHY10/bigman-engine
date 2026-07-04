/**
 * Overnight picklist batch cron.
 * Runs Mon-Sat at 6:30 AM before the warehouse opens.
 * Groups ALL pending orders into one picklist, sorted by SKU — no cap.
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

const { generateOvernightPicklist } = await import('../lib/picklist/generate.js');

const picklist = generateOvernightPicklist();

if (!picklist) {
  console.log('[picklist-overnight] No pending orders — nothing to batch.');
} else {
  console.log(`[picklist-overnight] Created picklist ${picklist.id.slice(0, 8)} with ${picklist.orderCount} orders.`);
}
