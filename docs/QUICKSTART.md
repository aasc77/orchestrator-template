# Quickstart Guide

This guide walks you through setting up and running your first automated RGR (Red-Green-Refactor) session from scratch.

## How RGR Works

The orchestrator coordinates three Claude Code agents through a strict Red-Green-Refactor cycle:

```
+----------+     +----------+     +----------+
|  QA (RED)|---->|DEV (GREEN)|---->| REFACTOR |----> merge to main
|  writes  |     |  writes  |     |  (BLUE)  |
|  failing |     |  minimum |     |  cleans  |
|  tests   |     |  code to |     |  up code |
|          |     |  pass    |     |          |
+----------+     +----------+     +----------+
     ^                                  |
     |         next task                |
     +----------------------------------+
```

Each agent works in its own **git worktree** on a dedicated branch:

| Agent | Branch | Role |
|-------|--------|------|
| QA | `red/<task-id>` | Writes failing tests (or characterization tests for existing code) |
| Dev | `green/<task-id>` | Writes minimum code to make tests pass |
| Refactor | `blue/<task-id>` | Cleans up code (DRY, naming, docs) without changing behavior |

The orchestrator handles git merges between phases automatically:
- `red/<task>` merges into Dev's worktree
- `green/<task>` merges into Refactor's worktree
- `blue/<task>` merges into the default branch (main)

If a merge conflicts, the orchestrator sets state to BLOCKED and flags a human.

### Three modes

The wizard (`new-project.sh`) presents three options when you create a project:

| Mode | When to use | What happens |
|------|-------------|--------------|
| **1. PM Pre-Flight** | You have a vague idea but no clear requirements | Claude generates a PRD from your idea, then exits. Run the wizard again with mode 2 or 3 to start building. |
| **2. New Project** | Greenfield code -- nothing exists yet | Classic TDD: QA writes **failing** tests, Dev writes minimum code to pass, Refactor cleans up |
| **3. Existing Project** | You have a working codebase that needs tests and cleanup | Characterization: QA writes tests that **PASS** against existing code, Dev verifies coverage (no source changes), Refactor modernizes |

**How to choose between New and Existing:**

- **Use New** when starting from scratch or adding a brand-new feature. QA writes tests first, and they fail until Dev implements the code.
- **Use Existing** when you already have working code. QA writes tests that confirm current behavior. Dev does NOT modify source files -- only verifies and extends test coverage. Refactor then modernizes the code with a safety net of passing tests.

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

## 3. PM Pre-Flight (Optional)

If you have a vague idea but no clear requirements, start with PM Pre-Flight before creating your project:

```bash
my-orchestrator/scripts/new-project.sh
# Select option 1: PM Pre-Flight
```

The wizard will:
1. Ask for a one-paragraph description of your idea
2. Launch Claude Code as a PM agent
3. Generate a structured PRD (Product Requirements Document) with:
   - Happy paths, edge cases, and error states
   - Strict language (MUST, MUST NOT, WILL -- no ambiguity)
   - Specific fields, behaviors, and constraints
4. Show a preview of the generated PRD
5. Optionally save it to a project's QA mailbox (`shared/<project>/mailbox/to_qa/prd.md`)
6. **Exit** -- PM mode does not start the RGR pipeline

After reviewing the PRD, run the wizard again and select mode 2 (New Project) or 3 (Existing Project). The PRD in the QA mailbox gives the QA agent clear requirements to write tests against.

The PM agent prompt lives at `docs/pm_agent.md` -- customize it to match your team's PRD format.

## 4. Create Your Project

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

~/Repositories/my-app/                   # Main repo
├── CLAUDE.md                            # Dev agent instructions
├── .worktrees/
│   ├── qa/                              # QA worktree (red branches)
│   │   └── CLAUDE.md                    # QA agent instructions
│   ├── dev/                             # Dev worktree (green branches)
│   │   └── CLAUDE.md                    # Dev agent instructions
│   └── refactor/                        # Refactor worktree (blue branches)
│       └── CLAUDE.md                    # Refactor agent instructions
```

It also creates the shared mailbox and workspace directories at `shared/my-app/`.

**Where things live:**

| Location | What | Purpose |
|----------|------|---------|
| `~/Repositories/my-app/` | Main repo | Default branch, merge target |
| `~/Repositories/my-app/.worktrees/qa/` | QA worktree + `CLAUDE.md` | Where QA writes tests (`red/<task>` branches) |
| `~/Repositories/my-app/.worktrees/dev/` | Dev worktree + `CLAUDE.md` | Where Dev writes code (`green/<task>` branches) |
| `~/Repositories/my-app/.worktrees/refactor/` | Refactor worktree + `CLAUDE.md` | Where Refactor cleans up (`blue/<task>` branches) |
| `my-orchestrator/projects/my-app/` | Orchestrator config | Tasks, session settings, session reports |
| `my-orchestrator/shared/my-app/` | Runtime data | Mailbox (agent-to-agent messages) and shared workspace |

<details>
<summary>Manual setup (without wizard)</summary>

```bash
# Set up repo with git worktrees
cd ~/Repositories
git clone git@github.com:yourorg/my-app.git
cd my-app
git worktree add .worktrees/qa
git worktree add .worktrees/dev
git worktree add .worktrees/refactor

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

