#!/bin/bash
set -e

# ─── Color helpers ────────────────────────────────────────────────────────────
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    BOLD="" DIM="" RESET="" GREEN="" YELLOW="" RED="" CYAN=""
else
    BOLD=$(tput bold)    DIM=$(tput dim)     RESET=$(tput sgr0)
    GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3) RED=$(tput setaf 1) CYAN=$(tput setaf 6)
fi

info()    { echo "  ${CYAN}>${RESET} $*"; }
warn()    { echo "  ${YELLOW}!${RESET} $*"; }
error()   { echo "  ${RED}ERROR:${RESET} $*" >&2; }
success() { echo "  ${GREEN}>${RESET} $*"; }

# ─── Resolve script location ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_DIR="$HOME/Repositories"

# ─── Prompt extraction helper ───────────────────────────────────────────────
extract_prompt() {
    local file="$1" target="$2"
    awk -v t="$target" '
        $0 == "## FILE_TARGET: " t { found=1; next }
        /^## FILE_TARGET:/ { found=0 }
        found { print }
    ' "$file"
}

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
CLEANUP_PROJECT_DIR=""
CLEANUP_SHARED_DIR=""
CLEANUP_REPO_DIR=""

cleanup() {
    if [[ -n "$CLEANUP_PROJECT_DIR" && -d "$CLEANUP_PROJECT_DIR" ]]; then
        rm -rf "$CLEANUP_PROJECT_DIR"
        warn "Cleaned up partial project directory: $CLEANUP_PROJECT_DIR"
    fi
    if [[ -n "$CLEANUP_SHARED_DIR" && -d "$CLEANUP_SHARED_DIR" ]]; then
        rm -rf "$CLEANUP_SHARED_DIR"
        warn "Cleaned up partial shared directory: $CLEANUP_SHARED_DIR"
    fi
    if [[ -n "$CLEANUP_REPO_DIR" && -d "$CLEANUP_REPO_DIR" ]]; then
        rm -rf "$CLEANUP_REPO_DIR"
        warn "Cleaned up partial repo directory: $CLEANUP_REPO_DIR"
    fi
}

trap cleanup INT TERM ERR

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "  ${BOLD}New Project Wizard${RESET}"
echo "  =================="
echo ""

# ─── Phase 0: Mode selection ────────────────────────────────────────────────
echo "  Select a mode:"
echo ""
echo "    1) PM Pre-Flight    -- Generate a PRD from a vague idea"
echo "    2) New Project RGR  -- Set up Red-Green-Refactor for a new codebase"
echo "    3) Existing Project -- Backfill tests on an existing POC"
echo ""
read -r -p "  Mode [1/2/3]: " MODE_CHOICE

case "$MODE_CHOICE" in
    1) PROJECT_MODE="pm" ;;
    2) PROJECT_MODE="new" ;;
    3) PROJECT_MODE="existing" ;;
    *)
        error "Invalid choice. Pick 1, 2, or 3."
        exit 1
        ;;
esac
echo ""

# ─── PM Pre-Flight Mode ─────────────────────────────────────────────────────
if [[ "$PROJECT_MODE" == "pm" ]]; then
    info "PM Pre-Flight mode"
    echo ""
    echo "  Describe your idea (one paragraph):"
    read -r -p "  > " USER_IDEA

    if [[ -z "$USER_IDEA" ]]; then
        error "Idea cannot be empty."
        exit 1
    fi

    # Extract PM prompt from docs
    PM_PROMPT_FILE="$ROOT_DIR/docs/pm_agent.md"
    if [[ ! -f "$PM_PROMPT_FILE" ]]; then
        error "PM prompt file not found: $PM_PROMPT_FILE"
        exit 1
    fi

    PM_PROMPT=$(extract_prompt "$PM_PROMPT_FILE" "pm_agent/CLAUDE.md")
    # Replace placeholder with user idea
    PM_PROMPT="${PM_PROMPT//\{\{USER_IDEA\}\}/$USER_IDEA}"

    # Create temp working directory
    PM_TMPDIR=$(mktemp -d)
    cat > "$PM_TMPDIR/CLAUDE.md" <<PMEOF
$PM_PROMPT

---

## User's Idea
$USER_IDEA

