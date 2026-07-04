import { auth } from 'thepopebot/auth';
import { redirect } from 'next/navigation';
import { PrintView } from 'thepopebot/picklist';

export const metadata = {
  title: 'Picklist Print — ArryBarry',
};

export default async function PrintRoute({ params, searchParams }) {
  const session = await auth();
  if (!session?.user) redirect('/login');

  const { batchId } = await params;
  const sp = await searchParams;
  const autoprint = sp.autoprint === '1';
  const scanBaseUrl = process.env.PICKLIST_SCAN_BASE_URL ?? '';

  return (
    <PrintView
      batchId={batchId}
      scanBaseUrl={scanBaseUrl}
      autoprint={autoprint}
    />
  );
}
