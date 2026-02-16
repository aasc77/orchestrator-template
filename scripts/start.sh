#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SESSION="devqa"
MCP_CONFIG="$PROJECT_DIR/claude-code-mcp-config.json"

# ============================================================
# CONFIGURE THESE: Agent working directories
# Point each agent at the repo it should work in.
# ============================================================
DEV_DIR="$HOME/your-project"          # <-- Dev agent's repo
QA_DIR="$HOME/your-project-tests"     # <-- QA agent's repo

# System prompts for agents
DEV_PROMPT="You are the Dev agent. Check your messages using the check_messages MCP tool with role 'dev' to get your task assignment. Follow the instructions in your CLAUDE.md."
QA_PROMPT="You are the QA agent. Check your messages using the check_messages MCP tool with role 'qa' to get test requests. Follow the instructions in your CLAUDE.md."

echo "Multi-Agent Dev/QA Orchestrator"
echo "================================"
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
    echo "Run ./scripts/setup.sh first"
    exit 1
fi
echo "  MCP config OK"

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
rm -f "$PROJECT_DIR/shared/mailbox/to_dev/"*.json 2>/dev/null || true
rm -f "$PROJECT_DIR/shared/mailbox/to_qa/"*.json 2>/dev/null || true
echo "  Mailboxes cleared"

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

# Start orchestrator
tmux send-keys -t "$SESSION:orch" "python3 orchestrator.py" Enter
echo "  Orchestrator started"

# Start Dev agent (interactive Claude Code with MCP config)
# Unset CLAUDECODE to avoid "nested session" error when launched from within Claude Code
tmux send-keys -t "$SESSION:dev" "unset CLAUDECODE && claude --mcp-config $MCP_CONFIG --system-prompt \"$DEV_PROMPT\"" Enter
echo "  Dev agent started"

# Start QA agent (interactive Claude Code with MCP config)
tmux send-keys -t "$SESSION:qa" "unset CLAUDECODE && claude --mcp-config $MCP_CONFIG --system-prompt \"$QA_PROMPT\"" Enter
echo "  QA agent started"

# --- Merge into single window with split panes ---
echo ""
echo "Merging windows into split-pane layout..."

# Join dev and qa windows into the orch window as panes
# Layout: dev and qa side by side on top, orch full-width on bottom
tmux join-pane -s "$SESSION:dev" -t "$SESSION:orch" -v -b
tmux join-pane -s "$SESSION:qa" -t "$SESSION:orch.0" -h
echo "  Layout applied"

# --- Pane styling ---
echo "Applying pane styling..."

# Enable pane border labels
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #{?pane_active,#[bold],#[dim]}#{pane_title} "

# Set pane titles (pane 0=dev, 1=qa, 2=orch)
tmux select-pane -t "$SESSION:orch.0" -T "DEV"
tmux select-pane -t "$SESSION:orch.1" -T "QA"
tmux select-pane -t "$SESSION:orch.2" -T "ORCH"

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
echo "Session '$SESSION' is running!"
echo ""
echo "Panes:"
echo "  0: DEV   - Dev agent (top-left)        [dark blue bg]"
echo "  1: QA    - QA agent (top-right)        [near-black bg]"
echo "  2: ORCH  - Orchestrator (bottom)       [near-black bg]"
echo ""
echo "Navigation:"
echo "  Click      - Switch panes (mouse enabled)"
echo "  Ctrl-b q   - Show pane numbers"
echo "  Ctrl-b o   - Cycle to next pane"
echo "  Ctrl-b ;   - Toggle last active pane"
echo "  Ctrl-b d   - Detach (session keeps running)"
echo "  ./scripts/stop.sh - Graceful shutdown"
echo "================================"
echo ""

# Select the orchestrator pane and attach
tmux select-pane -t "$SESSION:orch.2"
tmux attach -t "$SESSION"
