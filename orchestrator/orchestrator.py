#!/usr/bin/env python3
"""
RGR (Red-Green-Refactor) Orchestrator (tmux + MCP/Mailbox + Git Worktrees)

Coordinates three Claude Code agents through a shared mailbox and git worktrees:
  - QA (RED): writes failing tests in .worktrees/qa on red/<task> branch
  - Dev (GREEN): writes minimum code in .worktrees/dev on green/<task> branch
  - Refactor (BLUE): cleans up code in .worktrees/refactor on blue/<task> branch

Git flow:
  main ──> red/<task> ──> green/<task> ──> blue/<task> ──> merge into main

Usage:
  python3 orchestrator.py <project>

  where <project> matches a directory under projects/ (e.g., example).
"""

import argparse
import json
import subprocess
import threading
import queue
import time
import logging
import sys
import yaml
from pathlib import Path

from llm_client import OllamaClient
from mailbox_watcher import MailboxWatcher

from enum import Enum

class RGRState(Enum):
    IDLE = "idle"
    WAITING_QA_RED = "waiting_qa_red"
    WAITING_DEV_GREEN = "waiting_dev_green"
    WAITING_REFACTOR_BLUE = "waiting_refactor_blue"
    BLOCKED = "blocked"

# --- Parse CLI args ---
parser = argparse.ArgumentParser(description="RGR Orchestrator")
parser.add_argument("project", help="Project name (matches projects/<name>/)")
args = parser.parse_args()

# --- Resolve paths ---
orchestrator_dir = Path(__file__).parent
root_dir = orchestrator_dir.parent
project_dir = root_dir / "projects" / args.project

if not project_dir.is_dir():
    print(f"Error: Project '{args.project}' not found at {project_dir}")
    print(f"Available projects: {', '.join(p.name for p in (root_dir / 'projects').iterdir() if p.is_dir())}")
    sys.exit(1)

# --- Load & merge configs ---
with open(orchestrator_dir / "config.yaml") as f:
    config = yaml.safe_load(f)

with open(project_dir / "config.yaml") as f:
    project_config = yaml.safe_load(f)

# Deep-merge: project overrides shared (two levels deep so that e.g.
# agents.dev from project config merges with agents.dev defaults rather
# than replacing the entire agents.dev dict).
for key, val in project_config.items():
    if isinstance(val, dict) and key in config and isinstance(config[key], dict):
        merged = {**config[key]}
        for k2, v2 in val.items():
            if isinstance(v2, dict) and k2 in merged and isinstance(merged[k2], dict):
                merged[k2] = {**merged[k2], **v2}
            else:
                merged[k2] = v2
        config[key] = merged
    else:
        config[key] = val

# --- Resolve per-project paths ---
mailbox_dir = str(root_dir / "shared" / args.project / "mailbox")
tasks_path = project_dir / "tasks.json"
repo_dir = config.get("repo_dir", "")
project_mode = config.get("mode", "new")

# --- Setup Logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("orchestrator.log"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)

# --- Initialize Components ---
llm = OllamaClient(
    base_url=config["llm"]["base_url"],
    model=config["llm"]["model"],
    disable_thinking=config["llm"].get("disable_thinking", False),
)

mailbox = MailboxWatcher(mailbox_dir=mailbox_dir)

# --- Load Tasks ---
with open(tasks_path) as f:
    tasks_data = json.load(f)

tasks = tasks_data["tasks"]

rgr_state = RGRState.IDLE

# --- Track current task branch suffix ---
current_task_id = None

# --- tmux nudge config ---
tmux_session = config.get("tmux", {}).get("session_name", "devqa")
tmux_nudge_prompt = config.get("tmux", {}).get(
    "nudge_prompt",
    "You have new messages. Use the check_messages MCP tool with your role to read and act on them.",
)
tmux_nudge_cooldown = config.get("tmux", {}).get("nudge_cooldown_seconds", 30)
# Build agent -> pane target mapping from config
_agent_pane_targets = {}
for agent_name, agent_cfg in config.get("agents", {}).items():
    pane = agent_cfg.get("pane")
    if pane:
        _agent_pane_targets[agent_name] = f"{tmux_session}:{pane}"
_last_nudge = {}


