import { auth } from 'thepopebot/auth';
import { ChatPage } from 'thepopebot/chat';

export default async function ChatRoute({ params }) {
  const { chatId } = await params;
  const session = await auth();
  const features = {
    codeWorkspace: !!process.env.CLAUDE_CODE_OAUTH_TOKEN,
    clusterWorkspace: !!process.env.CLAUDE_CODE_OAUTH_TOKEN,
  };
  return <ChatPage session={session} needsSetup={false} chatId={chatId} features={features} />;
}
