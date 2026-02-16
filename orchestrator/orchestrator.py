#!/usr/bin/env python3
"""
Multi-Agent Orchestrator (tmux + MCP/Mailbox)

Coordinates Dev and QA Claude Code agents through the shared mailbox.
Uses tmux send-keys to nudge agents when new messages arrive.

Flow:
  1. Orchestrator writes task assignment to Dev's mailbox
  2. tmux_nudge("dev") sends "check your messages" to Dev's terminal
  3. Dev picks it up, codes, calls send_to_qa
  4. Orchestrator sees new message in QA's mailbox
  5. Orchestrator writes "go test" instruction to QA's mailbox
  6. tmux_nudge("qa") sends "check your messages" to QA's terminal
  7. QA picks it up, tests, calls send_to_dev
  8. Orchestrator sees results in Dev's mailbox, asks LLM what to do
  9. Repeat until pass or stuck
"""

import json
import subprocess
import time
import logging
import sys
import yaml
from pathlib import Path

from llm_client import OllamaClient
from mailbox_watcher import MailboxWatcher

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

# --- Load Config ---
config_path = Path(__file__).parent / "config.yaml"
with open(config_path) as f:
    config = yaml.safe_load(f)

# --- Initialize Components ---
llm = OllamaClient(
    base_url=config["llm"]["base_url"],
    model=config["llm"]["model"],
    disable_thinking=config["llm"].get("disable_thinking", False),
)

mailbox_dir = str(Path(__file__).parent / config["polling"]["mailbox_dir"])
mailbox = MailboxWatcher(mailbox_dir=mailbox_dir)

# --- Load Tasks ---
tasks_path = Path(__file__).parent / config["tasks"]["file"]
with open(tasks_path) as f:
    tasks_data = json.load(f)

tasks = tasks_data["tasks"]

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


def tmux_nudge(agent: str):
    """Send a nudge to an agent's tmux pane via send-keys.

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
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "-l", tmux_nudge_prompt],
            capture_output=True, text=True, timeout=5,
        )
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True, text=True, timeout=5,
        )
        _last_nudge[agent] = now
        logger.info(f"Nudged {agent} via tmux send-keys")
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
            capture_output=True, text=True, timeout=5,
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


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
    logger.info(f"📤 Wrote {msg_type} to {recipient}'s mailbox ({msg_id})")
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


def assign_task_to_dev(task: dict):
    """Write a task assignment to Dev's mailbox."""
    content = {
        "task_id": task["id"],
        "title": task["title"],
        "description": task["description"],
        "acceptance_criteria": task.get("acceptance_criteria", []),
        "instructions": (
            "Implement this task. When done, use the send_to_qa MCP tool "
            "to notify QA with a summary, files changed, and test instructions."
        ),
    }
    write_to_mailbox("dev", "task_assignment", content)
    task["status"] = "in_progress"
    save_tasks()
    logger.info(f"Assigned task {task['id']} to Dev")
    tmux_nudge("dev")


def handle_qa_message(message: dict):
    """Handle a message from QA (test results arriving in Dev's mailbox)."""
    idx, task = get_current_task()
    if not task:
        logger.warning("Received QA message but no active task")
        return

    task["attempts"] += 1
    content = message.get("content", {})
    status = content.get("status", "unknown")

    context = build_context("qa_results", {
        "status": status,
        "summary": content.get("summary", ""),
        "bugs": content.get("bugs", []),
        "tests_run": content.get("tests_run", ""),
    })

    decision = llm.decide(context)
    action = decision.get("action", "flag_human")

    if action == "next_task":
        task["status"] = "completed"
        save_tasks()
        logger.info(f"✅ Task {task['id']} COMPLETED")

        next_idx, next_task = get_current_task()
        if next_task:
            assign_task_to_dev(next_task)
        else:
            logger.info("ALL TASKS COMPLETED!")
            write_to_mailbox("dev", "all_done", {"message": "All tasks complete! Great work."})
            write_to_mailbox("qa", "all_done", {"message": "All tasks complete! Great work."})
            tmux_nudge("dev")
            tmux_nudge("qa")

    elif action == "send_to_dev":
        if task["attempts"] >= config["tasks"]["max_attempts_per_task"]:
            logger.warning(f"⚠️ Task {task['id']} exceeded max attempts")
            task["status"] = "stuck"
            save_tasks()
            print(f"\n🚨 HUMAN REVIEW NEEDED: Task {task['id']} - {task['title']}")
            print(f"   Failed {task['attempts']} times. Check orchestrator.log.\n")
        else:
            fix_msg = decision.get("message", "QA found bugs. Check messages and fix.")
            write_to_mailbox("dev", "fix_required", {
                "task_id": task["id"],
                "message": fix_msg,
                "bugs": content.get("bugs", []),
                "instructions": (
                    "Fix the issues reported by QA. When done, use send_to_qa "
                    "again to notify QA for re-testing."
                ),
            })
            tmux_nudge("dev")
            logger.info(f"Task {task['id']} attempt {task['attempts']} - sent back to Dev")

    elif action == "flag_human":
        task["status"] = "stuck"
        save_tasks()
        msg = decision.get("message", "Unknown issue")
        print(f"\n🚨 HUMAN REVIEW NEEDED: {msg}\n")
        logger.warning(f"Flagged for human: {msg}")


