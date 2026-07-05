import { auth } from 'thepopebot/auth';
import { getPicklistWithOrders } from 'thepopebot/picklist/db';
import { renderPicklistHtml } from 'thepopebot/picklist/print';

export async function GET(request, { params }) {
  const session = await auth();
  if (!session?.user) {
    return new Response('Unauthorized', { status: 401 });
  }

  const { id } = await params;
  const data = getPicklistWithOrders(id);

  if (!data) {
    return new Response(`<html><body><h1>Picklist not found</h1><p>ID: ${id}</p></body></html>`, {
      status: 404,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }

  const host = request.headers.get('host') || 'localhost';
  const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
  const baseUrl = `${proto}://${host}`;

  const html = renderPicklistHtml(data, baseUrl);

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}
