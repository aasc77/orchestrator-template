# MCP Bridge Setup Guide

## What is the MCP Bridge?

The MCP bridge is a small Node.js server that gives both Claude Code instances
shared tools for communication: `send_to_qa`, `send_to_dev`, `check_messages`,
`list_workspace`, and `read_workspace_file`.

It uses a file-based mailbox system — messages are JSON files written to
`shared/<project>/mailbox/to_dev/` and `shared/<project>/mailbox/to_qa/`.

## Adding MCP to Claude Code

### Option 1: CLI (Recommended)
```bash
claude mcp add agent-bridge node /path/to/my-orchestrator/mcp-bridge/index.js
```

### Option 2: Config File
Add to `~/.claude/claude_code_config.json`:
```json
{
  "mcpServers": {
    "agent-bridge": {
      "command": "node",
      "args": ["/absolute/path/to/my-orchestrator/mcp-bridge/index.js"]
    }
  }
}
```

### Option 3: Per-session flag
```bash
claude --mcp-config /path/to/my-orchestrator/claude-code-mcp-config.json
```

## Verifying It Works

1. Start Claude Code with the MCP config
2. Ask Claude: "What MCP tools do you have?"
3. You should see: send_to_qa, send_to_dev, check_messages, list_workspace, read_workspace_file

## Troubleshooting

- **"No MCP tools found"**: Check the path in your config is absolute and correct
- **"Cannot find module"**: Run `npm install` in the mcp-bridge/ directory
- **Messages not appearing**: Check permissions on shared/<project>/mailbox/ directories
