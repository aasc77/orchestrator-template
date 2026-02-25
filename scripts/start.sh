#!/bin/bash
set -e

PROJECT=""
YOLO_FLAG=""

for arg in "$@"; do
    case "$arg" in
        --yolo) YOLO_FLAG="--dangerously-skip-permissions" ;;
        *) PROJECT="$arg" ;;
    esac
done

if [[ -z "$PROJECT" ]]; then
    echo "Usage: $0 <project> [--yolo]  (e.g., example)"
    echo "  --yolo      Skip Claude Code permission prompts"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_CONFIG="$PROJECT_DIR/projects/$PROJECT/config.yaml"
MCP_CONFIG="$PROJECT_DIR/claude-code-mcp-config.json"

# Validate project exists
if [ ! -f "$PROJECT_CONFIG" ]; then
    echo "Error: Project '$PROJECT' not found at $PROJECT_CONFIG"
    echo "Available projects:"
    ls -1 "$PROJECT_DIR/projects/"
    exit 1
fi

# Read project config values via Python/YAML
SESSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['tmux']['session_name'])")
DEV_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['dev']['working_dir'])")
QA_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['qa']['working_dir'])")
REFACTOR_DIR=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['agents']['refactor']['working_dir'])")
PROJECT_NAME=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['project'])")
REPO_DIR=$(python3 -c "import yaml; c=yaml.safe_load(open('$PROJECT_CONFIG')); print(c.get('repo_dir', ''))")
PROJECT_MODE=$(python3 -c "import yaml; c=yaml.safe_load(open('$PROJECT_CONFIG')); print(c.get('mode', 'new'))")

# System prompts for agents -- be extremely direct to avoid wasted exploration
DEV_PROMPT="You are the Dev agent (GREEN). Your ONLY communication channel is the agent-bridge MCP server. Do NOT search for config files or explore the filesystem for messages. To get tasks: call the check_messages MCP tool with role 'dev'. To send code to refactor: call send_to_refactor. IMPORTANT: Always git add and commit your code BEFORE calling send_to_refactor. Start by calling check_messages now."

if [[ "$PROJECT_MODE" == "existing" ]]; then
    QA_PROMPT="You are the QA agent (CHARACTERIZATION). Your ONLY communication channel is the agent-bridge MCP server. Do NOT search for config files or explore the filesystem for messages. To get tasks: call the check_messages MCP tool with role 'qa'. Your tests should PASS against the existing code (characterization, not TDD). To send test results: call send_to_dev. IMPORTANT: Always git add and commit your tests BEFORE calling send_to_dev. Start by calling check_messages now."
else
    QA_PROMPT="You are the QA agent (RED). Your ONLY communication channel is the agent-bridge MCP server. Do NOT search for config files or explore the filesystem for messages. To get tasks: call the check_messages MCP tool with role 'qa'. To send test results: call send_to_dev. IMPORTANT: Always git add and commit your tests BEFORE calling send_to_dev. Start by calling check_messages now."
fi

REFACTOR_PROMPT="You are the Refactor agent (BLUE). Your ONLY communication channel is the agent-bridge MCP server. Do NOT search for config files or explore the filesystem for messages. To get tasks: call the check_messages MCP tool with role 'refactor'. To send results: call send_refactor_complete. IMPORTANT: Always git add and commit your changes BEFORE calling send_refactor_complete. Start by calling check_messages now."

echo "Multi-Agent RGR Orchestrator"
echo "================================"
echo "Project: $PROJECT ($PROJECT_NAME)"
echo ""

# --- Pre-flight checks ---
echo "Pre-flight checks..."

command -v tmux >/dev/null 2>&1 || { echo "tmux not found. Install: brew install tmux"; exit 1; }
echo "  tmux OK"

command -v claude >/dev/null 2>&1 || { echo "Claude Code not found. Install: npm install -g @anthropic-ai/claude-code"; exit 1; }
echo "  claude OK"

command -v ollama >/dev/null 2>&1 || { echo "Ollama not found. Install: brew install ollama"; exit 1; }
echo "  ollama OK"

command -v python3 >/dev/null 2>&1 || { echo "Python3 not found."; exit 1; }
echo "  python3 OK"

command -v git >/dev/null 2>&1 || { echo "git not found."; exit 1; }
echo "  git OK"

