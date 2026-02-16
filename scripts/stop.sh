#!/bin/bash

SESSION="devqa"

echo "Stopping Dev/QA Orchestrator"
echo "============================"
echo ""

# Check if session exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "No '$SESSION' tmux session found."
    # Clean up any orphaned processes anyway
    pkill -f "python3 orchestrator.py" 2>/dev/null && echo "Killed orphaned orchestrator process" || true
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
pkill -f "python3 orchestrator.py" 2>/dev/null && echo "  Killed orphaned orchestrator" || true

echo ""
echo "Shutdown complete."
