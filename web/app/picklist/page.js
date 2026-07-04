import { auth } from 'thepopebot/auth';
import { redirect } from 'next/navigation';
import { PicklistPage } from 'thepopebot/picklist';

export const metadata = {
  title: 'Picklist — ArryBarry',
};

export default async function PicklistRoute() {
  const session = await auth();
  if (!session?.user) redirect('/login');
  return (
    <div className="min-h-screen bg-background">
      <div className="max-w-2xl mx-auto px-4 py-8">
        <div className="mb-6">
          <h1 className="text-2xl font-semibold">Pick List</h1>
          <p className="text-sm text-muted-foreground mt-1">
            Warehouse order picking queue — auto-batches at 25 orders or 1-hour time limit
          </p>
        </div>
        <PicklistPage />
      </div>
    </div>
  );
}
