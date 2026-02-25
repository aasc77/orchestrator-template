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

## 2. Clone and Run Setup

```bash
git clone https://github.com/aasc77/orchestrator-template.git my-orchestrator
my-orchestrator/scripts/setup.sh
```

Setup will:
- Verify all prerequisites are installed
- Pull the Qwen3 8B model for the orchestrator LLM
- Install Node.js dependencies for the MCP bridge
- Install Python dependencies for the orchestrator
- Configure the MCP bridge with the correct absolute path
- Run a quick self-test to verify the bridge works
- **Prompt to create your first project** (runs the wizard automatically)

## 3. Create Your Project

Setup prompts you to create a project at the end. If you skipped it, run the wizard manually:

```bash
my-orchestrator/scripts/new-project.sh
```

Or pass the folder name directly:

```bash
my-orchestrator/scripts/new-project.sh my-app
```

The wizard will:
1. Ask for the folder name in `~/Repositories/` (your dev repo)
2. Auto-derive a project name and key from the folder name
3. Auto-create the QA directory (clones from dev's git remote if available, otherwise creates an empty directory)
4. Show a summary and ask for confirmation
5. Generate all project files:

```
projects/my-app/
├── config.yaml              # Working dirs, session name, pane targets
└── tasks.json               # Two smoke-test tasks (ready to run)

~/Repositories/my-app/CLAUDE.md      # Dev agent instructions
~/Repositories/my-app_qa/CLAUDE.md   # QA agent instructions
```

It also creates the shared mailbox and workspace directories at `shared/my-app/`.

**Where things live:** Each project has files in three places:

| Location | What | Purpose |
|----------|------|---------|
| `~/Repositories/my-app/` | Your code + `CLAUDE.md` | Where the Dev agent works (CLAUDE.md is picked up automatically) |
| `~/Repositories/my-app_qa/` | Your code + `CLAUDE.md` | Where the QA agent works (CLAUDE.md is picked up automatically) |
| `my-orchestrator/projects/my-app/` | Orchestrator config | Tasks and session settings |

The `shared/my-app/` directory is created at runtime for the mailbox (how agents communicate) and workspace (shared files).

<details>
<summary>Manual setup (without wizard)</summary>

```bash
# Set up working directories
cd ~/Repositories
git clone git@github.com:yourorg/my-app.git            # Dev's copy
git clone git@github.com:yourorg/my-app.git my-app_qa   # QA's copy

# Create project from template
cp -r my-orchestrator/projects/example my-orchestrator/projects/myproject

# Edit config.yaml to point at your directories
vi my-orchestrator/projects/myproject/config.yaml
```

</details>

## Using with an Existing Project

If you already have a repo with a `CLAUDE.md`, the wizard won't overwrite it. It appends only the MCP communication section your agents need to talk to each other.

```bash
my-orchestrator/scripts/new-project.sh my-existing-app
```

The wizard will:
1. Find your existing dev directory at `~/Repositories/my-existing-app`
2. Create the QA directory (clone or empty) if it doesn't exist
3. Show what it will do to each `CLAUDE.md`:
   - **"exists -- will append MCP section"**: Your file is preserved, MCP protocol added to the end
   - **"exists, MCP already present -- skip"**: Nothing changes (safe to re-run)
   - **"new"**: Full template created
4. Create the orchestrator config and shared mailbox directories

### Tasks are optional

You don't need to pre-define tasks. The wizard creates smoke-test tasks by default, but you can clear them and drive the workflow manually:

```json
{
  "project": "my_existing_app",
  "tasks": []
}
```

Then just launch and talk directly to the Dev agent in its tmux pane:
- "Grab issue #42 from GitHub and fix it"
- "Refactor the auth middleware to use JWT"
- "Run the test suite and fix any failures"

The Dev agent implements the work, calls `send_to_qa`, and the orchestrator routes messages between agents automatically. The ORCH pane stays alive for interactive commands and message routing.

### What gets appended to your CLAUDE.md

For the **Dev** agent, this block is appended:

```markdown
---

## Communication Protocol (MCP-Based)

You are the **DEVELOPER** agent in an automated Dev/QA workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_qa`** -- Notify QA that code is ready for testing
- **`check_messages`** -- Check your mailbox (role: "dev")
- **`list_workspace`** / **`read_workspace_file`** -- Shared workspace access

### Workflow
1. Receive a task via `check_messages` or direct instruction
2. Implement the feature/fix
3. Call `send_to_qa` with summary, files changed, and test instructions
4. Call `check_messages` to get QA results
5. Fix bugs if needed, repeat
```

For the **QA** agent, a similar block is appended with `send_to_dev` and `check_messages` (role: "qa").

The full snippets are in `scripts/new-project.sh` if you need to add them manually.

---

## 4. Customize Your Project

The wizard generates working defaults, but you'll want to customize these files for your actual project.

### tasks.json

Replace the smoke-test tasks with your real work:

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

The wizard creates a `CLAUDE.md` in each working directory. Claude Code picks these up automatically -- both when launched by the orchestrator and when you run `claude` standalone. The more context you add, the better the agents perform. Fill in the `<!-- TODO -->` placeholders the wizard left in each file.

**`~/Repositories/my-app/CLAUDE.md`** (Dev) -- Add under "Project Context":
```markdown
## Project Context

- Node.js/Express API with PostgreSQL
- Codebase: ~/Repositories/my-app
- Run locally: `npm run dev` (port 3000)
- Database: `docker compose up -d` starts PostgreSQL on port 5432
- Existing patterns: see routes/users.js for reference
```

**`~/Repositories/my-app_qa/CLAUDE.md`** (QA) -- Add under "Test Environment":
```markdown
## Test Environment

- API runs at http://localhost:3000
- Test with: `curl`, `httpie`, or write scripts in tests/
- Database seed: `npm run seed` creates test users
- Test credentials: test@example.com / password123
```

The more context you provide, the better the agents perform.

## 5. iTerm2 Background Images (Optional)

Set up robot background images for each pane in the 2x2 grid. This creates a composite image with the QA (red), Dev (green), Refactor (blue), and Orchestrator robots, then uses transparent tmux panes so the images show through.

```bash
# One-time setup (creates iTerm2 "RGR" profile)
bash scripts/setup-iterm-profiles.sh

# Restart iTerm2 to pick up the new profile
# Cmd+Q, then reopen iTerm2
```

Verify the profile exists: **iTerm2 > Settings > Profiles > RGR**

When you run `start.sh`, it automatically detects the composite image, sets transparent pane backgrounds, and switches iTerm2 to the RGR profile. If the composite isn't found, it falls back to solid color backgrounds.

To regenerate the composite (e.g. after replacing images in `images/`):

```bash
bash scripts/setup-iterm-profiles.sh
# Restart iTerm2
```

Source images live in `images/` (Red_robot.png, Green_rotbot.png, Blue_robot.png, orchestrator.png).

## 6. Launch

```bash
my-orchestrator/scripts/start.sh myproject
```

To skip all Claude Code confirmation prompts (agents run fully autonomously):

```bash
my-orchestrator/scripts/start.sh myproject --yolo
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
my-orchestrator/scripts/stop.sh myproject
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

Dev and QA each work in their own `working_dir`. They share files through the MCP workspace tools (`read_workspace_file`, `list_workspace`), not through the filesystem directly. If an agent needs to share a file, it should use the MCP tools. Alternatively, point both agents at the same directory -- but be aware of potential conflicts.

### MCP tools not available to agents

Verify the MCP config has the correct absolute path:

```bash
cat claude-code-mcp-config.json
```

The `args` array should contain the full path to `mcp-bridge/index.js`. Run `my-orchestrator/scripts/setup.sh` again if it still shows the placeholder.
