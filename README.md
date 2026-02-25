# RGR Orchestrator (Red-Green-Refactor)

Automated Red-Green-Refactor workflow with three Claude Code agents: QA writes tests, Dev writes code, Refactor cleans up. A local AI orchestrator routes decisions and manages git merges.
Supports multiple projects from a single installation.

![Demo: QA, Dev, Refactor, and Orchestrator working together](docs/images/demo.gif)

## Architecture

```
+--------------------------------------+
|     Orchestrator (Qwen3 8B local)    |
|     Polls mailbox, makes decisions,  |
|     manages git merges between phases|
+-----------+--------------------------+
            | reads/writes
      +-----+-----+
      |  Mailbox  |  (shared/<project>/mailbox/)
      +-----+-----+
            | MCP tools: check_messages, send_to_dev,
            |   send_to_refactor, send_refactor_complete
      +-----+-----+-----+
      |           |           |
+-----v----+ +---v------+ +--v--------+
| QA Agent | | Dev Agent | | Refactor  |
| (RED)    | | (GREEN)   | | (BLUE)    |
| Claude   | | Claude    | | Claude    |
| Code     | | Code      | | Code      |
+----------+ +----------+ +-----------+
```

## How It Works (RGR Cycle)

Each task goes through three phases:

1. Orchestrator creates `red/<task>`, `green/<task>`, `blue/<task>` branches in each worktree
2. Orchestrator writes first task to QA's mailbox
3. **RED**: QA writes failing tests on `red/<task>`, commits, calls `send_to_dev`
4. Orchestrator merges `red/<task>` into Dev's worktree
5. **GREEN**: Dev writes minimum code to pass tests on `green/<task>`, commits, calls `send_to_refactor`
6. Orchestrator merges `green/<task>` into Refactor's worktree
7. **BLUE**: Refactor cleans up code on `blue/<task>`, runs `/review`, commits, calls `send_refactor_complete`
8. Orchestrator merges `blue/<task>` into the default branch (main)
9. Repeat for the next task

If a merge conflicts, the orchestrator sets state to BLOCKED and flags a human. Tasks that fail 5+ attempts are marked `stuck` for human review.

### Two Modes

- **New project (`mode: new`)**: Classic TDD -- QA writes failing tests, Dev makes them pass
- **Existing project (`mode: existing`)**: Characterization -- QA writes tests that PASS against existing code, Dev verifies coverage, Refactor cleans up legacy code

## Prerequisites

