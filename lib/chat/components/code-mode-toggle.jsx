'use client';

import { useState, useEffect, useCallback } from 'react';
import { GitBranchIcon } from './icons.js';
import { Combobox } from './ui/combobox.js';
import { cn } from '../utils.js';

/**
 * Code mode toggle with repo/branch pickers.
 * When locked (after first message), shows branch bar + headless/interactive toggle.
 *
 * @param {object} props
 * @param {boolean} props.enabled - Whether code mode is on
 * @param {Function} props.onToggle - Toggle callback
 * @param {string} props.repo - Selected repo
 * @param {Function} props.onRepoChange - Repo change callback
 * @param {string} props.branch - Selected branch
 * @param {Function} props.onBranchChange - Branch change callback
 * @param {boolean} props.locked - Whether the controls are locked (after first message)
 * @param {Function} props.getRepositories - Server action to fetch repos
 * @param {Function} props.getBranches - Server action to fetch branches
 * @param {object} [props.workspace] - Workspace object (id, repo, branch, containerName, featureBranch)
 * @param {boolean} [props.isInteractiveActive] - Whether interactive container is running
 * @param {Function} [props.onWorkspaceUpdate] - Callback to refresh workspace state after mode toggle
 */
export function CodeModeToggle({
  features,
  enabled,
  onToggle,
  repo,
  onRepoChange,
  branch,
  onBranchChange,
  locked,
  getRepositories,
  getBranches,
  workspace,
  isInteractiveActive,
  onWorkspaceUpdate,
}) {
  const [repos, setRepos] = useState([]);
  const [branches, setBranches] = useState([]);
  const [loadingRepos, setLoadingRepos] = useState(false);
  const [loadingBranches, setLoadingBranches] = useState(false);
  const [reposLoaded, setReposLoaded] = useState(false);
  const [togglingMode, setTogglingMode] = useState(false);

  // Load repos on first toggle-on
  const handleToggle = useCallback(() => {
    if (locked) return;
    const next = !enabled;
    onToggle(next);
    if (next && !reposLoaded) {
      setLoadingRepos(true);
      getRepositories().then((data) => {
        const list = data || [];
        setRepos(list);
        setReposLoaded(true);
        setLoadingRepos(false);
        if (list.length === 1) {
          onRepoChange(list[0].full_name);
        }
      }).catch(() => setLoadingRepos(false));
    }
    if (!next) {
      onRepoChange('');
      onBranchChange('');
      setBranches([]);
    }
  }, [locked, enabled, reposLoaded, onToggle, onRepoChange, onBranchChange, getRepositories]);

  // Load branches when repo changes
  useEffect(() => {
    if (!repo || locked) return;
    setLoadingBranches(true);
    setBranches([]);
    getBranches(repo).then((data) => {
      const branchList = data || [];
      setBranches(branchList);
      // Auto-select default branch
      const defaultBranch = branchList.find((b) => b.isDefault);
      if (defaultBranch) {
        onBranchChange(defaultBranch.name);
      }
      setLoadingBranches(false);
    }).catch(() => setLoadingBranches(false));
  }, [repo]);

  const handleModeToggle = useCallback(async () => {
    if (!workspace?.id || togglingMode || isInteractiveActive) return;
    setTogglingMode(true);
    try {
      // Only launch interactive mode — closing is handled from the code page
      const { startInteractiveMode } = await import('../../code/actions.js');
      const result = await startInteractiveMode(workspace.id);
      if (result.containerName && onWorkspaceUpdate) onWorkspaceUpdate(result.containerName);
    } catch (err) {
      console.error('Failed to toggle mode:', err);
    } finally {
      setTogglingMode(false);
    }
  }, [workspace?.id, togglingMode, isInteractiveActive, onWorkspaceUpdate]);

  if (!features?.codeWorkspace) return null;

  // Locked mode: show branch bar with feature branch + mode toggle
  if (locked && enabled) {
    const featureBranch = workspace?.featureBranch;
    // Extract just the repo name (last segment of owner/repo)
    const repoName = repo ? repo.split('/').pop() : '';

    return (
      <div className="flex items-center justify-between gap-2 text-sm min-w-0">
        {/* Left: branch flow — feature branch truncates dynamically to fill available space */}
        <div className="flex items-center gap-1.5 text-muted-foreground min-w-0 overflow-hidden">
          <GitBranchIcon size={14} className="shrink-0" />
          {repoName && <span className="shrink-0" title={repo}>{repoName}</span>}
          {branch && (
            <>
              <span className="shrink-0 text-muted-foreground/30">/</span>
              <span className="shrink-0 font-medium text-foreground" title={branch}>{branch}</span>
            </>
          )}
          {featureBranch && (
            <>
              <span className="shrink-0 text-muted-foreground/50">&larr;</span>
              <span className="text-primary truncate min-w-[60px]" title={featureBranch}>{featureBranch}</span>
            </>
          )}
        </div>

        {/* Right: mode toggle */}
        <div className="flex items-center shrink-0">
          <button
            type="button"
            onClick={handleModeToggle}
            disabled={togglingMode || isInteractiveActive}
            className={cn(
              'inline-flex items-center gap-1.5 group',
              isInteractiveActive && 'opacity-50 pointer-events-none'
            )}
            role="switch"
            aria-checked={isInteractiveActive}
            aria-label="Toggle interactive mode"
          >
            {togglingMode && (
              <svg className="animate-spin h-3 w-3 text-muted-foreground" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
            )}
            {/* Track */}
            <span
              className={cn(
                'relative inline-flex h-4 w-7 shrink-0 rounded-full transition-colors duration-200',
                togglingMode && 'opacity-50',
                isInteractiveActive ? 'bg-primary' : 'bg-muted-foreground/30'
              )}
            >
              {/* Knob */}
              <span
                className={cn(
                  'absolute top-0.5 left-0.5 h-3 w-3 rounded-full bg-white shadow-sm transition-transform duration-200',
                  isInteractiveActive && 'translate-x-3'
                )}
              />
            </span>
            {/* Label */}
            <span className={cn(
              'text-xs font-medium transition-colors whitespace-nowrap',
              isInteractiveActive ? 'text-primary' : 'text-muted-foreground'
            )}>
              {togglingMode
                ? (isInteractiveActive ? 'Closing...' : 'Launching...')
                : (isInteractiveActive ? 'Interactive' : 'Headless')
              }
            </span>
          </button>
        </div>
      </div>
    );
  }

  const repoOptions = repos.map((r) => ({ value: r.full_name, label: r.full_name }));
  const branchOptions = branches.map((b) => ({ value: b.name, label: b.name }));

  return (
    <div className="flex flex-wrap items-center justify-center gap-3">
      {/* Slide toggle + label */}
      <button
        type="button"
        onClick={handleToggle}
        className="inline-flex items-center gap-2 group"
        role="switch"
        aria-checked={enabled}
        aria-label="Toggle Code mode"
      >
        {/* Track */}
        <span
          className={cn(
            'relative inline-flex h-5 w-9 shrink-0 rounded-full transition-colors duration-200',
            enabled ? 'bg-primary' : 'bg-muted-foreground/30'
          )}
        >
          {/* Knob */}
          <span
            className={cn(
              'absolute top-0.5 left-0.5 h-4 w-4 rounded-full bg-white shadow-sm transition-transform duration-200',
              enabled && 'translate-x-4'
            )}
          />
        </span>
        {/* Label */}
        <span className={cn(
          'text-xs font-medium transition-colors',
          enabled ? 'text-foreground' : 'text-muted-foreground group-hover:text-foreground'
        )}>
          Code
        </span>
      </button>

      {/* Repo/branch pickers — inline, both always visible */}
      {enabled && (
        <>
          <div className="w-full sm:w-auto sm:min-w-[220px]">
            <Combobox
              options={repoOptions}
              value={repo}
              onChange={onRepoChange}
              placeholder="Select repository..."
              loading={loadingRepos}
              highlight={!repo && !loadingRepos}
            />
          </div>
          <div className={cn("w-full sm:w-auto sm:min-w-[180px]", !repo && "opacity-50 pointer-events-none")}>
            <Combobox
              options={branchOptions}
              value={branch}
              onChange={onBranchChange}
              placeholder="Select branch..."
              loading={loadingBranches}
              highlight={!!repo && !branch && !loadingBranches}
            />
          </div>
        </>
      )}
    </div>
  );
}
