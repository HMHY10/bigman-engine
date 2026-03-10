import { auth } from 'thepopebot/auth';
import { ChatPage } from 'thepopebot/chat';

export default async function Home() {
  const session = await auth();
  const features = {
    codeWorkspace: !!process.env.CLAUDE_CODE_OAUTH_TOKEN,
    clusterWorkspace: !!process.env.CLAUDE_CODE_OAUTH_TOKEN,
  };
  return <ChatPage session={session} needsSetup={false} features={features} />;
}
