"""Watch the shared mailbox directories for new messages."""

import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)


class MailboxWatcher:
    def __init__(self, mailbox_dir: str):
        self.mailbox_dir = Path(mailbox_dir)
        self.to_dev_dir = self.mailbox_dir / "to_dev"
        self.to_qa_dir = self.mailbox_dir / "to_qa"
        self._processed = set()

        # Ensure dirs exist
        self.to_dev_dir.mkdir(parents=True, exist_ok=True)
        self.to_qa_dir.mkdir(parents=True, exist_ok=True)

    def check_new_messages(self, recipient: str) -> list:
        """Check for unread messages for a recipient."""
        target_dir = self.to_dev_dir if recipient == "dev" else self.to_qa_dir
        new_messages = []

        for f in sorted(target_dir.glob("*.json")):
            if f.stem in self._processed:
                continue
            try:
                msg = json.loads(f.read_text())
                if not msg.get("read", False):
                    new_messages.append(msg)
                    self._processed.add(f.stem)
            except (json.JSONDecodeError, IOError) as e:
                logger.warning(f"Failed to read message {f}: {e}")

        if new_messages:
            logger.info(
                f"Found {len(new_messages)} new message(s) for {recipient}"
            )
        return new_messages

    def get_latest_message(self, recipient: str):
        """Get the most recent unprocessed message."""
        messages = self.check_new_messages(recipient)
        if messages:
            return max(messages, key=lambda m: m.get("timestamp", ""))
        return None

    def clear_mailbox(self, recipient: str):
        """Clear all messages for a recipient."""
        target_dir = self.to_dev_dir if recipient == "dev" else self.to_qa_dir
        for f in target_dir.glob("*.json"):
            f.unlink()
        logger.info(f"Cleared mailbox for {recipient}")

    def get_conversation_history(self) -> list:
        """Get all messages in chronological order for context."""
        all_messages = []
        for d in [self.to_dev_dir, self.to_qa_dir]:
            for f in d.glob("*.json"):
                try:
                    msg = json.loads(f.read_text())
                    all_messages.append(msg)
                except (json.JSONDecodeError, IOError):
                    pass
        return sorted(all_messages, key=lambda m: m.get("timestamp", ""))
