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
    echo "  Do you have an existing PRD to review, or start from scratch?"
    echo ""
    echo "    1) Start from scratch -- describe your idea and generate a PRD"
    echo "    2) Review existing PRD -- discuss and refine an existing document"
    echo ""
    read -r -p "  Choice [1/2]: " PM_CHOICE
    PM_CHOICE="${PM_CHOICE:-1}"

    # Extract PM prompt from docs
    PM_PROMPT_FILE="$ROOT_DIR/docs/pm_agent.md"
    if [[ ! -f "$PM_PROMPT_FILE" ]]; then
        error "PM prompt file not found: $PM_PROMPT_FILE"
        exit 1
    fi

    PM_TMPDIR=$(mktemp -d)

    if [[ "$PM_CHOICE" == "2" ]]; then
        # ─── Review existing PRD ─────────────────────────────────────────
        echo ""
        read -r -p "  Path to your PRD file: " PRD_INPUT_PATH

        # Expand ~ to home directory
        PRD_INPUT_PATH="${PRD_INPUT_PATH/#\~/$HOME}"

        if [[ ! -f "$PRD_INPUT_PATH" ]]; then
            error "File not found: $PRD_INPUT_PATH"
            exit 1
        fi

        PM_PROMPT=$(extract_prompt "$PM_PROMPT_FILE" "pm_agent_review/CLAUDE.md")

        # Copy PRD into temp dir so the agent can read it
        cp "$PRD_INPUT_PATH" "$PM_TMPDIR/existing-prd.md"

        cat > "$PM_TMPDIR/CLAUDE.md" <<PMEOF
$PM_PROMPT

---

