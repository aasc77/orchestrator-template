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

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
CLEANUP_PROJECT_DIR=""
CLEANUP_SHARED_DIR=""

cleanup() {
    if [[ -n "$CLEANUP_PROJECT_DIR" && -d "$CLEANUP_PROJECT_DIR" ]]; then
        rm -rf "$CLEANUP_PROJECT_DIR"
        warn "Cleaned up partial project directory: $CLEANUP_PROJECT_DIR"
    fi
    if [[ -n "$CLEANUP_SHARED_DIR" && -d "$CLEANUP_SHARED_DIR" ]]; then
        rm -rf "$CLEANUP_SHARED_DIR"
        warn "Cleaned up partial shared directory: $CLEANUP_SHARED_DIR"
    fi
}

trap cleanup INT TERM ERR

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo "  ${BOLD}New Project Wizard${RESET}"
echo "  =================="
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

# ─── Phase 2: Locate dev directory ───────────────────────────────────────────
DEV_DIR="$REPOS_DIR/$FOLDER_NAME"

if [[ -d "$DEV_DIR" ]]; then
    info "Dev directory found: $DEV_DIR"
else
    mkdir -p "$DEV_DIR"
    info "Created dev directory: $DEV_DIR"
fi

# ─── Phase 3: Derive project name + key ──────────────────────────────────────
# Project name: underscored version (e.g., my_app)
DEFAULT_PROJECT_NAME="${FOLDER_NAME//-/_}"
# Project key: hyphenated version (e.g., my-app)
DEFAULT_PROJECT_KEY="${FOLDER_NAME//_/-}"

echo ""
read -r -p "  Project name [${DEFAULT_PROJECT_NAME}]: " PROJECT_NAME
PROJECT_NAME="${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}"

read -r -p "  Project key  [${DEFAULT_PROJECT_KEY}]: " PROJECT_KEY
PROJECT_KEY="${PROJECT_KEY:-$DEFAULT_PROJECT_KEY}"

# Validate project key doesn't conflict with existing project
if [[ -d "$ROOT_DIR/projects/$PROJECT_KEY" ]]; then
    error "Project '$PROJECT_KEY' already exists at projects/$PROJECT_KEY/"
    echo "  Choose a different key or remove the existing project first."
    exit 1
fi

# ─── Phase 4: QA directory ───────────────────────────────────────────────────
QA_DIR="${DEV_DIR}_qa"

echo ""
if [[ -d "$QA_DIR" ]]; then
    info "QA directory found: $QA_DIR"
else
    # If dev has a git remote, clone it; otherwise create empty
    REMOTE_URL=""
    if [[ -d "$DEV_DIR/.git" ]]; then
        REMOTE_URL=$(git -C "$DEV_DIR" remote get-url origin 2>/dev/null || true)
    fi

    if [[ -n "$REMOTE_URL" ]]; then
        info "Cloning QA directory from $REMOTE_URL..."
        if git clone "$REMOTE_URL" "$QA_DIR" 2>/dev/null; then
            success "Cloned QA directory: $QA_DIR"
        else
            warn "Git clone failed. Creating empty directory instead."
            mkdir -p "$QA_DIR"
            info "Created QA directory: $QA_DIR"
        fi
    else
        mkdir -p "$QA_DIR"
        info "Created QA directory: $QA_DIR"
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
echo "  Dev directory: $DEV_DIR"
echo "  QA directory:  $QA_DIR"
echo ""
echo "  Will create:"
echo "    projects/$PROJECT_KEY/config.yaml"
echo "    projects/$PROJECT_KEY/tasks.json"
echo "    projects/$PROJECT_KEY/agents/dev/CLAUDE.md"
echo "    projects/$PROJECT_KEY/agents/qa/CLAUDE.md"
echo "    shared/$PROJECT_KEY/mailbox/{to_dev,to_qa}/"
echo "    shared/$PROJECT_KEY/workspace/"
echo "  ${BOLD}=================================${RESET}"
echo ""

read -r -p "  Proceed? [Y/n]: " confirm
confirm="${confirm:-Y}"

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 0
fi

# ─── Phase 6: Create all files ───────────────────────────────────────────────

