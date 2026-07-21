"""Low-cost filesystem invalidation for turns written by Codex Desktop.

The watcher deliberately treats rollout files as opaque.  It never opens or
parses them: only filename, size, and modification metadata are observed.  The
service uses the extracted opaque task identifier to perform a canonical,
targeted ``thread/read`` through Codex app-server.
"""

from __future__ import annotations

import os
import pathlib
import re
import select
import threading
import time
from typing import Callable, Dict, Iterable, List, Optional, Tuple


ActivityCallback = Callable[[str], None]

_SESSION_ID = re.compile(
    r"(?P<id>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:\.jsonl)?$"
)


def rollout_session_id(path: pathlib.Path) -> Optional[str]:
    """Return only the opaque task ID encoded in a Codex rollout filename."""

    match = _SESSION_ID.search(path.name)
    return match.group("id").lower() if match else None


class CodexFilesystemActivityWatcher:
    """Watch a bounded recent rollout set and report metadata changes.

    ``kqueue`` is used on macOS/BSD.  Other platforms use a bounded stat-only
    scan.  Neither implementation reads rollout bytes, SQLite, or auth files.
    """

    def __init__(
        self,
        roots: Iterable[pathlib.Path],
        callback: ActivityCallback,
        *,
        scan_interval: float = 1.0,
        max_files: int = 256,
        max_directories: int = 4_096,
        max_entries: int = 20_000,
        max_native_descriptors: int = 80,
        use_native: Optional[bool] = None,
    ) -> None:
        self.roots = tuple(pathlib.Path(root).expanduser() for root in roots)
        self.callback = callback
        self.scan_interval = max(0.05, float(scan_interval))
        self.max_files = max(1, int(max_files))
        self.max_directories = max(8, int(max_directories))
        self.max_entries = max(self.max_files, int(max_entries))
        # launchd commonly gives user agents a soft limit of 256 descriptors.
        # Keep the watcher itself comfortably below 96 including its kqueue fd,
        # so HTTP/SSE clients, SQLite, and the Codex child retain headroom.
        self.max_native_descriptors = max(8, min(94, int(max_native_descriptors)))
        self._closed = threading.Event()
        self._rebuild_requested = threading.Event()
        self._tracked_lock = threading.Lock()
        self._tracked_session_ids = set()  # type: set[str]
        parents = {root.parent for root in self.roots}
        self._invalidation_paths = tuple(
            parent / name
            for parent in parents
            for name in (
                "state_5.sqlite-wal",
                "session_index.jsonl",
                ".codex-global-state.json",
            )
        )
        self._native = bool(hasattr(select, "kqueue")) if use_native is None else use_native
        if self._native and not hasattr(select, "kqueue"):
            self._native = False
        self._thread = threading.Thread(
            target=self._run_native if self._native else self._run_stat_fallback,
            name="cofleet-codex-activity",
            daemon=True,
        )
        self._thread.start()

    @property
    def native(self) -> bool:
        return self._native

    def close(self) -> None:
        self._closed.set()
        self._rebuild_requested.set()
        if self._thread is not threading.current_thread():
            self._thread.join(timeout=max(2.0, self.scan_interval * 3.0))

    def track(self, session_id: str) -> None:
        """Prioritize a known task even when its rollout is old."""

        if not isinstance(session_id, str) or not _SESSION_ID.fullmatch(session_id):
            return
        with self._tracked_lock:
            changed = session_id.lower() not in self._tracked_session_ids
            self._tracked_session_ids.add(session_id.lower())
        if changed:
            self._rebuild_requested.set()

    def _candidate_paths(self) -> Tuple[List[pathlib.Path], List[pathlib.Path]]:
        directories: List[pathlib.Path] = []
        files: List[Tuple[int, pathlib.Path]] = []
        visited = 0
        entries_seen = 0
        for root in self.roots:
            if visited >= self.max_directories or entries_seen >= self.max_entries:
                break
            if not root.is_dir():
                continue
            pending = [root]
            while (
                pending
                and visited < self.max_directories
                and entries_seen < self.max_entries
            ):
                directory = pending.pop()
                visited += 1
                directories.append(directory)
                try:
                    entries = os.scandir(directory)
                except OSError:
                    continue
                with entries:
                    for entry in entries:
                        entries_seen += 1
                        if entries_seen > self.max_entries:
                            break
                        try:
                            if entry.is_dir(follow_symlinks=False):
                                pending.append(pathlib.Path(entry.path))
                            elif entry.is_file(follow_symlinks=False):
                                path = pathlib.Path(entry.path)
                                if rollout_session_id(path) is None:
                                    continue
                                stat = entry.stat(follow_symlinks=False)
                                files.append((stat.st_mtime_ns, path))
                        except OSError:
                            continue
        with self._tracked_lock:
            tracked_ids = set(self._tracked_session_ids)
        tracked = [item for item in files if rollout_session_id(item[1]) in tracked_ids]
        recent = [item for item in files if rollout_session_id(item[1]) not in tracked_ids]
        tracked.sort(key=lambda item: item[0], reverse=True)
        recent.sort(key=lambda item: item[0], reverse=True)
        selected = (tracked + recent)[: self.max_files]
        return directories, [path for _, path in selected]

    @staticmethod
    def _metadata(path: pathlib.Path) -> Optional[Tuple[int, int, str]]:
        session_id = rollout_session_id(path)
        if session_id is None:
            return None
        try:
            stat = path.stat()
        except OSError:
            return None
        return stat.st_mtime_ns, stat.st_size, session_id

    def _snapshot(self) -> Dict[pathlib.Path, Tuple[int, int, str]]:
        _, files = self._candidate_paths()
        snapshot: Dict[pathlib.Path, Tuple[int, int, str]] = {}
        for path in files:
            metadata = self._metadata(path)
            if metadata is not None:
                snapshot[path] = metadata
        return snapshot

    def _bounded_native_targets(
        self,
        directories: Iterable[pathlib.Path],
        files: Iterable[pathlib.Path],
    ) -> List[Tuple[pathlib.Path, str]]:
        """Choose a useful kqueue watch set within one hard fd budget.

        Roots and their parents keep hierarchy creation discoverable, while
        Codex index/WAL files invalidate the catalog. Rollout files arrive in
        tracked-then-recent order from ``_candidate_paths``; each one is added
        only with the directory chain required to discover its replacement.
        A periodic metadata reconciliation remains the fallback for older
        rollouts that do not fit in the immediate native set.
        """

        limit = self.max_native_descriptors
        discovered_directories = set(directories)
        targets: List[Tuple[pathlib.Path, str]] = []
        selected = set()  # type: set[pathlib.Path]

        def add(path: pathlib.Path, kind: str) -> bool:
            if path in selected:
                return True
            if len(targets) >= limit:
                return False
            selected.add(path)
            targets.append((path, kind))
            return True

        # A root event discovers a new year/month/day hierarchy. Its parent is
        # also needed when Codex replaces or recreates the root itself.
        for root in self.roots:
            for directory in (root.parent, root):
                if directory.is_dir() and not add(directory, "directory"):
                    return targets

        # These files cheaply signal app-server/catalog changes that are not a
        # direct append to one of the selected rollout files.
        for path in self._invalidation_paths:
            if path.is_file() and not add(path, "invalidation"):
                return targets

        roots_by_depth = sorted(
            self.roots,
            key=lambda path: len(path.parts),
            reverse=True,
        )
        for path in files:
            anchor = next(
                (
                    root
                    for root in roots_by_depth
                    if path.parent == root or root in path.parent.parents
                ),
                None,
            )
            if anchor is None:
                continue

            chain: List[pathlib.Path] = []
            parent = path.parent
            while True:
                chain.append(parent)
                if parent == anchor:
                    break
                parent = parent.parent
            chain.reverse()

            additions = [directory for directory in chain if directory not in selected]
            if path not in selected:
                additions.append(path)
            if len(targets) + len(additions) > limit:
                continue
            for directory in chain:
                add(directory, "directory")
            add(path, "rollout")

        # Spend any remaining budget on shallow discovered directories. This
        # improves new-task discovery without displacing tracked/recent files.
        remaining_directories = sorted(
            discovered_directories - selected,
            key=lambda path: (len(path.parts), str(path)),
        )
        for directory in remaining_directories:
            if not add(directory, "directory"):
                break
        return targets

    def _notify(self, session_id: Optional[str]) -> None:
        if not session_id or self._closed.is_set():
            return
        try:
            self.callback(session_id)
        except Exception:
            # Filesystem notification must never take down the host service.
            pass

    def _run_stat_fallback(self) -> None:
        previous = self._snapshot()
        while not self._closed.wait(self.scan_interval):
            current = self._snapshot()
            for path, metadata in current.items():
                if previous.get(path) != metadata:
                    self._notify(metadata[2])
            previous = current

    def _run_native(self) -> None:
        # kqueue reports which opaque rollout changed, avoiding directory scans
        # during normal append-heavy turns. Directory events only rebuild the
        # bounded watch set to discover a newly-created task.
        kqueue = select.kqueue()
        descriptors: Dict[int, Tuple[pathlib.Path, str]] = {}
        snapshot = self._snapshot()

        def close_descriptors() -> None:
            for descriptor in tuple(descriptors):
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            descriptors.clear()

        def rebuild() -> None:
            close_descriptors()
            directories, files = self._candidate_paths()
            open_flag = getattr(os, "O_EVTONLY", os.O_RDONLY)
            note_mask = (
                select.KQ_NOTE_WRITE
                | select.KQ_NOTE_EXTEND
                | select.KQ_NOTE_ATTRIB
                | select.KQ_NOTE_RENAME
                | select.KQ_NOTE_DELETE
            )
            changes = []
            for path, kind in self._bounded_native_targets(directories, files):
                try:
                    descriptor = os.open(path, open_flag)
                except OSError:
                    continue
                descriptors[descriptor] = (path, kind)
                changes.append(
                    select.kevent(
                        descriptor,
                        filter=select.KQ_FILTER_VNODE,
                        flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                        fflags=note_mask,
                    )
                )
            if changes:
                try:
                    kqueue.control(changes, 0, 0)
                except OSError:
                    close_descriptors()

        try:
            rebuild()
            last_rebuild = time.monotonic()
            while not self._closed.is_set():
                try:
                    changes = kqueue.control(None, max(1, len(descriptors)), self.scan_interval)
                except OSError:
                    changes = []
                refresh = self._rebuild_requested.is_set()
                if refresh:
                    self._rebuild_requested.clear()
                if time.monotonic() - last_rebuild >= 30.0:
                    refresh = True
                for change in changes:
                    target = descriptors.get(int(change.ident))
                    if target is None:
                        continue
                    path, kind = target
                    if kind in ("directory", "invalidation"):
                        refresh = True
                    else:
                        self._notify(rollout_session_id(path))
                        metadata = self._metadata(path)
                        if metadata is not None:
                            snapshot[path] = metadata
                        if change.fflags & (select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE):
                            refresh = True
                if refresh and not self._closed.is_set():
                    current = self._snapshot()
                    for path, metadata in current.items():
                        if snapshot.get(path) != metadata:
                            self._notify(metadata[2])
                    snapshot = current
                    rebuild()
                    last_rebuild = time.monotonic()
        finally:
            close_descriptors()
            kqueue.close()