## Output
Write the complete PRD to a file called \`prd.md\` in this directory.
PMEOF

    info "Launching Claude Code as PM agent..."
    echo "  Working dir: $PM_TMPDIR"
    echo ""

    # Launch Claude Code with PM system prompt
    (cd "$PM_TMPDIR" && claude --dangerously-skip-permissions) || true

    # Check for generated PRD
    if [[ -f "$PM_TMPDIR/prd.md" ]]; then
        success "PRD generated: $PM_TMPDIR/prd.md"
        echo ""
        echo "  ${BOLD}Preview (first 20 lines):${RESET}"
        head -20 "$PM_TMPDIR/prd.md" | sed 's/^/    /'
        echo "    ..."
        echo ""
        read -r -p "  Save PRD to a project's QA mailbox? [folder name or n]: " SAVE_TARGET
        if [[ -n "$SAVE_TARGET" && "$SAVE_TARGET" != "n" ]]; then
            SAVE_KEY="${SAVE_TARGET//_/-}"
            SAVE_MAILBOX="$ROOT_DIR/shared/$SAVE_KEY/mailbox/to_qa"
            if [[ -d "$SAVE_MAILBOX" ]]; then
                cp "$PM_TMPDIR/prd.md" "$SAVE_MAILBOX/prd.md"
                success "Saved PRD to $SAVE_MAILBOX/prd.md"
            else
                warn "Mailbox not found: $SAVE_MAILBOX"
                warn "PRD remains at: $PM_TMPDIR/prd.md"
            fi
        else
            info "PRD remains at: $PM_TMPDIR/prd.md"
        fi
    else
        warn "No prd.md generated. Check $PM_TMPDIR for output."
    fi

    exit 0
fi

# ─── Select prompt file based on mode ───────────────────────────────────────
if [[ "$PROJECT_MODE" == "new" ]]; then
    PROMPT_FILE="$ROOT_DIR/docs/NEW PROJECT PROMPTS.md"
    info "Mode: New Project RGR"
else
    PROMPT_FILE="$ROOT_DIR/docs/EXISTING PROJECT PROMPTS.md"
    info "Mode: Existing Project Backfill"
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
    error "Prompt file not found: $PROMPT_FILE"
    exit 1
fi
echo ""

# ─── Phase 1: Gather folder name ─────────────────────────────────────────────
FOLDER_NAME="${1:-}"

while true; do
    if [[ -z "$FOLDER_NAME" ]]; then
        read -r -p "  Folder name (in ~/Repositories/): " FOLDER_NAME
    fi

    if [[ -z "$FOLDER_NAME" ]]; then
        warn "Folder name cannot be empty."
        FOLDER_NAME=""
        continue
    fi

    if [[ ! "$FOLDER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "Invalid name: only letters, numbers, hyphens, and underscores allowed."
        FOLDER_NAME=""
        continue
    fi

    break
done

# ─── Phase 2: Derive project name + key ──────────────────────────────────────
REPO_DIR="$REPOS_DIR/$FOLDER_NAME"
# Project name: underscored version (e.g., my_app)
PROJECT_NAME="${FOLDER_NAME//-/_}"
# Project key: hyphenated version (e.g., my-app)
PROJECT_KEY="${FOLDER_NAME//_/-}"

# Worktree paths inside the repo
QA_DIR="$REPO_DIR/.worktrees/qa"
DEV_DIR="$REPO_DIR/.worktrees/dev"
REFACTOR_DIR="$REPO_DIR/.worktrees/refactor"

echo ""
info "Project name: $PROJECT_NAME"
info "Project key:  $PROJECT_KEY"
info "Repo dir:     $REPO_DIR"

# Validate project key doesn't conflict with existing project
if [[ -d "$ROOT_DIR/projects/$PROJECT_KEY" ]]; then
    error "Project '$PROJECT_KEY' already exists at projects/$PROJECT_KEY/"
    echo "  Choose a different key or remove the existing project first."
    exit 1
fi

# ─── Phase 3: Initialize git repo ────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
    info "Git repo already exists at $REPO_DIR"
else
    mkdir -p "$REPO_DIR"
    git -C "$REPO_DIR" init --quiet
    info "Initialized git repo: $REPO_DIR"

    # Create .gitignore
    cat > "$REPO_DIR/.gitignore" <<'GIEOF'
# Worktrees (agent-specific checkouts)
.worktrees/

# Python
__pycache__/
*.pyc
.pytest_cache/
*.egg-info/
venv/
.venv/

# IDE
.vscode/
.idea/

# OS
.DS_Store
GIEOF
    info "Created .gitignore"

    # Create initial commit so worktrees can branch from HEAD
    git -C "$REPO_DIR" add .gitignore
    git -C "$REPO_DIR" commit --quiet -m "chore: initial commit with .gitignore"
    info "Created initial commit on main"
fi

# Detect default branch name (existing repos may use master or other names)
DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")

# Ensure .worktrees/ is in .gitignore (for existing repos that skipped git init)
if [[ -f "$REPO_DIR/.gitignore" ]]; then
    if ! grep -q '^\.worktrees/' "$REPO_DIR/.gitignore"; then
        echo -e '\n# Worktrees (agent-specific checkouts)\n.worktrees/' >> "$REPO_DIR/.gitignore"
        git -C "$REPO_DIR" add .gitignore
        git -C "$REPO_DIR" commit --quiet -m "chore: add .worktrees/ to .gitignore"
        info "Added .worktrees/ to existing .gitignore"
    fi
else
    # No .gitignore at all -- create minimal one
    echo -e '# Worktrees (agent-specific checkouts)\n.worktrees/' > "$REPO_DIR/.gitignore"
    git -C "$REPO_DIR" add .gitignore
    git -C "$REPO_DIR" commit --quiet -m "chore: add .gitignore with .worktrees/"
    info "Created .gitignore with .worktrees/"
fi

# ─── Phase 4: Create worktrees ───────────────────────────────────────────────
for wt_name in qa dev refactor; do
    wt_path="$REPO_DIR/.worktrees/$wt_name"
    wt_branch="${wt_name}-main"
    if [[ -d "$wt_path" ]]; then
        info "Worktree already exists: .worktrees/$wt_name"
    else
        git -C "$REPO_DIR" worktree add "$wt_path" -b "$wt_branch" --quiet
        info "Created worktree: .worktrees/$wt_name (branch: $wt_branch)"
    fi
done

# Clean up stale root-level files from old wizard runs
if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    warn "Found stale CLAUDE.md at repo root (from old wizard run)"
    warn "Agents use .worktrees/*/CLAUDE.md now. Removing root copy."
    if git -C "$REPO_DIR" ls-files --error-unmatch CLAUDE.md 2>/dev/null; then
        git -C "$REPO_DIR" rm --quiet -f CLAUDE.md
        git -C "$REPO_DIR" commit --quiet -m "chore: remove stale root CLAUDE.md"
    else
        rm "$REPO_DIR/CLAUDE.md"
    fi
fi

# ─── Phase 5: Confirmation summary ───────────────────────────────────────────
PROJECT_DIR="$ROOT_DIR/projects/$PROJECT_KEY"
SHARED_DIR="$ROOT_DIR/shared/$PROJECT_KEY"

echo ""
echo "  ${BOLD}=================================${RESET}"
echo "  ${BOLD}Project Setup Summary${RESET}"
echo "  ${BOLD}=================================${RESET}"
echo "  Project key:   ${CYAN}$PROJECT_KEY${RESET}"
echo "  Project name:  ${CYAN}$PROJECT_NAME${RESET}"
echo "  Repo dir:      $REPO_DIR"
echo "    .worktrees/qa/:        QA agent (RED)"
echo "    .worktrees/dev/:       Dev agent (GREEN)"
echo "    .worktrees/refactor/:  Refactor agent (BLUE)"
echo ""
echo "  Will create:"
echo "    projects/$PROJECT_KEY/config.yaml"
echo "    projects/$PROJECT_KEY/tasks.json"
echo "    shared/$PROJECT_KEY/mailbox/{to_dev,to_qa,to_refactor}/"
echo "    shared/$PROJECT_KEY/workspace/"
for agent_name in qa dev refactor; do
    agent_dir="$REPO_DIR/.worktrees/$agent_name"
    if [[ -f "$agent_dir/CLAUDE.md" ]]; then
        if grep -q "agent-bridge" "$agent_dir/CLAUDE.md" 2>/dev/null; then
            echo "    .worktrees/$agent_name/CLAUDE.md  ${DIM}(exists, MCP already present -- skip)${RESET}"
        else
            echo "    .worktrees/$agent_name/CLAUDE.md  ${YELLOW}(exists -- will append MCP section)${RESET}"
        fi
    else
        echo "    .worktrees/$agent_name/CLAUDE.md  ${DIM}(new)${RESET}"
    fi
done
echo "  ${BOLD}=================================${RESET}"
echo ""

echo ""

# ─── Phase 6: Create all files ───────────────────────────────────────────────

# Mark for cleanup on failure
CLEANUP_PROJECT_DIR="$PROJECT_DIR"
CLEANUP_SHARED_DIR="$SHARED_DIR"

# Create directory structure
mkdir -p "$PROJECT_DIR"
mkdir -p "$SHARED_DIR/mailbox/to_dev"
mkdir -p "$SHARED_DIR/mailbox/to_qa"
mkdir -p "$SHARED_DIR/mailbox/to_refactor"
mkdir -p "$SHARED_DIR/workspace"

# --- config.yaml ---
cat > "$PROJECT_DIR/config.yaml" <<EOF
# Project: $PROJECT_NAME
project: $PROJECT_NAME

tmux:
  session_name: $PROJECT_KEY

repo_dir: $REPO_DIR

agents:
  qa:
    working_dir: $QA_DIR
    pane: qa.0
  dev:
    working_dir: $DEV_DIR
    pane: qa.1
  refactor:
    working_dir: $REFACTOR_DIR
    pane: qa.2
EOF
info "Created projects/$PROJECT_KEY/config.yaml"

# --- tasks.json ---
cat > "$PROJECT_DIR/tasks.json" <<EOF
{
  "project": "$PROJECT_NAME",
  "tasks": [
    {
      "id": "rgr-1",
      "title": "Create a greeting module with tests",
      "description": "Create a Python module greeting.py with a function greet(name) that returns 'Hello, <name>!' where <name> is the argument passed in. For example, greet('World') returns 'Hello, World!'. QA writes a failing test first, Dev implements the function, Refactor cleans up.",
      "acceptance_criteria": [
        "greeting.py exists with a greet(name) function",
        "greet('World') returns 'Hello, World!'",
        "greet('Alice') returns 'Hello, Alice!'",
        "A pytest test file exists that verifies the function",
        "All tests pass"
      ],
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }
  ]
}
EOF
info "Created projects/$PROJECT_KEY/tasks.json"

# --- MCP protocol snippets (appended to existing CLAUDE.md or written fresh) ---

IFS= read -r -d '' DEV_MCP_SECTION <<'DEVMCP' || true

---

## Communication Protocol (MCP-Based)

You are the **DEVELOPER** agent (GREEN) in an automated Red-Green-Refactor workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_refactor`** -- Notify Refactor agent that code is ready for cleanup
  - `summary`: What you built/changed
  - `files_changed`: List of files created or modified
  - `test_commands`: Commands to run tests (e.g., "pytest")

