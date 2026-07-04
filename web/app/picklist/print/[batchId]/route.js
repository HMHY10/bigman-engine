import { auth } from 'thepopebot/auth';
import fs from 'fs';
import path from 'path';

const BATCHES_DIR = path.join(process.cwd(), 'data', 'picklist-ops', 'batches');

export async function GET(request, { params }) {
  // Require authenticated session
  const session = await auth();
  if (!session?.user?.id) {
    return new Response('Unauthorized', { status: 401 });
  }

  const { batchId } = await params;
  // Sanitise — only allow safe batch ID characters
  const safe = batchId.replace(/[^a-zA-Z0-9_-]/g, '');
  const htmlPath = path.join(BATCHES_DIR, `${safe}.html`);

  if (!fs.existsSync(htmlPath)) {
    return new Response('Batch not found', { status: 404 });
  }

  const html = fs.readFileSync(htmlPath, 'utf8');
  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}