- macOS (tested on Apple Silicon)
- [tmux](https://github.com/tmux/tmux) -- `brew install tmux`
- [Node.js](https://nodejs.org/) -- `brew install node`
- [Python 3](https://www.python.org/) -- `brew install python3`
- [Claude Code](https://claude.com/claude-code) -- `npm install -g @anthropic-ai/claude-code`
- [Ollama](https://ollama.ai/) -- `brew install ollama` (+ `ollama pull qwen3:8b`)

## Quick Start

> For a detailed walkthrough with configuration examples and troubleshooting, see [docs/QUICKSTART.md](docs/QUICKSTART.md).

**1. Clone and install** (setup will prompt to create a project):

```bash
git clone https://github.com/aasc77/orchestrator-template.git my-orchestrator
my-orchestrator/scripts/setup.sh
```

**2. Customize tasks and agent instructions:**

```bash
vi my-orchestrator/projects/<name>/tasks.json
vi ~/Repositories/<name>/CLAUDE.md                    # Main repo instructions
vi ~/Repositories/<name>/.worktrees/qa/CLAUDE.md      # QA agent
vi ~/Repositories/<name>/.worktrees/dev/CLAUDE.md     # Dev agent
vi ~/Repositories/<name>/.worktrees/refactor/CLAUDE.md # Refactor agent
```

**3. Launch:**

```bash
my-orchestrator/scripts/start.sh <name>
```

Or with no confirmation prompts (agents run fully autonomously):

```bash
my-orchestrator/scripts/start.sh <name> --yolo
```

**4. Stop:**

```bash
my-orchestrator/scripts/stop.sh <name>
```

<details>
<summary>Manual setup (without wizard)</summary>

```bash
# 1. Set up your repo with git worktrees
cd ~/Repositories
git clone git@github.com:yourorg/my-app.git
cd my-app
git worktree add .worktrees/qa
git worktree add .worktrees/dev
git worktree add .worktrees/refactor

# 2. Create your project from the example
cp -r my-orchestrator/projects/example my-orchestrator/projects/myproject

# 3. Configure
vi my-orchestrator/projects/myproject/config.yaml   # Set working dirs, session name
vi my-orchestrator/projects/myproject/tasks.json     # Define your tasks
vi ~/Repositories/my-app/.worktrees/qa/CLAUDE.md     # QA agent instructions
vi ~/Repositories/my-app/.worktrees/dev/CLAUDE.md    # Dev agent instructions
vi ~/Repositories/my-app/.worktrees/refactor/CLAUDE.md # Refactor agent instructions
```

</details>

**Why git worktrees?** Each agent (QA, Dev, Refactor) works on its own branch in its own worktree directory. This lets all three agents work simultaneously on the same repo without conflicts. The orchestrator handles git merges between phases automatically.

## Adding a New Project

```bash
my-orchestrator/scripts/new-project.sh
```

The wizard handles everything: locates your dev repo, creates git worktrees (`.worktrees/qa`, `.worktrees/dev`, `.worktrees/refactor`), and generates `config.yaml`, `tasks.json`, and agent `CLAUDE.md` files with correct pane values and smoke-test tasks.

Pass the folder name as an argument to skip the first prompt:

```bash
my-orchestrator/scripts/new-project.sh my-app
```

After the wizard finishes, customize the generated files:
1. Replace smoke-test tasks in `projects/<name>/tasks.json` with your real work
2. Fill in the `<!-- TODO -->` placeholders in `CLAUDE.md` in each working directory
3. Launch with `my-orchestrator/scripts/start.sh <name>`

Multiple projects can run simultaneously (each gets its own tmux session and mailbox).

<details>
<summary>Manual setup (without wizard)</summary>

```bash
cd ~/Repositories
git clone git@github.com:yourorg/new-project.git
cd new-project
git worktree add .worktrees/qa
git worktree add .worktrees/dev
git worktree add .worktrees/refactor
```

```bash
cp -r my-orchestrator/projects/example my-orchestrator/projects/<name>
```

Edit `my-orchestrator/projects/<name>/config.yaml` to point at your working directories:

```yaml
project: my_new_project
repo_dir: ~/Repositories/new-project
tmux:
  session_name: mynewproject
agents:
  qa:
    working_dir: ~/Repositories/new-project/.worktrees/qa
    pane: qa.0
  dev:
    working_dir: ~/Repositories/new-project/.worktrees/dev
    pane: qa.1
  refactor:
    working_dir: ~/Repositories/new-project/.worktrees/refactor
    pane: qa.2
```

Then add tasks to `projects/<name>/tasks.json` and launch with `my-orchestrator/scripts/start.sh <name>`.

</details>

## Adding an Existing Project

Already have a repo with its own `CLAUDE.md`? The wizard is safe to run -- it won't overwrite your files:

```bash
my-orchestrator/scripts/new-project.sh my-existing-app
```

The wizard detects existing files and handles them:

| What it finds | What it does |
|---|---|
| Dev directory exists | Uses it as-is, creates worktrees |
| `CLAUDE.md` exists, no MCP section | Appends only the MCP communication protocol to the end |
| `CLAUDE.md` exists, already has MCP | Skips entirely (no changes) |
| No `CLAUDE.md` | Creates the full template |

The confirmation screen shows exactly what will happen before you proceed:

```
Will create:
  projects/my-existing-app/config.yaml
  projects/my-existing-app/tasks.json
  shared/my-existing-app/mailbox/{to_dev,to_qa,to_refactor}/
  shared/my-existing-app/workspace/
  ~/Repositories/my-existing-app/.worktrees/qa/CLAUDE.md
  ~/Repositories/my-existing-app/.worktrees/dev/CLAUDE.md
  ~/Repositories/my-existing-app/.worktrees/refactor/CLAUDE.md
  ~/Repositories/my-existing-app/CLAUDE.md      (exists -- will append MCP section)
```

Running the wizard again is safe -- it's idempotent.

### Using without pre-defined tasks

You don't need to populate `tasks.json` to use the orchestrator. The task system is optional. You can leave the task list empty and drive the workflow manually:

1. Launch: `my-orchestrator/scripts/start.sh my-existing-app`
2. Click the **DEV** pane and tell the agent what to work on (e.g., "grab issue #42 from GitHub and fix it")
3. Dev implements and calls `send_to_qa` -- the orchestrator routes it to QA
4. QA tests and calls `send_to_dev` -- the orchestrator routes results back
5. On pass, orchestrator routes to Refactor for cleanup, then merges to main

The orchestrator stays alive with an empty task list, polls the mailbox, routes messages between agents, and accepts interactive commands in the ORCH pane.

### Custom project key

The wizard derives the project key from the folder name, but for existing projects you may want a shorter key. Create the project manually:

```bash
mkdir -p my-orchestrator/projects/myapp
mkdir -p my-orchestrator/shared/myapp/mailbox/{to_dev,to_qa,to_refactor}
mkdir -p my-orchestrator/shared/myapp/workspace
```

```yaml
# my-orchestrator/projects/myapp/config.yaml
project: myapp
repo_dir: /full/path/to/your-existing-repo
tmux:
  session_name: myapp
agents:
  qa:
    working_dir: /full/path/to/your-existing-repo/.worktrees/qa
    pane: qa.0
  dev:
    working_dir: /full/path/to/your-existing-repo/.worktrees/dev
    pane: qa.1
  refactor:
    working_dir: /full/path/to/your-existing-repo/.worktrees/refactor
    pane: qa.2
```

```json
// my-orchestrator/projects/myapp/tasks.json
{
  "project": "myapp",
  "tasks": []
}
```

Then append the MCP protocol to your existing CLAUDE.md (see `docs/QUICKSTART.md` for the snippet) and launch with `start.sh myapp`.

## Configuration

### Project Config (`projects/<name>/config.yaml`)
Per-project settings that override shared defaults:
- `project`: Project identifier
- `repo_dir`: Path to the main git repository
- `tmux.session_name`: tmux session name (must be unique per project)
- `agents.qa.working_dir`: QA agent's worktree directory
- `agents.dev.working_dir`: Dev agent's worktree directory
- `agents.refactor.working_dir`: Refactor agent's worktree directory
- `agents.*.pane`: tmux pane target (qa.0 = QA, qa.1 = Dev, qa.2 = Refactor)

### Shared Config (`orchestrator/config.yaml`)
Defaults for all projects:
- LLM model and temperature
- Polling interval
- Max retry attempts per task
- tmux nudge prompt and cooldown

Project configs are deep-merged with shared defaults (project values win).

### Tasks (`projects/<name>/tasks.json`)
Define tasks with:
- `id`: Unique identifier
- `title`: Short description
- `description`: Detailed requirements
- `acceptance_criteria`: Measurable outcomes QA will verify
- `status`: `pending`, `in_progress`, `completed`, or `stuck`

### Agent Instructions (`CLAUDE.md` in worktree directories)
The wizard creates a `CLAUDE.md` in each agent's worktree directory (e.g., `.worktrees/dev/CLAUDE.md` for Dev, `.worktrees/qa/CLAUDE.md` for QA, `.worktrees/refactor/CLAUDE.md` for Refactor). Claude Code picks these up automatically -- both when launched by the orchestrator and when you run `claude` standalone. Customize with:
- Tech stack, architecture, key URLs
- Test credentials and environment details
- Known bugs and deployment instructions

## File Structure

```
orchestrator-template/
├── README.md
├── claude-code-mcp-config.json      # MCP config for Claude Code agents
├── images/                          # Robot background images (source PNGs)
│   ├── Red_robot.png                # QA agent (red)
│   ├── Green_rotbot.png             # Dev agent (green)
│   ├── Blue_robot.png               # Refactor agent (blue)
│   └── orchestrator.png             # Orchestrator
├── projects/
│   └── example/                     # Template project (copy to create new)
│       ├── config.yaml              # Project config (session, working dirs)
│       └── tasks.json               # Task queue
├── orchestrator/
│   ├── orchestrator.py              # Main loop (polls mailbox, asks LLM, merges)
│   ├── llm_client.py                # Ollama API client
│   ├── mailbox_watcher.py           # File watcher for mailbox
│   ├── config.yaml                  # Shared defaults
│   └── requirements.txt
├── mcp-bridge/
│   ├── index.js                     # MCP server (mailbox tools)
│   ├── package.json
│   └── test.js
├── scripts/
│   ├── setup.sh                     # One-time install
│   ├── new-project.sh               # Interactive project setup wizard
│   ├── setup-iterm-profiles.sh      # iTerm2 background image setup
│   ├── start.sh <project>           # Launch a project session
│   └── stop.sh <project>            # Stop a project session
├── shared/                          # Created at runtime per project
│   └── <project>/
│       ├── mailbox/
│       │   ├── to_dev/
│       │   ├── to_qa/
│       │   └── to_refactor/
│       └── workspace/
└── docs/
    ├── QUICKSTART.md
    ├── MCP Bridge Setup Guide.md
    └── troubleshooting.md
```

## Interactive Commands

While the orchestrator is running, type commands in the ORCH pane:

| Command | Description |
|---|---|
| `status` | Current task and progress |
| `tasks` | List all tasks with status |
| `skip` | Skip current stuck task |
| `nudge dev\|qa\|refactor` | Manually nudge an agent |
| `msg dev\|qa\|refactor TEXT` | Send text to an agent's pane |
| `pause` / `resume` | Pause/resume mailbox polling |
| `log` | Show last 10 log entries |
| `help` | Show all commands |

You can also type natural language -- the orchestrator's LLM will interpret it.
