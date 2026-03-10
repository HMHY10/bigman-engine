'use client';

import { useEffect, useLayoutEffect, useState } from 'react';
import { SidebarHistoryItem } from './sidebar-history-item.js';
import { SidebarGroup, SidebarGroupContent, SidebarGroupLabel, SidebarMenu } from './ui/sidebar.js';
import { useChatNav } from './chat-nav-context.js';
import { getChats, deleteChat, renameChat, starChat } from '../actions.js';
import { cn } from '../utils.js';
import { MessageIcon, CodeIcon } from './icons.js';

function groupChatsByDate(chats) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterday = new Date(today.getTime() - 86400000);
  const last7Days = new Date(today.getTime() - 7 * 86400000);
  const last30Days = new Date(today.getTime() - 30 * 86400000);

  const groups = {
    Starred: [],
    Today: [],
    Yesterday: [],
    'Last 7 Days': [],
    'Last 30 Days': [],
    Older: [],
  };

  for (const chat of chats) {
    if (chat.starred) {
      groups.Starred.push(chat);
      continue;
    }
    const date = new Date(chat.updatedAt);
    if (date >= today) {
      groups.Today.push(chat);
    } else if (date >= yesterday) {
      groups.Yesterday.push(chat);
    } else if (date >= last7Days) {
      groups['Last 7 Days'].push(chat);
    } else if (date >= last30Days) {
      groups['Last 30 Days'].push(chat);
    } else {
      groups.Older.push(chat);
    }
  }

  return groups;
}

const BASE_FILTERS = [
  { value: 'all', label: 'All', icon: null },
  { value: 'chat', label: 'Chat', icon: MessageIcon },
];
const CODE_FILTER = { value: 'code', label: 'Code', icon: CodeIcon };

function ChatTypeFilter({ filter, setFilter, features }) {
  const filters = features?.codeWorkspace ? [...BASE_FILTERS, CODE_FILTER] : BASE_FILTERS;
  return (
    <div className="flex items-center gap-0.5 px-2 pt-2 mb-1">
      {filters.map(({ value, label, icon: Icon }) => (
        <button
          key={value}
          onClick={() => setFilter(value)}
          className={cn(
            'flex items-center gap-1 rounded-md px-2.5 py-1 text-[0.8rem] md:text-xs font-medium transition-colors',
            filter === value
              ? 'bg-background text-foreground shadow-sm'
              : 'text-muted-foreground hover:text-foreground'
          )}
        >
          {Icon && <Icon size={14} />}
          {label}
        </button>
      ))}
    </div>
  );
}

const isCodeChat = (chat) => Boolean(chat.codeWorkspaceId);

