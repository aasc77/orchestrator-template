#!/bin/bash
# migrate-comms.sh
# Bridges existing ~/shared-comms/ folder structure to the MCP mailbox system.
# Run this ONCE to connect your existing agents to the new orchestrator.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHARED_COMMS="$HOME/shared-comms"
MCP_MAILBOX="$PROJECT_DIR/shared/mailbox"

echo "🔗 Migrating shared-comms to MCP mailbox"
echo "========================================="
echo ""
echo "Existing:  $SHARED_COMMS"
echo "MCP:       $MCP_MAILBOX"
echo ""

# Check if shared-comms exists
if [ ! -d "$SHARED_COMMS" ]; then
    echo "❌ ~/shared-comms/ not found. Creating it..."
    mkdir -p "$SHARED_COMMS/dev-to-qa"
    mkdir -p "$SHARED_COMMS/qa-to-dev"
fi

# Mapping:
#   dev-to-qa  = messages FROM dev, FOR qa  = to_qa
#   qa-to-dev  = messages FROM qa, FOR dev  = to_dev

echo "Option 1: Symlink MCP mailbox to existing shared-comms (recommended)"
echo "  This makes the MCP bridge read/write to the same folders your agents already use."
echo ""
echo "Option 2: Symlink shared-comms to MCP mailbox"
echo "  This points your old folders at the new MCP location."
echo ""

read -p "Which option? (1 or 2, default 1): " OPTION
OPTION=${OPTION:-1}

if [ "$OPTION" = "1" ]; then
    # Point MCP at existing shared-comms folders
    echo ""
    echo "Linking MCP mailbox → shared-comms..."

    # Remove MCP default dirs if they exist (and are empty)
    rmdir "$MCP_MAILBOX/to_qa" 2>/dev/null || true
    rmdir "$MCP_MAILBOX/to_dev" 2>/dev/null || true

    # Create symlinks
    ln -sf "$SHARED_COMMS/dev-to-qa" "$MCP_MAILBOX/to_qa"
    ln -sf "$SHARED_COMMS/qa-to-dev" "$MCP_MAILBOX/to_dev"

    echo "  ✅ $MCP_MAILBOX/to_qa → $SHARED_COMMS/dev-to-qa"
    echo "  ✅ $MCP_MAILBOX/to_dev → $SHARED_COMMS/qa-to-dev"

elif [ "$OPTION" = "2" ]; then
    # Point shared-comms at MCP mailbox
    echo ""
    echo "Linking shared-comms → MCP mailbox..."

    # Backup existing folders if they have content
    if [ "$(ls -A $SHARED_COMMS/dev-to-qa 2>/dev/null)" ]; then
        echo "  ⚠️  dev-to-qa has files, backing up..."
        mv "$SHARED_COMMS/dev-to-qa" "$SHARED_COMMS/dev-to-qa.bak"
    else
        rmdir "$SHARED_COMMS/dev-to-qa" 2>/dev/null || true
    fi

    if [ "$(ls -A $SHARED_COMMS/qa-to-dev 2>/dev/null)" ]; then
        echo "  ⚠️  qa-to-dev has files, backing up..."
        mv "$SHARED_COMMS/qa-to-dev" "$SHARED_COMMS/qa-to-dev.bak"
    else
        rmdir "$SHARED_COMMS/qa-to-dev" 2>/dev/null || true
    fi

    # Ensure MCP dirs exist
    mkdir -p "$MCP_MAILBOX/to_qa"
    mkdir -p "$MCP_MAILBOX/to_dev"

    # Create symlinks
    ln -sf "$MCP_MAILBOX/to_qa" "$SHARED_COMMS/dev-to-qa"
    ln -sf "$MCP_MAILBOX/to_dev" "$SHARED_COMMS/qa-to-dev"

    echo "  ✅ $SHARED_COMMS/dev-to-qa → $MCP_MAILBOX/to_qa"
    echo "  ✅ $SHARED_COMMS/qa-to-dev → $MCP_MAILBOX/to_dev"
fi

echo ""
echo "✅ Migration complete!"
echo ""
echo "Both the MCP bridge and your existing agents will now"
echo "read/write to the same message folders."
echo ""
echo "Next steps:"
echo "  1. Add MCP tools to both agents:"
echo "     claude mcp add agent-bridge node $PROJECT_DIR/mcp-bridge/index.js"
echo ""
echo "  2. Tell each agent to re-read their CLAUDE.md:"
echo "     Dev: 'Read CLAUDE.md and adopt the new MCP workflow'"
echo "     QA:  'Read CLAUDE.md and adopt the new MCP workflow'"
echo ""
echo "  3. Start the orchestrator:"
echo "     cd $PROJECT_DIR/orchestrator && python3 orchestrator.py"
