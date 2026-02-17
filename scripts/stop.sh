#!/bin/bash

PROJECT=${1:?"Usage: ./scripts/stop.sh <project>  (e.g., example)"}

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_CONFIG="$PROJECT_DIR/projects/$PROJECT/config.yaml"

# Read session name from project config
if [ -f "$PROJECT_CONFIG" ]; then
    SESSION=$(python3 -c "import yaml; print(yaml.safe_load(open('$PROJECT_CONFIG'))['tmux']['session_name'])")
else
    echo "Warning: Project config not found at $PROJECT_CONFIG, using '$PROJECT' as session name"
    SESSION="$PROJECT"
fi

echo "Stopping Dev/QA Orchestrator (project: $PROJECT)"
echo "============================"
echo ""

# Check if session exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "No '$SESSION' tmux session found."
    # Clean up any orphaned processes anyway
    pkill -fx "python3 orchestrator.py $PROJECT" 2>/dev/null && echo "Killed orphaned orchestrator process" || true
    exit 0
fi

# Step 1: Send /exit to Claude Code agents (panes in merged layout)
# Try pane references first (merged layout), fall back to window names (legacy)
echo "Sending /exit to Dev agent..."
tmux send-keys -t "$SESSION:orch.0" "/exit" Enter 2>/dev/null \
    || tmux send-keys -t "$SESSION:dev" "/exit" Enter 2>/dev/null || true

echo "Sending /exit to QA agent..."
tmux send-keys -t "$SESSION:orch.1" "/exit" Enter 2>/dev/null \
    || tmux send-keys -t "$SESSION:qa" "/exit" Enter 2>/dev/null || true

# Step 2: Wait for agents to exit gracefully
echo "Waiting 5s for agents to shut down..."
sleep 5

# Step 3: Stop orchestrator with Ctrl-C
echo "Stopping orchestrator..."
tmux send-keys -t "$SESSION:orch.2" C-c 2>/dev/null \
    || tmux send-keys -t "$SESSION:orch" C-c 2>/dev/null || true
sleep 2

# Step 4: Kill the tmux session
echo "Killing tmux session '$SESSION'..."
tmux kill-session -t "$SESSION" 2>/dev/null && echo "  Session killed" || echo "  Session already gone"

# Step 5: Clean up any orphaned processes
pkill -fx "python3 orchestrator.py $PROJECT" 2>/dev/null && echo "  Killed orphaned orchestrator" || true

echo ""
echo "Shutdown complete."