# Check Ollama is running (with timeout), auto-start if needed
if ! curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "  ollama server not responding -- starting it..."
    # Try macOS app first, fall back to CLI
    if [[ -d "/Applications/Ollama.app" ]]; then
        open -a Ollama
    else
        ollama serve &>/dev/null &
    fi
    for i in $(seq 1 15); do
        sleep 2
        if curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
            break
        fi
        echo "  waiting for ollama... (${i}/15)"
    done
    if ! curl -sf --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo ""
        echo "Ollama failed to start after 30s. Run manually: ollama serve"
        exit 1
    fi
fi
echo "  ollama server OK"

# Check MCP config exists
if [ ! -f "$MCP_CONFIG" ]; then
    echo "MCP config not found at $MCP_CONFIG"
    echo "Run $PROJECT_DIR/scripts/setup.sh first"
    exit 1
fi
echo "  MCP config OK"

# Ensure MCP bridge dependencies are installed
if [ ! -d "$PROJECT_DIR/mcp-bridge/node_modules" ]; then
    echo "  Installing MCP bridge dependencies..."
    (cd "$PROJECT_DIR/mcp-bridge" && npm install --silent)
fi
echo "  MCP bridge deps OK"

# Check agent working dirs exist (worktrees)
for agent_label_dir in "Dev:$DEV_DIR" "QA:$QA_DIR" "Refactor:$REFACTOR_DIR"; do
    label="${agent_label_dir%%:*}"
    dir="${agent_label_dir#*:}"
    if [ ! -d "$dir" ]; then
        echo "$label working dir not found: $dir"
        echo "Run new-project.sh to set up worktrees, or update $PROJECT_CONFIG"
        exit 1
    fi
    echo "  $label dir OK ($dir)"
done

# Check repo_dir is a git repo (if configured)
if [[ -n "$REPO_DIR" ]]; then
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "Warning: repo_dir ($REPO_DIR) is not a git repository"
    else
        echo "  Repo dir OK ($REPO_DIR)"
    fi
fi

echo ""

