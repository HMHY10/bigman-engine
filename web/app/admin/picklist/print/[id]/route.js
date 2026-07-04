import { getPicklistById, getPicklistItems } from 'thepopebot/picklist/db';
import { generatePicklistHtml } from 'thepopebot/picklist/print';
import { auth } from 'thepopebot/auth';

export async function GET(request, { params }) {
  const session = await auth();
  if (!session?.user) {
    return new Response('Unauthorised', { status: 401 });
  }

  const { id } = await params;

  const picklist = getPicklistById(id);
  if (!picklist) {
    return new Response('Picklist not found', { status: 404 });
  }

  const items = getPicklistItems(id);

  const url = new URL(request.url);
  const baseUrl = `${url.protocol}//${url.host}`;

  const html = generatePicklistHtml(picklist, items, baseUrl);

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}
