'use client';

import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';
import { useState, useEffect, useRef, useMemo, useCallback } from 'react';
import { Messages } from './messages.js';
import { ChatInput } from './chat-input.js';
import { ChatHeader } from './chat-header.js';
import { Greeting } from './greeting.js';
import { CodeModeToggle } from './code-mode-toggle.js';
import { getRepositories, getBranches } from '../actions.js';

export function Chat({ chatId, initialMessages = [], workspace = null, features }) {
  const [input, setInput] = useState('');
  const [files, setFiles] = useState([]);
  const hasNavigated = useRef(false);
  const [codeMode, setCodeMode] = useState(!!workspace);
  const [repo, setRepo] = useState(workspace?.repo || '');
  const [branch, setBranch] = useState(workspace?.branch || '');
  const [workspaceState, setWorkspaceState] = useState(workspace);

  // Auto-forward to interactive workspace — only on toggle, not on mount
  const hasMounted = useRef(false);
  useEffect(() => {
    if (!hasMounted.current) {
      hasMounted.current = true;
      return;
    }
    if (workspaceState?.containerName && workspaceState?.id) {
      window.location.href = `/code/${workspaceState.id}`;
    }
  }, [workspaceState?.containerName]);

  const codeModeRef = useRef({ codeMode, repo, branch, workspaceId: workspaceState?.id });
  codeModeRef.current = { codeMode, repo, branch, workspaceId: workspaceState?.id };

  const transport = useMemo(
    () =>
      new DefaultChatTransport({
        api: '/stream/chat',
        body: () => ({
          chatId,
          ...(codeModeRef.current.codeMode && codeModeRef.current.repo && codeModeRef.current.branch
            ? { codeMode: true, repo: codeModeRef.current.repo, branch: codeModeRef.current.branch, workspaceId: codeModeRef.current.workspaceId }
            : {}),
        }),
      }),
    [chatId]
  );

  const {
    messages,
    status,
    stop,
    error,
    sendMessage,
    regenerate,
    setMessages,
  } = useChat({
    id: chatId,
    messages: initialMessages,
    transport,
    onError: (err) => console.error('Chat error:', err),
  });

  // After first message sent, update URL and notify sidebar
  useEffect(() => {
    if (!hasNavigated.current && messages.length >= 1 && status !== 'ready' && window.location.pathname !== `/chat/${chatId}`) {
      hasNavigated.current = true;
      window.history.replaceState({}, '', `/chat/${chatId}`);
    }
  }, [messages.length, status, chatId]);

  const handleSend = async () => {
    if (!input.trim() && files.length === 0) return;
    const text = input;
    const isFirstMessage = messages.length === 0;
    const currentFiles = files;
    setInput('');
    setFiles([]);

    const fileParts = currentFiles.map((f) => ({
      type: 'file',
      mediaType: f.file.type || 'text/plain',
      url: f.previewUrl,
      filename: f.file.name,
    }));
    await sendMessage({ text: text || undefined, files: fileParts });

    if (isFirstMessage && text) {
      fetch('/chat/finalize-chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chatId, message: text }),
      })
        .then(res => res.json())
        .then(({ title, codeWorkspaceId, featureBranch }) => {
          if (title) {
            window.dispatchEvent(new CustomEvent('chatTitleUpdated', { detail: { chatId, title, codeWorkspaceId } }));
          }
          if (codeWorkspaceId) {
            setWorkspaceState({ id: codeWorkspaceId, featureBranch, repo, branch, containerName: null });
          }
        })
        .catch(err => console.error('Failed to finalize chat:', err));
    }
  };

  const handleRetry = useCallback((message) => {
    if (message.role === 'assistant') {
      regenerate({ messageId: message.id });
    } else {
      // User message — find the next assistant message and regenerate it
      const idx = messages.findIndex((m) => m.id === message.id);
      const nextAssistant = messages.slice(idx + 1).find((m) => m.role === 'assistant');
      if (nextAssistant) {
        regenerate({ messageId: nextAssistant.id });
      } else {
        // No assistant response yet — extract text and resend
        const text =
          message.parts
            ?.filter((p) => p.type === 'text')
            .map((p) => p.text)
            .join('\n') ||
          message.content ||
          '';
        if (text.trim()) {
          sendMessage({ text });
        }
      }
    }
  }, [messages, regenerate, sendMessage]);

  const handleEdit = useCallback((message, newText) => {
    const idx = messages.findIndex((m) => m.id === message.id);
    if (idx === -1) return;
    // Truncate conversation to before this message, then send edited text
    setMessages(messages.slice(0, idx));
    sendMessage({ text: newText });
  }, [messages, setMessages, sendMessage]);

  // Interactive mode is active if containerName is set
  const isInteractiveActive = !!workspaceState?.containerName;

  // In code mode, disable send until repo+branch selected
  const codeModeCanSend = !codeMode || (!!repo && !!branch);

  const codeModeToggle = (
    <CodeModeToggle
      features={features}
      enabled={codeMode}
      onToggle={setCodeMode}
      repo={repo}
      onRepoChange={setRepo}
      branch={branch}
      onBranchChange={setBranch}
      locked={messages.length > 0}
      getRepositories={getRepositories}
      getBranches={getBranches}
      workspace={workspaceState}
      isInteractiveActive={isInteractiveActive}
      onWorkspaceUpdate={(containerName) => {
        setWorkspaceState(prev => ({ ...prev, containerName }));
      }}
    />
  );

  return (
    <div className="flex h-svh flex-col">
      <ChatHeader chatId={chatId} />
      {messages.length === 0 ? (
        <div className="flex flex-1 flex-col items-center justify-center px-2.5 md:px-6">
          <div className="w-full max-w-4xl">
            <Greeting codeMode={codeMode} />
            {error && (
              <div className="mt-4 rounded-lg border border-destructive/50 bg-destructive/10 px-4 py-2 text-sm text-destructive">
                {error.message || 'Something went wrong. Please try again.'}
              </div>
            )}
            <div className="mt-4">
              <ChatInput
                input={input}
                setInput={setInput}
                onSubmit={handleSend}
                status={status}
                stop={stop}
                files={files}
                setFiles={setFiles}
                canSendOverride={codeModeCanSend ? undefined : false}
              />
            </div>
            <div className="mt-5 pb-8">
              {codeModeToggle}
            </div>
          </div>
        </div>
      ) : (
        <>
          <Messages messages={messages} status={status} onRetry={handleRetry} onEdit={handleEdit} />
          {error && (
            <div className="mx-auto w-full max-w-4xl px-2 md:px-4">
              <div className="rounded-lg border border-destructive/50 bg-destructive/10 px-4 py-2 text-sm text-destructive">
                {error.message || 'Something went wrong. Please try again.'}
              </div>
            </div>
          )}
          {codeMode ? (
            <div className="mx-auto w-full max-w-4xl px-4 pb-4 md:px-6">
              {isInteractiveActive && (
                <a
                  href={`/code/${workspaceState?.id}`}
                  className="flex items-center justify-center gap-2 rounded-xl border border-primary/20 bg-primary/5 px-4 py-3 mb-2 text-sm font-medium text-primary hover:bg-primary/10 transition-colors"
                >
                  <span className="h-2 w-2 rounded-full bg-green-500 animate-pulse" />
                  Click here to access Interactive Mode
                </a>
              )}
              <div className="rounded-t-xl border border-b-0 border-border px-3 py-2.5">
                {codeModeToggle}
              </div>
              <ChatInput
                bare
                input={input}
                setInput={setInput}
                onSubmit={handleSend}
                status={status}
                stop={stop}
                files={files}
                setFiles={setFiles}
                disabled={isInteractiveActive}
                placeholder={isInteractiveActive ? 'Interactive mode is active.' : 'Send a message...'}
                className="rounded-t-none"
              />
            </div>
          ) : (
            <div className="px-2.5 md:px-0">
              <ChatInput
                input={input}
                setInput={setInput}
                onSubmit={handleSend}
                status={status}
                stop={stop}
                files={files}
                setFiles={setFiles}
              />
            </div>
          )}
        </>
      )}
    </div>
  );
}