# --- Determine task ID for branch names ---
TASKS_FILE="$PROJECT_DIR/projects/$PROJECT/tasks.json"
TASK_ID=""
if [[ -f "$TASKS_FILE" ]]; then
    # Get the first pending or in_progress task ID
    TASK_ID=$(python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
for t in data['tasks']:
    if t['status'] in ('pending', 'in_progress'):
        print(t['id'])
        break
" 2>/dev/null || true)
fi
TASK_ID="${TASK_ID:-task-1}"
echo "Task branch suffix: $TASK_ID"

# --- Create task branches in worktrees ---
if [[ -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]]; then
    echo "Creating task branches..."

    # QA worktree: red/<task-id>
    if git -C "$QA_DIR" rev-parse --verify "red/$TASK_ID" >/dev/null 2>&1; then
        git -C "$QA_DIR" checkout "red/$TASK_ID" --quiet
        echo "  QA: checked out existing red/$TASK_ID"
    else
        git -C "$QA_DIR" checkout -b "red/$TASK_ID" --quiet
        echo "  QA: created red/$TASK_ID"
    fi

    # Dev worktree: green/<task-id>
    if git -C "$DEV_DIR" rev-parse --verify "green/$TASK_ID" >/dev/null 2>&1; then
        git -C "$DEV_DIR" checkout "green/$TASK_ID" --quiet
        echo "  Dev: checked out existing green/$TASK_ID"
    else
        git -C "$DEV_DIR" checkout -b "green/$TASK_ID" --quiet
        echo "  Dev: created green/$TASK_ID"
    fi

    # Refactor worktree: blue/<task-id>
    if git -C "$REFACTOR_DIR" rev-parse --verify "blue/$TASK_ID" >/dev/null 2>&1; then
        git -C "$REFACTOR_DIR" checkout "blue/$TASK_ID" --quiet
        echo "  Refactor: checked out existing blue/$TASK_ID"
    else
        git -C "$REFACTOR_DIR" checkout -b "blue/$TASK_ID" --quiet
        echo "  Refactor: created blue/$TASK_ID"
    fi

    echo ""
fi

# --- Kill existing session ---
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Existing '$SESSION' tmux session found."
    read -r -p "Kill it and start fresh? [y/N] " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        tmux kill-session -t "$SESSION"
        echo "  Killed existing session"
        sleep 1
    else
        echo "Aborting. Attach with: tmux attach -t $SESSION"
        exit 0
    fi
fi

# --- Generate per-project MCP config (bakes in ORCH_PROJECT for the bridge) ---
PROJECT_MCP_CONFIG="$PROJECT_DIR/shared/$PROJECT/mcp-config.json"
mkdir -p "$(dirname "$PROJECT_MCP_CONFIG")"
cat > "$PROJECT_MCP_CONFIG" <<MCPEOF
{
  "mcpServers": {
    "agent-bridge": {
      "command": "node",
      "args": ["$PROJECT_DIR/mcp-bridge/index.js"],
      "env": {
        "ORCH_PROJECT": "$PROJECT"
      }
    }
  }
}
MCPEOF
MCP_CONFIG="$PROJECT_MCP_CONFIG"
echo "  MCP config generated ($MCP_CONFIG)"

# --- Clear old mailbox messages ---
echo "Clearing old mailbox messages..."
MAILBOX_DIR="$PROJECT_DIR/shared/$PROJECT/mailbox"
mkdir -p "$MAILBOX_DIR/to_dev" "$MAILBOX_DIR/to_qa" "$MAILBOX_DIR/to_refactor"
rm -f "$MAILBOX_DIR/to_dev/"*.json 2>/dev/null || true
rm -f "$MAILBOX_DIR/to_qa/"*.json 2>/dev/null || true
rm -f "$MAILBOX_DIR/to_refactor/"*.json 2>/dev/null || true
echo "  Mailboxes cleared ($MAILBOX_DIR)"

# --- Create tmux session ---
echo ""
echo "Creating tmux session '$SESSION'..."

# Window creation order determines pane positions after tiled layout:
#   pane 0 = top-left, 1 = top-right, 2 = bottom-left, 3 = bottom-right

# Session starts with QA (pane 0, top-left)
tmux new-session -d -s "$SESSION" -n "qa" -c "$QA_DIR"
echo "  Window 'qa' created (dir: $QA_DIR)"

# Dev (pane 1, top-right)
tmux new-window -t "$SESSION" -n "dev" -c "$DEV_DIR"
echo "  Window 'dev' created (dir: $DEV_DIR)"

# Refactor (pane 2, bottom-left)
tmux new-window -t "$SESSION" -n "refactor" -c "$REFACTOR_DIR"
echo "  Window 'refactor' created (dir: $REFACTOR_DIR)"

# Orchestrator (pane 3, bottom-right)
tmux new-window -t "$SESSION" -n "orch" -c "$PROJECT_DIR/orchestrator"
echo "  Window 'orch' created"

# --- Launch processes ---
echo ""
echo "Launching agents..."

# Start QA agent (RED)
tmux send-keys -t "$SESSION:qa" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$QA_PROMPT\" $YOLO_FLAG" Enter
echo "  QA agent started (RED)"

# Start Dev agent (GREEN)
tmux send-keys -t "$SESSION:dev" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$DEV_PROMPT\" $YOLO_FLAG" Enter
echo "  Dev agent started (GREEN)"

# Start Refactor agent (BLUE)
tmux send-keys -t "$SESSION:refactor" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$REFACTOR_PROMPT\" $YOLO_FLAG" Enter
echo "  Refactor agent started (BLUE)"

# Start orchestrator with project argument
tmux send-keys -t "$SESSION:orch" "python3 orchestrator.py $PROJECT" Enter
echo "  Orchestrator started (project: $PROJECT)"

# --- Merge into single window with 2x2 split panes ---
echo ""
echo "Merging windows into 2x2 layout..."

# Layout (after tiled):
# +----------+----------+
# | QA_RED(0)|DEV_GRN(1)|
# +----------+----------+
# |REFAC (2) | ORCH (3) |
# +----------+----------+

# Join all into the qa window (first window), then tile
tmux join-pane -s "$SESSION:dev" -t "$SESSION:qa"
tmux join-pane -s "$SESSION:refactor" -t "$SESSION:qa"
tmux join-pane -s "$SESSION:orch" -t "$SESSION:qa"
tmux select-layout -t "$SESSION:qa" tiled
echo "  2x2 grid layout applied"

# --- Pane styling ---
echo "Applying pane styling..."

# Enable pane border labels
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #{?pane_active,#[bold],#[dim]}#{pane_title} "

# Set pane titles (pane 0=qa, 1=dev, 2=refactor, 3=orch)
tmux select-pane -t "$SESSION:qa.0" -T "QA_RED [$PROJECT]"
tmux select-pane -t "$SESSION:qa.1" -T "DEV_GREEN [$PROJECT]"
tmux select-pane -t "$SESSION:qa.2" -T "REFACTOR_BLUE [$PROJECT]"
tmux select-pane -t "$SESSION:qa.3" -T "ORCH [$PROJECT]"

# Check if the RGR composite background image exists
COMPOSITE_IMG="$HOME/.config/orchestrator-template/images/rgr_composite.png"
if [ -f "$COMPOSITE_IMG" ]; then
    # Transparent pane backgrounds -- let iTerm2's background image show through
    tmux select-pane -t "$SESSION:qa.0" -P 'bg=default'
    tmux select-pane -t "$SESSION:qa.1" -P 'bg=default'
    tmux select-pane -t "$SESSION:qa.2" -P 'bg=default'
    tmux select-pane -t "$SESSION:qa.3" -P 'bg=default'
    # Also set window/pane default styles to transparent
    tmux set-option -t "$SESSION" window-style 'bg=default'
    tmux set-option -t "$SESSION" window-active-style 'bg=default'
    echo "  Transparent pane backgrounds (composite image will show through)"
    USE_COMPOSITE=true
else
    # Fallback: solid color backgrounds (no composite image found)
    tmux select-pane -t "$SESSION:qa.0" -P 'bg=colour52'     # qa: dark red
    tmux select-pane -t "$SESSION:qa.1" -P 'bg=colour22'     # dev: dark green
    tmux select-pane -t "$SESSION:qa.2" -P 'bg=colour17'     # refactor: dark blue
    tmux select-pane -t "$SESSION:qa.3" -P 'bg=colour233'    # orch: near-black
    echo "  Solid color pane backgrounds (run setup-iterm-profiles.sh for robot images)"
    USE_COMPOSITE=false
fi

# Border colors
tmux set-option -t "$SESSION" pane-border-style "fg=colour240"
tmux set-option -t "$SESSION" pane-active-border-style "fg=colour75,bold"

# Enable mouse mode (click to switch panes, scroll, resize)
tmux set-option -t "$SESSION" mouse on
echo "  Pane styling applied"

# --- Initial nudge ---
echo ""
echo "Waiting for agents to initialize..."
sleep 5

# Nudge QA to pick up first task (RGR starts with RED phase)
tmux send-keys -t "$SESSION:qa.0" -l "You have new messages. Use the check_messages MCP tool with role 'qa' to read and act on them."
sleep 0.2
tmux send-keys -t "$SESSION:qa.0" Enter
echo "  Nudged QA to pick up first task (RED phase)"

# --- Attach ---
echo ""
echo "================================"
echo "RGR Session '$SESSION' is running! (project: $PROJECT)"
echo ""
echo "Panes:"
echo "  0: QA_RED        - QA agent (top-left)          [dark red bg]"
echo "  1: DEV_GREEN     - Dev agent (top-right)        [dark green bg]"
echo "  2: REFACTOR_BLUE - Refactor agent (bottom-left) [dark blue bg]"
echo "  3: ORCH          - Orchestrator (bottom-right)  [near-black bg]"
echo ""
echo "Git branches:"
echo "  QA:       red/$TASK_ID"
echo "  Dev:      green/$TASK_ID"
echo "  Refactor: blue/$TASK_ID"
echo ""
echo "Navigation:"
echo "  Ctrl-b q       - Show pane numbers"
echo "  Ctrl-b o       - Cycle to next pane"
echo "  Ctrl-b ;       - Toggle last active pane"
echo "  Ctrl-b d       - Detach (session keeps running)"
echo "  $PROJECT_DIR/scripts/stop.sh $PROJECT - Graceful shutdown"
echo "================================"
echo ""

# Select the orchestrator pane
tmux select-pane -t "$SESSION:qa.3"

# If composite image exists, switch iTerm2 to the RGR profile before attaching.
# The escape sequence sets the profile for this iTerm2 session so the
# composite robot background shows through the transparent tmux panes.
if $USE_COMPOSITE; then
    printf '\033]1337;SetProfile=RGR\007'
    echo "  iTerm2 profile set to 'RGR' (composite background)"
fi

tmux attach -t "$SESSION"