# Mark for cleanup on failure
CLEANUP_PROJECT_DIR="$PROJECT_DIR"
CLEANUP_SHARED_DIR="$SHARED_DIR"

# Create directory structure
mkdir -p "$PROJECT_DIR/agents/dev"
mkdir -p "$PROJECT_DIR/agents/qa"
mkdir -p "$SHARED_DIR/mailbox/to_dev"
mkdir -p "$SHARED_DIR/mailbox/to_qa"
mkdir -p "$SHARED_DIR/workspace"

# --- config.yaml ---
cat > "$PROJECT_DIR/config.yaml" <<EOF
# Project: $PROJECT_NAME
project: $PROJECT_NAME

tmux:
  session_name: $PROJECT_KEY

agents:
  dev:
    working_dir: $DEV_DIR
    pane: orch.0
  qa:
    working_dir: $QA_DIR
    pane: orch.1
EOF
info "Created projects/$PROJECT_KEY/config.yaml"

# --- tasks.json ---
cat > "$PROJECT_DIR/tasks.json" <<EOF
{
  "project": "$PROJECT_NAME",
  "tasks": [
    {
      "id": "smoke-1",
      "title": "Smoke test: create task1.txt in shared workspace",
      "description": "Create a file at $ROOT_DIR/shared/$PROJECT_KEY/workspace/task1.txt containing exactly: 'task 1 done'. This is a simple smoke test to verify the Dev->QA pipeline works end-to-end.",
      "acceptance_criteria": [
        "$ROOT_DIR/shared/$PROJECT_KEY/workspace/task1.txt exists",
        "File contains exactly: 'task 1 done'",
        "File is readable via the read_workspace_file MCP tool"
      ],
      "status": "pending",
      "attempts": 0,
      "max_attempts": 3
    },
    {
      "id": "smoke-2",
      "title": "Smoke test: create task2.txt in shared workspace",
      "description": "Create a file at $ROOT_DIR/shared/$PROJECT_KEY/workspace/task2.txt containing exactly: 'task 2 done'. This tests that the orchestrator correctly hands off to the next task after the first one completes.",
      "acceptance_criteria": [
        "$ROOT_DIR/shared/$PROJECT_KEY/workspace/task2.txt exists",
        "File contains exactly: 'task 2 done'",
        "File is readable via the read_workspace_file MCP tool"
      ],
      "status": "pending",
      "attempts": 0,
      "max_attempts": 3
    }
  ]
}
EOF
info "Created projects/$PROJECT_KEY/tasks.json"

# --- agents/dev/CLAUDE.md ---
cat > "$PROJECT_DIR/agents/dev/CLAUDE.md" <<'DEVEOF'
# Dev Agent

You are the **DEVELOPER** agent in an automated Dev/QA workflow with an AI orchestrator.

---

## Project Context

<!-- TODO: Add your project-specific context here -->
<!-- Examples: tech stack, architecture, key URLs, deployment commands, DB schemas, etc. -->

---

## Communication Protocol (MCP-Based)

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_qa`** -- Notify QA that code is ready for testing
  - `summary`: What you built/changed
  - `files_changed`: List of files created or modified
  - `test_instructions`: How QA should test (URLs, commands, expected behavior)

- **`check_messages`** -- Check your mailbox for orchestrator tasks and QA feedback
  - `role`: Always use `"dev"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. Receive a task via `check_messages` (role: `"dev"`)
2. Implement the feature/fix in the project codebase
3. When ready, call `send_to_qa` with:
   - What changed (summary)
   - Files modified (list)
   - How to test (URLs, steps, expected behavior)
4. Wait -- periodically call `check_messages` with role `"dev"` to get QA results
5. If QA reports bugs -> fix them -> call `send_to_qa` again
6. If QA passes -> wait for next task from orchestrator

### Rules
- Always include test instructions when sending to QA
- Include relevant URLs, endpoints, and test credentials
- Be specific about expected behavior for each acceptance criterion
- If a task is ambiguous, make reasonable assumptions and document them
- Code should be committed/deployed before sending to QA
DEVEOF