# --- Git helpers ---
def run_git_command(cwd: str, *git_args) -> tuple[bool, str]:
    """Run a git command in the given directory.

    Returns (success, output) tuple.
    """
    cmd = ["git", "-C", cwd] + list(git_args)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            logger.warning(f"Git command failed: {' '.join(cmd)}\n  {output}")
            return False, output
        return True, output
    except subprocess.TimeoutExpired:
        logger.error(f"Git command timed out: {' '.join(cmd)}")
        return False, "Command timed out"
    except subprocess.SubprocessError as e:
        logger.error(f"Git command error: {e}")
        return False, str(e)


def get_default_branch(repo_path: str) -> str:
    """Detect the default branch name (main, master, etc.)."""
    success, output = run_git_command(repo_path, "symbolic-ref", "--short", "HEAD")
    return output.strip() if success else "main"


# Resolve default branch at startup (used by merge operations)
default_branch = get_default_branch(repo_dir) if repo_dir else "main"


def git_merge_branch(worktree_path: str, source_branch: str) -> tuple[bool, str]:
    """Merge a source branch into the current branch of a worktree.

    Returns (success, output). On conflict, aborts the merge.
    """
    success, output = run_git_command(worktree_path, "merge", source_branch, "--no-edit")
    if not success:
        if "CONFLICT" in output or "conflict" in output.lower():
            logger.error(f"Merge conflict merging {source_branch} into {worktree_path}")
            # Abort the failed merge to leave worktree clean
            run_git_command(worktree_path, "merge", "--abort")
            return False, f"MERGE CONFLICT: {output}"
        return False, output
    return True, output


def git_merge_into_default(repo_path: str, source_branch: str) -> tuple[bool, str]:
    """Merge a branch into the default branch in the main repo directory.

    Stashes any uncommitted changes before checkout to prevent
    'untracked working tree files would be overwritten' errors.

    Returns (success, output).
    """
    # Stash any uncommitted changes (including untracked files)
    stashed = False
    _, status_output = run_git_command(repo_path, "status", "--porcelain")
    if status_output.strip():
        success, stash_output = run_git_command(repo_path, "stash", "push", "--include-untracked", "-m", f"orchestrator-auto-stash-before-{source_branch}")
        if success and "No local changes" not in stash_output:
            stashed = True
            logger.info(f"Stashed uncommitted changes in {repo_path}")

    # Ensure we're on the default branch
    success, output = run_git_command(repo_path, "checkout", default_branch)
    if not success:
        if stashed:
            run_git_command(repo_path, "stash", "pop")
        return False, f"Failed to checkout {default_branch}: {output}"

    success, output = run_git_command(repo_path, "merge", source_branch, "--no-edit")
    if not success:
        if "CONFLICT" in output or "conflict" in output.lower():
            logger.error(f"Merge conflict merging {source_branch} into {default_branch}")
            run_git_command(repo_path, "merge", "--abort")
            if stashed:
                run_git_command(repo_path, "stash", "pop")
            return False, f"MERGE CONFLICT: {output}"
        if stashed:
            run_git_command(repo_path, "stash", "pop")
        return False, output

    # Merge succeeded -- drop the stash (merged content supersedes it)
    if stashed:
        run_git_command(repo_path, "stash", "drop")
        logger.info("Dropped auto-stash after successful merge")

    return True, output


def tmux_clear(agent: str):
    """Send /clear to an agent's tmux pane to reset context."""
    target = _agent_pane_targets.get(agent, f"{tmux_session}:{agent}")
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", "/clear"],
            capture_output=True, text=True, timeout=5,
        )
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        logger.info(f"Sent /clear to {agent} (target={target})")
        time.sleep(1)  # Give Claude Code a moment to process
    except subprocess.SubprocessError as e:
        logger.warning(f"Failed to send /clear to {agent}: {e}")