For each agent, an MCP communication protocol block is appended:

**Dev agent** (`send_to_qa`, `check_messages` with role "dev"):
- Receive task -> implement -> `git add && git commit` -> `send_to_qa`

**QA agent** (`send_to_dev`, `check_messages` with role "qa"):
- Receive test request -> write/run tests -> `git add && git commit` -> `send_to_dev` with pass/fail

**Refactor agent** (`send_refactor_complete`, `check_messages` with role "refactor"):
- Receive code -> clean up (DRY, naming, docs) -> run `/review` -> `git add && git commit` -> `send_refactor_complete`

All agents also have `list_workspace` and `read_workspace_file` for shared workspace access.

The full snippets are in `scripts/new-project.sh` if you need to add them manually.

---

## 5. Customize Your Project

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

**`~/Repositories/my-app/.worktrees/dev/CLAUDE.md`** (Dev) -- Add under "Project Context":
```markdown
## Project Context

- Node.js/Express API with PostgreSQL
- Codebase: ~/Repositories/my-app
- Run locally: `npm run dev` (port 3000)
- Database: `docker compose up -d` starts PostgreSQL on port 5432
- Existing patterns: see routes/users.js for reference
```

**`~/Repositories/my-app/.worktrees/qa/CLAUDE.md`** (QA) -- Add under "Test Environment":
```markdown
## Test Environment

- API runs at http://localhost:3000
- Test with: `curl`, `httpie`, or write scripts in tests/
- Database seed: `npm run seed` creates test users
- Test credentials: test@example.com / password123
```

**`~/Repositories/my-app/.worktrees/refactor/CLAUDE.md`** (Refactor) -- Add under "Refactoring Guidelines":
```markdown
## Refactoring Guidelines

- Do NOT change behavior -- only improve structure, naming, and readability
- Run `/review` before completing to catch issues
- Follow existing code style and patterns
```

The more context you provide, the better the agents perform.

## 6. iTerm2 Background Images (Optional)

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

## 7. Launch

```bash
my-orchestrator/scripts/start.sh myproject
```

To skip all Claude Code confirmation prompts (agents run fully autonomously):

```bash
my-orchestrator/scripts/start.sh myproject --yolo
```

You'll see pre-flight checks, then a tmux session with four panes:

```
+--------------------+--------------------+
|                    |                    |
|  QA_RED [myproj]   | DEV_GREEN [myproj] |
|  (Claude Code)     | (Claude Code)      |
|                    |                    |
+--------------------+--------------------+
|                    |                    |
| REFACTOR_BLUE      |  ORCH [myproj]     |
|  (Claude Code)     |  (Python orch)     |
|                    |                    |
+--------------------+--------------------+
```

**What happens next (RGR cycle):**
1. Orchestrator creates `red/<task>`, `green/<task>`, `blue/<task>` branches in each worktree
2. Orchestrator writes the first task to QA's mailbox
3. **RED**: QA writes failing tests on `red/<task>`, commits, calls `send_to_dev`
4. Orchestrator merges `red/<task>` into Dev's worktree
5. **GREEN**: Dev writes minimum code to pass tests on `green/<task>`, commits, calls `send_to_refactor`
6. Orchestrator merges `green/<task>` into Refactor's worktree
7. **BLUE**: Refactor cleans up code on `blue/<task>`, runs `/review`, commits, calls `send_refactor_complete`
8. Orchestrator merges `blue/<task>` into the default branch (main)
9. Repeat for the next task

## 8. Monitor and Interact

Click the **ORCH** pane (bottom) to interact with the orchestrator.

### Built-in commands

```
status                    Show current task, RGR state, and progress
tasks                     List all tasks with status markers
skip                      Skip a stuck task and move to the next one
nudge dev|qa|refactor     Manually remind an agent to check messages
msg dev|qa|refactor TEXT  Send arbitrary text to an agent's terminal
pause                     Pause mailbox polling
resume                    Resume polling
log                       Show last 10 log entries
help                      Show all commands
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

## 9. Stop

```bash
my-orchestrator/scripts/stop.sh myproject
```

This sends `/exit` to all three Claude Code agents, stops the orchestrator, kills the tmux session, resets the iTerm2 profile, and optionally cleans up task branches.

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
