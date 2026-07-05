import { auth } from 'thepopebot/auth';
import { PicklistPage } from 'thepopebot/picklist';

export default async function WarehousePage() {
  const session = await auth();
  return <PicklistPage session={session} />;
}