def tmux_nudge(agent: str):
    """Send a nudge to an agent's tmux window via send-keys.

    Includes cooldown to prevent stacking multiple nudges.
    Gracefully degrades if tmux is unavailable or session is gone.
    """
    now = time.time()
    last = _last_nudge.get(agent, 0)
    if now - last < tmux_nudge_cooldown:
        logger.debug(
            f"Skipping nudge to {agent} (cooldown: {int(tmux_nudge_cooldown - (now - last))}s remaining)"
        )
        return

    target = _agent_pane_targets.get(agent, f"{tmux_session}:{agent}")
    try:
        # Send text and Enter separately — Claude Code's TUI needs a brief
        # gap between input and submit for the keypress to register.
        result = subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", tmux_nudge_prompt],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            logger.warning(f"tmux send-keys to {agent} failed (target={target}): {result.stderr.strip()}")
            return
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        _last_nudge[agent] = now
        logger.info(f"Nudged {agent} via tmux send-keys (target={target})")
    except FileNotFoundError:
        logger.warning("tmux not found — nudge skipped (agents must poll manually)")
    except subprocess.TimeoutExpired:
        logger.warning(f"tmux send-keys to {agent} timed out")
    except subprocess.SubprocessError as e:
        logger.warning(f"tmux nudge to {agent} failed: {e}")


def check_tmux_session() -> bool:
    """Check if the tmux session exists."""
    try:
        result = subprocess.run(
            ["tmux", "has-session", "-t", tmux_session],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


# --- Interactive command interface ---
_cmd_queue = queue.Queue()
_paused = False


def _stdin_reader():
    """Background thread that reads stdin and queues commands."""
    while True:
        try:
            line = input()
            if line.strip():
                _cmd_queue.put(line.strip())
        except EOFError:
            break


def send_to_pane(agent: str, text: str):
    """Send arbitrary text to an agent's tmux pane and press Enter."""
    target = _agent_pane_targets.get(agent, f"{tmux_session}:{agent}")
    try:
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", text],
            capture_output=True, text=True, timeout=5,
        )
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        print(f"  Sent to {agent}: {text[:80]}")
    except subprocess.SubprocessError as e:
        print(f"  Failed to send to {agent}: {e}")


def interpret_natural_command(text: str):
    """Use the LLM to interpret a natural language command."""
    idx, task = get_current_task()
    completed = sum(1 for t in tasks if t["status"] == "completed")
    stuck = sum(1 for t in tasks if t["status"] == "stuck")
    pending = sum(1 for t in tasks if t["status"] == "pending")

    system = """You are the orchestrator's command interpreter. The human typed a message in the orchestrator console.
Interpret their intent and respond with JSON only:
{
  "action": "msg_dev" | "msg_qa" | "msg_refactor" | "nudge_dev" | "nudge_qa" | "nudge_refactor" | "skip" | "pause" | "resume" | "status" | "reply",
  "text": "text to send to agent (for msg_dev/msg_qa/msg_refactor) or reply to show the human (for reply/status)",
  "reasoning": "brief explanation"
}

Actions:
- msg_dev: send text to Dev agent's terminal
- msg_qa: send text to QA agent's terminal
- msg_refactor: send text to Refactor agent's terminal
- nudge_dev/nudge_qa/nudge_refactor: remind agent to check messages
- skip: skip current task
- pause/resume: pause/resume polling
- status: show current state (put a summary in "text")
- reply: just respond to the human (for questions, chitchat, etc.)

Keep "text" concise and actionable."""

    context = f"""## Current State
- Current task: {json.dumps(task, indent=2) if task else "None"}
- Completed: {completed}, Pending: {pending}, Stuck: {stuck}, Paused: {_paused}

## Human said:
{text}"""

    decision = llm.decide_with_system(system, context)
    action = decision.get("action", "reply")
    reply_text = decision.get("text", "")

    if action == "msg_dev":
        send_to_pane("dev", reply_text)
    elif action == "msg_qa":
        send_to_pane("qa", reply_text)
    elif action == "msg_refactor":
        send_to_pane("refactor", reply_text)
    elif action == "nudge_dev":
        _last_nudge.pop("dev", None)
        tmux_nudge("dev")
    elif action == "nudge_qa":
        _last_nudge.pop("qa", None)
        tmux_nudge("qa")
    elif action == "nudge_refactor":
        _last_nudge.pop("refactor", None)
        tmux_nudge("refactor")
    elif action == "skip":
        handle_command("skip")
    elif action == "pause":
        handle_command("pause")
    elif action == "resume":
        handle_command("resume")
    elif action == "status":
        if reply_text:
            print(f"\n  {reply_text}\n")
        else:
            handle_command("status")
    elif action == "reply":
        print(f"\n  {reply_text}\n")
    else:
        fallback = "Sorry, I didn't understand that."
        print(f"\n  {reply_text or fallback}\n")


