# Quickstart Guide

This guide walks you through setting up and running your first automated Dev/QA session from scratch.

## 1. Install Prerequisites

Make sure you have these installed before proceeding:

```bash
brew install tmux node python3 ollama
npm install -g @anthropic-ai/claude-code
```

Start Ollama (leave it running in a separate terminal or as a background service):

```bash
ollama serve
```

## 2. Set Up Working Directories

Each agent needs its own working directory. Dev writes code in one, QA tests in the other.

**Why two directories?** Dev and QA run as separate Claude Code sessions. Giving them separate directories prevents them from interfering with each other (e.g., Dev editing a file while QA is reading it). They communicate through a shared MCP mailbox, not through the filesystem.

```bash
# Example: Dev works in the main repo, QA gets a separate clone
cd ~/Repositories
git clone git@github.com:yourorg/my-app.git            # Dev's copy
git clone git@github.com:yourorg/my-app.git my-app-qa   # QA's copy
```

You can also point both to the same directory if you prefer -- it works but can cause conflicts if both agents touch the same files simultaneously.

## 3. Clone and Run Setup

```bash
git clone <this-repo> my-orchestrator
cd my-orchestrator
./scripts/setup.sh
```

Setup will:
- Verify all prerequisites are installed
- Pull the Qwen3 8B model for the orchestrator LLM
- Install Node.js dependencies for the MCP bridge
- Install Python dependencies for the orchestrator
- Configure the MCP bridge with the correct absolute path
- Run a quick self-test to verify the bridge works

## 4. Create Your Project

```bash
cp -r projects/example projects/myproject
```

This gives you:

```
projects/myproject/
├── config.yaml              # Project settings
├── tasks.json               # Task queue
└── agents/
    ├── dev/CLAUDE.md        # Dev agent instructions
    └── qa/CLAUDE.md         # QA agent instructions
```

## 5. Configure Your Project

### config.yaml

Point the agents at the working directories you created in step 2:

```yaml
project: myproject                    # Identifier (used in logs and prompts)

tmux:
  session_name: myproject             # tmux session name (must be unique per project)

agents:
  dev:
    working_dir: ~/Repositories/my-app        # Dev's repo clone from step 2
    pane: orch.0                               # Don't change this
  qa:
    working_dir: ~/Repositories/my-app-qa     # QA's repo clone from step 2
    pane: orch.1                               # Don't change this
```

**Important:**
- Both `working_dir` paths must exist before launching. Each agent opens a Claude Code session rooted there.
- `session_name` must be unique if you run multiple projects simultaneously.
- `pane` values (`orch.0`, `orch.1`) map to the tmux layout and should not be changed.

### tasks.json

Define the work you want the agents to do:

```json
{
  "project": "myproject",
  "tasks": [
    {
      "id": "task-1",
      "title": "Add user login endpoint",
      "description": "Create a POST /api/login endpoint that accepts email and password, validates credentials against the users table, and returns a JWT token. Use the existing db.js connection pool.",
      "acceptance_criteria": [
        "POST /api/login returns 200 with JWT for valid credentials",
        "Returns 401 for invalid password",
        "Returns 400 if email or password is missing",
        "JWT contains user ID and email in payload"
      ],
      "status": "pending",
      "attempts": 0
    }
  ]
}
```

Tips for writing good tasks:
- **Be specific in the description.** Mention relevant files, existing patterns, and technical constraints.
- **Make acceptance criteria measurable.** QA will test each one and pass/fail based on them.
- **One feature per task.** Break large features into smaller tasks that can be tested independently.
- **Order matters.** Tasks are assigned sequentially, so put foundational work first.

### Agent CLAUDE.md Files

Add project context so agents know what they're working with.

**`agents/dev/CLAUDE.md`** -- Add under "Project Context":
```markdown
## Project Context

- Node.js/Express API with PostgreSQL
- Codebase: ~/Repositories/my-app
- Run locally: `npm run dev` (port 3000)
- Database: `docker compose up -d` starts PostgreSQL on port 5432
- Existing patterns: see routes/users.js for reference
```

