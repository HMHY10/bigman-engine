'use client';

import { useEffect, useRef, useCallback, useState } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { SearchAddon } from '@xterm/addon-search';
import { WebLinksAddon } from '@xterm/addon-web-links';
import { SerializeAddon } from '@xterm/addon-serialize';
import '@xterm/xterm/css/xterm.css';
import { SpinnerIcon } from '../chat/components/icons.js';

const STATUS = { connected: '#22c55e', connecting: '#eab308', disconnected: '#ef4444' };
const RECONNECT_INTERVAL = 3000;

const TERM_THEMES = {
  dark: { background: '#1a1b26', foreground: '#a9b1d6', cursor: '#c0caf5', selectionBackground: '#33467c' },
  light: { background: '#f5f5f5', foreground: '#171717', cursor: '#171717', selectionBackground: '#d4d4d4' },
};

// Toolbar button colors that contrast with each terminal theme background
const TOOLBAR_COLORS = {
  dark: { color: '#787c99', border: 'rgba(169,177,214,0.15)', hoverColor: '#a9b1d6' },
  light: { color: '#555555', border: 'rgba(23,23,23,0.15)', hoverColor: '#171717' },
};

function getSystemTheme() {
  const cs = getComputedStyle(document.documentElement);
  return {
    background: cs.getPropertyValue('--muted').trim() || '#1a1b26',
    foreground: cs.getPropertyValue('--muted-foreground').trim() || '#a9b1d6',
    cursor: cs.getPropertyValue('--foreground').trim() || '#c0caf5',
    selectionBackground: cs.getPropertyValue('--border').trim() || '#33467c',
  };
}

function resolveTheme(mode) {
  if (mode === 'system') return getSystemTheme();
  return TERM_THEMES[mode] || TERM_THEMES.dark;
}

const THEME_CYCLE = ['dark', 'light', 'system'];