def handle_command(cmd: str):
    """Process an interactive command."""
    global _paused
    parts = cmd.split(None, 2)
    command = parts[0].lower()

    if command == "help":
        print("\n--- RGR Orchestrator Commands ---")
        print("  status                    - Current task and progress")
        print("  tasks                     - List all tasks with status")
        print("  skip                      - Skip current stuck/in-progress task")
        print("  nudge dev|qa|refactor     - Manually nudge an agent")
        print("  msg dev|qa|refactor TEXT  - Send text to an agent's pane")
        print("  pause                     - Pause mailbox polling")
        print("  resume                    - Resume mailbox polling")
        print("  log                       - Show last 10 log entries")
        print("  help                      - Show this help")
        print("----------------------------------\n")

    elif command == "status":
        idx, task = get_current_task()
        completed = sum(1 for t in tasks if t["status"] == "completed")
        stuck = sum(1 for t in tasks if t["status"] == "stuck")
        pending = sum(1 for t in tasks if t["status"] == "pending")
        print(f"\n--- Status ({args.project}) ---")
        print(f"  Completed: {completed}  In-progress: {1 if task else 0}  Pending: {pending}  Stuck: {stuck}")
        if task:
            print(f"  Current: [{task['id']}] {task['title']}")
            print(f"  Attempts: {task['attempts']}/{config['tasks']['max_attempts_per_task']}")
        else:
            print("  No active task")
        print(f"  Paused: {_paused}")
        print(f"  RGR State: {rgr_state.value}")
        print(f"  Default branch: {default_branch}")
        if current_task_id:
            print(f"  Branches: red/{current_task_id}, green/{current_task_id}, blue/{current_task_id}")
        print(f"--------------\n")

    elif command == "tasks":
        print("\n--- Tasks ---")
        for t in tasks:
            marker = {"completed": "+", "in_progress": ">", "pending": " ", "stuck": "!"}
            m = marker.get(t["status"], "?")
            print(f"  [{m}] {t['id']}: {t['title']} ({t['status']}, attempts: {t['attempts']})")
        print(f"-------------\n")

    elif command == "skip":
        idx, task = get_current_task()
        if task:
            task["status"] = "stuck"
            save_tasks()
            print(f"  Skipped task {task['id']}: {task['title']}")
            next_idx, next_task = get_current_task()
            if next_task:
                print(f"  Next task: {next_task['id']}: {next_task['title']}")
                assign_task_to_qa(next_task)
            else:
                print("  No more tasks")
        else:
            print("  No active task to skip")

    elif command == "nudge":
        if len(parts) < 2 or parts[1] not in ("dev", "qa", "refactor"):
            print("  Usage: nudge dev|qa|refactor")
        else:
            agent = parts[1]
            _last_nudge.pop(agent, None)  # clear cooldown
            tmux_nudge(agent)

    elif command == "msg":
        if len(parts) < 3 or parts[1] not in ("dev", "qa", "refactor"):
            print("  Usage: msg dev|qa|refactor <text to send>")
        else:
            send_to_pane(parts[1], parts[2])

    elif command == "pause":
        _paused = True
        print("  Polling paused. Type 'resume' to continue.")

    elif command == "resume":
        _paused = False
        print("  Polling resumed.")

    elif command == "log":
        try:
            log_path = Path(__file__).parent / "orchestrator.log"
            lines = log_path.read_text().strip().split("\n")
            print("\n--- Last 10 log entries ---")
            for line in lines[-10:]:
                print(f"  {line}")
            print(f"---------------------------\n")
        except Exception as e:
            print(f"  Could not read log: {e}")

    else:
        # Natural language -- route through LLM
        interpret_natural_command(cmd)


def save_tasks():
    """Persist task state back to file."""
    with open(tasks_path, "w") as f:
        json.dump(tasks_data, f, indent=2)


def get_current_task():
    """Get the current pending or in-progress task."""
    for i, task in enumerate(tasks):
        if task["status"] in ("pending", "in_progress"):
            return i, task
    return None, None