def handle_dev_message(message: dict):
    """Handle a message from Dev (code ready, arriving in QA's mailbox)."""
    content = message.get("content", {})

    # Write instruction to QA's mailbox
    write_to_mailbox("qa", "test_request", {
        "summary": content.get("summary", ""),
        "files_changed": content.get("files_changed", []),
        "test_instructions": content.get("test_instructions", ""),
        "instructions": (
            "New code is ready for testing. Use check_messages to see what "
            "Dev built and how to test it. Run your tests and use send_to_dev "
            "to report results (pass/fail/partial with bug details)."
        ),
    })
    tmux_nudge("qa")
    logger.info("Notified QA of new code ready for testing")


def main():
    """Main orchestrator loop."""
    logger.info("=" * 60)
    logger.info("Multi-Agent Orchestrator Starting (tmux + MCP/Mailbox)")
    logger.info("=" * 60)

    # Pre-flight: check LLM
    if not llm.health_check():
        logger.error("Ollama is not running or model not available!")
        logger.error(f"   Run: ollama pull {config['llm']['model']}")
        sys.exit(1)
    logger.info(f"LLM ready ({config['llm']['model']})")
    logger.info(f"Mailbox dir: {mailbox_dir}")

    # Detect tmux session
    if check_tmux_session():
        logger.info(f"tmux session '{tmux_session}' detected — nudges enabled")
    else:
        logger.info(f"tmux session '{tmux_session}' not found — agents must poll manually")

    # Assign first task
    idx, first_task = get_current_task()
    if first_task:
        logger.info(f"Starting with task: {first_task['title']}")
        assign_task_to_dev(first_task)
        tmux_nudge("dev")
    else:
        logger.info("No pending tasks found")
        return

    # Main polling loop
    poll_interval = config["polling"]["interval_seconds"]
    logger.info(f"Polling mailbox every {poll_interval}s...")
    logger.info("Agents will be nudged via tmux when new messages arrive.")
    logger.info("")

    try:
        while True:
            # Check for messages from Dev -> QA (Dev sent code for testing)
            for dev_msg in mailbox.check_new_messages("qa"):
                if dev_msg.get("from") != "orchestrator":
                    logger.info(f"📨 Dev sent: {dev_msg['type']}")
                    handle_dev_message(dev_msg)

            # Check for messages from QA -> Dev (QA sent test results)
            for qa_msg in mailbox.check_new_messages("dev"):
                if qa_msg.get("from") != "orchestrator":
                    logger.info(f"📨 QA sent: {qa_msg['type']}")
                    handle_qa_message(qa_msg)

            # Check if all tasks done
            all_done = all(
                t["status"] in ("completed", "stuck") for t in tasks
            )
            if all_done:
                completed = sum(1 for t in tasks if t["status"] == "completed")
                stuck = sum(1 for t in tasks if t["status"] == "stuck")
                logger.info(f"🏁 All tasks processed: {completed} completed, {stuck} stuck")
                break

            time.sleep(poll_interval)

    except KeyboardInterrupt:
        logger.info("Orchestrator stopped by user")
    except Exception as e:
        logger.error(f"Orchestrator crashed: {e}", exc_info=True)


if __name__ == "__main__":
    main()