export default function TerminalView({ codeWorkspaceId, wsPath, isActive = true, showToolbar = true, ensureContainer, onCloseSession }) {
  const containerRef = useRef(null);
  const termRef = useRef(null);
  const fitAddonRef = useRef(null);
  const wsRef = useRef(null);
  const retryTimer = useRef(null);
  const statusRef = useRef(null);
  const styleRef = useRef(null);
  const toolbarRef = useRef(null);
  const disconnectedAtRef = useRef(null);
  const ensuredRef = useRef(false);
  const [connected, setConnected] = useState(false);
  const [containerError, setContainerError] = useState(null);
  const [termTheme, setTermTheme] = useState('dark');
  const [voiceActive, setVoiceActive] = useState(false);
  const [voiceText, setVoiceText] = useState('');
  const [voiceInterim, setVoiceInterim] = useState('');
  const recognitionRef = useRef(null);

  const setStatus = useCallback((color) => {
    if (statusRef.current) statusRef.current.style.backgroundColor = color;
    setConnected(color === STATUS.connected);
  }, []);

  const sendResize = useCallback(() => {
    const fit = fitAddonRef.current;
    const ws = wsRef.current;
    const term = termRef.current;
    if (!fit || !term || !ws || ws.readyState !== WebSocket.OPEN) return;
    fit.fit();
    const payload = JSON.stringify({ columns: term.cols, rows: term.rows });
    ws.send('1' + payload);
  }, []);

  const applyTheme = useCallback((mode) => {
    const theme = resolveTheme(mode);
    const tb = TOOLBAR_COLORS[mode] || TOOLBAR_COLORS.dark;
    const term = termRef.current;
    if (term) term.options.theme = theme;
    if (styleRef.current) {
      styleRef.current.textContent = `.xterm { padding: 5px; background-color: ${theme.background} !important; } .xterm-viewport { background-color: ${theme.background} !important; }`;
    }
    if (containerRef.current) containerRef.current.style.backgroundColor = theme.background;
    if (toolbarRef.current) {
      toolbarRef.current.style.background = theme.background;
      toolbarRef.current.style.setProperty('--tb-color', tb.color);
      toolbarRef.current.style.setProperty('--tb-border', tb.border);
      toolbarRef.current.style.setProperty('--tb-hover', tb.hoverColor);
    }
  }, []);

  const connect = useCallback(() => {
    const term = termRef.current;
    if (!term) return;

    setStatus(STATUS.connecting);

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const path = wsPath || `/code/${codeWorkspaceId}/ws`;
    const ws = new WebSocket(`${protocol}//${window.location.host}${path}`);
    wsRef.current = ws;

    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
      const handshake = JSON.stringify({ AuthToken: '', columns: term.cols, rows: term.rows });
      ws.send(handshake);
      setStatus(STATUS.connected);
      // Reset reconnect state on successful connection
      disconnectedAtRef.current = null;
      ensuredRef.current = false;
    };

    ws.onmessage = (ev) => {
      const data = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
      const type = data[0];
      const payload = data.slice(1);

      switch (type) {
        case '0':
          term.write(payload);
          break;
        case '1':
          // Ignore terminal title changes — global page title is set by layout
          break;
        case '2':
          break;
      }
    };

    ws.onclose = () => {
      setStatus(STATUS.disconnected);

      // Track when disconnection started
      if (!disconnectedAtRef.current) {
        disconnectedAtRef.current = Date.now();
      }

      // Give up after 60s of failed reconnection
      if (Date.now() - disconnectedAtRef.current > 60_000) {
        setContainerError('Failed to connect');
        return;
      }

      // Call ensureContainer once per disconnect cycle to restart the container
      if (!ensuredRef.current && ensureContainer) {
        ensuredRef.current = true;
        ensureContainer(codeWorkspaceId).catch(() => {});
      }

      retryTimer.current = setTimeout(connect, RECONNECT_INTERVAL);
    };

    ws.onerror = () => {
      ws.close();
    };
  }, [codeWorkspaceId, wsPath, setStatus, ensureContainer]);

  useEffect(() => {
    const saved = localStorage.getItem('terminal-theme') || 'dark';
    setTermTheme(saved);

    const theme = resolveTheme(saved);
    const term = new Terminal({
      cursorBlink: true,
      fontSize: 16,
      fontFamily: '"Fira Code", "Cascadia Code", "JetBrains Mono", Menlo, monospace',
      theme,
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon();
    const searchAddon = new SearchAddon();
    const webLinksAddon = new WebLinksAddon();
    const serializeAddon = new SerializeAddon();

    term.loadAddon(fitAddon);
    term.loadAddon(searchAddon);
    term.loadAddon(webLinksAddon);
    term.loadAddon(serializeAddon);

    termRef.current = term;
    fitAddonRef.current = fitAddon;

    term.open(containerRef.current);

    const style = document.createElement('style');
    style.textContent = `.xterm { padding: 5px; background-color: ${theme.background} !important; } .xterm-viewport { background-color: ${theme.background} !important; }`;
    containerRef.current.appendChild(style);
    styleRef.current = style;

    containerRef.current.style.backgroundColor = theme.background;
    const tb = TOOLBAR_COLORS[saved] || TOOLBAR_COLORS.dark;
    if (toolbarRef.current) {
      toolbarRef.current.style.background = theme.background;
      toolbarRef.current.style.setProperty('--tb-color', tb.color);
      toolbarRef.current.style.setProperty('--tb-border', tb.border);
      toolbarRef.current.style.setProperty('--tb-hover', tb.hoverColor);
    }

    fitAddon.fit();

    term.onData((data) => {
      const ws = wsRef.current;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send('0' + data);
      }
    });

    let resizeTimeout;
    const handleResize = () => {
      clearTimeout(resizeTimeout);
      resizeTimeout = setTimeout(sendResize, 100);
    };
    window.addEventListener('resize', handleResize);

    let cancelled = false;

    if (ensureContainer) {
      (async () => {
        try {
          const result = await ensureContainer(codeWorkspaceId);
          if (result?.status === 'error') {
            const msg = result.message || 'Unknown container error';
            console.error('ensureContainer:', msg);
            if (!cancelled) setContainerError(msg);
            return;
          }
        } catch (err) {
          console.error('ensureContainer:', err);
          if (!cancelled) setContainerError(err.message || String(err));
          return;
        }
        if (!cancelled) connect();
      })();
    } else {
      connect();
    }

    return () => {
      cancelled = true;
      clearTimeout(resizeTimeout);
      clearTimeout(retryTimer.current);
      window.removeEventListener('resize', handleResize);
      if (wsRef.current) wsRef.current.close();
      term.dispose();
    };
  }, [connect, sendResize, codeWorkspaceId]);

  useEffect(() => {
    if (isActive && termRef.current && fitAddonRef.current) {
      requestAnimationFrame(() => {
        fitAddonRef.current?.fit();
        termRef.current?.focus();
      });
    }
  }, [isActive]);

  const sendCommand = useCallback((text) => {
    const ws = wsRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const encoder = new TextEncoder();

    // Ctrl+C as binary frame (cancel current input)
    ws.send(new Uint8Array([0x30, 0x03]));

    setTimeout(() => {
      if (ws.readyState !== WebSocket.OPEN) return;
      // Command text as binary frame (no \r)
      const buf = new Uint8Array(text.length * 3 + 1);
      buf[0] = 0x30; // INPUT command
      const { written } = encoder.encodeInto(text, buf.subarray(1));
      ws.send(buf.subarray(0, written + 1));

      // Enter as its own binary frame — separate pty_write() = standalone keystroke
      setTimeout(() => {
        if (ws.readyState !== WebSocket.OPEN) return;
        ws.send(new Uint8Array([0x30, 0x0d])); // 0x0d = \r
      }, 50);
    }, 150);
  }, []);

  const handleReconnect = async () => {
    clearTimeout(retryTimer.current);
    if (wsRef.current) wsRef.current.close();
    // Reset reconnect state so the 60s timer starts fresh
    disconnectedAtRef.current = null;
    ensuredRef.current = false;
    if (ensureContainer) {
      try {
        setContainerError(null);
        const result = await ensureContainer(codeWorkspaceId);
        if (result?.status === 'error') {
          const msg = result.message || 'Unknown container error';
          console.error('ensureContainer:', msg);
          setContainerError(msg);
          return;
        }
      } catch (err) {
        console.error('ensureContainer:', err);
        setContainerError(err.message || String(err));
        return;
      }
    }
    connect();
  };

  const cycleTheme = useCallback(() => {
    setTermTheme((prev) => {
      const idx = THEME_CYCLE.indexOf(prev);
      const next = THEME_CYCLE[(idx + 1) % THEME_CYCLE.length];
      localStorage.setItem('terminal-theme', next);
      applyTheme(next);
      return next;
    });
  }, [applyTheme]);

  const startVoice = useCallback(() => {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      alert('Speech recognition is not supported in this browser.');
      return;
    }
    const recognition = new SpeechRecognition();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = 'en-US';

    recognition.onresult = (event) => {
      let final = '';
      let interim = '';
      for (let i = 0; i < event.results.length; i++) {
        const transcript = event.results[i][0].transcript;
        if (event.results[i].isFinal) {
          final += transcript;
        } else {
          interim += transcript;
        }
      }
      if (final) setVoiceText((prev) => (prev + ' ' + final).trim());
      setVoiceInterim(interim);
    };

    recognition.onerror = (event) => {
      if (event.error !== 'aborted') console.error('Speech recognition error:', event.error);
      setVoiceActive(false);
    };

    recognition.onend = () => {
      setVoiceActive(false);
      setVoiceInterim('');
    };

    recognitionRef.current = recognition;
    recognition.start();
    setVoiceActive(true);
    setVoiceText('');
    setVoiceInterim('');
  }, []);

  const stopVoice = useCallback(() => {
    if (recognitionRef.current) {
      recognitionRef.current.stop();
      recognitionRef.current = null;
    }
    setVoiceActive(false);
    setVoiceInterim('');
  }, []);

  const sendVoiceText = useCallback(() => {
    const text = voiceText.trim();
    if (text) sendCommand(text);
    stopVoice();
    setVoiceText('');
  }, [voiceText, sendCommand, stopVoice]);

  const cancelVoice = useCallback(() => {
    stopVoice();
    setVoiceText('');
  }, [stopVoice]);

  const themeIcon = termTheme === 'light' ? (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
      <circle cx="8" cy="8" r="3" />
      <line x1="8" y1="1" x2="8" y2="3" />
      <line x1="8" y1="13" x2="8" y2="15" />
      <line x1="1" y1="8" x2="3" y2="8" />
      <line x1="13" y1="8" x2="15" y2="8" />
      <line x1="3.05" y1="3.05" x2="4.46" y2="4.46" />
      <line x1="11.54" y1="11.54" x2="12.95" y2="12.95" />
      <line x1="3.05" y1="12.95" x2="4.46" y2="11.54" />
      <line x1="11.54" y1="4.46" x2="12.95" y2="3.05" />
    </svg>
  ) : termTheme === 'dark' ? (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <path d="M13.5 8.5a5.5 5.5 0 1 1-6-6 4.5 4.5 0 0 0 6 6z" />
    </svg>
  ) : (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <rect x="2" y="3" width="12" height="9" rx="1" />
      <line x1="5" y1="14" x2="11" y2="14" />
      <line x1="8" y1="12" x2="8" y2="14" />
    </svg>
  );

  const themeLabel = termTheme === 'light' ? 'Light' : termTheme === 'dark' ? 'Dark' : 'System';

  return (
    <>
      <style>{`
        .code-toolbar-btn {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          background: transparent;
          border: 1px solid var(--tb-border, rgba(169,177,214,0.15));
          color: var(--tb-color, #787c99);
          padding: 5px 12px;
          border-radius: 6px;
          cursor: pointer;
          font-size: 12px;
          font-family: ui-monospace, 'Cascadia Code', 'Source Code Pro', monospace;
          font-weight: 500;
          letter-spacing: 0.01em;
          transition: all 0.15s ease;
          white-space: nowrap;
          line-height: 1;
        }
        .code-toolbar-btn:hover {
          background: transparent;
          color: var(--tb-hover, #a9b1d6);
        }
        .code-toolbar-btn:active {
          transform: scale(0.97);
        }
        .code-toolbar-btn svg {
          flex-shrink: 0;
        }
        .code-toolbar-btn--commit:hover {
          border-color: rgba(115,218,149,0.3);
          color: #73da95;
          background: rgba(115,218,149,0.08);
        }
        .code-toolbar-btn--merge:hover {
          border-color: rgba(122,162,247,0.3);
          color: #7aa2f7;
          background: rgba(122,162,247,0.08);
        }
        .code-toolbar-btn--reconnect:hover {
          color: var(--tb-hover, #a9b1d6);
        }
        .code-toolbar-btn--theme:hover {
          border-color: rgba(168,153,215,0.3);
          color: #a899d7;
          background: rgba(168,153,215,0.08);
        }
        .code-toolbar-btn--close:hover {
          border-color: rgba(239,68,68,0.3);
          color: #ef4444;
          background: rgba(239,68,68,0.08);
        }
        .code-toolbar-btn--voice:hover {
          border-color: rgba(244,114,182,0.3);
          color: #f472b6;
          background: rgba(244,114,182,0.08);
        }
        .code-toolbar-btn--voice-active {
          border-color: rgba(239,68,68,0.4) !important;
          color: #ef4444 !important;
          background: rgba(239,68,68,0.1) !important;
          animation: voice-pulse 1.5s ease-in-out infinite;
        }
        @keyframes voice-pulse {
          0%, 100% { box-shadow: 0 0 0 0 rgba(239,68,68,0.2); }
          50% { box-shadow: 0 0 0 4px rgba(239,68,68,0.1); }
        }
        .voice-overlay {
          position: absolute;
          bottom: 52px;
          left: 16px;
          right: 16px;
          z-index: 20;
          display: flex;
          align-items: center;
          gap: 8px;
          padding: 8px 12px;
          border-radius: 8px;
          border: 1px solid var(--tb-border, rgba(169,177,214,0.15));
          background: var(--voice-bg, #1a1b26);
          font-family: ui-monospace, 'Cascadia Code', 'Source Code Pro', monospace;
          font-size: 13px;
          box-shadow: 0 4px 20px rgba(0,0,0,0.3);
        }
        .voice-overlay input {
          flex: 1;
          background: transparent;
          border: none;
          outline: none;
          color: inherit;
          font-family: inherit;
          font-size: inherit;
        }
        .voice-overlay input::placeholder {
          opacity: 0.4;
        }
        .voice-overlay-btn {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          background: transparent;
          border: 1px solid var(--tb-border, rgba(169,177,214,0.15));
          color: var(--tb-color, #787c99);
          width: 28px;
          height: 28px;
          border-radius: 6px;
          cursor: pointer;
          transition: all 0.15s ease;
          flex-shrink: 0;
        }
        .voice-overlay-btn:hover {
          color: var(--tb-hover, #a9b1d6);
        }
        .voice-overlay-btn--send:hover {
          border-color: rgba(34,197,94,0.4);
          color: #22c55e;
          background: rgba(34,197,94,0.1);
        }
        .voice-overlay-btn--cancel:hover {
          border-color: rgba(239,68,68,0.4);
          color: #ef4444;
          background: rgba(239,68,68,0.1);
        }
        .voice-interim {
          opacity: 0.4;
          font-style: italic;
        }
      `}</style>

      <div className="mx-4 mb-4" style={{ position: 'relative', flex: 1, minHeight: 0 }}>
        <div style={{ height: '100%', borderRadius: 6, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          <div ref={containerRef} style={{ flex: 1, minHeight: 0 }} />
          {(!connected || containerError) && (
            <div style={{
              position: 'absolute',
              top: '50%', left: '50%',
              transform: 'translate(-50%, -50%)',
              background: containerError ? 'rgba(255,235,235,0.95)' : 'var(--muted)',
              color: containerError ? '#991b1b' : 'var(--muted-foreground)',
              padding: '14px 28px',
              borderRadius: 8,
              fontSize: 13,
              fontFamily: "ui-monospace, 'Cascadia Code', 'Source Code Pro', monospace",
              fontWeight: 500,
              border: '1px solid var(--border)',
              boxShadow: '0 4px 24px rgba(0,0,0,0.4)',
              zIndex: 10,
              textAlign: 'center',
              maxWidth: 320,
              letterSpacing: '0.02em',
              display: 'flex',
              alignItems: 'center',
              gap: 8,
            }}>
              {containerError
                ? `Container error: ${containerError}`
                : <><SpinnerIcon size={16} /> Loading...</>}
            </div>
          )}

          {/* Voice-to-text overlay */}
          {(voiceActive || voiceText) && (
            <div className="voice-overlay" style={{ '--voice-bg': resolveTheme(termTheme).background, color: resolveTheme(termTheme).foreground }}>
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#ef4444" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ flexShrink: 0, animation: voiceActive ? 'voice-pulse 1.5s ease-in-out infinite' : 'none' }}>
                <rect x="5" y="1" width="6" height="8" rx="3" />
                <path d="M3 7a5 5 0 0 0 10 0" />
                <line x1="8" y1="12" x2="8" y2="15" />
              </svg>
              <input
                type="text"
                value={voiceText + (voiceInterim ? ' ' + voiceInterim : '')}
                onChange={(e) => { setVoiceText(e.target.value); setVoiceInterim(''); }}
                onKeyDown={(e) => { if (e.key === 'Enter') sendVoiceText(); if (e.key === 'Escape') cancelVoice(); }}
                placeholder="Listening..."
                autoFocus
              />
              <button className="voice-overlay-btn voice-overlay-btn--send" onClick={sendVoiceText} title="Send to terminal">
                <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="2" y1="8" x2="14" y2="8" />
                  <polyline points="9,3 14,8 9,13" />
                </svg>
              </button>
              <button className="voice-overlay-btn voice-overlay-btn--cancel" onClick={cancelVoice} title="Cancel">
                <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
                  <line x1="4" y1="4" x2="12" y2="12" />
                  <line x1="12" y1="4" x2="4" y2="12" />
                </svg>
              </button>
            </div>
          )}

          {/* Toolbar */}
          {showToolbar && (
          <div
            ref={toolbarRef}
            style={{
              flexShrink: 0,
              height: 42,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              padding: '0 16px',
              background: 'var(--muted)',
            }}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <button
                className="code-toolbar-btn code-toolbar-btn--theme"
                onClick={cycleTheme}
              >
                {themeIcon}
                {themeLabel}
              </button>
              <button
                className={`code-toolbar-btn code-toolbar-btn--voice${voiceActive ? ' code-toolbar-btn--voice-active' : ''}`}
                onClick={voiceActive ? stopVoice : startVoice}
                title="Voice to text"
              >
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <rect x="5" y="1" width="6" height="8" rx="3" />
                  <path d="M3 7a5 5 0 0 0 10 0" />
                  <line x1="8" y1="12" x2="8" y2="15" />
                </svg>
                Voice
              </button>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <button
                className="code-toolbar-btn code-toolbar-btn--commit"
                onClick={() => sendCommand('/commit-changes')}
              >
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
                  <circle cx="8" cy="8" r="3" />
                  <line x1="8" y1="1" x2="8" y2="5" />
                  <line x1="8" y1="11" x2="8" y2="15" />
                </svg>
                Commit
              </button>
              <button
                className="code-toolbar-btn code-toolbar-btn--merge"
                onClick={() => sendCommand('/ai-merge-back')}
              >
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <circle cx="4" cy="4" r="2" />
                  <circle cx="12" cy="12" r="2" />
                  <path d="M4 6v2c0 2.2 1.8 4 4 4h2" />
                </svg>
                Merge
              </button>
              <button
                className="code-toolbar-btn code-toolbar-btn--reconnect"
                onClick={handleReconnect}
              >
                <div
                  ref={statusRef}
                  style={{
                    width: 7,
                    height: 7,
                    borderRadius: '50%',
                    backgroundColor: STATUS.connecting,
                    boxShadow: `0 0 6px ${STATUS.connecting}`,
                    transition: 'all 0.3s ease',
                  }}
                />
                Reconnect
              </button>
              <button
                className="code-toolbar-btn code-toolbar-btn--close"
                onClick={onCloseSession}
              >
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="#ef4444" strokeWidth="1.5" strokeLinecap="round">
                  <line x1="4" y1="4" x2="12" y2="12" />
                  <line x1="12" y1="4" x2="4" y2="12" />
                </svg>
                Close Session
              </button>
            </div>
          </div>
          )}
        </div>
      </div>
    </>
  );
}