def write_to_mailbox(recipient: str, msg_type: str, content: dict):
    """Write a message directly to an agent's mailbox folder."""
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    msg_id = f"orch-{int(time.time())}-{msg_type}"
    message = {
        "id": msg_id,
        "from": "orchestrator",
        "to": recipient,
        "type": msg_type,
        "content": content,
        "timestamp": timestamp,
        "read": False,
    }

    target_dir = Path(mailbox_dir) / f"to_{recipient}"
    target_dir.mkdir(parents=True, exist_ok=True)
    filepath = target_dir / f"{msg_id}.json"
    filepath.write_text(json.dumps(message, indent=2))
    logger.info(f"Wrote {msg_type} to {recipient}'s mailbox ({msg_id})")
    return message


def build_context(event_type: str, event_data: dict) -> str:
    """Build context string for the LLM decision."""
    idx, current_task = get_current_task()
    remaining = sum(1 for t in tasks if t["status"] == "pending")
    completed = sum(1 for t in tasks if t["status"] == "completed")
    history = mailbox.get_conversation_history()
    recent_history = history[-6:]

    context = f"""## Current State
- Current task: {json.dumps(current_task, indent=2) if current_task else "None"}
- Tasks remaining: {remaining}
- Tasks completed: {completed}
- Task attempts: {current_task['attempts'] if current_task else 0}/{config['tasks']['max_attempts_per_task']}

## Event
Type: {event_type}
Data: {json.dumps(event_data, indent=2)}

## Recent Message History
{json.dumps(recent_history, indent=2) if recent_history else "No messages yet."}

## What should happen next?"""

    return context


def create_task_branches(task_id: str):
    """Create red/green/blue branches for a new task in each worktree.

    Always branches from the default branch (main) to ensure a clean start.
    Deletes stale branches from previous runs before creating.
    """
    if not repo_dir:
        return
    agents_cfg = config.get("agents", {})
    branch_map = {
        "qa": f"red/{task_id}",
        "dev": f"green/{task_id}",
        "refactor": f"blue/{task_id}",
    }
    for agent, branch in branch_map.items():
        wt_dir = agents_cfg.get(agent, {}).get("working_dir", "")
        if not wt_dir:
            continue
        # First checkout the default branch to have a clean base
        run_git_command(wt_dir, "checkout", default_branch)
        # Delete stale branch from previous runs if it exists
        exists, _ = run_git_command(wt_dir, "rev-parse", "--verify", branch)
        if exists:
            run_git_command(wt_dir, "branch", "-D", branch)
            logger.info(f"Deleted stale {branch} in {agent} worktree")
        # Create fresh branch from default branch
        success, output = run_git_command(wt_dir, "checkout", "-b", branch)
        if success:
            logger.info(f"Created {branch} from {default_branch} in {agent} worktree")
        else:
            logger.warning(f"Failed to create {branch} in {agent}: {output}")


def assign_task_to_qa(task: dict):
    """Write a task assignment to QA's mailbox."""
    global rgr_state, current_task_id
    current_task_id = task["id"]

    # Clear agent contexts and create task branches for new tasks
    if current_task_id != task["id"]:
        for agent in ("qa", "dev", "refactor"):
            tmux_clear(agent)
    create_task_branches(task["id"])

    if project_mode == "existing":
        source_file = task.get("source_file", "")
        instructions = (
            f"Write characterization tests for {source_file}. Read the source file from your "
            "worktree, identify all public functions/classes, then write tests that PASS against "
            "the current implementation. When your tests are ready and confirmed PASSING, commit "
            "them with: git add . && git commit -m 'red: characterize <file>' "
            "then use the send_to_dev MCP tool to notify Dev."
        )
        phase_label = "characterization phase"
    else:
        source_file = ""
        instructions = (
            "Write failing tests for this requirement. When your tests are ready "
            "and confirmed FAILING (RED), commit them with: git add . && git commit -m 'red: <description>' "
            "then use the send_to_dev MCP tool to notify Dev."
        )
        phase_label = "RED phase"

    content = {
        "task_id": task["id"],
        "title": task["title"],
        "description": task["description"],
        "acceptance_criteria": task.get("acceptance_criteria", []),
        "instructions": instructions,
    }
    if source_file:
        content["source_file"] = source_file

    write_to_mailbox("qa", "task_assignment", content)
    tmux_nudge("qa")
    task["status"] = "in_progress"
    save_tasks()
    rgr_state = RGRState.WAITING_QA_RED
    logger.info(f"Assigned task {task['id']} to QA ({phase_label})")


