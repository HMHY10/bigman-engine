import { createReactAgent } from '@langchain/langgraph/prebuilt';
import { SystemMessage } from '@langchain/core/messages';
import { createModel } from './model.js';
import { createJobTool, getJobStatusTool, planPopebotUpdatesTool, createStartHeadlessCodingTool, createGetRepositoryDetailsTool } from './tools.js';
import { SqliteSaver } from '@langchain/langgraph-checkpoint-sqlite';
import { jobPlanningMd, codePlanningMd, thepopebotDb } from '../paths.js';
import { render_md } from '../utils/render-md.js';
import { createWebSearchTool, getProvider } from './web-search.js';
import { getConfig } from '../config.js';

let _chatAgent = null;

let _currentCodeModeType = 'plan';
export function setCurrentCodeModeType(mode) { _currentCodeModeType = mode; }
export function getCurrentCodeModeType() { return _currentCodeModeType; }

/**
 * Get or create the LangGraph job agent singleton.
 * Uses createReactAgent which handles the tool loop automatically.
 * Prompt is a function so {{datetime}} resolves fresh each invocation.
 */
export async function getChatAgent() {
  if (!_chatAgent) {
    // Chat agent needs enough tokens to generate complete job descriptions with tool calls.
    // Enforce a minimum of 4096 regardless of LLM_MAX_TOKENS (which may be set low for cost savings).
    const configuredTokens = Number(getConfig('LLM_MAX_TOKENS')) || 4096;
    const model = await createModel({ maxTokens: Math.max(configuredTokens, 4096) });
    const tools = [createJobTool, getJobStatusTool, planPopebotUpdatesTool];

    const webSearchTool = await createWebSearchTool();
    if (webSearchTool) {
      tools.push(webSearchTool);
      console.log(`[agent] Web search enabled (provider: ${getProvider()})`);
    }

    const checkpointer = SqliteSaver.fromConnString(thepopebotDb);

    _chatAgent = createReactAgent({
      llm: model,
      tools,
      checkpointSaver: checkpointer,
      prompt: (state) => [new SystemMessage(render_md(jobPlanningMd)), ...state.messages],
    });
  }
  return _chatAgent;
}

/**
 * Reset the chat agent singleton (e.g., when config changes).
 */
export function resetChatAgent() {
  _chatAgent = null;
}

const _codeAgents = new Map();

/**
 * Get or create a code agent for a specific chat/workspace.
 * Each code chat gets its own agent with unique start_coding tool bindings.
 * @param {object} context
 * @param {string} context.repo - GitHub repo
 * @param {string} context.branch - Git branch
 * @param {string} context.workspaceId - Pre-created workspace row ID
 * @param {string} context.chatId - Chat thread ID
 * @returns {Promise<object>} LangGraph agent
 */
export async function getCodeAgent({ repo, branch, workspaceId, chatId }) {
  const key = `${repo}_${branch}_${workspaceId}`;
  if (_codeAgents.has(key)) {
    return _codeAgents.get(key);
  }

  const model = await createModel();
  const startHeadlessCodingTool = createStartHeadlessCodingTool({ repo, branch, workspaceId });
  const getRepoDetailsTool = createGetRepositoryDetailsTool({ repo, branch });

  const tools = [startHeadlessCodingTool, getRepoDetailsTool];

  const webSearchTool = await createWebSearchTool();
  if (webSearchTool) {
    tools.push(webSearchTool);
    console.log(`[agent] Web search enabled for code agent (provider: ${getProvider()})`);
  }

  const checkpointer = SqliteSaver.fromConnString(thepopebotDb);

  const agent = createReactAgent({
    llm: model,
    tools,
    checkpointSaver: checkpointer,
    prompt: (state) => [new SystemMessage(render_md(codePlanningMd)), ...state.messages],
  });

  _codeAgents.set(key, agent);
  return agent;
}