- **`check_messages`** -- Check your mailbox for orchestrator tasks and QA feedback
  - `role`: Always use `"dev"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a task via `check_messages` (role: `"dev"`)
2. The failing tests from QA are already in your worktree (merged by the orchestrator)
3. Write the minimum code to make the tests pass
4. Run the tests to confirm they pass
5. **Commit your work**: `git add . && git commit -m "green: <description>"`
6. Call `send_to_refactor` with summary and files changed
7. Wait -- periodically call `check_messages` with role `"dev"` to get feedback

### Rules
- ALWAYS commit your code BEFORE calling send_to_refactor
- Do NOT modify test files -- only write implementation code
- Write the minimum code to pass tests, nothing more
- If a task is ambiguous, make reasonable assumptions and document them
DEVMCP

IFS= read -r -d '' QA_MCP_SECTION <<'QAMCP' || true

---

## Communication Protocol (MCP-Based)

You are the **QA Agent** (RED) in an automated Red-Green-Refactor workflow with an AI orchestrator.
You write FAILING tests that define the contract for the Dev agent.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_dev`** -- Send test results back to Dev
  - `status`: `"pass"`, `"fail"`, or `"partial"`
  - `summary`: Overall test results summary
  - `bugs`: Array of bug objects (empty if pass)
  - `tests_run`: Description of what you tested

