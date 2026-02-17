#!/bin/bash
set -e

PROJECT=${1:?"Usage: $0 <project> [--yolo]  (e.g., example)"}
YOLO_FLAG=""
if [[ "${2:-}" == "--yolo" ]]; then
    YOLO_FLAG="--dangerously-skip-permissions"
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
PROJECT_NAME=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['project'])")

# System prompts for agents (CLAUDE.md in working dirs is picked up automatically by Claude Code)
DEV_PROMPT="You are the Dev agent for project '$PROJECT_NAME'. Check your messages using the check_messages MCP tool with role 'dev' to get your task assignment."
QA_PROMPT="You are the QA agent for project '$PROJECT_NAME'. Check your messages using the check_messages MCP tool with role 'qa' to get test requests."

echo "Multi-Agent Dev/QA Orchestrator"
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

# Check Ollama is running
if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo ""
    echo "Ollama is not running. Start it with: ollama serve"
    exit 1
fi
echo "  ollama server OK"

# Check MCP config exists
if [ ! -f "$MCP_CONFIG" ]; then
    echo "MCP config not found at $MCP_CONFIG"
    echo "Run $PROJECT_DIR/scripts/setup.sh first"
    exit 1
fi
echo "  MCP config OK"

# Check agent working dirs exist
if [ ! -d "$DEV_DIR" ]; then
    echo "Dev working dir not found: $DEV_DIR"
    echo "Create it or update $PROJECT_CONFIG"
    exit 1
fi
echo "  Dev dir OK ($DEV_DIR)"

if [ ! -d "$QA_DIR" ]; then
    echo "QA working dir not found: $QA_DIR"
    echo "Creating it..."
    mkdir -p "$QA_DIR"
fi
echo "  QA dir OK ($QA_DIR)"

echo ""

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

# --- Clear old mailbox messages ---
echo "Clearing old mailbox messages..."
MAILBOX_DIR="$PROJECT_DIR/shared/$PROJECT/mailbox"
mkdir -p "$MAILBOX_DIR/to_dev" "$MAILBOX_DIR/to_qa"
rm -f "$MAILBOX_DIR/to_dev/"*.json 2>/dev/null || true
rm -f "$MAILBOX_DIR/to_qa/"*.json 2>/dev/null || true
echo "  Mailboxes cleared ($MAILBOX_DIR)"

# --- Create tmux session ---
echo ""
echo "Creating tmux session '$SESSION'..."

# Window 0: orchestrator
tmux new-session -d -s "$SESSION" -n "orch" -c "$PROJECT_DIR/orchestrator"
echo "  Window 'orch' created"

# Window 1: dev agent
tmux new-window -t "$SESSION" -n "dev" -c "$DEV_DIR"
echo "  Window 'dev' created (dir: $DEV_DIR)"

# Window 2: qa agent
tmux new-window -t "$SESSION" -n "qa" -c "$QA_DIR"
echo "  Window 'qa' created (dir: $QA_DIR)"

# --- Launch processes ---
echo ""
echo "Launching agents..."

# Start orchestrator with project argument
tmux send-keys -t "$SESSION:orch" "python3 orchestrator.py $PROJECT" Enter
echo "  Orchestrator started (project: $PROJECT)"

# Start Dev agent (CLAUDE.md in working dir is picked up automatically)
# Unset CLAUDECODE to avoid "nested session" error when launched from within Claude Code
# Pass ORCH_PROJECT env var so MCP bridge knows which project's mailbox to use
tmux send-keys -t "$SESSION:dev" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$DEV_PROMPT\" $YOLO_FLAG" Enter
echo "  Dev agent started"

# Start QA agent
tmux send-keys -t "$SESSION:qa" "unset CLAUDECODE && ORCH_PROJECT=$PROJECT claude --mcp-config $MCP_CONFIG --system-prompt \"$QA_PROMPT\" $YOLO_FLAG" Enter
echo "  QA agent started"

# --- Merge into single window with split panes ---
echo ""
echo "Merging windows into split-pane layout..."

# Join dev and qa windows into the orch window as panes
# Layout: dev and qa side by side on top, orch full-width on bottom
tmux join-pane -s "$SESSION:dev" -t "$SESSION:orch" -v -b
tmux join-pane -s "$SESSION:qa" -t "$SESSION:orch.0" -h
echo "  Tiled layout applied"

# --- Pane styling ---
echo "Applying pane styling..."

# Enable pane border labels
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #{?pane_active,#[bold],#[dim]}#{pane_title} "

# Set pane titles (pane 0=dev, 1=qa, 2=orch)
tmux select-pane -t "$SESSION:orch.0" -T "DEV [$PROJECT]"
tmux select-pane -t "$SESSION:orch.1" -T "QA [$PROJECT]"
tmux select-pane -t "$SESSION:orch.2" -T "ORCH [$PROJECT]"

# Per-pane background tinting (subtle, not distracting)
tmux select-pane -t "$SESSION:orch.0" -P 'bg=colour17'     # dev: very dark blue
tmux select-pane -t "$SESSION:orch.1" -P 'bg=colour233'    # qa: near-black
tmux select-pane -t "$SESSION:orch.2" -P 'bg=colour233'    # orch: near-black

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

# Nudge dev to pick up first task
tmux send-keys -t "$SESSION:orch.0" -l "You have new messages. Use the check_messages MCP tool with role 'dev' to read and act on them."
sleep 0.2
tmux send-keys -t "$SESSION:orch.0" Enter
echo "  Nudged Dev to pick up first task"

# --- Attach ---
echo ""
echo "================================"
echo "Session '$SESSION' is running! (project: $PROJECT)"
echo ""
echo "Panes:"
echo "  0: DEV   - Dev agent (top-left)        [dark blue bg]"
echo "  1: QA    - QA agent (top-right)        [near-black bg]"
echo "  2: ORCH  - Orchestrator (bottom)       [near-black bg]"
echo ""
echo "Navigation:"
echo "  Ctrl-b q       - Show pane numbers"
echo "  Ctrl-b o       - Cycle to next pane"
echo "  Ctrl-b ;       - Toggle last active pane"
echo "  Ctrl-b d       - Detach (session keeps running)"
echo "  $PROJECT_DIR/scripts/stop.sh $PROJECT - Graceful shutdown"
echo "================================"
echo ""

# Select the orchestrator pane and attach
tmux select-pane -t "$SESSION:orch.2"
tmux attach -t "$SESSION"
