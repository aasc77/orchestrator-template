# Troubleshooting Guide

## Orchestrator won't start

**"Ollama is not running"**
```bash
ollama serve
ollama pull qwen3:8b
```

**"No pending tasks found"**
- Check `tasks.json` — all tasks might be marked `completed` or `stuck`
- Reset a task: set its `status` to `"pending"` and `attempts` to `0`

## Agents aren't picking up messages

1. Verify MCP bridge is installed:
   ```bash
   node my-orchestrator/mcp-bridge/test.js
   ```

2. Verify MCP is registered with Claude Code:
   - Ask the agent: "What MCP tools do you have?"
   - Should see: send_to_qa, send_to_dev, send_to_refactor, send_refactor_complete, check_messages, list_workspace, read_workspace_file

3. Check for messages manually:
   ```bash
   ls shared/<project>/mailbox/to_dev/       # Messages waiting for Dev
   ls shared/<project>/mailbox/to_qa/        # Messages waiting for QA
   ls shared/<project>/mailbox/to_refactor/  # Messages waiting for Refactor
   cat shared/<project>/mailbox/to_dev/*.json
   ```

4. Tell the agent: "Use check_messages with role dev" (or qa, or refactor)

## Orchestrator ignores its own messages

The orchestrator writes messages to agent mailboxes (from: "orchestrator").
It filters these out when polling so it doesn't react to its own messages.
If you see it looping on its own messages, check that `from` field is set correctly.

## Task stuck in a loop

- Check `orchestrator/orchestrator.log` for LLM reasoning
- Default max is 5 attempts per task — configurable in `config.yaml`
- Reset: edit `tasks.json`, set `"attempts": 0` and `"status": "in_progress"`

## Orchestrator LLM gives bad JSON

Qwen3 sometimes adds `<think>` tags. The `llm_client.py` strips these automatically.
If parse errors persist:
- Check `orchestrator.log` for raw LLM response
- Try a different model in `config.yaml`
- Increase temperature slightly

## Changing the orchestrator model

Edit `orchestrator/config.yaml`:
```yaml
llm:
  model: qwen3:14b
```

Good options:
- `qwen3:4b` — fastest, minimal memory
- `qwen3:8b` — default, good balance (recommended)
- `qwen3:14b` — smarter routing
- `qwen3:32b` — even smarter, needs ~20GB+ RAM
- `deepseek-r1:8b` — better at reasoning about bug severity
- `llama3.3:70b` — most capable, needs ~40GB+ RAM

## Claude Code runs out of context

Long sessions exhaust the context window. Solutions:
- Start a fresh Claude Code session
- The CLAUDE.md re-orients the agent on its role
- Message history is in the mailbox files, so context carries over

## Git worktree issues

**"fatal: '<path>' is already checked out"**
A worktree is already using that branch. Each worktree must be on a different branch:
```bash
cd <your-repo>
git worktree list    # See what's checked out where
```

**Worktree in dirty state after failed merge**
The orchestrator stashes/unstashes when merging. If a merge fails mid-way:
```bash
cd <your-repo>/.worktrees/dev
git stash list       # Check for orphaned stashes
git status           # Check for merge conflicts
git merge --abort    # If mid-merge
```

**Worktree not found**
The wizard creates worktrees at `.worktrees/qa`, `.worktrees/dev`, `.worktrees/refactor`. If they're missing:
```bash
cd <your-repo>
git worktree add .worktrees/qa
git worktree add .worktrees/dev
git worktree add .worktrees/refactor
```

## Characterization mode (existing projects)

**QA tests are failing instead of passing**
In `mode: existing`, QA should write tests that PASS against the existing code. Check:
- `config.yaml` has `mode: existing`
- The QA `CLAUDE.md` instructs writing characterization tests (tests that capture current behavior)

**Dev modifying source code in existing mode**
In characterization mode, Dev should NOT modify source files -- only verify test coverage and add test cases. Check the Dev `CLAUDE.md` for correct instructions.

## Merge conflicts between phases

If the orchestrator reports BLOCKED:
1. Check the ORCH pane for which merge failed (e.g., "merge red/task-1 into dev failed")
2. Go to the affected worktree and resolve manually:
   ```bash
   cd <your-repo>/.worktrees/dev
   git status    # See conflicting files
   # Resolve conflicts, then:
   git add .
   git commit
   ```
3. Reset the task in `tasks.json` (`status: "pending"`, `attempts: 0`)

## Agent permission prompts slowing things down

Agents frequently block on MCP tool permissions. To run fully autonomously:
```bash
my-orchestrator/scripts/start.sh <project> --yolo
```

This passes `--dangerouslySkipPermissions` to all Claude Code agents.
