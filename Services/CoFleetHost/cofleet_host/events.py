"""Durable event publication and SSE wakeups."""

import threading
from typing import Any, Dict, List, Optional, Tuple

from .database import Database


class EventBroker:
    def __init__(self, database: Database) -> None:
        self.database = database
        self._condition = threading.Condition()

    def publish(self, event_type: str, data: Dict[str, Any]) -> Dict[str, Any]:
        event = self.database.append_event(event_type, data)
        with self._condition:
            self._condition.notify_all()
        return event

    def replay(self, after_id: int, limit: int = 200) -> Tuple[List[Dict[str, Any]], bool]:
        return self.database.events_after(after_id, limit)

    def wait(self, timeout: float) -> None:
        with self._condition:
            self._condition.wait(timeout)
