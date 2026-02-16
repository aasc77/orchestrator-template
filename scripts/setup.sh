#!/bin/bash
set -e

echo "🔧 Multi-Agent Dev/QA Setup"
echo "=========================="

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Check prerequisites
echo ""
echo "Checking prerequisites..."

command -v tmux >/dev/null 2>&1 || { echo "❌ tmux not found. Install: brew install tmux"; exit 1; }
echo "  ✅ tmux"

command -v node >/dev/null 2>&1 || { echo "❌ Node.js not found. Install: brew install node"; exit 1; }
echo "  ✅ Node.js $(node --version)"

command -v python3 >/dev/null 2>&1 || { echo "❌ Python3 not found."; exit 1; }
echo "  ✅ Python3 $(python3 --version)"

command -v claude >/dev/null 2>&1 || { echo "❌ Claude Code not found. Install: npm install -g @anthropic-ai/claude-code"; exit 1; }
echo "  ✅ Claude Code"

command -v ollama >/dev/null 2>&1 || { echo "❌ Ollama not found. Install: brew install ollama"; exit 1; }
echo "  ✅ Ollama"

# Pull orchestrator model
echo ""
echo "Pulling orchestrator LLM model..."
ollama pull qwen3:8b

# Install MCP bridge dependencies
echo ""
echo "Installing MCP bridge dependencies..."
cd "$PROJECT_DIR/mcp-bridge"
npm install

# Install orchestrator dependencies
echo ""
echo "Installing orchestrator dependencies..."
cd "$PROJECT_DIR/orchestrator"
pip install -r requirements.txt --break-system-packages 2>/dev/null || pip install -r requirements.txt

# Create shared directories
echo ""
echo "Creating shared directories..."
mkdir -p "$PROJECT_DIR/shared/mailbox/to_dev"
mkdir -p "$PROJECT_DIR/shared/mailbox/to_qa"
mkdir -p "$PROJECT_DIR/shared/workspace"

# Update MCP config with actual path
echo ""
echo "Configuring MCP bridge..."
MCP_CONFIG="$PROJECT_DIR/claude-code-mcp-config.json"
if grep -q "REPLACE_WITH_ABSOLUTE_PATH" "$MCP_CONFIG" 2>/dev/null; then
    sed "s|REPLACE_WITH_ABSOLUTE_PATH_TO_multi-agent-dev-qa|$PROJECT_DIR|g" "$MCP_CONFIG" > "$MCP_CONFIG.tmp" && mv "$MCP_CONFIG.tmp" "$MCP_CONFIG"
fi

echo ""
echo "📋 MCP Config (add to your Claude Code settings):"
cat "$MCP_CONFIG"

echo ""
echo "To add MCP to Claude Code, run:"
echo "  claude mcp add agent-bridge node $PROJECT_DIR/mcp-bridge/index.js"

# Test MCP bridge
echo ""
echo "Testing MCP bridge..."
cd "$PROJECT_DIR/mcp-bridge"
node test.js

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Add MCP server to Claude Code (see above)"
echo "  2. Edit tasks.json with your tasks"
echo "  3. Run: ./scripts/start.sh"