def handle_qa_message(message: dict):
    """Handle message from QA: failing tests ready -> merge into Dev, nudge Dev (GREEN phase)."""
    global rgr_state
    idx, task = get_current_task()
    if not task:
        logger.warning("Received QA message but no active task")
        return

    content = message.get("content", {})
    task_id = current_task_id or task["id"]

    # Merge red/<task> branch into Dev worktree
    dev_dir = config.get("agents", {}).get("dev", {}).get("working_dir", "")
    if repo_dir and dev_dir:
        red_branch = f"red/{task_id}"
        logger.info(f"Merging {red_branch} into Dev worktree...")
        success, output = git_merge_branch(dev_dir, red_branch)
        if not success:
            rgr_state = RGRState.BLOCKED
            logger.error(f"Failed to merge {red_branch} into Dev: {output}")
            print(f"\nBLOCKED: Git merge failed ({red_branch} -> Dev)")
            print(f"  {output}")
            print(f"  Resolve manually in {dev_dir} then type 'resume'\n")
            return
        logger.info(f"Merged {red_branch} into Dev worktree successfully")

    # Forward QA's tests to Dev
    if project_mode == "existing":
        dev_instructions = (
            "QA wrote characterization tests that PASS against the existing code. They have been "
            "merged into your worktree. Your job is to VERIFY the tests are correct and thorough -- "
            "NOT to refactor or rewrite the source code. Review the test coverage, add any missing "
            "edge cases, and ensure tests accurately document the current behavior. "
            "Do NOT modify the source code. When done, commit with: "
            "git add . && git commit -m 'green: <description>' then use send_to_refactor."
        )
        phase_label = "characterization review"
    else:
        dev_instructions = (
            "QA has written failing tests (RED) and they have been merged into your worktree. "
            "Write the minimum code to make them pass (GREEN). When all tests pass, commit with: "
            "git add . && git commit -m 'green: <description>' then use send_to_refactor."
        )
        phase_label = "GREEN phase"

    dev_content = {
        "task_id": task["id"],
        "summary": content.get("summary", ""),
        "files_changed": content.get("files_changed", []),
        "test_instructions": content.get("test_instructions", ""),
        "branch": f"red/{task_id}",
        "instructions": dev_instructions,
    }
    source_file = task.get("source_file", "")
    if source_file:
        dev_content["source_file"] = source_file

    write_to_mailbox("dev", "test_request", dev_content)
    tmux_nudge("dev")
    rgr_state = RGRState.WAITING_DEV_GREEN
    logger.info(f"QA tests ready for task {task['id']} -> merged into Dev, forwarded ({phase_label})")


def handle_dev_message(message: dict):
    """Handle message from Dev: code passes tests -> merge into Refactor, nudge Refactor (BLUE phase)."""
    global rgr_state
    content = message.get("content", {})

    idx, task = get_current_task()
    if not task:
        logger.warning("Received Dev message but no active task")
        return

    task_id = current_task_id or task["id"]

    # Merge green/<task> branch into Refactor worktree
    refactor_dir = config.get("agents", {}).get("refactor", {}).get("working_dir", "")
    if repo_dir and refactor_dir:
        green_branch = f"green/{task_id}"
        logger.info(f"Merging {green_branch} into Refactor worktree...")
        success, output = git_merge_branch(refactor_dir, green_branch)
        if not success:
            rgr_state = RGRState.BLOCKED
            logger.error(f"Failed to merge {green_branch} into Refactor: {output}")
            print(f"\nBLOCKED: Git merge failed ({green_branch} -> Refactor)")
            print(f"  {output}")
            print(f"  Resolve manually in {refactor_dir} then type 'resume'\n")
            return
        logger.info(f"Merged {green_branch} into Refactor worktree successfully")

    # Forward Dev's code to Refactor
    if project_mode == "existing":
        refactor_instructions = (
            "Legacy code with characterization tests has been merged into your worktree. "
            "Refactor the legacy code for quality: address TODO comments from QA, improve DRY, "
            "naming, type hints, and docs. All characterization tests must stay GREEN. "
            "Commit with: git add . && git commit -m 'blue: <description>' "
            "then use send_refactor_complete to report results."
        )
        phase_label = "legacy refactor"
    else:
        refactor_instructions = (
            "Dev has written code that passes the tests (GREEN) and it has been merged into your worktree. "
            "Refactor the code for quality (DRY, naming, docs) without changing behavior. Run tests to "
            "verify they still pass. Commit with: git add . && git commit -m 'blue: <description>' "
            "then use send_refactor_complete to report results."
        )
        phase_label = "BLUE phase"

    refactor_content = {
        "task_id": task["id"],
        "summary": content.get("summary", ""),
        "files_changed": content.get("files_changed", []),
        "test_commands": content.get("test_commands", content.get("test_instructions", "")),
        "branch": f"green/{task_id}",
        "instructions": refactor_instructions,
    }
    source_file = task.get("source_file", "")
    if source_file:
        refactor_content["source_file"] = source_file

    write_to_mailbox("refactor", "refactor_request", refactor_content)
    tmux_nudge("refactor")
    rgr_state = RGRState.WAITING_REFACTOR_BLUE
    logger.info(f"Dev code ready for task {task['id']} -> merged into Refactor, forwarded ({phase_label})")


