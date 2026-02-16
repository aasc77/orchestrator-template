# Multi-Agent Dev/QA System with AI Orchestrator

Fully automated: Dev codes, QA tests, local AI orchestrator routes decisions.
All communication happens through a shared MCP mailbox — no tmux wiring needed.

## Architecture

```
+--------------------------------------+
|     Orchestrator (Qwen3 8B local)    |
|     Polls mailbox, makes decisions,  |
|     writes instructions back         |
+-----------+--------------------------+
            | reads/writes
      +-----+-----+
      |  Mailbox  |  (shared/mailbox/ or ~/shared-comms/)
      +-----+-----+
            | MCP tools: check_messages, send_to_qa, send_to_dev
      +-----+-----+
      |           |
+-----v----+ +---v------+
| Dev Agent | | QA Agent |
| Claude    | | Claude   |
| Code      | | Code     |
+----------+ +----------+
```

## How It Works

1. Orchestrator writes first task to Dev's mailbox
2. Dev agent calls `check_messages` -> gets the task -> codes it
3. Dev calls `send_to_qa` with summary + test instructions
4. Orchestrator sees the message, writes test instruction to QA's mailbox
5. QA agent calls `check_messages` -> gets test request -> tests it
6. QA calls `send_to_dev` with pass/fail + bugs
7. Orchestrator sees results, asks local LLM to decide:
   - **PASS** -> writes next task to Dev's mailbox
   - **FAIL** -> writes bug details to Dev's mailbox
   - **STUCK** (5+ attempts) -> flags for human review
8. Loop until all tasks complete

No tmux. No keystrokes. Just files in a folder.

## Quick Start (Existing Agents)

If you already have Dev and QA agents running with `~/shared-comms/`:

```bash
# 1. Copy this template to your project
cp -r orchestrator-template my-project-orchestrator
cd my-project-orchestrator

# 2. Bridge existing folders to MCP mailbox
chmod +x scripts/*.sh
./scripts/migrate-comms.sh

# 3. Add MCP tools to both agents (if not already done)
claude mcp add agent-bridge node $(pwd)/mcp-bridge/index.js

# 4. Copy CLAUDE.md to each agent's working directory
cp agents/dev/CLAUDE.md /path/to/dev/agent/CLAUDE.md
cp agents/qa/CLAUDE.md /path/to/qa/agent/CLAUDE.md

# 5. Edit tasks.json with your project's tasks

# 6. Tell each agent to re-read CLAUDE.md

# 7. Start orchestrator
./scripts/start.sh
```

## Fresh Install

```bash
cd my-project-orchestrator
./scripts/setup.sh      # Install deps, pull Qwen3 8B
# Edit tasks.json with your tasks
# Edit agents/dev/CLAUDE.md and agents/qa/CLAUDE.md with project context
./scripts/start.sh      # Start orchestrator
# Start Claude Code in two terminals with MCP config
```

## Configuration

### tasks.json
Define your tasks with:
- `id`: Unique identifier (e.g., `issue-42`)
- `title`: Short description
- `description`: Detailed requirements for the Dev agent
- `acceptance_criteria`: Measurable outcomes QA will verify
- `status`: `pending`, `in_progress`, `completed`, or `stuck`

### Agent CLAUDE.md Files
Customize `agents/dev/CLAUDE.md` and `agents/qa/CLAUDE.md` with:
- Project-specific context (architecture, tech stack, URLs)
- Test credentials and environment details
- Known bugs and deployment instructions

### config.yaml
Tune orchestrator behavior:
- LLM model and temperature
- Polling interval
- Max retry attempts per task

## File Structure

```
orchestrator-template/
├── README.md
├── tasks.json                   # Task queue (edit with your tasks)
├── claude-code-mcp-config.json  # MCP config for Claude Code
├── mcp-bridge/
│   ├── package.json
│   ├── index.js                 # MCP server (mailbox tools)
│   └── test.js
├── orchestrator/
│   ├── orchestrator.py          # Main loop (polls mailbox, asks LLM)
│   ├── llm_client.py            # Ollama API client
│   ├── mailbox_watcher.py       # File watcher for mailbox
│   ├── requirements.txt
│   └── config.yaml              # Settings (model, poll interval, etc)
├── agents/
│   ├── dev/CLAUDE.md            # Dev persona + project context
│   └── qa/CLAUDE.md             # QA persona + test environment
├── shared/
│   └── mailbox/
│       ├── to_dev/              # Messages for Dev
│       └── to_qa/               # Messages for QA
├── scripts/
│   ├── setup.sh                 # One-time install
│   ├── start.sh                 # Start orchestrator
│   ├── stop.sh                  # Stop orchestrator
│   └── migrate-comms.sh         # Bridge existing ~/shared-comms/
└── docs/
    ├── mcp-setup.md
    └── troubleshooting.md
```

## For Claude Code

If you are Claude Code continuing this project:
1. Read ALL files before making changes
2. The MCP bridge must be installed (`npm install` in mcp-bridge/)
3. Agents communicate ONLY through MCP tools (check_messages, send_to_qa, send_to_dev)
4. The orchestrator is a separate Python process that polls the same mailbox
5. Orchestrator writes messages as JSON files — agents read them via MCP
6. Check config.yaml for tunable settings (model, poll interval, max attempts)
