"""Bounded transcript tails for Codex rollouts too large for app-server JSONL.

``thread/read`` has no pagination: ``includeTurns`` is all-or-nothing.  The
app-server also writes one JSON response per line, so a sufficiently large
task cannot cross CoFleet's bounded JSONL transport.  This module reads only a
small suffix of Codex's own rollout and exposes the final conversational pair.
It never reads authentication, reasoning contents, tool inputs, or tool output.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
from typing import Any, Dict, List, Optional, Tuple


_SESSION_ID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


class CodexRolloutTranscriptTail:
    """Find and decode a bounded user/assistant tail from one Codex task."""

    def __init__(
        self,
        codex_state_path: pathlib.Path,
        *,
        large_rollout_threshold: int = 8 * 1024 * 1024,
        maximum_tail_bytes: int = 16 * 1024 * 1024,
        maximum_line_bytes: int = 2 * 1024 * 1024,
    ) -> None:
        self.codex_state_path = pathlib.Path(codex_state_path).expanduser()
        self.large_rollout_threshold = max(1, int(large_rollout_threshold))
        self.maximum_tail_bytes = max(1, int(maximum_tail_bytes))
        self.maximum_line_bytes = max(1, int(maximum_line_bytes))

    def read_if_large(self, session_id: str) -> Optional[List[Dict[str, Any]]]:
        path = self._rollout_path(session_id)
        if path is None:
            return None
        try:
            size = path.stat().st_size
        except OSError:
            return None
        if size <= self.large_rollout_threshold:
            return None
        messages = self._messages(path, size)
        if not messages:
            return None
        turn_id = "tail_" + session_id
        items = []
        for role, message_id, text in messages:
            digest = hashlib.sha256((role + "\0" + text).encode("utf-8")).hexdigest()[:24]
            items.append(
                {
                    "id": message_id or ("tail_item_" + digest),
                    "turnID": turn_id,
                    "type": "userMessage" if role == "user" else "agentMessage",
                    "role": role,
                    "text": text,
                    "status": "completed",
                    "title": None,
                    "detail": None,
                }
            )
        return [{"id": turn_id, "status": "completed", "error": None, "items": items}]

    def _rollout_path(self, session_id: str) -> Optional[pathlib.Path]:
        if not isinstance(session_id, str) or _SESSION_ID.fullmatch(session_id) is None:
            return None
        suffix = session_id.lower() + ".jsonl"
        candidates: List[pathlib.Path] = []
        sessions = self.codex_state_path / "sessions"
        archived = self.codex_state_path / "archived_sessions"
        if sessions.is_dir():
            candidates.extend(sessions.glob("*/*/*/*" + suffix))
        if archived.is_dir():
            candidates.extend(archived.glob("*" + suffix))
            candidates.extend(archived.glob("*/*/*/*" + suffix))
        for candidate in candidates[:8]:
            try:
                if candidate.is_file() and not candidate.is_symlink():
                    return candidate
            except OSError:
                continue
        return None

    def _messages(self, path: pathlib.Path, size: int) -> List[Tuple[str, Optional[str], str]]:
        start = max(0, size - self.maximum_tail_bytes)
        try:
            with path.open("rb") as stream:
                stream.seek(start)
                raw = stream.read(self.maximum_tail_bytes)
        except OSError:
            return []
        if start > 0:
            newline = raw.find(b"\n")
            raw = raw[newline + 1 :] if newline >= 0 else b""

        assistant: Optional[Tuple[str, Optional[str], str]] = None
        user: Optional[Tuple[str, Optional[str], str]] = None
        for encoded in reversed(raw.splitlines()):
            if not encoded or len(encoded) > self.maximum_line_bytes:
                continue
            try:
                envelope = json.loads(encoded)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            message = self._conversation_message(envelope)
            if message is None:
                continue
            if assistant is None and message[0] == "assistant":
                assistant = message
                continue
            if message[0] == "user":
                user = message
                break
        if user is None:
            return []
        return [user] + ([assistant] if assistant is not None else [])

    @staticmethod
    def _conversation_message(
        envelope: Any,
    ) -> Optional[Tuple[str, Optional[str], str]]:
        if not isinstance(envelope, dict) or envelope.get("type") != "response_item":
            return None
        payload = envelope.get("payload")
        if not isinstance(payload, dict) or payload.get("type") != "message":
            return None
        role = payload.get("role")
        if role not in ("user", "assistant"):
            return None
        content = payload.get("content")
        if not isinstance(content, list):
            return None
        pieces: List[str] = []
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") not in ("input_text", "output_text", "text"):
                continue
            text = part.get("text")
            if isinstance(text, str) and text:
                pieces.append(text)
        text = "\n".join(pieces).strip()
        if not text:
            return None
        message_id = payload.get("id")
        return role, message_id if isinstance(message_id, str) else None, text