## Existing PRD
Read the file \`existing-prd.md\` in this directory. This is the user's current PRD.

## Process
1. Read existing-prd.md
2. Summarize it back to the user
3. Discuss gaps, ambiguities, and improvements
4. When the user is satisfied, write the final refined version to \`prd.md\`
5. After writing prd.md, tell the user: "PRD written! Type /exit to continue." and stop.
PMEOF

        PM_INITIAL_PROMPT="Read existing-prd.md and start the review. Summarize the PRD's scope and key requirements, then identify any gaps or areas to discuss."

        info "Launching Claude Code as PM agent (review mode)..."
        info "PRD loaded from: $PRD_INPUT_PATH"
    else
        # ─── Generate from scratch ───────────────────────────────────────
        echo ""
        echo "  Describe your idea (one paragraph):"
        read -r -p "  > " USER_IDEA

        if [[ -z "$USER_IDEA" ]]; then
            error "Idea cannot be empty."
            exit 1
        fi

        PM_PROMPT=$(extract_prompt "$PM_PROMPT_FILE" "pm_agent/CLAUDE.md")
        PM_PROMPT="${PM_PROMPT//\{\{USER_IDEA\}\}/$USER_IDEA}"

        cat > "$PM_TMPDIR/CLAUDE.md" <<PMEOF
$PM_PROMPT

---

## User's Idea
$USER_IDEA

## Output
Write the complete PRD to a file called \`prd.md\` in this directory.
PMEOF

        PM_INITIAL_PROMPT="Generate a comprehensive PRD based on the user's idea described in CLAUDE.md."

        info "Launching Claude Code as PM agent..."
    fi

    echo "  Working dir: $PM_TMPDIR"
    echo ""
    if [[ "$PM_CHOICE" == "2" ]]; then
        echo "  ${YELLOW}When the PM finishes writing prd.md, type /exit to continue.${RESET}"
        echo ""
    fi

    # Launch Claude Code with PM system prompt and initial prompt
    # Review mode: normal permissions (agent discusses first, asks before writing)
    # Scratch mode: skip permissions (agent generates autonomously)
    if [[ "$PM_CHOICE" == "2" ]]; then
        (cd "$PM_TMPDIR" && claude "$PM_INITIAL_PROMPT") || true
    else
        (cd "$PM_TMPDIR" && claude --dangerously-skip-permissions "$PM_INITIAL_PROMPT") || true
    fi

    echo ""
    info "PM session ended."
    echo ""

    # Check for generated PRD
    if [[ -f "$PM_TMPDIR/prd.md" ]]; then
        success "PRD ready: $PM_TMPDIR/prd.md"
        echo ""
        echo "  ${BOLD}Preview (first 20 lines):${RESET}"
        head -20 "$PM_TMPDIR/prd.md" | sed 's/^/    /'
        echo "    ..."
        echo ""
        echo "  ${BOLD}Next step:${RESET} Run this wizard again, pick mode 2 or 3,"
        echo "  and provide this PRD path when prompted:"
        echo ""
        echo "    ${CYAN}$PM_TMPDIR/prd.md${RESET}"
        echo ""
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

# ─── Optional PRD import ───────────────────────────────────────────────────
PRD_PATH=""
echo "  Do you have a PRD to guide the agents?"
echo ""
echo "    1) No PRD -- start without one"
echo "    2) Yes -- provide path to a PRD file"
echo ""
read -r -p "  Choice [1/2]: " PRD_CHOICE
PRD_CHOICE="${PRD_CHOICE:-1}"

if [[ "$PRD_CHOICE" == "2" ]]; then
    echo ""
    read -r -p "  Path to PRD file: " PRD_INPUT
    PRD_INPUT="${PRD_INPUT/#\~/$HOME}"

    if [[ -f "$PRD_INPUT" ]]; then
        PRD_PATH="$PRD_INPUT"
        success "PRD found: $PRD_PATH"
    else
        warn "File not found: $PRD_INPUT -- continuing without PRD"
    fi
fi
echo ""

# ─── Phase 1: Gather folder name ─────────────────────────────────────────────
FOLDER_NAME="${1:-}"

if [[ -z "$FOLDER_NAME" && "$PROJECT_MODE" == "existing" ]]; then
    # Interactive picker: list git repos in ~/Repositories/
    REPO_DIRS=()
    while IFS= read -r d; do
        if [[ -d "$d/.git" ]]; then
            REPO_DIRS+=("$(basename "$d")")
        fi
    done < <(find "$REPOS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [[ ${#REPO_DIRS[@]} -eq 0 ]]; then
        error "No git repos found in $REPOS_DIR"
        exit 1
    fi

    echo "  ${BOLD}Git repos in ~/Repositories/:${RESET}"
    echo ""
    for i in "${!REPO_DIRS[@]}"; do
        printf "    %3d) %s\n" "$((i + 1))" "${REPO_DIRS[$i]}"
    done
    echo ""
    read -r -p "  Select repo number: " REPO_SELECTION

    if [[ "$REPO_SELECTION" =~ ^[0-9]+$ ]] && (( REPO_SELECTION >= 1 && REPO_SELECTION <= ${#REPO_DIRS[@]} )); then
        FOLDER_NAME="${REPO_DIRS[$((REPO_SELECTION - 1))]}"
    else
        error "Invalid selection."
        exit 1
    fi
fi

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

    # Existing mode: folder must already exist with a git repo
    if [[ "$PROJECT_MODE" == "existing" ]]; then
        if [[ ! -d "$REPOS_DIR/$FOLDER_NAME/.git" ]]; then
            warn "Folder '$FOLDER_NAME' does not exist or is not a git repo in ~/Repositories/"
            FOLDER_NAME=""
            continue
        fi
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

# ─── Phase 3b: File discovery (existing projects only) ──────────────────────
CHAR_FILES=()
if [[ "$PROJECT_MODE" == "existing" ]]; then
    echo ""
    info "Discovering source files for characterization..."

    # Common find exclusions
    FIND_EXCLUDES=(
        -not -path "*/node_modules/*" -not -path "*/__pycache__/*"
        -not -path "*/venv/*" -not -path "*/.venv*/*"
        -not -path "*/.worktrees/*" -not -path "*/.next/*"
        -not -path "*/dist/*" -not -path "*/build/*"
        -not -path "*/.playwright*/*" -not -path "*/.qa-workspace/*"
        -not -path "*/test*/*" -not -name "test_*" -not -name "*_test.*"
        -not -name "conftest.py" -not -name "setup.py"
    )
    FIND_EXTENSIONS=( \( -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.tsx" -o -name "*.jsx" \) )

    # Step 1: Discover folders that contain source files
    SRC_FOLDERS=()
    SRC_FOLDER_COUNTS=()
    # Root-level files
    ROOT_COUNT=$(find "$REPO_DIR" -maxdepth 1 -type f "${FIND_EXTENSIONS[@]}" "${FIND_EXCLUDES[@]}" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ROOT_COUNT" -gt 0 ]]; then
        SRC_FOLDERS+=(".")
        SRC_FOLDER_COUNTS+=("$ROOT_COUNT")
    fi
    # Subdirectories
    while IFS= read -r folder; do
        count=$(find "$folder" -type f "${FIND_EXTENSIONS[@]}" "${FIND_EXCLUDES[@]}" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$count" -gt 0 ]]; then
            REL="${folder#$REPO_DIR/}"
            SRC_FOLDERS+=("$REL")
            SRC_FOLDER_COUNTS+=("$count")
        fi
    done < <(find "$REPO_DIR" -mindepth 1 -maxdepth 1 -type d \
        -not -name "node_modules" -not -name "__pycache__" \
        -not -name "venv" -not -name ".venv*" \
        -not -name ".worktrees" -not -name ".next" \
        -not -name "dist" -not -name "build" \
        -not -name ".playwright*" -not -name ".qa-workspace" \
        -not -name ".git" -not -name "test*" \
        2>/dev/null | sort)

    if [[ ${#SRC_FOLDERS[@]} -eq 0 ]]; then
        error "No source files (.py, .js, .ts, .tsx, .jsx) found in $REPO_DIR"
        exit 1
    fi

    echo ""
    echo "  ${BOLD}Folders with source files:${RESET}"
    echo ""
    TOTAL_FILES=0
    for i in "${!SRC_FOLDERS[@]}"; do
        printf "    %3d) %-40s (%s files)\n" "$((i + 1))" "${SRC_FOLDERS[$i]}/" "${SRC_FOLDER_COUNTS[$i]}"
        TOTAL_FILES=$((TOTAL_FILES + SRC_FOLDER_COUNTS[$i]))
    done
    echo ""
    echo "  ${DIM}Total: $TOTAL_FILES source files across ${#SRC_FOLDERS[@]} folders${RESET}"
    echo ""
    echo "  Enter folder numbers (comma-separated), or 'a' for all:"
    read -r -p "  > " FOLDER_SELECTION

    # Step 2: Collect files from selected folders
    SELECTED_DIRS=()
    if [[ "$FOLDER_SELECTION" == "a" || "$FOLDER_SELECTION" == "A" ]]; then
        SELECTED_DIRS=("${SRC_FOLDERS[@]}")
    else
        IFS=',' read -ra SELECTIONS <<< "$FOLDER_SELECTION"
        for sel in "${SELECTIONS[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#SRC_FOLDERS[@]} )); then
                SELECTED_DIRS+=("${SRC_FOLDERS[$((sel - 1))]}")
            else
                warn "Ignoring invalid selection: $sel"
            fi
        done
    fi

    if [[ ${#SELECTED_DIRS[@]} -eq 0 ]]; then
        error "No folders selected. Aborting."
        exit 1
    fi

    for dir in "${SELECTED_DIRS[@]}"; do
        if [[ "$dir" == "." ]]; then
            search_path="$REPO_DIR"
            depth_args=(-maxdepth 1)
        else
            search_path="$REPO_DIR/$dir"
            depth_args=()
        fi
        while IFS= read -r line; do
            CHAR_FILES+=("$line")
        done < <(find "$search_path" "${depth_args[@]}" -type f "${FIND_EXTENSIONS[@]}" "${FIND_EXCLUDES[@]}" 2>/dev/null | sort)
    done

    if [[ ${#CHAR_FILES[@]} -eq 0 ]]; then
        error "No source files found in selected folders. Aborting."
        exit 1
    fi

    echo ""
    info "Selected ${#CHAR_FILES[@]} file(s) across ${#SELECTED_DIRS[@]} folder(s)"
fi

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

# ─── Phase 4b: Copy PRD into repo ────────────────────────────────────────────
if [[ -n "$PRD_PATH" ]]; then
    cp "$PRD_PATH" "$REPO_DIR/prd.md"
    git -C "$REPO_DIR" add prd.md
    git -C "$REPO_DIR" commit --quiet -m "chore: add PRD for project reference"
    success "Copied PRD to $REPO_DIR/prd.md"

    # Sync PRD into all worktrees
    for wt_name in qa dev refactor; do
        wt_path="$REPO_DIR/.worktrees/$wt_name"
        git -C "$wt_path" merge --quiet "$DEFAULT_BRANCH" 2>/dev/null || true
    done
    info "Synced PRD into all worktrees"
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
mode: $PROJECT_MODE

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
if [[ "$PROJECT_MODE" == "existing" && ${#CHAR_FILES[@]} -gt 0 ]]; then
    # Generate characterization tasks from selected files
    {
        echo "{"
        echo "  \"project\": \"$PROJECT_NAME\","
        echo "  \"tasks\": ["
        TASK_NUM=0
        LAST_IDX=$(( ${#CHAR_FILES[@]} - 1 ))
        for char_file in "${CHAR_FILES[@]}"; do
            TASK_NUM=$((TASK_NUM + 1))
            REL_PATH="${char_file#$REPO_DIR/}"
            COMMA=","
            if [[ $((TASK_NUM - 1)) -eq $LAST_IDX ]]; then
                COMMA=""
            fi
            cat <<TASKEOF
    {
      "id": "char-$TASK_NUM",
      "title": "Characterize $REL_PATH",
      "description": "Write characterization tests for $REL_PATH. Read the source file from your worktree, identify all public functions/classes, then write tests that PASS against the current implementation.",
      "acceptance_criteria": [
        "Test file exists",
        "Tests cover all public functions/classes",
        "All tests PASS against current code"
      ],
      "source_file": "$REL_PATH",
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }$COMMA
TASKEOF
        done
        echo "  ]"
        echo "}"
    } > "$PROJECT_DIR/tasks.json"
    info "Created projects/$PROJECT_KEY/tasks.json (${#CHAR_FILES[@]} characterization tasks)"
elif [[ -n "$PRD_PATH" ]]; then
    # Interactive task planning session -- user discusses breakdown with Claude
    info "Launching Task Planner to decompose PRD into RGR tasks..."
    echo ""
    TASK_GEN_TMPDIR=$(mktemp -d)
    cp "$PRD_PATH" "$TASK_GEN_TMPDIR/prd.md"

    cat > "$TASK_GEN_TMPDIR/CLAUDE.md" <<'TASKGENEOF'
# Task Planner

You are a task planning agent. You read a PRD and collaborate with the user to produce a well-scoped tasks.json file for a Red-Green-Refactor development pipeline.

## Process
1. Read `prd.md`
2. Propose a task breakdown to the user -- show a numbered list with task titles, short descriptions, and key acceptance criteria
3. Discuss with the user: ask about priorities, scope questions, whether tasks should be split or merged, dependency ordering
4. Iterate until the user approves the plan
5. Only when the user says the plan is good, write `tasks.json`
6. After writing tasks.json, tell the user: "Tasks written! Type /exit to continue with project setup." and stop.

## Task Rules
- Each task = one RGR cycle (QA writes failing tests, Dev implements, Refactor cleans up)
- Tasks ordered by dependency (foundational pieces first, features that depend on them later)
- Task IDs: `rgr-N` (sequential starting at 1)
- Each task needs: id, title, description, acceptance_criteria (array), status ("pending"), attempts (0), max_attempts (5)
- Descriptions must be precise enough for QA to write failing tests and Dev to implement from those tests
- Do NOT create setup/infrastructure tasks (repo init, CI, configs) -- only feature/logic/module tasks
- Aim for 5-15 tasks depending on PRD scope
- Group related functionality into single tasks when they share the same test surface
- Split tasks that would require more than ~200 lines of implementation

## Output Format
When writing tasks.json, output ONLY valid JSON with keys: "project" (string) and "tasks" (array). No markdown fences.
TASKGENEOF

    TASK_GEN_PROMPT="Read prd.md. Propose a task breakdown for the RGR pipeline. Show me the list and let's discuss before you write tasks.json."

    echo "  Working dir: $TASK_GEN_TMPDIR"
    echo ""
    echo "  ${YELLOW}When the Task Planner finishes writing tasks.json, type /exit to continue.${RESET}"
    echo ""

    (cd "$TASK_GEN_TMPDIR" && claude "$TASK_GEN_PROMPT") || true

    echo ""
    info "Task Planner session ended. Continuing with project setup..."
    echo ""

    if [[ -f "$TASK_GEN_TMPDIR/tasks.json" ]]; then
        # Validate it's valid JSON
        if python3 -c "import json; json.load(open('$TASK_GEN_TMPDIR/tasks.json'))" 2>/dev/null; then
            cp "$TASK_GEN_TMPDIR/tasks.json" "$PROJECT_DIR/tasks.json"
            TASK_COUNT=$(python3 -c "import json; print(len(json.load(open('$PROJECT_DIR/tasks.json'))['tasks']))")
            success "Generated $TASK_COUNT tasks from PRD"
        else
            warn "Generated tasks.json is invalid JSON -- falling back to placeholder"
            cat > "$PROJECT_DIR/tasks.json" <<EOF
{
  "project": "$PROJECT_NAME",
  "tasks": [
    {
      "id": "rgr-1",
      "title": "PLACEHOLDER -- replace with real tasks from PRD",
      "description": "The task planner did not produce valid JSON. Read prd.md in the repo root and manually create tasks.",
      "acceptance_criteria": ["Replace this task with real ones from the PRD"],
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }
  ]
}
EOF
            info "Created projects/$PROJECT_KEY/tasks.json (placeholder)"
        fi
    else
        warn "Task planner did not produce tasks.json -- falling back to placeholder"
        cat > "$PROJECT_DIR/tasks.json" <<EOF
{
  "project": "$PROJECT_NAME",
  "tasks": [
    {
      "id": "rgr-1",
      "title": "PLACEHOLDER -- replace with real tasks from PRD",
      "description": "The task planner did not produce a file. Read prd.md in the repo root and manually create tasks.",
      "acceptance_criteria": ["Replace this task with real ones from the PRD"],
      "status": "pending",
      "attempts": 0,
      "max_attempts": 5
    }
  ]
}
EOF
        info "Created projects/$PROJECT_KEY/tasks.json (placeholder)"
    fi
    rm -rf "$TASK_GEN_TMPDIR"
else
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
fi

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
6. Run `/review` to scan for security, performance, and quality issues
7. If `/review` finds **critical or major** issues that require functional changes:
   - Do NOT fix them yourself -- report `status: "fail"` with the findings in `issues`
   - The orchestrator will route them back to Dev for fixing
8. If `/review` is clean or only has minor/cosmetic findings:
   - **Commit your changes**: `git add . && git commit -m "blue: <description>"`
   - Call `send_refactor_complete` with `status: "pass"` and include any minor findings in summary

### Rules
- ALWAYS commit your changes BEFORE calling send_refactor_complete
- NEVER change functional behavior
- NEVER modify test files
- Run tests BEFORE reporting completion
- Run `/review` BEFORE committing -- only safe refactoring fixes (naming, DRY, docs) are yours to make
- Security/performance issues that need functional changes go back to Dev via `status: "fail"`
- Focus on code quality: DRY, naming, extracting constants, documentation
- If unsure whether a change is safe, skip it
REFMCP

# Override QA MCP section for characterization mode
if [[ "$PROJECT_MODE" == "existing" ]]; then
IFS= read -r -d '' QA_MCP_SECTION <<'QAMCP_CHAR' || true

---

## Communication Protocol (MCP-Based)

You are the **QA Agent** (CHARACTERIZATION) in an automated workflow with an AI orchestrator.
You write PASSING tests that document the existing behavior of legacy code.

### MCP Tools Available
You have these tools from the `agent-bridge` MCP server:

- **`send_to_dev`** -- Send test results back to Dev
  - `status`: `"pass"`, `"fail"`, or `"partial"`
  - `summary`: Overall test results summary
  - `bugs`: Array of bug objects (empty if pass)
  - `tests_run`: Description of what you tested

- **`check_messages`** -- Check your mailbox for new work
  - `role`: Always use `"qa"`

### Important: File Access
- **DO NOT use `list_workspace` or `read_workspace_file`** -- the shared workspace is not used in this mode
- All source files are in your **current working directory** (your worktree)
- Use your normal file reading tools to read source files directly

### Workflow
1. Receive a task via `check_messages` with role `"qa"`
2. Read the `source_file` from the task message **directly from your working directory**
3. Identify all public functions, classes, and key behaviors
4. Write characterization tests that PASS against the existing code
5. Run tests to confirm they PASS (the code already exists!)
6. **Commit your tests**: `git add . && git commit -m "red: characterize <file>"`
7. Call `send_to_dev` with status "pass", summary, and tests_run

### Rules
- ALWAYS commit your tests BEFORE calling send_to_dev
- Only write tests, NEVER write implementation code
- Tests MUST PASS before handoff (characterization, not TDD)
- Use pytest for Python projects
- Add `# TODO:` comments for missing standards (e.g., type hints, docstrings)
- Be thorough: test happy path, edge cases, and error conditions
QAMCP_CHAR
fi

# Extract role prompts from selected prompt file
QA_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "qa_agent/CLAUDE.md")
DEV_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "dev_agent/CLAUDE.md")
REFACTOR_ROLE_PROMPT=$(extract_prompt "$PROMPT_FILE" "refactor_agent/CLAUDE.md")

# --- Build PRD section for CLAUDE.md files ---
PRD_CLAUDE_SECTION=""
if [[ -n "$PRD_PATH" ]]; then
    PRD_CLAUDE_SECTION="

---

## Product Requirements Document

A PRD is available at \`prd.md\` in the repo root (also in your worktree).
Read it before starting any task. Every test and implementation MUST trace back to a requirement in the PRD.
Use the PRD's acceptance criteria, edge cases, and error states to guide your work.
"
fi

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
        if [[ -n "$PRD_CLAUDE_SECTION" ]]; then
            printf '%s\n' "$PRD_CLAUDE_SECTION"
        fi
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
        if [[ -n "$PRD_CLAUDE_SECTION" ]]; then
            printf '%s\n' "$PRD_CLAUDE_SECTION"
        fi
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
        if [[ -n "$PRD_CLAUDE_SECTION" ]]; then
            printf '%s\n' "$PRD_CLAUDE_SECTION"
        fi
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
