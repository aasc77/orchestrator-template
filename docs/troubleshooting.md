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
   cd mcp-bridge && node test.js
   ```

2. Verify MCP is registered with Claude Code:
   - Ask the agent: "What MCP tools do you have?"
   - Should see: send_to_qa, send_to_dev, check_messages, list_workspace, read_workspace_file

3. Check for messages manually:
   ```bash
   ls shared/mailbox/to_dev/    # Messages waiting for Dev
   ls shared/mailbox/to_qa/     # Messages waiting for QA
   cat shared/mailbox/to_dev/*.json
   ```

4. If using symlinks (migrate-comms.sh), verify they're valid:
   ```bash
   ls -la shared/mailbox/
   ```

5. Tell the agent: "Use check_messages with role dev" (or qa)

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