def handle_refactor_message(message: dict):
    """Handle message from Refactor: cleanup done -> merge into main or retry."""
    global rgr_state
    idx, task = get_current_task()
    if not task:
        logger.warning("Received Refactor message but no active task")
        return

    task["attempts"] += 1
    content = message.get("content", {})
    status = content.get("status", "unknown")

    if status == "pass":
        task_id = current_task_id or task["id"]

        # Merge blue/<task> into default branch
        if repo_dir:
            blue_branch = f"blue/{task_id}"
            logger.info(f"Merging {blue_branch} into {default_branch}...")
            success, output = git_merge_into_default(repo_dir, blue_branch)
            if not success:
                rgr_state = RGRState.BLOCKED
                logger.error(f"Failed to merge {blue_branch} into {default_branch}: {output}")
                print(f"\nBLOCKED: Git merge into {default_branch} failed ({blue_branch})")
                print(f"  {output}")
                print(f"  Resolve manually in {repo_dir} then type 'resume'\n")
                return
            logger.info(f"Merged {blue_branch} into {default_branch} successfully")

        # Refactor succeeded -- task complete
        task["status"] = "completed"
        save_tasks()
        rgr_state = RGRState.IDLE
        logger.info(f"Task {task['id']} COMPLETED (RGR cycle done)")

        next_idx, next_task = get_current_task()
        if next_task:
            assign_task_to_qa(next_task)
        else:
            logger.info("ALL TASKS COMPLETED!")
            for agent in ("qa", "dev", "refactor"):
                write_to_mailbox(agent, "all_done", {"message": "All tasks complete! Great work."})
                tmux_nudge(agent)

    elif status == "fail":
        # Refactor broke tests -- send back to Dev
        if task["attempts"] >= config["tasks"]["max_attempts_per_task"]:
            logger.warning(f"Task {task['id']} exceeded max attempts")
            task["status"] = "stuck"
            save_tasks()
            rgr_state = RGRState.IDLE
            print(f"\nHUMAN REVIEW NEEDED: Task {task['id']} - {task['title']}")
            print(f"   Failed {task['attempts']} times. Check orchestrator.log.\n")
        else:
            write_to_mailbox("dev", "fix_required", {
                "task_id": task["id"],
                "message": "Refactor broke tests. Fix the issues and re-send to refactor.",
                "issues": content.get("issues", ""),
                "instructions": (
                    "The Refactor agent's changes broke the tests. Fix the code so tests "
                    "pass again, then commit and use send_to_refactor to hand off for another attempt."
                ),
            })
            tmux_nudge("dev")
            rgr_state = RGRState.WAITING_DEV_GREEN
            logger.info(f"Task {task['id']} attempt {task['attempts']} - refactor failed, back to Dev")

    else:
        # Unknown status -- ask LLM
        context = build_context("refactor_results", {
            "status": status,
            "summary": content.get("summary", ""),
        })
        decision = llm.decide(context)
        action = decision.get("action", "flag_human")

        if action == "flag_human":
            task["status"] = "stuck"
            save_tasks()
            rgr_state = RGRState.IDLE
            msg = decision.get("message", "Unknown issue")
            print(f"\nHUMAN REVIEW NEEDED: {msg}\n")
            logger.warning(f"Flagged for human: {msg}")


