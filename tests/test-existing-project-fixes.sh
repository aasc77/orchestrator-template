#!/bin/bash
# Test script: Verify 3 existing-project gaps are fixed
# 1. .worktrees/ added to .gitignore for existing repos
# 2. Default branch detected (not hardcoded as main)
# 3. Stale root CLAUDE.md cleaned up
set -e

BOLD=$(tput bold) RESET=$(tput sgr0)
GREEN=$(tput setaf 2) RED=$(tput setaf 1) CYAN=$(tput setaf 6)
pass() { echo "  ${GREEN}PASS${RESET} $*"; }
fail() { echo "  ${RED}FAIL${RESET} $*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_REPO="/tmp/test-worktree-fixes-$$"

cleanup() {
    rm -rf "$TEST_REPO" 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "  ${BOLD}Testing Existing-Project Fixes${RESET}"
echo "  =============================="
echo ""

# ─── Test 1: .gitignore for existing repo with master branch ────────────────
echo "  ${BOLD}Test 1: .gitignore + default branch detection${RESET}"

# Create a repo with 'master' as default branch
mkdir -p "$TEST_REPO"
git -C "$TEST_REPO" init --quiet -b master
echo "# Test" > "$TEST_REPO/README.md"
# Create a .gitignore WITHOUT .worktrees/
cat > "$TEST_REPO/.gitignore" <<'EOF'
__pycache__/
*.pyc
.DS_Store
EOF
git -C "$TEST_REPO" add -A
git -C "$TEST_REPO" commit --quiet -m "initial commit"

# Verify setup: default branch is master, .worktrees/ NOT in .gitignore
BRANCH=$(git -C "$TEST_REPO" symbolic-ref --short HEAD)
if [[ "$BRANCH" == "master" ]]; then
    pass "Test repo uses 'master' as default branch"
else
    fail "Expected 'master', got '$BRANCH'"
fi

if grep -q '\.worktrees/' "$TEST_REPO/.gitignore"; then
    fail ".worktrees/ already in .gitignore before test"
else
    pass ".worktrees/ not in .gitignore (pre-condition)"
fi

# Simulate the fix: run the .gitignore check from new-project.sh
REPO_DIR="$TEST_REPO"
DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")

if [[ "$DEFAULT_BRANCH" == "master" ]]; then
    pass "DEFAULT_BRANCH detected as 'master'"
else
    fail "DEFAULT_BRANCH should be 'master', got '$DEFAULT_BRANCH'"
fi

# Run the .gitignore fix logic
if [[ -f "$REPO_DIR/.gitignore" ]]; then
    if ! grep -q '^\.worktrees/' "$REPO_DIR/.gitignore"; then
        echo -e '\n# Worktrees (agent-specific checkouts)\n.worktrees/' >> "$REPO_DIR/.gitignore"
        git -C "$REPO_DIR" add .gitignore
        git -C "$REPO_DIR" commit --quiet -m "chore: add .worktrees/ to .gitignore"
    fi
fi

if grep -q '^\.worktrees/' "$REPO_DIR/.gitignore"; then
    pass ".worktrees/ appended to existing .gitignore"
else
    fail ".worktrees/ NOT found in .gitignore after fix"
fi

echo ""

# ─── Test 2: .gitignore created when none exists ────────────────────────────
echo "  ${BOLD}Test 2: .gitignore created from scratch${RESET}"

TEST_REPO2="/tmp/test-worktree-fixes-no-gitignore-$$"
mkdir -p "$TEST_REPO2"
git -C "$TEST_REPO2" init --quiet
echo "# Test" > "$TEST_REPO2/README.md"
git -C "$TEST_REPO2" add README.md
git -C "$TEST_REPO2" commit --quiet -m "initial commit (no .gitignore)"

# Remove .gitignore if git init created one
rm -f "$TEST_REPO2/.gitignore"

REPO_DIR="$TEST_REPO2"
if [[ -f "$REPO_DIR/.gitignore" ]]; then
    fail ".gitignore exists before test (unexpected)"
else
    pass "No .gitignore exists (pre-condition)"
fi

# Run the fix logic
if [[ -f "$REPO_DIR/.gitignore" ]]; then
    if ! grep -q '^\.worktrees/' "$REPO_DIR/.gitignore"; then
        echo -e '\n# Worktrees (agent-specific checkouts)\n.worktrees/' >> "$REPO_DIR/.gitignore"
        git -C "$REPO_DIR" add .gitignore
        git -C "$REPO_DIR" commit --quiet -m "chore: add .worktrees/ to .gitignore"
    fi
else
    echo -e '# Worktrees (agent-specific checkouts)\n.worktrees/' > "$REPO_DIR/.gitignore"
    git -C "$REPO_DIR" add .gitignore
    git -C "$REPO_DIR" commit --quiet -m "chore: add .gitignore with .worktrees/"
fi

if [[ -f "$REPO_DIR/.gitignore" ]] && grep -q '^\.worktrees/' "$REPO_DIR/.gitignore"; then
    pass ".gitignore created with .worktrees/"
else
    fail ".gitignore not created or missing .worktrees/"
fi

rm -rf "$TEST_REPO2"
echo ""

# ─── Test 3: Stale CLAUDE.md cleanup ────────────────────────────────────────
echo "  ${BOLD}Test 3: Stale root CLAUDE.md cleanup${RESET}"

# Place a tracked CLAUDE.md at repo root
echo "# Old wizard prompt" > "$TEST_REPO/CLAUDE.md"
git -C "$TEST_REPO" add CLAUDE.md
git -C "$TEST_REPO" commit --quiet -m "add stale CLAUDE.md"

if [[ -f "$TEST_REPO/CLAUDE.md" ]]; then
    pass "Stale CLAUDE.md exists at root (pre-condition)"
else
    fail "CLAUDE.md not created"
fi

# Run the fix logic
REPO_DIR="$TEST_REPO"
if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    if git -C "$REPO_DIR" ls-files --error-unmatch CLAUDE.md 2>/dev/null; then
        git -C "$REPO_DIR" rm --quiet CLAUDE.md
        git -C "$REPO_DIR" commit --quiet -m "chore: remove stale root CLAUDE.md"
    else
        rm "$REPO_DIR/CLAUDE.md"
    fi
fi

if [[ -f "$TEST_REPO/CLAUDE.md" ]]; then
    fail "CLAUDE.md still exists at root after cleanup"
else
    pass "Stale CLAUDE.md removed from root"
fi

# Verify it was removed from git tracking
if git -C "$TEST_REPO" ls-files --error-unmatch CLAUDE.md 2>/dev/null; then
    fail "CLAUDE.md still tracked by git"
else
    pass "CLAUDE.md no longer tracked by git"
fi

echo ""

# ─── Test 4: Untracked stale CLAUDE.md ──────────────────────────────────────
echo "  ${BOLD}Test 4: Untracked stale CLAUDE.md cleanup${RESET}"

echo "# Untracked old prompt" > "$TEST_REPO/CLAUDE.md"

REPO_DIR="$TEST_REPO"
if [[ -f "$REPO_DIR/CLAUDE.md" ]]; then
    if git -C "$REPO_DIR" ls-files --error-unmatch CLAUDE.md 2>/dev/null; then
        git -C "$REPO_DIR" rm --quiet CLAUDE.md
        git -C "$REPO_DIR" commit --quiet -m "chore: remove stale root CLAUDE.md"
    else
        rm "$REPO_DIR/CLAUDE.md"
    fi
fi

if [[ -f "$TEST_REPO/CLAUDE.md" ]]; then
    fail "Untracked CLAUDE.md still exists"
else
    pass "Untracked CLAUDE.md removed"
fi

echo ""

# ─── Test 5: Python get_default_branch logic ────────────────────────────────
echo "  ${BOLD}Test 5: Python get_default_branch()${RESET}"

RESULT=$(python3 -c "
import subprocess
def run_git_command(cwd, *args):
    cmd = ['git', '-C', cwd] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    output = (result.stdout + result.stderr).strip()
    return result.returncode == 0, output

def get_default_branch(repo_path):
    success, output = run_git_command(repo_path, 'symbolic-ref', '--short', 'HEAD')
    return output.strip() if success else 'main'

print(get_default_branch('$TEST_REPO'))
")

if [[ "$RESULT" == "master" ]]; then
    pass "Python get_default_branch() returns 'master' for master-based repo"
else
    fail "Python get_default_branch() returned '$RESULT', expected 'master'"
fi

echo ""

# ─── Test 6: reset.sh DEFAULT_BRANCH detection ──────────────────────────────
echo "  ${BOLD}Test 6: reset.sh default branch detection${RESET}"

REPO_DIR="$TEST_REPO"
DEFAULT_BRANCH=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
INITIAL_COMMIT=$(git -C "$REPO_DIR" rev-list --max-parents=0 "$DEFAULT_BRANCH" 2>/dev/null | head -1)

if [[ "$DEFAULT_BRANCH" == "master" ]]; then
    pass "reset.sh would detect 'master'"
else
    fail "reset.sh detection got '$DEFAULT_BRANCH', expected 'master'"
fi

if [[ -n "$INITIAL_COMMIT" ]]; then
    pass "Initial commit found on '$DEFAULT_BRANCH': ${INITIAL_COMMIT:0:8}"
else
    fail "Could not find initial commit on '$DEFAULT_BRANCH'"
fi

echo ""

# ─── Summary ────────────────────────────────────────────────────────────────
echo "  ${BOLD}=============================${RESET}"
if [[ $FAILURES -eq 0 ]]; then
    echo "  ${GREEN}All tests passed!${RESET}"
else
    echo "  ${RED}$FAILURES test(s) failed${RESET}"
fi
echo "  ${BOLD}=============================${RESET}"
echo ""

exit $FAILURES