**`agents/qa/CLAUDE.md`** -- Add under "Test Environment":
```markdown
## Test Environment

- API runs at http://localhost:3000
- Test with: `curl`, `httpie`, or write scripts in tests/
- Database seed: `npm run seed` creates test users
- Test credentials: test@example.com / password123
```

The more context you provide, the better the agents perform.

## 6. Launch

```bash
./scripts/start.sh myproject
```

To skip all Claude Code confirmation prompts (agents run fully autonomously):

```bash
./scripts/start.sh myproject --yolo
```

You'll see pre-flight checks, then a tmux session with three panes:

```
+------------------+------------------+
|                  |                  |
|   DEV [myproj]   |   QA [myproj]    |
|   (Claude Code)  |   (Claude Code)  |
|                  |                  |
+------------------+------------------+
|                                     |
|         ORCH [myproj]               |
|         (Python orchestrator)       |
|                                     |
+-------------------------------------+
```

**What happens next:**
1. The orchestrator writes the first task to Dev's mailbox
2. Dev gets nudged ("You have new messages...")
3. Dev reads the task, implements it, calls `send_to_qa`
4. The orchestrator sees the message and writes a test request to QA
5. QA gets nudged, tests the work, calls `send_to_dev` with results
6. The orchestrator decides: advance to next task (pass) or send back (fail)

## 7. Monitor and Interact

Click the **ORCH** pane (bottom) to interact with the orchestrator.

### Built-in commands

```
status          Show current task and progress
tasks           List all tasks with status markers
skip            Skip a stuck task and move to the next one
nudge dev       Manually remind Dev to check messages
nudge qa        Manually remind QA to check messages
msg dev <text>  Send arbitrary text to Dev's terminal
msg qa <text>   Send arbitrary text to QA's terminal
pause           Pause mailbox polling
resume          Resume polling
log             Show last 10 log entries
help            Show all commands
```

### Natural language

You can also just type normally. The orchestrator's LLM will interpret your intent:

```
> what's dev working on?
> tell qa to also test the edge case with empty email
> skip this task, it's blocked on the database migration
```

### Navigation

| Shortcut | Action |
|---|---|
| Click a pane | Switch focus (mouse enabled) |
| `Ctrl-b q` | Show pane numbers |
| `Ctrl-b o` | Cycle to next pane |
| `Ctrl-b ;` | Toggle between last two panes |
| `Ctrl-b d` | Detach (session keeps running in background) |

To reattach after detaching:

```bash
tmux attach -t myproject
```

## 8. Stop

```bash
./scripts/stop.sh myproject
```

This sends `/exit` to both Claude Code agents, stops the orchestrator, and kills the tmux session.

## Troubleshooting

### "Ollama is not running"

```bash
ollama serve    # Start in a separate terminal
ollama pull qwen3:8b   # If model is missing
```

### Agent not responding to nudges

The orchestrator has a 30-second nudge cooldown. If an agent seems stuck:

```
nudge dev       # Force a nudge (clears cooldown)
```

Or check if Claude Code is still running in that pane -- it may have crashed or be waiting for input.

### "nested session" error from Claude Code

This happens when launching `claude` from within an existing Claude Code session. The `start.sh` script handles this by unsetting the `CLAUDECODE` env var, but if you're launching manually:

```bash
unset CLAUDECODE && claude --mcp-config ...
```

### Task stuck after 5 attempts

The orchestrator marks tasks as `stuck` after 5 failed attempts and prints `HUMAN REVIEW NEEDED`. Options:
- Fix the issue manually, reset the task status in `tasks.json` to `pending` and `attempts` to `0`, restart
- Type `skip` in the ORCH pane to move to the next task

### Dev says it wrote files but QA can't find them

Dev and QA each work in their own `working_dir` (see step 2). They share files through the MCP workspace tools (`read_workspace_file`, `list_workspace`), not through the filesystem directly. If an agent needs to share a file, it should use the MCP tools. Alternatively, point both agents at the same directory -- but be aware of potential conflicts.

### MCP tools not available to agents

Verify the MCP config has the correct absolute path:

```bash
cat claude-code-mcp-config.json
```

The `args` array should contain the full path to `mcp-bridge/index.js`. Run `./scripts/setup.sh` again if it still shows the placeholder.