def main():
    """Main orchestrator loop."""
    logger.info("=" * 60)
    logger.info(f"RGR Orchestrator Starting — project: {args.project}")
    logger.info("=" * 60)

    # Pre-flight: check LLM
    if not llm.health_check():
        logger.error("Ollama is not running or model not available!")
        logger.error(f"   Run: ollama pull {config['llm']['model']}")
        sys.exit(1)
    logger.info(f"LLM ready ({config['llm']['model']})")
    logger.info(f"Project mode: {project_mode}")
    logger.info(f"Mailbox dir: {mailbox_dir}")
    logger.info(f"Tasks file: {tasks_path}")
    if repo_dir:
        logger.info(f"Repo dir: {repo_dir}")
        logger.info(f"Default branch: {default_branch}")
    else:
        logger.warning("No repo_dir configured — git operations disabled")

    # Pre-flight: check tmux session
    if check_tmux_session():
        logger.info(f"tmux session '{tmux_session}' detected — nudges enabled")
    else:
        logger.warning(f"tmux session '{tmux_session}' not found — nudges will be skipped")

    # Assign first task (if any)
    idx, first_task = get_current_task()
    if first_task:
        logger.info(f"Starting with task: {first_task['title']}")
        assign_task_to_qa(first_task)
    else:
        logger.info("No pending tasks found — waiting for new tasks or commands")

    # Start interactive command reader
    cmd_thread = threading.Thread(target=_stdin_reader, daemon=True)
    cmd_thread.start()

    # Main polling loop
    poll_interval = config["polling"]["interval_seconds"]
    logger.info(f"Polling mailbox every {poll_interval}s...")
    logger.info("Agents will be nudged via tmux when new messages arrive.")
    logger.info("Type 'help' for interactive commands.")
    logger.info("")

    try:
        while True:
            # Process any queued commands
            while not _cmd_queue.empty():
                try:
                    cmd = _cmd_queue.get_nowait()
                    handle_command(cmd)
                except queue.Empty:
                    break

            # Skip mailbox polling if paused
            if not _paused:
                # Check QA's mailbox -- messages from Dev (code ready for testing)
                # In RGR, QA mailbox receives task assignments from orchestrator
                for qa_msg in mailbox.check_new_messages("qa"):
                    if qa_msg.get("from") != "orchestrator":
                        logger.info(f"Message in QA mailbox from {qa_msg.get('from')}: {qa_msg['type']}")

                # Check Dev's mailbox -- messages from QA (tests) or Refactor (results)
                for dev_msg in mailbox.check_new_messages("dev"):
                    sender = dev_msg.get("from", "")
                    if sender == "orchestrator":
                        continue
                    elif sender == "qa":
                        logger.info(f"QA sent tests: {dev_msg['type']}")
                        handle_qa_message(dev_msg)
                    elif sender == "refactor":
                        logger.info(f"Refactor sent results: {dev_msg['type']}")
                        handle_refactor_message(dev_msg)
                    else:
                        logger.info(f"Unknown sender '{sender}' in Dev mailbox: {dev_msg['type']}")

                # Check Refactor's mailbox -- messages from Dev (code ready for refactoring)
                for ref_msg in mailbox.check_new_messages("refactor"):
                    sender = ref_msg.get("from", "")
                    if sender == "orchestrator":
                        continue
                    elif sender == "dev":
                        logger.info(f"Dev sent code to refactor: {ref_msg['type']}")
                        handle_dev_message(ref_msg)
                    else:
                        logger.info(f"Message in Refactor mailbox from {sender}: {ref_msg['type']}")

                # Check if all tasks done
                all_done = all(
                    t["status"] in ("completed", "stuck") for t in tasks
                )
                if all_done and any(t["status"] == "completed" for t in tasks):
                    completed = sum(1 for t in tasks if t["status"] == "completed")
                    stuck = sum(1 for t in tasks if t["status"] == "stuck")
                    logger.info(f"All tasks processed: {completed} completed, {stuck} stuck -- still polling")

            time.sleep(poll_interval)

    except KeyboardInterrupt:
        logger.info("Orchestrator stopped by user")
    except Exception as e:
        logger.error(f"Orchestrator crashed: {e}", exc_info=True)


if __name__ == "__main__":
    main()
