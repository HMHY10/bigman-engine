import { auth } from 'thepopebot/auth';
import { PicklistPage } from 'thepopebot/chat';

export const metadata = { title: 'Picklists' };

export default async function PicklistsRoute() {
  const session = await auth();
  return <PicklistPage session={session} />;
}
