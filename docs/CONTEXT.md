# Architecture Context

High-level overview of how the RGR orchestrator is built. Use this as a reference when contributing or debugging.

## System Components

```
scripts/new-project.sh     Interactive wizard (mode selection, worktree setup, config generation)
scripts/start.sh           Launches tmux 2x2 grid + orchestrator + 3 Claude Code agents
scripts/stop.sh            Sends /exit to agents, kills tmux session, cleans up branches
orchestrator/orchestrator.py   Main event loop (polls mailbox, asks LLM, manages git merges)
orchestrator/llm_client.py     Ollama API client (Qwen3 8B default)
orchestrator/mailbox_watcher.py  File watcher for JSON messages in shared/<project>/mailbox/
mcp-bridge/index.js        MCP server exposing mailbox tools to Claude Code agents
```

## Three Modes

The wizard (`new-project.sh`) presents three options:

1. **PM Pre-Flight** -- Launches Claude Code as a PM agent to generate a PRD from a vague idea. Standalone step that exits after generating `prd.md`. Does not start the RGR pipeline. Prompt template: `docs/pm_agent.md`.

2. **New Project (`mode: new`)** -- Classic TDD. QA writes failing tests, Dev writes minimum code to pass, Refactor cleans up. Agent prompts loaded from `docs/NEW PROJECT PROMPTS.md`.

3. **Existing Project (`mode: existing`)** -- Characterization. QA writes tests that PASS against existing code, Dev verifies coverage (no source changes), Refactor modernizes. Agent prompts loaded from `docs/EXISTING PROJECT PROMPTS.md`. Includes interactive file/folder discovery for selecting source files to characterize.

## Git Worktree Layout

Each project uses a single repo with three worktrees:

```
~/Repositories/my-app/              # Main repo (default branch, merge target)
├── .worktrees/
│   ├── qa/                         # QA worktree (red/<task> branches)
│   ├── dev/                        # Dev worktree (green/<task> branches)
│   └── refactor/                   # Refactor worktree (blue/<task> branches)
```

Each worktree has its own `CLAUDE.md` with agent-specific instructions and MCP communication protocol.

## RGR State Machine

The orchestrator cycles through these states per task:

```
IDLE ──> WAITING_QA_RED ──> WAITING_DEV_GREEN ──> WAITING_REFACTOR_BLUE ──> IDLE (next task)
                                                                      └──> BLOCKED (merge conflict)
```

Git merges happen between phases (bash subprocess, not LLM):
- `red/<task>` merges into Dev's worktree before GREEN
- `green/<task>` merges into Refactor's worktree before BLUE
- `blue/<task>` merges into the default branch (main) after BLUE

Merge conflicts set state to BLOCKED and flag human review.

## Communication (MCP Bridge)

Agents communicate through JSON files in `shared/<project>/mailbox/`:

```
shared/<project>/mailbox/
├── to_dev/          # Messages for Dev agent
├── to_qa/           # Messages for QA agent
└── to_refactor/     # Messages for Refactor agent
```

MCP tools available to agents:
- `check_messages` -- Poll mailbox (with role: dev/qa/refactor)
- `send_to_qa` -- Dev notifies QA that code is ready for testing
- `send_to_dev` -- QA sends test results back to Dev
- `send_to_refactor` -- Dev sends passing code to Refactor
- `send_refactor_complete` -- Refactor signals cleanup is done
- `list_workspace` / `read_workspace_file` -- Shared workspace access

The orchestrator polls the mailbox independently via `mailbox_watcher.py`, routes messages, and writes instructions to agent mailboxes.

## Configuration

```yaml
# projects/<name>/config.yaml
project: my_project
mode: new                    # "new" or "existing"
repo_dir: ~/Repositories/my-app

tmux:
  session_name: myproject

agents:
  qa:
    working_dir: ~/Repositories/my-app/.worktrees/qa
    pane: qa.0
  dev:
    working_dir: ~/Repositories/my-app/.worktrees/dev
    pane: qa.1
  refactor:
    working_dir: ~/Repositories/my-app/.worktrees/refactor
    pane: qa.2
```

Shared defaults in `orchestrator/config.yaml` (LLM model, polling interval, max retries, nudge cooldown). Project configs are deep-merged with shared defaults.

## tmux Layout

```
+--------------------+--------------------+
|  QA_RED [project]  | DEV_GREEN [project]|
|  (Claude Code)     | (Claude Code)      |
+--------------------+--------------------+
| REFACTOR_BLUE      |  ORCH [project]    |
|  (Claude Code)     |  (Python orch)     |
+--------------------+--------------------+
```

Optional iTerm2 background images: `scripts/setup-iterm-profiles.sh` creates a composite 2x2 image with robot avatars at 35% opacity. `start.sh` switches to the RGR profile and sets transparent pane backgrounds.