- **`check_messages`** -- Check your mailbox for new work
  - `role`: Always use `"qa"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a task via `check_messages` with role `"qa"`
2. Write failing tests that define the expected behavior
3. Run the tests to confirm they FAIL (no implementation yet)
4. **Commit your tests**: `git add . && git commit -m "red: <description>"`
5. Call `send_to_dev` with status "fail", summary, and tests_run
6. Wait for orchestrator to assign the next task

### Rules
- ALWAYS commit your tests BEFORE calling send_to_dev
- Only write tests, NEVER write implementation code
- Tests MUST fail before handoff (that's the RED in Red-Green-Refactor)
- Use pytest for Python projects
- Be thorough: test happy path, edge cases, and error conditions
QAMCP

IFS= read -r -d '' REFACTOR_MCP_SECTION <<'REFMCP' || true

---

## Communication Protocol (MCP-Based)

You are the **REFACTOR** agent (BLUE) in an automated Red-Green-Refactor workflow with an AI orchestrator.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_refactor_complete`** -- Report your refactoring results
  - `status`: `"pass"` (tests still green) or `"fail"` (tests broke)
  - `summary`: What you refactored
  - `files_changed`: List of files modified (optional)
  - `issues`: Description of issues if tests broke (optional)

- **`check_messages`** -- Check your mailbox for refactoring requests
  - `role`: Always use `"refactor"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive code via `check_messages` (role: `"refactor"`)
2. The implementation and tests are already in your worktree (merged by the orchestrator)
3. Review the implementation and its tests
4. Refactor: improve DRY, naming, magic strings, documentation, type hints
5. Run the test suite to verify tests still pass
6. **Commit your changes**: `git add . && git commit -m "blue: <description>"`
7. Call `send_refactor_complete` with status and summary

### Rules
- ALWAYS commit your changes BEFORE calling send_refactor_complete
- NEVER change functional behavior
- NEVER modify test files
- Run tests BEFORE reporting completion
- Focus on code quality: DRY, naming, extracting constants, documentation
- If unsure whether a change is safe, skip it
REFMCP

# Extract role prompts from selected prompt file
QA_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "qa_agent/CLAUDE.md")
DEV_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "dev_agent/CLAUDE.md")
REFACTOR_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "refactor_agent/CLAUDE.md")

# --- Dev CLAUDE.md ---
if [[ -f "$DEV_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$DEV_DIR/CLAUDE.md" 2>/dev/null; then
        info "Dev CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$DEV_MCP_SECTION" >> "$DEV_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $DEV_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# Dev Agent (GREEN) -- $PROJECT_NAME"
        printf '%s\n' "$DEV_ROLE_PROMPT"
        printf '%s\n' "$DEV_MCP_SECTION"
    } > "$DEV_DIR/CLAUDE.md"
    info "Created $DEV_DIR/CLAUDE.md"
fi

# --- QA CLAUDE.md ---
if [[ -f "$QA_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$QA_DIR/CLAUDE.md" 2>/dev/null; then
        info "QA CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$QA_MCP_SECTION" >> "$QA_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $QA_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# QA Agent (RED) -- $PROJECT_NAME"
        printf '%s\n' "$QA_ROLE_PROMPT"
        printf '%s\n' "$QA_MCP_SECTION"
    } > "$QA_DIR/CLAUDE.md"
    info "Created $QA_DIR/CLAUDE.md"
fi

# --- Refactor CLAUDE.md ---
if [[ -f "$REFACTOR_DIR/CLAUDE.md" ]]; then
    if grep -q "agent-bridge" "$REFACTOR_DIR/CLAUDE.md" 2>/dev/null; then
        info "Refactor CLAUDE.md already has MCP protocol -- skipped"
    else
        echo "$REFACTOR_MCP_SECTION" >> "$REFACTOR_DIR/CLAUDE.md"
        success "Appended MCP protocol to existing $REFACTOR_DIR/CLAUDE.md"
    fi
else
    {
        printf '%s\n\n' "# Refactor Agent (BLUE) -- $PROJECT_NAME"
        printf '%s\n' "$REFACTOR_ROLE_PROMPT"
        printf '%s\n' "$REFACTOR_MCP_SECTION"
    } > "$REFACTOR_DIR/CLAUDE.md"
    info "Created $REFACTOR_DIR/CLAUDE.md"
fi

# Clear cleanup markers on success
CLEANUP_PROJECT_DIR=""
CLEANUP_SHARED_DIR=""
CLEANUP_REPO_DIR=""

success "Created projects/$PROJECT_KEY/"
success "Created shared/$PROJECT_KEY/mailbox/"
success "Done!"

# ─── Phase 7: Launch ─────────────────────────────────────────────────────────
echo ""
read -r -p "  Auto-approve agent actions (--yolo)? [Y/n]: " YOLO_CHOICE
YOLO_CHOICE="${YOLO_CHOICE:-Y}"
YOLO_ARG=""
if [[ "$YOLO_CHOICE" =~ ^[Yy]$ ]]; then
    YOLO_ARG="--yolo"
fi
echo ""
exec "$ROOT_DIR/scripts/start.sh" "$PROJECT_KEY" $YOLO_ARG