# Substitute project name into the header
sed -i '' "s/^# Dev Agent$/# Dev Agent -- $PROJECT_NAME/" "$PROJECT_DIR/agents/dev/CLAUDE.md"
info "Created projects/$PROJECT_KEY/agents/dev/CLAUDE.md"

# --- agents/qa/CLAUDE.md ---
cat > "$PROJECT_DIR/agents/qa/CLAUDE.md" <<'QAEOF'
# QA Agent -- Black-Box Testing

You are the **QA Agent** in an automated Dev/QA workflow with an AI orchestrator.
You do BLACK-BOX testing only -- test behavior, not implementation.

---

## Test Environment

<!-- TODO: Add your project-specific test context here -->
<!-- Examples: key URLs, test credentials, API endpoints, test commands, known bugs, etc. -->

---

## Communication Protocol (MCP-Based)

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_dev`** -- Send test results back to Dev
  - `status`: `"pass"`, `"fail"`, or `"partial"`
  - `summary`: Overall test results summary
  - `bugs`: Array of bug objects (empty if pass)
  - `tests_run`: Description of what you tested

- **`check_messages`** -- Check your mailbox for new work from Dev
  - `role`: Always use `"qa"`

- **`list_workspace`** -- See all files in the shared workspace

- **`read_workspace_file`** -- Read a specific file from workspace

### Workflow
1. When notified, call `check_messages` with role `"qa"` to get Dev's submission
2. Read what was built and the test instructions
3. Test the feature:
   - Hit the URLs/endpoints Dev specified
   - Use the test credentials provided
   - Check acceptance criteria one by one
4. Call `send_to_dev` with results:
   - **pass** -- All acceptance criteria met
   - **fail** -- Bugs found (include bug details)
   - **partial** -- Some criteria met, some not

### Bug Report Format
For each bug in the `bugs` array:
```json
{
  "description": "What's wrong",
  "severity": "critical|major|minor|cosmetic",
  "steps_to_reproduce": "Exact steps",
  "expected": "What should happen",
  "actual": "What actually happens"
}
```

### Testing Approach
- Test as an end user would -- use the UI, call the APIs, try the flows
- Test happy path first, then edge cases
- Test with bad inputs: empty fields, invalid data
- Verify error messages are helpful and correct HTTP status codes
- Check all acceptance criteria from the task -- every one must pass for a PASS verdict

### Severity Guide
- **critical** -- Feature broken, can't complete the flow at all
- **major** -- Feature works but significant issue (wrong data, security hole, bad error handling)
- **minor** -- Works but UX issue (confusing message, slow response, minor display bug)
- **cosmetic** -- Visual only (alignment, typo, color)

### Rules
- Be thorough but fair -- don't block on cosmetic issues
- If you can't test because setup instructions are missing, report THAT as a bug
- If all acceptance criteria pass, mark PASS even with minor cosmetic findings
QAEOF

# Substitute project name into the header
sed -i '' "s/^# QA Agent -- Black-Box Testing$/# QA Agent -- $PROJECT_NAME/" "$PROJECT_DIR/agents/qa/CLAUDE.md"
info "Created projects/$PROJECT_KEY/agents/qa/CLAUDE.md"

# Clear cleanup markers on success
CLEANUP_PROJECT_DIR=""
CLEANUP_SHARED_DIR=""

success "Created projects/$PROJECT_KEY/"
success "Created shared/$PROJECT_KEY/mailbox/"
success "Done!"

# ─── Phase 7: Next steps ─────────────────────────────────────────────────────
echo ""
echo "  ${BOLD}Next steps:${RESET}"
echo "    1. Edit tasks:    ${DIM}vi projects/$PROJECT_KEY/tasks.json${RESET}"
echo "    2. Customize Dev: ${DIM}vi projects/$PROJECT_KEY/agents/dev/CLAUDE.md${RESET}"
echo "    3. Customize QA:  ${DIM}vi projects/$PROJECT_KEY/agents/qa/CLAUDE.md${RESET}"
echo "    4. Launch:        ${DIM}./scripts/start.sh $PROJECT_KEY${RESET}"
echo "    5. Launch (auto): ${DIM}./scripts/start.sh $PROJECT_KEY --yolo${RESET}"
echo ""