export function SidebarHistory({ features }) {
  const [chats, setChats] = useState([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState('all');
  const updateFilter = (v) => { setFilter(v); try { localStorage.setItem('sidebar-chat-filter', v); } catch {} };
  const { activeChatId, navigateToChat } = useChatNav();

  const [hasMore, setHasMore] = useState(false);

  const loadChats = async () => {
    try {
      const result = await getChats(51);
      if (result.length > 50) {
        setChats(result.slice(0, 50));
        setHasMore(true);
      } else {
        setChats(result);
        setHasMore(false);
      }
    } catch (err) {
      console.error('Failed to load chats:', err);
    } finally {
      setLoading(false);
    }
  };

  // Sync filter from localStorage on mount (useLayoutEffect prevents flash)
  useLayoutEffect(() => {
    try {
      const v = localStorage.getItem('sidebar-chat-filter');
      if (v === 'chat' || v === 'code') setFilter(v);
    } catch {}
  }, []);

  // Load chats on mount
  useEffect(() => {
    loadChats();
  }, []);

  useEffect(() => {
    const titleHandler = (e) => {
      const { chatId, title, codeWorkspaceId } = e.detail;
      setChats(prev => {
        const exists = prev.some(c => c.id === chatId);
        if (exists) return prev.map(c => c.id === chatId ? { ...c, title } : c);
        return [{ id: chatId, title, starred: 0, updatedAt: new Date().toISOString(), codeWorkspaceId: codeWorkspaceId || null }, ...prev];
      });
    };
    const starHandler = (e) => {
      const { chatId, starred } = e.detail;
      setChats(prev => prev.map(c => c.id === chatId ? { ...c, starred } : c));
    };
    const deleteHandler = (e) => {
      const { chatId } = e.detail;
      setChats(prev => prev.filter(c => c.id !== chatId));
    };
    window.addEventListener('chatTitleUpdated', titleHandler);
    window.addEventListener('chatStarUpdated', starHandler);
    window.addEventListener('chatDeleted', deleteHandler);
    return () => {
      window.removeEventListener('chatTitleUpdated', titleHandler);
      window.removeEventListener('chatStarUpdated', starHandler);
      window.removeEventListener('chatDeleted', deleteHandler);
    };
  }, []);

  const handleDelete = async (chatId) => {
    setChats((prev) => prev.filter((c) => c.id !== chatId));
    const { success } = await deleteChat(chatId);
    if (success) {
      window.dispatchEvent(new CustomEvent('chatDeleted', { detail: { chatId } }));
      if (chatId === activeChatId) {
        navigateToChat(null);
      }
    } else {
      loadChats();
    }
  };

  const handleStar = async (chatId) => {
    const newStarred = chats.find(c => c.id === chatId)?.starred ? 0 : 1;
    setChats((prev) =>
      prev.map((c) => (c.id === chatId ? { ...c, starred: newStarred } : c))
    );
    const { success } = await starChat(chatId);
    if (success) {
      window.dispatchEvent(new CustomEvent('chatStarUpdated', { detail: { chatId, starred: newStarred } }));
    } else {
      loadChats();
    }
  };

  const handleRename = async (chatId, title) => {
    setChats((prev) =>
      prev.map((c) => (c.id === chatId ? { ...c, title } : c))
    );
    const { success } = await renameChat(chatId, title);
    if (success) {
      window.dispatchEvent(new CustomEvent('chatTitleUpdated', { detail: { chatId, title } }));
    } else {
      loadChats();
    }
  };

  if (loading && chats.length === 0) {
    return (
      <>
        <SidebarGroup className="sticky top-0 z-10 bg-muted">
          <SidebarGroupContent>
            <ChatTypeFilter filter={filter} setFilter={updateFilter} features={features} />
          </SidebarGroupContent>
        </SidebarGroup>
        <SidebarGroup>
          <SidebarGroupContent>
            <div className="flex flex-col gap-2 px-2">
              {[...Array(5)].map((_, i) => (
                <div key={i} className="h-8 animate-pulse rounded-md bg-border/50" />
              ))}
            </div>
          </SidebarGroupContent>
        </SidebarGroup>
      </>
    );
  }

  if (chats.length === 0) {
    return (
      <SidebarGroup>
        <SidebarGroupContent>
          <p className="px-4 py-2 text-sm text-muted-foreground">
            No chats yet. Start a conversation!
          </p>
        </SidebarGroupContent>
      </SidebarGroup>
    );
  }

  const filteredChats = !filter || filter === 'all' ? chats
    : filter === 'code' ? chats.filter(isCodeChat)
    : chats.filter((c) => !isCodeChat(c));
  const grouped = groupChatsByDate(filteredChats);

  const hasResults = Object.values(grouped).some((g) => g.length > 0);

  return (
    <>
      <SidebarGroup className="sticky top-0 z-10 bg-muted">
        <SidebarGroupContent>
          <ChatTypeFilter filter={filter} setFilter={updateFilter} features={features} />
        </SidebarGroupContent>
      </SidebarGroup>
      {hasResults ? (
        Object.entries(grouped).map(
          ([label, groupChats]) =>
            groupChats.length > 0 && (
              <SidebarGroup key={label} className="pt-1">
                <SidebarGroupLabel>{label}</SidebarGroupLabel>
                <SidebarGroupContent>
                  <SidebarMenu>
                    {groupChats.map((chat) => (
                      <SidebarHistoryItem
                        key={chat.id}
                        chat={chat}
                        isActive={chat.id === activeChatId}
                        onDelete={handleDelete}
                        onStar={handleStar}
                        onRename={handleRename}
                      />
                    ))}
                  </SidebarMenu>
                </SidebarGroupContent>
              </SidebarGroup>
            )
        )
      ) : (
        <SidebarGroup>
          <SidebarGroupContent>
            <p className="px-4 py-2 text-sm text-muted-foreground">
              No {filter === 'code' ? 'code' : 'chat'} chats yet.
            </p>
          </SidebarGroupContent>
        </SidebarGroup>
      )}
      {hasMore && (
        <SidebarGroup className="pt-0">
          <SidebarGroupContent>
            <a
              href="/chats"
              className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-muted-foreground hover:text-foreground transition-colors"
            >
              <MessageIcon size={14} />
              All Chats
            </a>
          </SidebarGroupContent>
        </SidebarGroup>
      )}
    </>
  );
}
