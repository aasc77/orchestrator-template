# Quickstart Guide

Get up and running in 5 minutes. See the [README](../README.md) for architecture details, mode explanations, and configuration reference.

## 1. Install

```bash
brew install tmux node python3 ollama
npm install -g @anthropic-ai/claude-code
ollama serve   # leave running
```

## 2. Setup

```bash
git clone https://github.com/aasc77/orchestrator-template.git my-orchestrator
my-orchestrator/scripts/setup.sh
```

Setup installs dependencies, pulls the Qwen3 8B model, configures the MCP bridge, and prompts you to create your first project.

## 3. Create a Project

The setup wizard runs automatically at the end of step 2. To run it again later:

```bash
my-orchestrator/scripts/new-project.sh           # interactive
my-orchestrator/scripts/new-project.sh my-app     # skip folder prompt
```

The wizard asks you to pick a mode:
1. **PM Pre-Flight** -- generate or review a PRD (exits after, run wizard again for mode 2/3)
   - **Start from scratch** -- describe your idea and the PM agent generates a full PRD
   - **Review existing PRD** -- provide a file path, the PM agent reads it, discusses gaps and improvements with you, then writes the refined version
2. **New Project** -- classic TDD on a new codebase
3. **Existing Project** -- characterization tests on an existing codebase

For modes 2 and 3, the wizard then asks **"Do you have a PRD?"** -- if yes, provide the file path and the wizard launches an interactive **Task Planner** that reads your PRD, proposes a task breakdown, discusses it with you, and writes `tasks.json` when you approve. Type `/exit` after the planner finishes to continue setup.

It then creates worktrees, config, tasks, and agent `CLAUDE.md` files. See [README > Three Modes](../README.md#three-modes) for details on when to use each.

## 4. Customize

Edit the generated files before launching:

```bash
vi my-orchestrator/projects/<name>/tasks.json       # review tasks (auto-generated from PRD, or replace sample)
vi <your-repo>/.worktrees/qa/CLAUDE.md              # QA: test environment, credentials
vi <your-repo>/.worktrees/dev/CLAUDE.md             # Dev: tech stack, architecture, patterns
vi <your-repo>/.worktrees/refactor/CLAUDE.md        # Refactor: code style, guidelines
```

If you provided a PRD, `tasks.json` already has real tasks from the Task Planner and each agent `CLAUDE.md` includes a PRD reference section. Fill in the `<!-- TODO -->` placeholders the wizard left in each `CLAUDE.md`. The more project context you add, the better the agents perform.

## 5. Launch

```bash
my-orchestrator/scripts/start.sh <name>             # with confirmation prompts
my-orchestrator/scripts/start.sh <name> --yolo      # fully autonomous (no prompts)
```

You'll see a 2x2 tmux grid:

```
+--------------------+--------------------+
|  QA_RED            | DEV_GREEN          |
+--------------------+--------------------+
| REFACTOR_BLUE      |  ORCH              |
+--------------------+--------------------+
```

The orchestrator starts the RGR cycle automatically. Type `status`, `tasks`, or `help` in the ORCH pane to interact. See [README > Interactive Commands](../README.md#interactive-commands) for the full command list.

## 6. Stop

```bash
my-orchestrator/scripts/stop.sh <name>
```

## Optional: iTerm2 Background Images

```bash
bash scripts/setup-iterm-profiles.sh
# Restart iTerm2 (Cmd+Q, reopen)
```

Creates a composite robot image for each pane quadrant. `start.sh` detects it automatically and switches to transparent pane backgrounds. See `images/` for source PNGs.
